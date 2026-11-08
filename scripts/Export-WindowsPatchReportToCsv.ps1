<#
.SYNOPSIS
    Exports Windows patch installation history for a given month to per-organization CSV files. Report-only.

.DESCRIPTION
    Bridgehead IT adaptation of jeffhunterninja's Export-WindowsPatchReportToCsv.ps1
    (https://github.com/jeffhunterninja/NinjaOne-Scripts/tree/main/Windows%20OS%20Patch%20Reporting).

    Pulls one row per installed patch per Windows Workstation/Server device, for the specified month,
    via the NinjaOne API, and writes CSV files to the local disk of the device this script runs on.
    This is the CSV-export path only - it never touches NinjaOne Documentation, Knowledge Base, or any
    custom field. Microsoft Defender Security Intelligence (definition) updates are excluded, matching
    the upstream script.

    This script is report-only: it reads from the NinjaOne API and writes local files. It does not
    change, remove, or disable anything on any device.

    Runs as a NinjaOne automation (Condition/Task/manual "Run script"). Whatever device NinjaOne
    executes it on is where the CSVs land - this is a central API pull across every managed Windows
    Workstation/Server in scope for the credentials below, not a per-device local report.

    Defaults: prior calendar month (the month that just closed), one CSV per organization, all
    Windows devices (servers and workstations), every in-scope device listed.

    Coverage notes (changes from the upstream script):
      * ALL pages of patch installs are read. NinjaOne's queries/* endpoints use cursor paging, and the
        NinjaOneDocs module's -Paginate switch only follows 'after'/'pageSize' paging on endpoints that
        return a bare array - on queries/os-patch-installs it returns just the first page. Upstream
        therefore only ever saw the first page (about 1000 rows, most of them Defender definition
        updates), which is why whole organizations and most devices were missing. This script follows the
        cursor itself until NinjaOne runs out of rows and warns (and exits non-zero) if it cannot.
      * Every in-scope device appears in its organization's CSV. A device with no patch installs
        recorded in the period gets a single "NoInstallsRecorded" row instead of silently vanishing.
        Use -ExcludeDevicesWithNoInstalls for the old behavior.
      * The NinjaOne query window is widened by a day on each side and trimmed locally, so installs on
        the last day of the month (and timezone edge cases) are not lost.
      * Rows are never dropped silently: the log reports, stage by stage, how many pages and patch rows
        the API returned and how many were dropped and why (definition updates, outside the window,
        filtered out by device type/OS, or a device ID the device list did not contain).

.PARAMETER ReportMonth
    Optional. Month and year to report on, e.g. "December 2024". Defaults to the PRIOR calendar
    month (not the current one). Maps to the NinjaOne script variable reportMonth.

.PARAMETER OutputPath
    Optional. Folder on the local device to write the CSVs into. Created if it doesn't exist.
    Defaults to C:\Reports. Maps to the NinjaOne script variable outputPath.

.PARAMETER PerOrganization
    Optional switch. Defaults to ON - one CSV per organization
    (WindowsPatchReport_<OrgName>_<YYYYMM>.csv). Set the NinjaOne script variable perOrganization to
    false (or pass -PerOrganization:$false) for a single combined CSV across every organization
    (WindowsPatchReport_<YYYYMM>.csv).

.PARAMETER DeviceType
    Optional. All (default), Servers, or Workstations. Maps to the NinjaOne script variable deviceType
    (Drop-down: All / Servers / Workstations). Filtered runs add a suffix to the file names
    (e.g. WindowsPatchReport_<OrgName>_Servers_<YYYYMM>.csv) so they never overwrite an unfiltered run.

.PARAMETER OsNameLike
    Optional. Only include devices whose OS name matches. Wildcards allowed; a plain value is treated as
    "contains". Comma-separate to match any of several, e.g. "Server 2019, Server 2022" or "Windows 11".
    Devices NinjaOne has no OS name for are excluded when this is set. Maps to the NinjaOne script
    variable osNameLike (String). Combine with DeviceType, e.g. Servers + "Server 2016".

.PARAMETER ExcludeDevicesWithNoInstalls
    Optional switch. When set, devices (and organizations) with no patch installs in the period are
    omitted instead of listed with a "NoInstallsRecorded" row. Maps to the NinjaOne script variable
    excludeDevicesWithNoInstalls (checkbox, leave unchecked by default).

.NOTES
    Requires PowerShell 7+ (self-relaunches under pwsh if invoked from Windows PowerShell 5.1)
    and the NinjaOneDocs module (https://github.com/lwhitelock/NinjaOneDocs) for Connect-NinjaOne /
    Invoke-NinjaOneRequest - installed automatically if missing.

    Reads existing Global custom fields for NinjaOne API credentials (already provisioned for
    other Bridgehead automations - Cove, Quest Rapid Recovery):
      - ninjaoneInstance     (Global, Text)
      - ninjaoneClientId     (Global, Secure)
      - ninjaoneClientSecret (Global, Secure)
    No new custom fields are created or required by this script.

    NinjaOne script variables (all optional): reportMonth (String), outputPath (String),
    perOrganization (Checkbox, default checked), deviceType (Drop-down: All, Servers, Workstations),
    osNameLike (String), excludeDevicesWithNoInstalls (Checkbox, default unchecked). Advanced, normally
    left unset: queryPageSize (String, default 1000) - rows requested per page of patch installs.

    CSV columns: OrganizationName, DeviceName, PatchName, KBNumber, InstalledAt, Timestamp, DeviceId
    (same as upstream, same order), then DeviceClass, OperatingSystem, LastContact, RowType
    (Install | NoInstallsRecorded). InstalledAt/Timestamp/LastContact are UTC as reported by NinjaOne.

    Patch data is only as fresh as each device's last report to NinjaOne: Timestamp is when NinjaOne last
    captured that device's patch list and LastContact is when the agent last checked in. Installs that
    happened after those times are not in NinjaOne yet and cannot appear in this report. The report
    month is UTC, so an install late on the last evening (US time) of a month can land in the next month.

    Exit codes: 0 = success. Non-zero = failed, nothing matched / nothing could be written, or the patch
    install data may be incomplete (CSVs are still written in that last case, with a WARNING in the log) -
    surfaces in NinjaOne's activity/failure feed as a second alert channel.
#>

[CmdletBinding()]
param (
    [Parameter()]
    [string]$ReportMonth = $env:reportMonth,  # Optional (e.g., "December 2024"); defaults to the prior calendar month
    [Parameter()]
    [string]$OutputPath = $env:outputPath,    # Optional; folder for CSV output on this device. Default: C:\Reports
    [Parameter()]
    # Defaults to $true (one CSV per organization) unless perOrganization is explicitly set to a
    # recognized "false" value - never throws on a missing/blank NinjaOne script variable.
    [Switch]$PerOrganization = -not ($env:perOrganization -match '^(?i:false|0|no)$'),
    [Parameter()]
    [string]$DeviceType = $(if ([string]::IsNullOrWhiteSpace($env:deviceType)) { 'All' } else { $env:deviceType }),
    [Parameter()]
    [string]$OsNameLike = $env:osNameLike,
    [Parameter()]
    [Switch]$ExcludeDevicesWithNoInstalls = ($env:excludeDevicesWithNoInstalls -match '^(?i:true|1|yes)$')
)

function Write-Log {
    param([Parameter(Mandatory)][string]$Message)
    Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
}

# Check for required PowerShell version (7+)
if (!($PSVersionTable.PSVersion.Major -ge 7)) {
    try {
        if (!(Test-Path "$env:SystemDrive\Program Files\PowerShell\7")) {
            Write-Log 'PowerShell 7 does not appear to be installed. Install it and try again.'
            exit 1
        }

        # Refresh PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path', 'User')

        # Restart script in PowerShell 7
        pwsh -File "`"$PSCommandPath`"" @PSBoundParameters
    }
    catch {
        Write-Log "PowerShell 7 relaunch failed. Error: $_"
        exit 1
    }
    finally { exit $LASTEXITCODE }
}

# Validate the device type / OS filters up front, before any API work
$deviceTypeNorm = $null
switch -Regex ($DeviceType.Trim()) {
    '^(all)?$'         { $deviceTypeNorm = 'All' }
    '^servers?$'       { $deviceTypeNorm = 'Servers' }
    '^workstations?$'  { $deviceTypeNorm = 'Workstations' }
}
if (-not $deviceTypeNorm) {
    Write-Log "Invalid DeviceType '$DeviceType'. Use All, Servers, or Workstations."
    exit 1
}

# Plain values mean "contains"; values that already contain wildcards are used as written
$osPatterns = @()
if (-not [string]::IsNullOrWhiteSpace($OsNameLike)) {
    $osPatterns = @($OsNameLike -split '[,;]' |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ } |
        ForEach-Object { if ($_ -match '[\*\?\[]') { $_ } else { "*$_*" } })
}

# Rows requested per page of patch installs (advanced; leave the queryPageSize script variable unset)
$QueryPageSize = 1000
if ($env:queryPageSize -match '^\d+$' -and [int]$env:queryPageSize -ge 1) { $QueryPageSize = [int]$env:queryPageSize }

# Install or update the NinjaOneDocs module
try {
    $moduleName = "NinjaOneDocs"
    if (-not (Get-Module -ListAvailable -Name $moduleName)) {
        Install-Module -Name $moduleName -Force -AllowClobber
    }
    Import-Module $moduleName
}
catch {
    Write-Log "Failed to import NinjaOneDocs module. Error: $_"
    exit 1
}

# NinjaOne API credentials - existing Global custom fields (Name values, not Labels)
$NinjaOneInstance = Ninja-Property-Get ninjaoneInstance
$NinjaOneClientId = Ninja-Property-Get ninjaoneClientId
$NinjaOneClientSecret = Ninja-Property-Get ninjaoneClientSecret

if (!$NinjaOneInstance -or !$NinjaOneClientId -or !$NinjaOneClientSecret) {
    Write-Log "Missing required NinjaOne API credentials (ninjaoneInstance / ninjaoneClientId / ninjaoneClientSecret)."
    exit 1
}

try {
    Connect-NinjaOne -NinjaOneInstance $NinjaOneInstance -NinjaOneClientID $NinjaOneClientId -NinjaOneClientSecret $NinjaOneClientSecret
}
catch {
    Write-Log "Failed to connect to NinjaOne API. Error: $_"
    exit 1
}

function Convert-ActivityTime {
    param([AllowNull()]$TimeValue)

    if ($null -eq $TimeValue) {
        return $null
    } elseif ($TimeValue -is [datetime]) {
        return $TimeValue
    } elseif ($TimeValue -is [int] -or $TimeValue -is [int64]) {
        return [System.DateTimeOffset]::FromUnixTimeSeconds([int64]$TimeValue).DateTime
    } elseif ($TimeValue -is [double]) {
        $roundedUnixTime = [long][math]::Floor($TimeValue)
        return [System.DateTimeOffset]::FromUnixTimeSeconds($roundedUnixTime).DateTime
    } else {
        return $TimeValue
    }
}

function ConvertTo-DateTimeSafe {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }
    try { return [datetime]$Value } catch { return $null }
}

function ConvertTo-QueryParamString {
    param([Parameter(Mandatory)][hashtable]$QueryParams)
    ($QueryParams.GetEnumerator() | ForEach-Object {
        "$($_.Key)=$([System.Uri]::EscapeDataString([string]$_.Value))"
    }) -join '&'
}

# Reads EVERY page of a NinjaOne queries/* endpoint. These endpoints return { cursor: {name,...}, results: [...] }
# and are paged by passing the cursor name back in; the NinjaOneDocs module's -Paginate switch does not do that
# (it only follows after/pageSize paging on bare-array endpoints) and so returns just the first page.
# Returns Results, Pages, Complete, Notes. Never writes to the output stream except via the returned object.
function Get-NinjaOneQueryResults {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][hashtable]$QueryParams,
        [int]$PageSize = 1000,
        [int]$MaxPages = 5000
    )

    $all = [System.Collections.Generic.List[object]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    $complete = $true
    $pages = 0
    $cursorName = $null
    $cursorOnly = $false
    $lastCount = 0
    $previousSignature = $null

    while ($pages -lt $MaxPages) {
        $fullParams = $QueryParams.Clone()
        $fullParams['pageSize'] = $PageSize
        if ($cursorName) { $fullParams['cursor'] = $cursorName }

        # Continuation pages: send the filters again; if NinjaOne rejects that, fall back to cursor + pageSize only
        $attempts = @($fullParams)
        if ($cursorName) {
            $cursorOnlyParams = @{ pageSize = $PageSize; cursor = $cursorName }
            $attempts = if ($cursorOnly) { @($cursorOnlyParams) } else { @($fullParams, $cursorOnlyParams) }
        }

        $response = $null
        $lastError = $null
        foreach ($attempt in $attempts) {
            try {
                $response = Invoke-NinjaOneRequest -Method GET -Path $Path -QueryParams (ConvertTo-QueryParamString -QueryParams $attempt)
                $lastError = $null
                if ($cursorName -and -not $cursorOnly -and $attempt.Count -eq 2) {
                    $cursorOnly = $true
                    $notes.Add('NinjaOne rejected filters on cursor requests; continuing with cursor + pageSize only.')
                }
                break
            }
            catch { $lastError = $_ }
        }

        if ($lastError) {
            if ($pages -eq 0) { throw $lastError }
            if ($lastCount -lt $PageSize) {
                $notes.Add("Page $($pages + 1) request failed after a short page ($lastCount of $PageSize rows); treating page $pages as the last one. Error: $($lastError.Exception.Message)")
            } else {
                $complete = $false
                $notes.Add("WARNING: page $($pages + 1) request failed after a full page of $lastCount rows - more patch installs probably exist than were read. Error: $($lastError.Exception.Message)")
            }
            break
        }

        $items = @($response.results | Where-Object { $null -ne $_ })
        if ($items.Count -eq 0) { break }

        $first = $items[0]
        $last = $items[$items.Count - 1]
        $signature = "$($items.Count)|$($first.deviceId)|$($first.name)|$($first.installedAt)|$($last.deviceId)|$($last.name)|$($last.installedAt)"
        if ($signature -eq $previousSignature) {
            if ($items.Count -ge $PageSize) {
                $complete = $false
                $notes.Add("WARNING: NinjaOne returned the same full page of $($items.Count) rows twice in a row (cursor not advancing); stopping - patch installs are probably incomplete.")
            } else {
                $notes.Add('NinjaOne repeated the final short page; treating that as the end of the data.')
            }
            break
        }
        $previousSignature = $signature

        $pages++
        $lastCount = $items.Count
        $all.AddRange($items)

        $cursorName = [string]$response.cursor.name
        if (-not $cursorName) {
            if ($items.Count -ge $PageSize) {
                $complete = $false
                $notes.Add("WARNING: NinjaOne returned a full page of $($items.Count) rows but no cursor to read the next page - patch installs are probably incomplete.")
            }
            break
        }
    }

    if ($pages -ge $MaxPages) {
        $complete = $false
        $notes.Add("WARNING: stopped after $MaxPages pages (safety limit) - patch installs are incomplete.")
    }

    [PSCustomObject]@{
        Results  = $all.ToArray()
        Pages    = $pages
        Complete = $complete
        Notes    = $notes.ToArray()
    }
}

function Get-ReportDateRange {
    param([string]$ReportMonth)
    if ($ReportMonth) {
        try {
            $ParsedDate = [datetime]::ParseExact($ReportMonth.Trim(), "MMMM yyyy", [cultureinfo]::InvariantCulture)
            $FirstDayOfMonth = Get-Date -Year $ParsedDate.Year -Month $ParsedDate.Month -Day 1
        }
        catch {
            throw "Invalid ReportMonth '$ReportMonth'. Use 'MMMM yyyy' (e.g., 'December 2024')."
        }
    } else {
        # No ReportMonth given: default to the PRIOR calendar month, not the current (still in-progress) one.
        $FirstDayOfMonth = (Get-Date -Day 1).AddMonths(-1)
    }
    $LastDayOfMonth = $FirstDayOfMonth.AddMonths(1).AddDays(-1)
    [PSCustomObject]@{
        FirstDayOfMonth = $FirstDayOfMonth
        LastDayOfMonth  = $LastDayOfMonth
    }
}

# Server / Workstation / Unknown, from the NinjaOne device class (falls back to the OS name)
function Get-DeviceTypeLabel {
    param($Device)
    $class = [string]$Device.nodeClass
    if ($class -match 'SERVER') { return 'Server' }
    if ($class -match 'WORKSTATION') { return 'Workstation' }
    $osName = [string]$Device.os.name
    if ($osName -match 'Server') { return 'Server' }
    if ($osName) { return 'Workstation' }
    return 'Unknown'
}

function Test-DeviceInScope {
    param($Device)
    $type = Get-DeviceTypeLabel -Device $Device
    if ($deviceTypeNorm -eq 'Servers' -and $type -ne 'Server') { return $false }
    if ($deviceTypeNorm -eq 'Workstations' -and $type -ne 'Workstation') { return $false }
    if ($osPatterns.Count -gt 0) {
        $osName = [string]$Device.os.name
        if (-not $osName) { return $false }
        foreach ($pattern in $osPatterns) {
            if ($osName -like $pattern) { return $true }
        }
        return $false
    }
    return $true
}

function Get-DeviceDisplayName {
    param($Device)
    if ($Device.systemName) { return $Device.systemName }
    return $Device.displayName
}

function Get-OrgDisplayName {
    param([string]$OrgId)
    if ($orgIndex.ContainsKey($OrgId) -and $orgIndex[$OrgId].name) { return $orgIndex[$OrgId].name }
    return "Unknown organization ($OrgId)"
}

function Get-SafeFileName {
    param([string]$Name)
    return ($Name -replace '[^\w\s\-]', '' -replace '\s+', '_').Trim('_', ' ')
}

try {
    $dateRange = Get-ReportDateRange -ReportMonth $ReportMonth
}
catch {
    Write-Log $_.Exception.Message
    exit 1
}

$FirstDayOfMonth = $dateRange.FirstDayOfMonth
$LastDayOfMonth = $dateRange.LastDayOfMonth
$yyyyMM = $FirstDayOfMonth.ToString('yyyyMM')

# Report window is [windowStart, windowEnd). The API call is widened by a day each side (so last-day-of-month
# installs and timezone edges are never lost whether the API treats its bounds as inclusive or exclusive)
# and trimmed back to this window locally.
$windowStart = $FirstDayOfMonth.Date
$windowEnd = $windowStart.AddMonths(1)
$apiAfter = $windowStart.AddDays(-1).ToString('yyyyMMdd')
$apiBefore = $windowEnd.AddDays(1).ToString('yyyyMMdd')

Write-Log "Generating patch install CSVs for: $($FirstDayOfMonth.ToString('MMMM yyyy')) ($($windowStart.ToString('yyyy-MM-dd')) to $($windowEnd.AddDays(-1).ToString('yyyy-MM-dd')), UTC)"
Write-Log ("Scope: DeviceType={0}; OS filter={1}; devices with no installs {2}." -f $deviceTypeNorm, $(if ($osPatterns.Count) { $osPatterns -join ' | ' } else { '(none)' }), $(if ($ExcludeDevicesWithNoInstalls) { 'EXCLUDED' } else { 'listed' }))

# Fetch devices and organizations
try {
    $devicesQueryParams = @{ df = 'class in (WINDOWS_WORKSTATION, WINDOWS_SERVER)' }
    $devices = Invoke-NinjaOneRequest -Method GET -Path 'devices-detailed' -QueryParams (ConvertTo-QueryParamString -QueryParams $devicesQueryParams)
    $organizations = Invoke-NinjaOneRequest -Method GET -Path 'organizations'
}
catch {
    Write-Log "Failed to retrieve devices or organizations. Error: $_"
    exit 1
}

$deviceList = @($devices | Where-Object { $null -ne $_ })
$orgList = @($organizations | Where-Object { $null -ne $_ })

# Fetch patch installations for the (widened) date range - every page
try {
    $queryParams = @{
        df              = 'class in (WINDOWS_WORKSTATION, WINDOWS_SERVER)'
        status          = 'Installed'
        installedBefore = $apiBefore
        installedAfter  = $apiAfter
    }
    $patchQuery = Get-NinjaOneQueryResults -Path 'queries/os-patch-installs' -QueryParams $queryParams -PageSize $QueryPageSize
    $patchinstalls = $patchQuery.Results
}
catch {
    Write-Log "Failed to retrieve patch installations. Error: $_"
    exit 1
}
Write-Log ("Patch install query: read {0} page(s) of up to {1} row(s) = {2} row(s) from NinjaOne." -f $patchQuery.Pages, $QueryPageSize, @($patchinstalls).Count)
foreach ($note in $patchQuery.Notes) { Write-Log $note }
$paginationIncomplete = -not $patchQuery.Complete

# Index organizations and devices for lookup (string keys so Int32/Int64 IDs can't mismatch)
$orgIndex = @{}
foreach ($organization in $orgList) {
    $orgIndex[[string]$organization.id] = $organization
}
$deviceIndexAll = @{}
foreach ($device in $deviceList) {
    $deviceIndexAll[[string]$device.id] = $device
}

# Devices in scope after the device type / OS filters
$scopeDevices = @{}
$devicesWithUnknownOrg = 0
foreach ($device in $deviceList) {
    if (-not (Test-DeviceInScope -Device $device)) { continue }
    $scopeDevices[[string]$device.id] = $device
    if (-not $orgIndex.ContainsKey([string]$device.organizationId)) { $devicesWithUnknownOrg++ }
}

$typeBreakdown = ($scopeDevices.Values | Group-Object { Get-DeviceTypeLabel -Device $_ } | Sort-Object Name | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
Write-Log ("NinjaOne returned {0} organization(s) and {1} Windows device(s); {2} device(s) in scope after filters{3}." -f $orgList.Count, $deviceList.Count, $scopeDevices.Count, $(if ($typeBreakdown) { " ($typeBreakdown)" } else { '' }))
if ($devicesWithUnknownOrg -gt 0) {
    Write-Log "WARNING: $devicesWithUnknownOrg in-scope device(s) belong to an organization ID the organizations list did not contain; they are listed under 'Unknown organization (<id>)'."
}

if ($scopeDevices.Count -eq 0) {
    Write-Log "No devices matched the selected filters (DeviceType=$deviceTypeNorm, OS filter=$(if ($osPatterns.Count) { $osPatterns -join ' | ' } else { 'none' })). Nothing to write."
    exit 1
}

# Build rows: one per patch install per in-scope device (exclude Defender Security Intelligence updates)
$rowsByOrg = @{}
$devicesWithInstalls = [System.Collections.Generic.HashSet[string]]::new()
$unknownDeviceIds = [System.Collections.Generic.HashSet[string]]::new()
$stats = @{ Raw = 0; DefenderDefinitions = 0; UnknownDevice = 0; FilteredOut = 0; OutsideWindow = 0; Kept = 0 }

function Add-ReportRow {
    param([string]$OrgId, $Row)
    if (-not $rowsByOrg.ContainsKey($OrgId)) {
        $rowsByOrg[$OrgId] = [System.Collections.Generic.List[object]]::new()
    }
    $rowsByOrg[$OrgId].Add($Row)
}

foreach ($patchinstall in @($patchinstalls | Where-Object { $null -ne $_ })) {
    $stats.Raw++

    if ($patchinstall.name -like "*Security Intelligence Update for Microsoft Defender Antivirus*") {
        $stats.DefenderDefinitions++
        continue
    }

    $deviceKey = [string]$patchinstall.deviceId
    if (-not $deviceIndexAll.ContainsKey($deviceKey)) {
        $stats.UnknownDevice++
        [void]$unknownDeviceIds.Add($deviceKey)
        continue
    }
    if (-not $scopeDevices.ContainsKey($deviceKey)) {
        $stats.FilteredOut++
        continue
    }

    $installedAt = ConvertTo-DateTimeSafe (Convert-ActivityTime $patchinstall.installedAt)
    if ($installedAt -and ($installedAt -lt $windowStart -or $installedAt -ge $windowEnd)) {
        $stats.OutsideWindow++
        continue
    }

    $device = $scopeDevices[$deviceKey]
    $orgId = [string]$device.organizationId

    $row = [PSCustomObject]@{
        OrganizationName = Get-OrgDisplayName -OrgId $orgId
        DeviceName       = Get-DeviceDisplayName -Device $device
        PatchName        = $patchinstall.name
        KBNumber         = $patchinstall.kbNumber
        InstalledAt      = $installedAt
        Timestamp        = Convert-ActivityTime $patchinstall.timestamp
        DeviceId         = $patchinstall.deviceId
        DeviceClass      = Get-DeviceTypeLabel -Device $device
        OperatingSystem  = $device.os.name
        LastContact      = Convert-ActivityTime $device.lastContact
        RowType          = 'Install'
    }
    Add-ReportRow -OrgId $orgId -Row $row
    [void]$devicesWithInstalls.Add($deviceKey)
    $stats.Kept++
}

Write-Log ("Patch rows: API returned {0}; dropped {1} Defender definition update(s), {2} outside the report window, {3} for devices excluded by the type/OS filter, {4} for device IDs missing from the device list; kept {5}." -f $stats.Raw, $stats.DefenderDefinitions, $stats.OutsideWindow, $stats.FilteredOut, $stats.UnknownDevice, $stats.Kept)
if ($stats.UnknownDevice -gt 0) {
    $sample = ($unknownDeviceIds | Select-Object -First 10) -join ', '
    Write-Log "WARNING: $($stats.UnknownDevice) patch row(s) from $($unknownDeviceIds.Count) device ID(s) were not in the device list returned by NinjaOne and are NOT in the CSVs. First IDs: $sample"
}

# Devices with no installs in the period: list them rather than letting them (or their organization) vanish
$noInstallDevices = 0
foreach ($deviceKey in $scopeDevices.Keys) {
    if ($devicesWithInstalls.Contains($deviceKey)) { continue }
    $noInstallDevices++
    if ($ExcludeDevicesWithNoInstalls) { continue }

    $device = $scopeDevices[$deviceKey]
    $orgId = [string]$device.organizationId
    $row = [PSCustomObject]@{
        OrganizationName = Get-OrgDisplayName -OrgId $orgId
        DeviceName       = Get-DeviceDisplayName -Device $device
        PatchName        = '(no patch installs recorded for this period)'
        KBNumber         = $null
        InstalledAt      = $null
        Timestamp        = $null
        DeviceId         = $device.id
        DeviceClass      = Get-DeviceTypeLabel -Device $device
        OperatingSystem  = $device.os.name
        LastContact      = Convert-ActivityTime $device.lastContact
        RowType          = 'NoInstallsRecorded'
    }
    Add-ReportRow -OrgId $orgId -Row $row
}

if ($rowsByOrg.Count -eq 0) {
    Write-Log "No patch install rows to write for $($FirstDayOfMonth.ToString('MMMM yyyy')) with the current filters."
    exit 1
}

$exportParams = @{
    NoTypeInformation = $true
    Encoding          = [System.Text.Encoding]::UTF8
}

# Default output folder on this device: C:\Reports. Override per-run via the outputPath script variable.
$outDir = if ([string]::IsNullOrWhiteSpace($OutputPath)) { 'C:\Reports' } else { $OutputPath.Trim() }

try {
    if (-not (Test-Path -Path $outDir -PathType Container)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
}
catch {
    Write-Log "Failed to create output folder '$outDir'. Error: $_"
    exit 1
}

# Filtered runs get a file-name suffix so they never overwrite an unfiltered run's files
$filterTag = ''
if ($deviceTypeNorm -eq 'Servers') { $filterTag += '_Servers' }
if ($deviceTypeNorm -eq 'Workstations') { $filterTag += '_Workstations' }
if ($osPatterns.Count -gt 0) {
    $osTag = Get-SafeFileName -Name $OsNameLike
    if ($osTag.Length -gt 40) { $osTag = $osTag.Substring(0, 40) }
    $filterTag += "_OS-$osTag"
}

$orgIdsSorted = @($rowsByOrg.Keys | Sort-Object { Get-OrgDisplayName -OrgId $_ })
$filesWritten = 0
$installRowCount = 0
foreach ($orgId in $orgIdsSorted) { $installRowCount += @($rowsByOrg[$orgId] | Where-Object { $_.RowType -eq 'Install' }).Count }

try {
    if ($PerOrganization) {
        $usedNames = @{}
        foreach ($orgId in $orgIdsSorted) {
            $safeName = Get-SafeFileName -Name (Get-OrgDisplayName -OrgId $orgId)
            if (-not $safeName) { $safeName = "Org_$orgId" }
            # Two organizations can sanitize to the same file name; never let one overwrite the other
            if ($usedNames.ContainsKey($safeName.ToLowerInvariant())) { $safeName = "${safeName}_$orgId" }
            $usedNames[$safeName.ToLowerInvariant()] = $true

            $path = Join-Path $outDir "WindowsPatchReport_${safeName}${filterTag}_${yyyyMM}.csv"
            $orgRows = @($rowsByOrg[$orgId] | Sort-Object DeviceName, InstalledAt)
            $orgRows | Export-Csv -Path $path @exportParams
            $filesWritten++
            Write-Log ('Exported {0} row(s) to {1}' -f $orgRows.Count, $path)
        }
    } else {
        $filePath = Join-Path $outDir "WindowsPatchReport${filterTag}_${yyyyMM}.csv"
        $allRows = @(foreach ($orgId in $orgIdsSorted) { $rowsByOrg[$orgId] }) | Sort-Object OrganizationName, DeviceName, InstalledAt
        $allRows | Export-Csv -Path $filePath @exportParams
        $filesWritten++
        Write-Log ('Exported {0} row(s) to {1}' -f @($allRows).Count, $filePath)
    }
}
catch {
    Write-Log "Failed to write CSV output to '$outDir'. Error: $_"
    exit 1
}

Write-Log ("Done: {0} file(s) in {1} - {2} organization(s), {3} device(s) ({4} with no installs recorded), {5} install row(s)." -f $filesWritten, $outDir, $rowsByOrg.Count, $scopeDevices.Count, $noInstallDevices, $installRowCount)

if ($paginationIncomplete) {
    Write-Log 'COMPLETED WITH WARNINGS: NinjaOne patch install data may be incomplete (see the WARNING lines above). The CSVs were written, but devices may show NoInstallsRecorded wrongly.'
    exit 1
}
exit 0

