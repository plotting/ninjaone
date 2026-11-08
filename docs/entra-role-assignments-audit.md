# Entra Role Assignments Audit — NinjaOne Automation

Built 2026-08-14, rearchitected same day after rollout problems. Report-only automation that audits current Entra ID directory role assignments per Client tenant, resolved via Partner Center, written into NinjaOne **organization-level** custom fields.

## Current architecture (v2.1) — central script via NinjaOne API, with org-name auto-match

Runs as **one centrally-scheduled script** on a single utility device — NOT deployed per organization. Mirrors `Set-CoveBackupRollup-NinjaOrg.ps1`'s architecture exactly, because the same constraint applies: **`Ninja-Property-Set` cannot write Organization-level custom fields at all** — only Device-level. Organization-level reads/writes go through the NinjaOne public API (OAuth 2.0 client credentials).

Script file: `Set-EntraRoleAssignmentsAudit-NinjaOrg.ps1` (renamed from the old per-org `Entra-Role-Assignments-Audit.ps1`, which is retired).

Flow: authenticate to NinjaOne API once → GET all organizations → for each org, GET its custom fields via API → if `Entra Roles Partner Center Org Name` is blank, try an **auto-match** (v2.1, new): compare the NinjaOne organization's name to the cached Partner Center customer list using the same whitespace/case-insensitive normalization already used for manual matching; if exactly one Partner Center customer's company name is an exact match, write that customer's Microsoft ID back to `Entra Roles Partner Center Org Name` via the API and continue processing that org in the same run — if 0 or 2+ customers match exactly, skip silently, same as always (auto-match never guesses). If still blank after that, skip silently (not every Client is onboarded) → otherwise resolve the Partner Center tenant (cached customer list, fetched once) → Graph pull (per-tenant) → PATCH `Entra Roles Report` and `Entra Roles Changelog` via API. A single organization's failure is logged and skipped — never fatal to the run (explicit user decision, matching Cove's convention). Only a total inability to start (credential/auth failure) exits non-zero.

Auto-match is gated by `$AutoMatchByExactOrgName = $true` (toggle to disable) and respects the existing `$WriteToNinja` dry-run flag — in dry-run it logs what it *would* write but doesn't write it, then still proceeds to build (not persist) that org's report so a dry run gives a full preview. The run summary line now reports a fourth count: organizations auto-mapped by exact org name, alongside processed/skipped/failed.

Example from the field (2026-08-18): NinjaOne org "Blue Skies of Texas" had a blank mapping field but matched Partner Center customer "Blue Skies of Texas" (Microsoft ID `6ae24ffe-5239-4502-be56-22df5156d0a8`) exactly — auto-match writes that GUID into the field and the org gets processed that same run instead of requiring a manual fill-in first.

## Custom fields

| Field name | Type | Level | Purpose |
|---|---|---|---|
| Entra Roles Partner Center Org Name | Text | Organization | Read via NinjaOne API. Blank = auto-match attempted first (v2.1), then org silently skipped if still unresolved. **Now also written by the script** (auto-match), not read-only. **Also reused as-is by the MFA Enrollment Posture Audit automation (2026-08-25)** — that automation reads/writes this exact field rather than creating a second mapping field; see `claude/mfa-posture-ninjaone-build.md`. |
| Entra Roles Report | WYSIWYG | Organization | Write via NinjaOne API (PATCH, `{html: ...}` shape). |
| Entra Roles Changelog | Multi-line text | Organization | Read + write via NinjaOne API. |
| Entra Roles Partner Client Secret | Secure | Global | Read via Ninja-Property-Get (still works — Global fields aren't the problem, only Organization-level ones are). **Also reused by the MFA Enrollment Posture Audit automation.** |
| Entra Roles Graph Client Secret | Secure | Global | Read via Ninja-Property-Get. **Also reused by the MFA Enrollment Posture Audit automation — that automation additionally requires `UserAuthenticationMethod.Read.All` added to this app registration's permissions and re-consented per tenant**, on top of the permissions this automation already needed. |
| ninjaoneInstance / ninjaoneClientId / ninjaoneClientSecret | Text/Secure/Secure | Global | **Reused from the Cove roll-up automation** — same NinjaOne API app and credentials, by explicit user choice, rather than a second app. Also reused by the MFA Enrollment Posture Audit automation. |

**Field permission gotcha (v2.0, updated in v2.1):** each Organization-level field's own Permissions tab needs API access enabled — separate from and in addition to the OAuth app's `monitoring`/`management` scopes. As of v2.1, `Entra Roles Partner Center Org Name` needs **API = Read/Write** (not just Read) because auto-match now writes to it. `Entra Roles Report`/`Entra Roles Changelog` still need Read/Write. Easy to miss since the per-org version only ever needed Automations permission.

**NinjaOne API app (client credentials) setup:** Application platform = "API Services (machine-to-machine)"; Scopes = Monitoring + Management (not Control); Allowed grant types = Client credentials only (uncheck Authorization code, leave Refresh token unchecked). Reused from Cove — no second app needed. Scopes control what the app can call at all; per-field API Read/Write permissions (above) are a separate, additional gate.

## Bugs found and fixed (chronological — real production incidents)

1. **PowerShell array-unwrapping bug.** Windows PowerShell 5.1 collapses a single-item `Where-Object` result to a bare object (no `.Count`), so `.Count -eq 1` silently evaluated false even on a clean single match. Fixed with `@(...)` wrapping everywhere. (Still present/needed in v2.0's `Resolve-PartnerCenterCustomer`, and reused in v2.1's auto-match block.)
2. **Device-vs-Organization field scope.** Originally diagnosed as "Report/Changelog fields were accidentally created as Device scope" — partially right (the specific error text confirmed the fields *were* Device-scoped), but the deeper truth surfaced later: **this doesn't matter, because `Ninja-Property-Set` can't write Organization-scoped fields at all**, confirmed by Cove's own script documentation. This is what actually forced the v2.0 rearchitecture.
3. **Global-scope Secure field appeared empty** — still being diagnosed with the user when the API rearchitecture request came in (screenshots showed the field's Inheritance tab correctly set to System/no override, so likely just needed the value entered in the right admin location, not a scope bug like #2). Worth checking this is resolved once the new script is deployed.

## Key decisions

- **No allow-list / no flagging** — report-only, no "Unauthorized Found" checkbox.
- **NinjaOne API app and credentials are shared with Cove**, not duplicated — user's explicit choice.
- **Per-organization failures never fail the whole run** — user's explicit choice (matches Cove exactly). Only startup-level failures (NinjaOne API auth, Partner Center auth, missing credentials) exit non-zero.
- Client/tenant IDs (PartnerClientId, PartnerTenantId, GraphClientId) stay hardcoded — not secrets. Both client secrets live in Global Secure custom fields.
- **Auto-match only ever acts on an exact, unambiguous org-name match** (v2.1) — never partial/fuzzy, and never overwrites a field that already has a value. Ambiguity always falls back to silent skip, consistent with the rest of the script's "never guess" posture.
- MFA data was originally out of scope for this script (separate mechanism elsewhere); org-level field pattern confirmed as the right shape for that if/when built. **Built 2026-08-25 as its own automation** — MFA Enrollment Posture Audit — which deliberately reuses this automation's mapping field and shared credential fields rather than folding into this report. See `claude/mfa-posture-ninjaone-build.md`.

## Deliverables

- Script: `Set-EntraRoleAssignmentsAudit-NinjaOrg.ps1` (delivered to user, syntax-validated with pwsh 7.4.6 ParseFile after every revision, including the v2.1 auto-match addition)
- SOP: [SOP: NinjaOne — Entra Role Assignments Audit Deployment & Operation](https://bridgeheadit.atlassian.net/wiki/spaces/BIT/pages/1795358721) (v2.0 — pending v2.1 update for auto-match + field permission change)
- Runbook: [Runbook: NinjaOne — Entra Role Assignments Audit Operations & Troubleshooting](https://bridgeheadit.atlassian.net/wiki/spaces/BIT/pages/1795391489) (v2.0, Scenarios A–E cover skip/failure/API cases — pending v2.1 update for auto-match)
- **Sibling automation**: [SOP: NinjaOne — MFA Enrollment Posture Audit Deployment & Operation](https://bridgeheadit.atlassian.net/wiki/spaces/BIT/pages/1814200322/SOP+NinjaOne+MFA+Enrollment+Posture+Audit+Deployment+Operation) / [Runbook](https://bridgeheadit.atlassian.net/wiki/spaces/BIT/pages/1814265857/Runbook+NinjaOne+MFA+Enrollment+Posture+Audit+Operations+Troubleshooting) (2026-08-25) — reuses this automation's mapping field and Global Secure credentials; not a companion of this automation, cross-referenced as a sibling on both sides.

## Open follow-up

- Update SOP and Runbook Confluence pages to v2.1: document the auto-match behavior, the `Entra Roles Partner Center Org Name` permission change (Read → Read/Write), and the new summary count/log lines.
- Confirm the NinjaOne API GET response shape for organization custom fields (Text vs WYSIWYG vs Multi-line) matches what `Get-NinjaOrgFieldValue` assumes — not verified against a live tenant response, only inferred from the PATCH shape Cove's script already validated. Check this on first real run.
- Confirm each of the three Organization-level fields' Permissions tab has API access enabled — new requirement in v2.0, easy to miss. `Entra Roles Partner Center Org Name` specifically needs upgrading from Read to Read/Write for v2.1's auto-match to work.
- Add `UserAuthenticationMethod.Read.All` to the shared Graph app registration (client ID `65343291-651c-48c9-bfce-85b17b41e949`) and re-consent per tenant — required by the new sibling MFA Posture automation, not by this one, but it's the same app registration so do this once, not twice.
