# NinjaOne Advanced BitLocker automation (Bitlockervanced.ps1)

## What this is

A report-only NinjaOne PowerShell automation ("Server - Advanced BitLocker") that audits BitLocker encryption/protection status across every OS and Fixed data volume on a Windows endpoint, captures recovery passwords into a secure custom field, and raises an alert when an OS/Fixed volume needs attention. Built to mirror the existing LAPSvanced.ps1 / AVvanced.ps1 automations (audit log, changelog, WYSIWYG report, alert checkbox).

Script location (this session's workspace, not persistent): `/home/claude/ninja-scripts/Bitlockervanced.ps1` — always re-deliver via SendUserFile since the sandbox filesystem doesn't persist across sessions; treat Confluence + this doc as the source of truth for what's actually deployed.

## Confluence

- SOP: [SOP: NinjaOne — Advanced BitLocker Deployment & Operation](https://bridgeheadit.atlassian.net/wiki/spaces/BIT/pages/1789329468) (page `1789329468`, currently v1.2 / API version 5)
- Runbook: [Runbook: NinjaOne — Advanced BitLocker Alert Remediation](https://bridgeheadit.atlassian.net/wiki/spaces/BIT/pages/1794179074) (page `1794179074`, currently v1.2 / API version 5)
- Cross-linked both directions (companion SOP / companion runbook) since v1.1 of each.

## Custom fields (8 total)

| Field name | Type | Level | Purpose |
|---|---|---|---|
| BitlockerHealthReport | WYSIWYG | Device | HTML health report, one card per volume category (OS / Fixed / USB-External / Other) plus a TPM status card |
| BitlockerUnhealthyFound | Checkbox | Device | Alert trigger — true when an OS/Fixed volume is unencrypted, mid-decryption, protection-suspended, or missing a recovery password protector |
| BitlockerStatusSummary | Text | Device | One-line status, handy as a device-list column |
| BitlockerRecoveryKeys | Secure | Device | Captured RecoveryPassword protector values, one line per volume that has one |
| Bitlockerchangelog | Multi-line | Device | READ+WRITE — per-device run history |
| BitlockerExcludeDevice | Checkbox | Device | Added 2026-08-26 — excludes the entire device from the health verdict/alert |
| BitlockerExcludedDrives | Text | Device | Added 2026-08-26 — comma-separated drive letters excluded from the health verdict/alert (still shown, tagged EXCLUDED) |
| BitlockerExclusionReason | Text | Device | Added 2026-08-26 — shared documented reason for either exclusion type above |

Field naming note: these are flat PascalCase identifiers (e.g. `BitlockerHealthReport`) used directly as both the NinjaOne field Label and the literal string passed to `Ninja-Property-Get`/`Set` in the script — this predates the `bit-ninjaone-automation` skill's later Label-with-spaces/derived-camelCase-Name convention. Deliberately kept the original flat style for the new exclusion fields too, rather than mixing conventions within one already-shipped script. If this script is ever substantially reworked, reconciling with the skill's convention is worth revisiting — not done as of this note.

## Key design decisions

- **USB/external classification**: uses actual disk `BusType` (`Get-Partition | Get-Disk`) rather than `Get-Volume`'s `DriveType`, because many USB-attached portable hard drives self-report as "Fixed" media — this was a real misclassification bug found in live testing (BIT-JBROTHERS, an external Seagate drive).
- **Locked-drive display**: `IsEncrypted` is inferred from `LockStatus` as well as `VolumeStatus`, since a locked volume's `VolumeStatus`/`ProtectionStatus` can read as unrecognized — without this a locked-but-encrypted drive misreported as "unknown"/"not encrypted". Lock state has its own report column and is informational only, never alert-driving (explicit user decision, including for OS/Fixed drives).
- **TPM card**: device-level, informational only (Present/Ready/Activated via `Get-Tpm`). Never drives the alert.
- **Alert trigger for "key not backed up"**: absence of any RecoveryPassword key protector on an encrypted OS/Fixed volume — deliberately not based on the AD/Entra backup event log (events 845/846), which is kept as informational-only supplementary context due to log-retention unreliability.
- **Exclusions (added 2026-08-26)**: whole-device (`BitlockerExcludeDevice`) and/or specific drive letters (`BitlockerExcludedDrives`), both requiring a documented `BitlockerExclusionReason`. Excluded volumes are still discovered and shown in the report (tagged EXCLUDED) but never count toward `Eligible`/health verdict/alert. Report shows a dedicated warning banner + info card when any exclusion is active. Runbook Scenario E covers applying/removing an exclusion; both docs require Engineering Lead approval per the SOP's Approvals table.

## Bug fixed 2026-08-27: HashSet pipeline-unrolling crash on `BitlockerExcludedDrives`

**Symptom (live run on ABC-PC010):** script failed with exit code 2 immediately after logging the startup line — `Unhandled exception: The property 'Count' cannot be found on this object.` at what was then line 1021, `if ($excludeDevice -or $excludedDriveSet.Count -gt 0)`.

**Root cause:** `ConvertTo-DriveLetterSet` built a `System.Collections.Generic.HashSet[string]` and did `return $set`. `HashSet[T]` implements `IEnumerable`, and PowerShell's success-output pipeline enumerates any `IEnumerable` return value unless explicitly guarded — so the "returned" collection got unrolled item-by-item before reaching the caller: with exactly one excluded drive letter (ABC-PC010's case) the caller received a bare `[string]` instead of a set, and a string has no `.Count` property; with zero elements it would have come back `$null` instead (same bug, different device). `Hashtable`-returning functions elsewhere in the script (`Get-VolumeDriveTypeMap`, `Get-VolumeBusTypeMap`) were never at risk — `Hashtable` implements `IDictionary`, which PowerShell's pipeline does NOT enumerate, so only the newly-added `HashSet` hit this.

**Fix:** both return statements in `ConvertTo-DriveLetterSet` now use the unary comma operator (`return ,$set`), the standard PowerShell idiom for passing a single collection through a function boundary without unrolling. Verified with an isolated functional test (0/1/2/3-element inputs) confirming the return value stays a real `HashSet` with a working `.Count` and `.Contains()` in every case — not just a syntax-parse check.

**Lesson for future edits to this script (or siblings):** any function returning a `System.Collections.Generic.*` collection (List, HashSet, Queue, etc.) — as opposed to a `Hashtable`/`pscustomobject` — needs the `,$x` guard on every return path, or it must be wrapped at the call site with `@(...)`. `pwsh`'s parser (`Parser::ParseFile`) does NOT catch this class of bug since it's a runtime semantics issue, not a syntax error — it only surfaces when actually exercised, ideally with a real functional test of the affected function, not just a parse check.

## Status

Live and current as of 2026-08-27. No open questions pending.
