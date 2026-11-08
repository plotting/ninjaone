# Quest Rapid Recovery backup monitoring integration (2026-08-19)

## What this is

Jeff asked to replicate the Cove Data Protection ↔ NinjaOne integration (see `cove-backup-monitoring-integration.md`) for Quest Rapid Recovery, starting from a Quest support-doc link (blocked to automated fetch by their bot protection) and an SDK he downloaded to `D:\Downloads\API-Reference-6.11.0-314`. Confirmed via AskUserQuestion: each Client runs its **own separate** Rapid Recovery Core (not a shared partner API like Cove), the deliverable is an **org-level rollup card only** (no per-device card), and Jeff has live Core access to validate against.

## Key technical finding: this is NOT a REST API

Unlike Cove's JSON/REST Partner API, Rapid Recovery's SDK is a **WCF (.NET SOAP-style) client library** — confirmed by exploring the actual SDK contents (1,064 `.htm` + 327 `.xml`/`.xsd` Sandcastle-style reference docs, plus a working C# sample project `AppRecoveryAPISamples` with ~20 vendor DLLs). A PowerShell script must `Add-Type` the vendor DLLs and drive an `ICoreClient` object through .NET interop — there is no `Invoke-RestMethod`-style path. Confirmed directly from the sample code (not guessed):

- Connect: `Replay.Core.Client.CoreClientFactory` → `.Create(uri)` → `ICoreClient`. URI is `https://<host>:<port>/apirecovery/api/core/`, default port **8006**. Auth via `UseSpecificCredentials(NetworkCredential)` or `UseDefaultCredentials()`.
- `AgentsManagement.GetProtectedAgents()` / `GetReplicatedAgents()` / `GetRecoveryPointsOnlyAgents()` / `GetAgents()`
- `BackgroundJobManagement.GetJobs(BackgroundJobSearchParameters)` — filter by `JobStatusFlags.Running` / `.Failed` + `MinStartTime`/`MaxStartTime`; `GetJob(id)` for polling one job to completion.
- `EventsManagement.GetEvents(EventSearchParameters)` / `GetEventsByPage(pageSize,page,search)` / `GetEventsCount(search)` — supports `EventLevels`, `IsAlert`, time range, and free-text/regex `UserSearchRequest`.
- `ProtectedItemsManagement.GetProtectedItems()` — tree of agents/clusters/groups with `IsProtectionPaused`, `IsLicenseExpired`, `RepositoryType`.
- `StatusSummaryManagement.GetDashboardInfo()` / `GetAgentDashboardInfo(id)` / `GetDvmRepositoriesDashboardInfo()` / `GetO3EPhantomRepositoriesDashboardInfo()` / `GetCoreSystemInfo()` / `GetCoreHomeInfo()` (includes `RecentAlerts`, last 10). Per-agent dashboard data includes `HostName` (**real OS hostname**, confirmed distinct from `DisplayName`, the console-editable label) — this is the direct equivalent of the Cove Computer-name/Device-name defect, and the new script matches on `HostName` first for exactly that reason.
- No WCF binding config needed in `App.config` — `CoreClientFactory.Create()` handles it internally. Target framework is .NET Framework 4.6.2, so the script **must run under Windows PowerShell 5.1**, not pwsh/PowerShell 7.
- Most Cores present a self-signed TLS cert by default — script has a `ServicePointManager.ServerCertificateValidationCallback` bypass gated by a Global field, on by default, flagged as a documented exception in the SOP (not an oversight).

Quest's own web docs (`support.quest.com/technical-documents/rapid-recovery/...`) are blocked to this session's WebFetch/WebSearch tooling by bot protection (robots.txt returns HTTP 202, treated as disallowed) — including the original URL Jeff linked and the "Top-Ten PowerShell cmdlets" KB article. All technical grounding above came from directly reading the downloaded SDK's sample C# project via the device bridge, not from the web docs. There is apparently also a native Rapid Recovery **PowerShell module** (cmdlets like the ones referenced in KB 4038040 / the Commands and Scripting Reference Guide) that could be a simpler alternative to the raw WCF approach — not evaluated in this build since its docs were equally blocked and the WCF sample code gave a fully working, verified path instead.

## Architecture (per-Client Core, unlike Cove's shared partner API)

Because every Client hosts their own Core, the design differs from Cove in two ways:

1. **Connection credentials are Organization-scoped**, not Global (Core Host/Port/Username/Password per NinjaOne Organization) — only the NinjaOne API creds themselves stay Global (reusing the existing `ninjaoneInstance`/`ninjaoneClientId`/`ninjaoneClientSecret` fields shared with Cove/Entra).
2. **No per-device status script needed.** Cove needed a device-side script (`Set-CoveBackupStatus-Ninja.ps1`) because Cove's local `ClientTool.exe` had data the Partner API path didn't reliably carry. Rapid Recovery's Core already centralizes full per-agent status, so a single org-rollup script covers everything — deliberately scoped out per Jeff's answer to "what should this produce."

The rollup script (`Set-RapidRecoveryBackupRollup-NinjaOrg.ps1`) runs **centrally on one designated runner device** (never on individual Core servers or protected agents), loads the vendor DLLs from a path stored in a new Global field, authenticates to NinjaOne, enumerates all Organizations, and for each one with populated RR connection fields: connects to that Org's Core, pulls agents/repositories/alerts/jobs, matches agents to NinjaOne devices by `HostName` (fallback `DisplayName`), builds one HTML card, and writes it back via the NinjaOne API. One Organization's failure doesn't stop the others.

## Custom fields (8 total: 5 new Organization + 2 new Global + 3 existing Global reused)

| Field name | Type | Level | Purpose |
|---|---|---|---|
| Rapid Recovery Core Host | Text | Organization | This Client's Core server hostname/IP |
| Rapid Recovery Core Port | Text | Organization | Core API port (script defaults to 8006 if blank) |
| Rapid Recovery Username | Text | Organization | Account used to authenticate to the Core API |
| Rapid Recovery Password | Secure | Organization | Password for the above account |
| Rapid Recovery Backup Rollup | WYSIWYG | Organization (API=Write) | Receives the HTML rollup card each run |
| Rapid Recovery Client DLL Path | Text | Global (new) | Folder on the runner device holding the vendor WCF client DLLs (copied from the SDK's `Dependencies` folder) |
| Rapid Recovery Trust Self-Signed Core Cert | Text (true/false) | Global (new) | Whether to bypass TLS cert validation per Core (default true) |
| NinjaOne Instance / Client ID / Client Secret | Text / Secure / Secure | Global (existing) | Already created for Cove/Entra scripts — reused as-is |

## Honest gaps flagged for live validation (Jeff has a real Core to test against)

- **NinjaOne API v2 call shapes in the script (OAuth token, `/api/v2/organizations`, `/api/v2/organization/{id}/devices`, `/api/v2/organization/{id}/custom-fields`) were NOT copied from the actual working Cove rollup script** — that script's file content wasn't available in this session, only its prose description in the Cove doc. They follow the standard documented v2 shape but should be reconciled against Cove's proven-working NinjaOne API helper functions before first live run.
- `BackgroundJobInfo` has no confirmed `AgentId`/agent-identifier property in the sample code, so running/failed jobs are listed by their own `Summary` text rather than joined to a specific agent row in the report.
- Agent/repository `Status` string values are treated as opaque display text (not color-coded by matching specific enum members) since the full enum member list wasn't confirmed from the SDK docs alone — coloring instead uses confirmed booleans/counts (`IsProtectionPaused`, `IsLicenseExpired`, `FailedChecksCount`, `InconsistentRecoveryPointsCount`, repository free-space %).
- Assumes the runner device has network access to each Client's Core on its API port — an infrastructure prerequisite, not yet confirmed, called out in the SOP.
- Script is syntax-validated (`[System.Management.Automation.Language.Parser]::ParseFile()`, no errors) but **has not been run against a live Core** — Jeff's next step, same pattern as the Cove build's live-iteration process.

## Confluence

- SOP: [NinjaOne — Quest Rapid Recovery Backup Monitoring Deployment & Operation](https://bridgeheadit.atlassian.net/wiki/spaces/BIT/pages/1801093123) (page 1801093123, v2)
- Runbook: [NinjaOne — Quest Rapid Recovery Backup Alert Remediation](https://bridgeheadit.atlassian.net/wiki/spaces/BIT/pages/1801125890) (page 1801125890, v2)
- Both cross-linked to each other (companion links verified via re-fetch) and to the sibling Cove SOP/Runbook (labeled sibling, not companion).

## Status as of 2026-08-19

Script delivered and syntax-validated only — not yet run against a live Core. Custom fields not yet created in NinjaOne (SOP documents them but Jeff hasn't created them per this doc). **Next real step is the same shape as the Cove build's rollout**: create the 5 new custom fields, copy the SDK's `Dependencies` DLLs to the runner device and set the DLL path field, populate one test Organization's Rapid Recovery connection fields, and run the script once against that real Core — expect to find and fix real bugs the way Benson Enterprises' live data surfaced two real bugs in the Cove build.
