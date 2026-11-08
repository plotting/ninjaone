# NinjaOne Automations

Bridgehead IT's NinjaOne RMM automation builds. Each automation is a PowerShell audit or integration that reads from Windows endpoints, Microsoft Entra ID, or a backup platform and writes its findings into NinjaOne custom fields, with a paired SOP and Runbook published in Confluence. Automations are report-only by default: they surface findings for technicians and alerting, and do not remediate anything on a Client's systems unless a build explicitly says otherwise. This repository holds the build documentation and, as they become available, the scripts.

## Documentation

| Doc | Purpose |
|---|---|
| [blacklisted-applications-ninjaone-build.md](docs/blacklisted-applications-ninjaone-build.md) | Report-only audit of blacklisted applications, replacing the legacy ConnectWise Automate `applicationblacklist` table. |
| [windows-patch-report-csv-ninjaone-build.md](docs/windows-patch-report-csv-ninjaone-build.md) | CSV-only Windows patch install report pulled centrally via the NinjaOne API; includes the full script. |
| [av-device-guard-ninjaone-build.md](docs/av-device-guard-ninjaone-build.md) | Standalone reference for the Server - Advanced Antivirus automation (AV health, Device Guard, expected product, duplicate detection). |
| [ad-stale-users-audit.md](docs/ad-stale-users-audit.md) | Report-only audit of stale Active Directory user objects, mirroring the AD Stale Computers Audit. |
| [bitlocker-ninjaone-automation-build.md](docs/bitlocker-ninjaone-automation-build.md) | Report-only BitLocker audit across OS and fixed volumes, with recovery key capture and exclusions. |
| [mfa-posture-ninjaone-build.md](docs/mfa-posture-ninjaone-build.md) | Entra ID MFA enrollment posture audit per Client tenant, resolved via Partner Center. |
| [entra-role-assignments-audit.md](docs/entra-role-assignments-audit.md) | Entra ID directory role assignment audit per Client tenant, run centrally through the NinjaOne API. |
| [vulnerability-management-ninjaone-build.md](docs/vulnerability-management-ninjaone-build.md) | Custom vulnerability scan build (paused: data source unavailable) and the case for NinjaOne's native Vulnerability Management. |
| [cove-backup-monitoring-integration.md](docs/cove-backup-monitoring-integration.md) | Cove Data Protection backup monitoring: device status card, organization roll-up, detection tagging, and chronic-stale ticket trigger. |
| [ninjaone-automation-build-administration-sop.md](docs/ninjaone-automation-build-administration-sop.md) | Meta-SOP for the administrative steps around a build: scope, approvals, naming, field creation, ConnectWise templates, and pilot testing. |
| [quest-rapid-recovery-ninjaone-integration.md](docs/quest-rapid-recovery-ninjaone-integration.md) | Quest Rapid Recovery backup monitoring through the Core WCF client, producing an organization-level roll-up card. |
| [ninjaone-sop-runbook-crosslink-audit.md](docs/ninjaone-sop-runbook-crosslink-audit.md) | Audit and fix of SOP and Runbook cross-links in Confluence, plus related TreeSize script fixes. |

## Scripts

`scripts/` currently holds only `Export-WindowsPatchReportToCsv.ps1`, extracted verbatim from the script block in the Windows patch report doc.

The following scripts are referenced by the docs, but their source was not stored in the project. Add them to `scripts/` when available:

- `Blacklisted-Applications-Audit.ps1`
- `AVvanced.ps1`
- `Bitlockervanced.ps1`
- `AD-Stale-Users-Audit.ps1`
- `Set-MFAPostureAudit-NinjaOrg.ps1`
- `Set-EntraRoleAssignmentsAudit-NinjaOrg.ps1`
- `Set-CoveBackupStatus-Ninja.ps1`
- `Set-CoveBackupRollup-NinjaOrg.ps1`
- `Set-CoveDetectionTag-Ninja.ps1`
- `Set-RapidRecoveryBackupRollup-NinjaOrg.ps1`

## Security

Never commit credentials, client secrets, API keys, or tokens to this repository. NinjaOne API credentials and Client tenant secrets belong in NinjaOne Global Secure custom fields, not in script source or documentation. The `.gitignore` excludes `*.csv`, `*.log`, `secrets*`, `.env`, and `*.secret`, but it is a safety net, not a substitute for review before committing.
