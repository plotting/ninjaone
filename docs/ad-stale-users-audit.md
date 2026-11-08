# AD Stale Users Audit — NinjaOne Automation

Built 2026-08-14, mirroring the existing **AD Stale Computers Audit** automation (`Server - AD Stale Computers Audit`) so the two stay operationally consistent. Report-only automation that identifies AD user objects that have not authenticated or changed their password within a configurable threshold (default 90 days), and writes results into NinjaOne **device-level** custom fields (same level as the Computers sibling — a stale user finding still needs per-device/per-DC alerting even though the underlying AD data is domain-wide).

## Custom fields

| Field name | Type | Level | Purpose |
|---|---|---|---|
| AD Stale Users Allow List | Text | Organization (inherited to device, with device overrides) | READ. Exclusion list — users, groups, OUs, or SIDs to omit from the stale report even if they exceed the threshold. |
| AD Stale Users Report | WYSIWYG | Device | WRITE. HTML report of stale users each run — user (name + SamAccountName), last activity, days stale, status. Written via `Ninja-Property-Set-Piped` (see Bug #5), not plain `Ninja-Property-Set`. |
| AD Stale Users Found | Checkbox | Device | WRITE. Set true when one or more (non-excluded) stale users are found; cleared when none are found. This is what the alert condition watches. |
| AD Stale Users Ratio | Text | Device | WRITE. At-a-glance `"<stale>/<total>"`, e.g. `276/1000` — stale is the same post-allow-list count as the report/checkbox, total is every AD user object retrieved that run. **Not yet created in NinjaOne** — create it (Text, Device, Automation permission WRITE, Name `adStaleUsersRatio`) before the next scheduled run. Mirrors `adStaleComputersRatio` on the Computers sibling. |
| AD Stale Users Changelog | Multi-line text | Device | READ+WRITE. Per-run history of findings, capped at 200 lines. Also written via `Ninja-Property-Set-Piped`. |

Script variable: `StaleDaysThreshold` (Integer, default 90 — matches the Computers sibling).

## Key decisions

- **Mirrors the AD Stale Computers Audit exactly** in field naming, allow-list prefix syntax (`group:`, `ou:`, `sid:`, `name:`, untagged), report styling (3-tier HTML color convention), and the Write-Log helper.
- **Report-only, permanently.** Never disables, resets passwords, changes group membership, or deletes any AD user object — verified by grepping the delivered script for `Remove-AD|Disable-AD|Set-ADUser|Set-ADAccountPassword|Reset-|Enable-AD` (no matches).
- **`Last Activity`** = the more recent of `LastLogonTimestamp` and `PasswordLastSet`, falling back to `whenCreated` if neither is populated — same definition as the Computers audit, adapted from machine-account-password-rotation to user-password-change semantics.
- **krbtgt is hardcoded-excluded**, independent of the allow list — it has no interactive logon of its own and disabling/deleting it breaks Kerberos domain-wide. This is a deliberate safety default not present in the Computers sibling (computers don't have an equivalent built-in account with the same blast radius).
- **Color coding differs slightly in emphasis from the Computers report**: Enabled + stale is colored red (higher priority — an unused-but-enabled user account is a larger attack surface than a stale computer), Disabled + stale is green (already handled, lower priority).
- **New Runbook scenario (D) not present in the Computers sibling**: stale service/application accounts require coordination with the application owner before disabling, since disabling an account tied to a scheduled task or app pool can break production — computers don't have this failure mode.
- **Report table is 4 columns, not 6** (as of Bug #5): "User (SamAccountName)", "Last Activity", "Days Stale", "Status" — Display Name and SamAccountName were merged into one column and the separate Enabled column was dropped (Status text already encodes it) to keep each row lighter. This was a secondary cleanup alongside Bug #5, not the fix for it — see below.
- **Stale ratio field** (`adStaleUsersRatio`) added after the same field was added to the Computers sibling, so a technician (or a dashboard column) can see e.g. `276/1000` at a glance without opening the WYSIWYG report. `stale` is post-allow-list (matches `adStaleUsersFound`/the report); `total` is every AD user object the script retrieved that run, before the stale-threshold filter and before allow-list exclusion.

## Bugs found and fixed during rollout (real production incidents, not hypothetical)

First scheduled run failed in production with: `Cannot bind argument to parameter 'Entries' because it is null` after logging `Allow-list entries parsed: 0`. Root cause turned out to be three related instances of the same underlying PowerShell 5.1/enumerable-collapse behavior — distinct from, but in the same family as, the single-item `Where-Object` collapse bug documented on the Entra Role Assignments Audit build:

1. **Empty-array-to-`$null` collapse on function return.** `ConvertTo-AllowListEntries` returns `$entries` (an empty `@()` when no allow list is configured). Capturing a function's `return $emptyArray` without wrapping in `@(...)` at the *call site* silently collapses it to `$null` — this is the zero-item counterpart of the already-known single-item collapse (single item → bare object; zero items → `$null`). Fixed by wrapping the call: `$allowListEntries = @(ConvertTo-AllowListEntries -Raw $allowListRaw)`.
2. **`Mandatory` + array-typed parameter rejects empty collections, not just `$null`.** Even after fix #1 produced a real (but empty) array, `Test-UserAllowListed`'s `-Entries` parameter was declared `[Parameter(Mandatory)][array]$Entries` — and PowerShell's Mandatory validation on an array-typed parameter throws on an *empty* collection too (`"...because it is an empty collection"`), unlike a scalar Mandatory parameter which only rejects `$null`. Confirmed by isolated repro. Fixed by removing `Mandatory` from that one parameter (kept on `$User` and `$GroupMemberSet`, which aren't affected).
3. **Any zero-count `IEnumerable` collapses to `$null` on `return`, not just arrays.** `Get-GroupAllowListMembers` returns a `HashSet[string]` via `return $members`. When the allow list has no `group:` entries, the HashSet has 0 elements — and PowerShell enumerates it on output same as an array, again collapsing to `$null`. `@(...)` at the call site doesn't help here (it would flatten the HashSet into an object array, losing the type). Fixed at the source with the unary comma operator: `return ,$members`, which suppresses enumeration and passes the HashSet through as a single object.

Also found and fixed while testing #1–#3 (not yet triggered in production, but would have caused silent wrong exclusions rather than a crash):

4. **Comma-splitting shredded `ou:` DistinguishedName entries.** The original parser split the whole allow-list blob on `[,\r\n]` (comma or newline). A real DN legitimately contains internal commas (e.g. `OU=Contractors,OU=Users,DC=contoso,DC=com`), so a single `ou:` entry was silently shredded into multiple bogus fragments (verified: 1 real entry → 4 garbage entries, only the first comma-delimited piece kept the `ou:` tag). Fixed by splitting on newline only; an `ou:` line is kept whole (not split further), while non-`ou:` lines may still list multiple comma-separated entries for convenience.

All four fixes were verified with isolated pwsh 7.4.6 repros (not just re-parsing — actually reproduced the exact production error message, then confirmed each fix resolves it) plus an end-to-end simulation of both an empty allow list and a populated multi-line allow list matching the SOP's documented example format.

**Second production incident**, after the four fixes above went out: with 152 stale users found (up from 0 on the first, allow-list-related run), the report write itself failed:

5. **`Ninja-Property-Set` hits an OS/shell argument-length ceiling on large field values — it is not the WYSIWYG field's own storage limit.** Production error: `WARN: Ninja-Property-Set failed for 'adStaleUsersReport': Exception calling "Start" with "0" argument(s): "The filename or extension is too long"`, with 152 stale users found. `Ninja-Property-Set` passes `-Value` as a literal command-line argument under the hood, which hits a small Windows/shell argument-length ceiling well before NinjaOne's own documented WYSIWYG field limit (NinjaOne's docs put that at roughly 200,000 characters). The original 6-column, per-cell-styled report for 152 users measured at ~55,800 characters of table body alone — comfortably past the argument ceiling, nowhere near the field's real storage limit.

   **The real fix, per NinjaOne's own documentation**: use `Ninja-Property-Set-Piped` (value supplied via the pipeline) instead of `Ninja-Property-Set` (value as an argument) for any field whose value can grow large. This is now the default for both `adStaleUsersReport` (WYSIWYG) and `adStaleUsersChangelog` (multi-line text) via `Set-NinjaField`'s new `-Piped` switch, with a fallback to the plain cmdlet (and a logged warning) if `-Piped` itself fails — e.g. on an older NinjaRMM agent that predates it.

   Two secondary changes were made alongside this (the user's own initial suggestion — "kill unneeded columns" — before the pipeline root cause was confirmed), kept as belt-and-suspenders rather than the actual fix: merging Display Name + SamAccountName into one column, dropping the separate Enabled column, and removing per-cell background-color styling except on Status. A generous character budget (`$ReportBudgetChars = 150000`, well under the ~200,000 WYSIWYG ceiling) still caps the report body, so an unusually large environment (thousands of stale users) can't blow past field storage limits even with `-Piped` in play — rows are sorted worst-first by Days Stale, so anything truncated is the least urgent. For a normal-sized report, nothing is truncated: re-tested with the same 152-user synthetic dataset used to reproduce the original failure, all 152 rows now fit (table body ~26,600 characters, vs. a 150,000 budget) with zero rows omitted. A pathological 5,000-user synthetic test confirmed the budget still engages sanely at scale (833 rows shown, safely under the cap) rather than ever attempting an oversized write.

**Open question for the Computers sibling:** `Server - AD Stale Computers Audit` almost certainly shares the same `ConvertTo-AllowListEntries` / `Get-GroupAllowListMembers` helper pattern (same author, same day, same design) — bugs #1–#3 would only manifest when that Client's `AD Stale Computers Allow List` is empty AND at least one stale computer is actually found in a run. It also likely writes its report with plain `Ninja-Property-Set`, so bug #5 (argument-length failure on a large report) would only manifest once enough stale computers accumulate in a single Client environment to push the HTML body past the argument ceiling — this may simply not have happened yet, not that the script is unaffected. Recommend checking that script directly (not just this doc) for both bug families before assuming it's unaffected; this session did not have that script's contents available to check directly.

## Deliverables

- Script: `AD-Stale-Users-Audit.ps1` (delivered to user, syntax-validated with pwsh 7.4.6 ParseFile after every revision, including both bugfix passes above and the ratio-field addition)
- SOP: [SOP: NinjaOne — AD Stale Users Audit Deployment & Operation](https://bridgeheadit.atlassian.net/wiki/spaces/BIT/pages/1795260420/SOP+NinjaOne+AD+Stale+Users+Audit+Deployment+Operation) (v1.0 — **not yet updated** for the Bug #5 report-format/write-mechanism change or the new Ratio field; still describes the old 6-column report and 4-field set)
- Runbook: [Runbook: NinjaOne — AD Stale Users Alert Remediation](https://bridgeheadit.atlassian.net/wiki/spaces/BIT/pages/1795358750/Runbook+NinjaOne+AD+Stale+Users+Alert+Remediation) (v1.0 — **not yet updated**; Diagnosis section still references the old separate Enabled column)
- Cross-linked into the sibling AD Stale Computers Audit's SOP (bumped to v1.1, Related documents) and Runbook (bumped to v1.1, Known issues note) so technicians working either automation can find the other.

## Sibling automation reference

- [SOP: NinjaOne — AD Stale Computers Audit Deployment & Operation](https://bridgeheadit.atlassian.net/wiki/spaces/BIT/pages/1795096588/SOP+NinjaOne+AD+Stale+Computers+Audit+Deployment+Operation)
- [Runbook: NinjaOne — AD Stale Computers Alert Remediation](https://bridgeheadit.atlassian.net/wiki/spaces/BIT/pages/1794736148/Runbook+NinjaOne+AD+Stale+Computers+Alert+Remediation)
- Computers sibling also got a matching `AD Stale Computers Ratio` field (`adStaleComputersRatio`, Text, Device, WRITE) the same day this Users field was added.

## Open follow-up

- Check the Computers sibling script for the same empty-collection-collapse/comma-split bugs (#1–#4) and the same `Ninja-Property-Set` argument-length exposure (#5) — same author/design pattern, neither confirmed nor ruled out yet.
- Update the SOP and Runbook Confluence pages for the new 4-column report format, the `-Piped` write mechanism, and the new Ratio field (currently still describe the pre-Bug-#5, pre-Ratio state). User noted they're mid-move to Entra and asked to hold off on Confluence updates for now — revisit once that settles.
- Create `AD Stale Users Ratio` (`adStaleUsersRatio`) in NinjaOne before the next scheduled run — it does not exist yet, same as every other field the first time this automation was built.
- Watch for the same field-scope mistake documented on the Entra Role Assignments Audit (device vs. organization scope) when creating these fields in NinjaOne for the first Client.
