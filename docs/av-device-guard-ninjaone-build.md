# Advanced Antivirus & Device Guard — NinjaOne Automation

Split out from the LAPS build thread (that conversation had both automations tangled together). This doc is the standalone reference for the **Server - Advanced Antivirus** automation (`AVvanced.ps1`) going forward — start new AV/Device Guard work from this doc, not the LAPS one.

## Automation overview

Report-only NinjaOne automation. Never changes AV state or Device Guard state itself — it only reads and reports.

- Script: `AVvanced.ps1` (NinjaOne script/automation name: **Server - Advanced Antivirus**)
- Alert fields (two, independent of each other — see "AV/Device Guard split" below):
  - `AVUnhealthyFound` (Checkbox, Device) — AV-only. Trips true if any of the five AV health conditions is met (four original + expected-product-missing, added 2026-09-03).
  - `AVDeviceGuardUnhealthyFound` (Checkbox, Device) — Device Guard-only. Trips true only when Device Guard is required for the org, the device isn't exempt, and it isn't running.
- Informational-only field (does NOT alert, does NOT affect any verdict): `AVDuplicateProductsFound` (Checkbox, Device) — see "Expected AV product + duplicate detection" below.
- Report field: `AVHealthReport` (WYSIWYG, Device) — full HTML report using NinjaOne's native CSS classes (card, info-card, stat-card, tag, row success/warning/danger). Renders as two sections — an AV section and a Device Guard section — each with its own verdict banner. The AV section also carries an "Expected antivirus product" card (when AVExpectedProduct is configured) and a "Multiple antivirus products enabled" card (when duplicates are found).
- Changelog field: per-device changelog custom field, with categories including `DeviceGuardMissing`, `ExpectedProductMissing`, `DuplicateProductsFound`
- Non-zero exit code as a secondary alert channel (fires if either AV or Device Guard is unhealthy — duplicate-product detection never affects this), same convention as other BIT NinjaOne scripts

## Health conditions

**AV (`AVUnhealthyFound` trips on ANY of):**
1. No enabled AV product registered with Windows Security Center
2. Real-time protection off
3. Definitions stale — older than `MaxDefinitionAgeDays` script variable (default 3 days)
4. Active threat present — `Get-MpThreat`, **filtered to `IsActive = true` only** (this excludes already-remediated threats that `Get-MpThreat` still returns — was a specific fix requested: "only trigger if the threat is active too")
5. **(Added 2026-09-03)** `AVExpectedProduct` is configured for the org AND that product wasn't detected on this device — see below. Skipped entirely when the field is blank.

**Device Guard (`AVDeviceGuardUnhealthyFound` trips only when ALL of):**
1. Device Guard required for the org (`AVDeviceGuardRequired`)
2. Device not exempt (`AVDeviceGuardExempt`)
3. Device Guard not currently running

**Informational only, never a verdict/alert:** `AVDuplicateProductsFound` — more than one AV product registered AND enabled at once. See below.

## Expected AV product + duplicate detection (2026-09-03)

Jeff asked for two more things: (1) a field for what AV solution is *expected*, so a device flags unhealthy if that specific product isn't installed even when some other AV is present and healthy; (2) the ability to flag duplicate/multiple AV products installed, explicitly **not** as unhealthy for now — "begin to surface it as an option."

