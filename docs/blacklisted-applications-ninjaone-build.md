# Blacklisted Applications Audit — NinjaOne Automation

Built 2026-11-07. Replaces the legacy ConnectWise Automate `applicationblacklist` table (name-only list) with a NinjaOne-native, report-only audit.

## Deliverables
- Script: `Blacklisted-Applications-Audit.ps1` (v1.0, parse-validated with pwsh 7.4.6; parsing, wildcard matching and allow-list logic tested against the seed list on Linux — registry/Ninja cmdlets not exercisable off-Windows, so a pilot device run is still required)
- Seed list: `Blacklisted-Applications-SeedList.txt` (73 rules, ~4,000 chars, collapsed from ~215 original rows)
- SOP: https://bridgeheadit.atlassian.net/wiki/spaces/BIT/pages/1925644298 (v1.1)
- Runbook: https://bridgeheadit.atlassian.net/wiki/spaces/BIT/pages/1926103041 (v1.0), cross-linked both ways

## Custom fields (Label / Type / Level)
| Field name | Type | Level | Purpose |
|---|---|---|---|
| Blacklisted Apps List | Multi-line text | Global | Master list (READ) |
| Blacklisted Apps Additional | Multi-line text | Organization | Client-specific extra rules (READ) |
| Blacklisted Apps Allow List | Multi-line text | Organization | Client exceptions (READ) |
| Blacklisted Apps Exempt | Checkbox | Device | Exempt device (READ) |
| Blacklisted Apps Report | WYSIWYG | Device | HTML report (WRITE, Piped) |
| Blacklisted Apps Found | Checkbox | Device | Alert condition (WRITE) |
| Blacklisted Apps Status Summary | Text | Device | <200 chars (WRITE) |
| Blacklisted Apps Changelog | Multi-line text | Device | History, newest first, 200 lines (READ+WRITE) |

Names assumed: blacklistedAppsList, blacklistedAppsAdditional, blacklistedAppsAllowList, blacklistedAppsExempt, blacklistedAppsReport, blacklistedAppsFound, blacklistedAppsStatusSummary, blacklistedAppsChangelog (verify after creating fields).

## Key decisions / design
- Report-only permanently; no remediation path.
- Rule line format: `Pattern | Category | Severity | ProcessNames(optional)`; `#` comments allowed.
- Allow list syntax: untagged = DisplayName wildcard, `rule:<pattern>`, `process:<name>`.
- Script vars: `alertMinSeverity` (default Medium), `scanUserHives` (default true).
- Detection: Uninstall keys (HKLM 64/32 + loaded and offline user hives) plus running-process check for rules with ProcessNames (portables).
- Removed from original list as likely false positives: Wazuh Agent, Remote Desktop Connection Manager, Zoho Exchange Migration, Zoho Expense Connector. `Desktop Mini` dropped (unknown product) — confirm.
- ScreenConnect/ConnectWise Control/Atera are commented out in the seed list pending confirmation of what BIT and Clients use on purpose.
- Global field needs CAB; Organization fields need Account Manager approval + Engineering Lead review.
- Uses `Ninja-Property-Set-Piped` for report/changelog (see AD Stale Users audit Bug #5).

## Open items
- Create fields, paste seed list, pilot on one device/org, then widen.
- Confirm NinjaOne's own remote tooling and BIT's tools don't match any Critical rule.
- Verify Multi-line text field character limit against the seed list size.
