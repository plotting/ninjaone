# SOP ↔ Runbook cross-link audit (2026-08-16/17)

## What triggered this

User asked for a full audit of every NinjaOne SOP/Runbook pair in the BIT Confluence space after noticing some pages were "matching unrelated items" in their Related documents sections.

## Findings

Two defect patterns across all 7 pre-existing SOP/Runbook pairs (AD Stale Computers, AD Stale Users, AD Privileged Groups, Antivirus, BitLocker, LAPS, Entra Role Assignments) plus the newly-created TreeSize pair:

1. **SOP side** — every SOP's Related documents section had a problem: plain unlinked text naming the companion Runbook (4 SOPs), no related-doc link at all (LAPS SOP), or — the bug the user actually flagged — an unrelated sibling SOP mislabeled as the "Companion automation": the Antivirus SOP named the LAPS SOP as its companion, and the BitLocker SOP listed LAPS + Antivirus SOPs as "Companion automations" while never mentioning its own actual Runbook.
2. **Runbook side** — none of the 7 pre-existing Runbooks (nor the new TreeSize Runbook) had any back-link to their own SOP at all. The Runbook template/convention in use had no such section built in.

## Fix applied

All 7 SOPs updated (via `updateConfluencePage`, `contentFormat: html`) to link their real companion Runbook with a proper hyperlink labeled "(companion runbook)"; sibling-SOP references (where they existed) relabeled as siblings, never "companion." All 8 Runbooks (7 existing + TreeSize) got a new "Related documents" section immediately before Revision History, linking back to their real companion SOP labeled "(companion SOP)." Every page got a new Change log / Revision History row documenting the fix. Page IDs (for reference):

| Automation | SOP | Runbook |
|---|---|---|
| AD Stale Computers | 1795096588 | 1794736148 |
| AD Stale Users | 1795260420 | 1795358750 |
| AD Privileged Groups | 1794310147 | 1794211842 |
| Antivirus | 1789231152 | 1793654926 |
| BitLocker | 1789329468 | 1794179074 |
| LAPS | 1791000580 | 1794080771 |
| Entra Role Assignments | 1795358721 | 1795391489 |
| TreeSize Disk Usage Reporting | 1796374530 | 1796308995 |

Not yet verified: whether the two standalone SOPs (1717698564, 1742929921) and two standalone Runbooks (1744601091, 1571717123) are genuinely out of scope (no companion expected) or need pairing — flagged but not investigated.

## Process fix

The `bit-ninjaone-automation` skill (delivered as an updated `.skill` file, not directly editable in-session — report as delivered, confirm with user whether they saved it) now has a mandatory Step 7 "Cross-link the SOP and Runbook" between publishing and delivery, plus an explicit Quality-bar checklist line, specifically because every prior automation shipped with a broken link on one or both sides. Future builds should not repeat this.

## Related: TreeSize script issues (same session)

Two rounds of real bugs surfaced in the TreeSize disk-usage script (delivered same session, before this audit):

**v1.1 — the reported PC crash.** User said running the v1.0 script twice crashed their PC. Root cause: UltraTree's `Get-FolderSizes` + `FindDuplicates` has no built-in memory/CPU ceiling (confirmed via UltraTree's own docs — "reduce depth and disable duplicates" is their only perf guidance), and the original script ran the scan in-process at normal priority with no watchdog, plus a size-guard path that could trigger a second full untracked re-scan back to back. Shipped v1.1: runs the actual scan in a supervised, low-priority child process with a memory floor (512MB default) and runtime ceiling (60 min default) that kill the scan before it can take the host down, added a same-host concurrency lock, and removed the double-rescan.

**v1.2 — a live run's actual error output surfaced two more bugs, both fixed:**
1. **Wrong NinjaOne field Names.** v1.0/v1.1 guessed camelCase Names from the field Labels (e.g. predicted `treeSizeFreeSpaceAlertThresholdPercent`); the org's real generated Name (per a screenshot of Administration > Custom Fields) is `treesizeFreeSpaceAlertThreshold` — first word fully lowercased, and the "(%)" suffix dropped entirely rather than becoming "Percent". All five field Names in the script were wrong and are now corrected to match the real list: `treesizeReport`, `treesizeAttentionNeeded`, `treesizeChangelog`, `treesizeFreeSpaceAlertThreshold`, `treesizeDuplicateWasteAlertThresholdgb`. This is a recurring risk for every NinjaOne automation this skill builds — always verify generated Names against the actual custom field list, never trust the prediction.
2. **Write-Log was silently corrupting captured return values.** `Write-Log` used `Write-Output`, which puts text on the success pipeline. Any function that called `Write-Log` internally and was itself invoked via `$x = Some-Function ...` had its real return value silently turned into an array mixed with every log line it emitted — confirmed empirically in a sandboxed PowerShell test. This was already latent in `Get-NinjaFieldSafe`/`Resolve-Threshold` since v1.0 (it only surfaces when a field lookup fails, which the wrong field names above triggered on every run) and was far more severe in v1.1's heavily-logged `Invoke-GuardedFolderScan`. Fixed by switching `Write-Log` to `Write-Host`, which still shows up in the NinjaOne activity log but never touches the success pipeline. Worth remembering for any future PowerShell automation this skill produces: never use `Write-Output` for logging inside a function whose result gets captured via assignment.

Script (both fixes applied) delivered via SendUserFile in this session; full source is in the chat history if it needs pulling again.