- **New field**: `AVExpectedProduct` (Text, **Organization**, READ) — free text naming the product/vendor keyword this org is standardized on (e.g. "SentinelOne", "Microsoft Defender"). Same org-level inheritance pattern as `AVDeviceGuardRequired`/`AVDeviceGuardExempt` — no per-device lookup code needed. **Blank = check skipped entirely** — never treated as "expected nothing."
- **Matching logic**: new `Test-ExpectedProductPresent` helper — case-insensitive substring match in both directions (configured keyword vs. each registered product's DisplayName), with wildcard metacharacters escaped via `[System.Management.Automation.WildcardPattern]::Escape()` so a stray `*`/`[` typed into the field can't misbehave. Falls back to treating Defender-platform presence as a match when the expected name contains "defender" and Security Center returned nothing at all (covers Windows Server, which has no `root\SecurityCenter2` namespace to enumerate).
- **When configured and not found**: adds an AV reason (factors into `AVUnhealthyFound`, same mechanism as the other four AV conditions) and a changelog entry under a new `ExpectedProductMissing` category. Report gets a dedicated "Expected antivirus product" card (green/found or red/not-found) — always shown when configured, same "visibility doesn't depend on the gate" posture as the Device Guard card.
- **New field**: `AVDuplicateProductsFound` (Checkbox, Device, WRITE) — set true when more than one Security-Center-registered product is *enabled* at once. **Deliberately NOT wired into `AVUnhealthyFound` or the exit code** — written independently every run regardless of the AV verdict, logged to changelog under a new `DuplicateProductsFound` category, and surfaced via its own report card ("Multiple antivirus products enabled," neutral/informational styling, explicitly states it doesn't affect health). This was an explicit scope decision: surface it first, decide whether to alert on it later once it's clear how often it actually fires across the fleet. No NinjaOne Custom Field Condition should be created on it yet.
- Detection is Security-Center-based only (same enumeration source as everything else AV-product-related) — so, like the rest of that enumeration, it's a no-op on Server SKUs with no Security Center namespace.
- Governance: added an Approvals row (Engineering Lead) for setting/changing `AVExpectedProduct` at the org level, matching the existing threshold-change/DeviceGuard-requirement approval pattern. Runbook got a new scenario F (expected product not detected, with a naming-mismatch-vs-real-gap diagnostic step) and new Escalation items (scoping a device out of `AVExpectedProduct`, and any future request to start alerting on `AVDuplicateProductsFound`).
- Script re-validated with the PowerShell 7.4.6 parser after these changes — no syntax errors, all new variables/fields consistently wired (verified via grep across the whole file).

## AV/Device Guard split (2026-08-28)

Jeff asked to separate the two so each triggers through its own mechanism instead of one shared `AVUnhealthyFound` checkbox, while keeping both in the same WYSIWYG report with each verdict "its own."

- **New field**: `AVDeviceGuardUnhealthyFound` (Checkbox, Device, WRITE) — the Device Guard-only alert trigger. `AVUnhealthyFound` no longer factors Device Guard into its verdict; it trips on the AV conditions only.
- **Script internals**: `Get-AvHealthAssessment` tracks `AvReasons` and `DeviceGuardReasons` as separate lists, with independent `IsAvUnhealthy` / `IsDeviceGuardUnhealthy` verdicts (`IsUnhealthy` kept as the OR of both, used only for the exit code and the combined one-line `AVStatusSummary` text field). Main script writes both checkboxes independently every run, and on an unhandled exception sets *both* flags true (previously only `AVUnhealthyFound`) since neither verdict could be confirmed.
- **Report**: `New-AvReport` builds two separate verdict banners (`info-card` blocks) — an AV banner near the top (using `AvReasons`), and a Device Guard banner placed directly above the Device Guard detail card (using `DeviceGuardReasons`, three states: unhealthy/red, running/green, or neutral/informational when not required or exempt). The AV-related cards (products, expected-product, duplicate-products, Defender detail, active threats, recent detections) are grouped together before the Device Guard banner+card.
- **Exit code**: single non-zero exit (1) if *either* verdict is unhealthy, 2 on unhandled exception. The two checkboxes are what give each condition its own NinjaOne alert; the exit code remains just the secondary channel.
- **NinjaOne admin-side change required**: existing deployments need a **second Custom Field Condition** created on `AVDeviceGuardUnhealthyFound` (operator: is checked) — the old single condition on `AVUnhealthyFound` no longer covers Device Guard. Documented as a required setup step (warning panel) in the SOP's Procedure section.
- Script delivered via SendUserFile each session (file_uuid will go stale across sessions — ask Jeff to re-attach if a future session needs the current source and doesn't have it on disk).

## Device Guard (renamed from "Credential Guard" 2026-08-17)

- Org-level opt-in: `AVDeviceGuardRequired` (Checkbox, **Organization**, READ) — inherited automatically to every device in the org via `Ninja-Property-Get`, no special per-device lookup needed (same pattern as `LAPSauthorizedLocalAdmins`)
- Device-level exemption override: `AVDeviceGuardExempt` (Checkbox, Device, READ)
- **The underlying technical check did NOT change with the rename** — when asked whether to broaden it to overall VBS or add HVCI, the explicit choice made was "just rename it." The script still queries `Win32_DeviceGuard` (namespace `root\Microsoft\Windows\DeviceGuard`) via `Get-CimInstance` and specifically evaluates the **Credential Guard security service** (`SecurityServicesRunning` bit 1) — not HVCI (bit 2), not overall VBS status. This distinction is preserved in code comments and in the Confluence Definitions entry for technical accuracy, even though everything user-facing now says "Device Guard."
- **Report always shows the real on/off status**, regardless of whether the org requires it — this was a bug fix from an earlier revision. Only the color/severity and the `AVDeviceGuardUnhealthyFound` verdict are gated by org-requirement.
- **Health verdict (`AVDeviceGuardUnhealthyFound`) only trips when: org requires it AND device is not exempt AND it's not running.** Visibility and severity are decoupled — one shared helper (`Get-DeviceGuardTileInfo`) computes both the stat tile and the report card's detail so they never disagree.

## Custom fields (current, post-2026-09-03)

| Field | Type | Level | Purpose |
|---|---|---|---|
| AVHealthReport | WYSIWYG | Device | WRITE. Full HTML report — AV section (incl. expected-product/duplicate cards) + Device Guard section, each with its own verdict banner. |
| AVUnhealthyFound | Checkbox | Device | WRITE. AV-only alert trigger (now 5 conditions). |
| AVDeviceGuardUnhealthyFound | Checkbox | Device | WRITE. Device Guard-only alert trigger, independent of AVUnhealthyFound. |
| AVDuplicateProductsFound | Checkbox | Device | WRITE. **Informational only** — does not affect AVUnhealthyFound or the exit code. |
| AVStatusSummary | Text | Device | WRITE. One-line combined status (device-list column). |
| AV changelog field | Multi-line | Device | READ+WRITE. Per-run history; categories include DeviceGuardMissing, ExpectedProductMissing, DuplicateProductsFound. |
| AVDeviceGuardRequired | Checkbox | Organization | READ. Org opt-in for the Device Guard check. |
| AVDeviceGuardExempt | Checkbox | Device | READ. Per-device exemption override. |
| AVExpectedProduct | Text | Organization | READ. Optional — product/vendor keyword this org is standardized on. Blank = check skipped. |

## Key decisions / bugs fixed (across all revisions)

- **Expected AV product + duplicate detection** (2026-09-03, latest revision) — see above.
- **AV/Device Guard alert split** (2026-08-28) — see above.
- **Function-hoisting bug**: `fmtDate`/`fmtBool` were originally defined only inside a conditional block in `New-AvReport`; the Device Guard card needed them unconditionally. Fixed by hoisting both (plus a new `fmtNeutralBool`) to the top of the function.
- **Report-vs-alert gating bug** (real, user-caught from a live screenshot): the report was hiding Device Guard's actual on/off state whenever the org didn't require it. Fixed so the report always shows real status; only the alert/verdict stays gated by org-requirement + non-exemption + not-running.
- **Credential Guard → Device Guard rename** (custom fields, variables, function names, report labels, comments, both Confluence docs) — done as a pure rename, not a scope change. The one exception kept verbatim: the literal Windows GPO checkbox name "Credential Guard Configured" (under Device Guard → Turn On Virtualization Based Security), since that's Microsoft's own UI label, not our naming.
- Validated with a real PowerShell 7.4.6 parser (`[System.Management.Automation.Language.Parser]::ParseFile()`) downloaded directly from GitHub releases (Microsoft's own package repo, `packages.microsoft.com`, returns 403 in this environment).

## Confluence docs

- SOP: [SOP: NinjaOne — Advanced Antivirus Deployment & Operation](https://bridgeheadit.atlassian.net/wiki/spaces/BIT/pages/1789231152) — page `1789231152`, currently **v1.7 / API version 9** (added AVExpectedProduct + AVDuplicateProductsFound: Definitions, field table (now 9 fields), Procedure (new Alert criteria row + panel-note clarifying AVDuplicateProductsFound is NOT an alert condition), Approvals and sign-offs (new row); change log preserves v1.0–1.6 verbatim with a new v1.7 row)
- Runbook: [Runbook: NinjaOne — Advanced Anti-virus Alert Remediation](https://bridgeheadit.atlassian.net/wiki/spaces/BIT/pages/1793654926) — page `1793654926`, currently **v1.5 / API version 7** (new scenario F, updated When to Use table + Diagnosis priority order + Verification + Escalation, new Preconditions note about AVDuplicateProductsFound; revision history preserves v1.0–1.4 verbatim with a new v1.5 row)
- Both still correctly cross-link to each other as companion SOP/Runbook (links preserved verbatim from the 2026-08-16/17 crosslink audit — see `claude/ninjaone-sop-runbook-crosslink-audit.md` — and untouched by any subsequent revision)

## Status as of 2026-09-03 (end of session)

Script now covers five things independently: AV health (`AVUnhealthyFound`), Device Guard (`AVDeviceGuardUnhealthyFound`), an optional expected-AV-product check (folded into `AVUnhealthyFound`), and duplicate-AV detection (`AVDuplicateProductsFound`, informational only, not wired to any alert). All fields written every run, all surfaced in the same `AVHealthReport` WYSIWYG field. Script, SOP, and Runbook are all published/delivered.

**Outstanding, NinjaOne-admin-side (not scriptable from here):**
1. Any Client/policy already running this automation needs a second Custom Field Condition on `AVDeviceGuardUnhealthyFound` (from the 2026-08-28 split) if it doesn't have one yet.
2. `AVExpectedProduct` is opt-in per organization (blank = skipped) — someone needs to actually go set it per Client in NinjaOne if/where desired; nothing fires until it's populated.
3. `AVDuplicateProductsFound` intentionally has **no** Custom Field Condition yet — don't create one without an explicit decision to start alerting on it (see Runbook Escalation).

The script itself was last delivered via SendUserFile in this session — if a new session needs the current `AVvanced.ps1` source and doesn't have it on disk, ask Jeff to re-attach it rather than assuming a stale file_uuid still resolves.
