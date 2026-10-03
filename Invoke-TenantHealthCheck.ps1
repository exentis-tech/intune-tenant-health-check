#Requires -Version 5.1
<#
.SYNOPSIS
    One-click health check for a Microsoft Intune tenant: expiring Apple tokens, connector health,
    app registration credentials, risky tenant settings, unassigned policies and device posture.

.DESCRIPTION
    Read-only. Uses Microsoft Graph with app-only authentication and writes:
      - report.html  interactive report
      - report.json  the same data for automation or monitoring

    Each check runs independently. If a permission is missing, that check is reported as
    "Couldn't check" and the rest of the report is still produced.

.PARAMETER ConfigPath
    Path to config.json. Defaults to config.json next to this script.

.PARAMETER OutputDirectory
    Folder for reports. Defaults to .\reports next to this script.

.PARAMETER FailOn
    For scheduled runs. Critical: exit code 2 when a critical issue is found.
    Warning: exit code 2 for critical issues, 1 for warnings. None (default): always exit 0.

.PARAMETER NoOpen
    Do not open the HTML report in the browser when finished.

.EXAMPLE
    .\Invoke-TenantHealthCheck.ps1

.EXAMPLE
    .\Invoke-TenantHealthCheck.ps1 -NoOpen -FailOn Critical

.LINK
    https://github.com/exentis-tech/intune-tenant-health-check
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$OutputDirectory,
    [ValidateSet('None', 'Critical', 'Warning')][string]$FailOn = 'None',
    [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'
$ToolName = 'Intune Tenant Health Check'
$ToolVersion = '1.0.0'
$ToolUrl = 'https://github.com/exentis-tech/intune-tenant-health-check'

$Root = $PSScriptRoot
. (Join-Path $Root 'lib\Common.ps1')
. (Join-Path $Root 'lib\GraphClient.ps1')
. (Join-Path $Root 'lib\HealthAnalysis.ps1')

if (-not $ConfigPath) { $ConfigPath = Join-Path $Root 'config.json' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $Root 'reports' }
$TemplatePath = Join-Path $Root 'templates\report-template.html'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$Config = Read-ToolConfig -ConfigPath $ConfigPath -ExamplePath (Join-Path $Root 'config.example.json')
if ($null -eq $Config) { return }
Initialize-GraphClient -Config $Config

$WarningDays = [int](Get-ConfigValue $Config 'WarningDays' 30)
$CriticalDays = [int](Get-ConfigValue $Config 'CriticalDays' 7)
$TokenSyncWarningHours = [int](Get-ConfigValue $Config 'TokenSyncWarningHours' 72)
$ConnectorWarningHours = [int](Get-ConfigValue $Config 'ConnectorHeartbeatWarningHours' 24)
$InactiveDays = [int](Get-ConfigValue $Config 'InactiveDays' 30)
$NonCompliantWarningPercent = [int](Get-ConfigValue $Config 'NonCompliantWarningPercent' 10)
$IncludeAppCredentials = [bool](Get-ConfigValue $Config 'IncludeAppRegistrationCredentials' $true)
$IncludePolicyHygiene = [bool](Get-ConfigValue $Config 'IncludePolicyHygiene' $true)
$Now = [datetime]::UtcNow
$base = $script:Graph.BaseUrl
$beta = $script:Graph.BetaUrl

Write-Host ''
Write-Host "$ToolName v$ToolVersion" -ForegroundColor Cyan
Write-Host "Read-only scan. Expiry warning: $WarningDays days, critical: $CriticalDays days." -ForegroundColor DarkGray
Write-Host ''

Write-Step 'Authenticating to Microsoft Graph...'
[void](Get-GraphAccessToken)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Invoke-Check {
    <# Runs one check. On failure returns a single "error" row instead of stopping the whole report. #>
    param(
        [Parameter(Mandatory = $true)][string]$Item,
        [Parameter(Mandatory = $true)][string]$Permission,
        [Parameter(Mandatory = $true)][scriptblock]$Script
    )
    Write-Step "Checking $Item..."
    try {
        return @(& $Script)
    }
    catch {
        $status = $_.Exception.Data['StatusCode']
        $detail = $_.Exception.Message
        if ($status -eq 403 -or $status -eq 401) { $detail = "Access denied. Grant the application permission $Permission with admin consent." }
        Write-Host "    Could not check: $detail" -ForegroundColor DarkYellow
        return @([pscustomobject]@{
                item   = $Item
                status = 'error'
                detail = $detail
                action = 'Fix the permission or connectivity issue and run again.'
            })
    }
}

function Test-NotFound {
    param($ErrorRecord)
    return ($ErrorRecord.Exception.Data['StatusCode'] -eq 404)
}

function Join-Detail {
    param([string[]]$Parts)
    return (@($Parts | Where-Object { $_ }) -join ' ')
}

function New-HealthSection {
    param($Id, $Title, $Description, $EmptyText, $Columns, $Rows)
    $list = @($Rows)
    return [pscustomobject]@{
        id          = $Id
        title       = $Title
        severity    = $(if ($list.Count -eq 0) { 'ok' } else { Get-WorstStatus @($list | ForEach-Object { [string]$_.status }) })
        unit        = 'item'
        description = $Description
        emptyText   = $EmptyText
        columns     = @($Columns)
        rows        = $list
        defaultSort = @{ key = 'status'; dir = 'desc' }
    }
}

$standardColumns = @(
    (New-ReportColumn 'item' 'Item'),
    (New-ReportColumn 'status' 'Status' 'status'),
    (New-ReportColumn 'detail' 'Detail' -Wide),
    (New-ReportColumn 'expires' 'Expires' 'date'),
    (New-ReportColumn 'lastSync' 'Last sync' 'date'),
    (New-ReportColumn 'action' 'What to do' -Wide)
)

# ---------------------------------------------------------------------------
# Apple
# ---------------------------------------------------------------------------
$appleRows = New-Object System.Collections.Generic.List[object]

foreach ($row in (Invoke-Check -Item 'Apple MDM push certificate' -Permission 'DeviceManagementServiceConfig.Read.All' -Script {
            $cert = $null
            try { $cert = Invoke-GraphRequest -Uri "$base/deviceManagement/applePushNotificationCertificate" }
            catch { if (-not (Test-NotFound $_)) { throw } }
            if ($null -eq $cert -or $null -eq (ConvertTo-UtcDate $cert.expirationDateTime)) {
                return [pscustomobject]@{ item = 'Apple MDM push certificate'; status = 'info'; detail = 'Not configured. Needed only if you manage iPhone, iPad or Mac devices.'; action = 'No action needed unless you plan to manage Apple devices.' }
            }
            $exp = Get-ExpiryStatus -ExpiresUtc $cert.expirationDateTime -WarningDays $WarningDays -CriticalDays $CriticalDays -Now $Now
            [pscustomobject]@{
                item    = 'Apple MDM push certificate'
                status  = $exp.Status
                detail  = Join-Detail @("$($exp.Text).", $(if ($cert.appleIdentifier) { "Apple ID: $($cert.appleIdentifier)." }))
                expires = Format-UtcDate $cert.expirationDateTime
                action  = $(if ($exp.Status -eq 'ok') { 'No action needed.' } else { 'Renew it in Intune (Devices > Enrollment > Apple > MDM Push Certificate) with the SAME Apple ID. Creating a new certificate instead forces every Apple device to re-enroll.' })
            }
        })) { $appleRows.Add($row) }

foreach ($row in (Invoke-Check -Item 'Apple automated device enrollment tokens' -Permission 'DeviceManagementServiceConfig.Read.All' -Script {
            $tokens = @(Get-GraphCollection -Uri "$beta/deviceManagement/depOnboardingSettings")
            if ($tokens.Count -eq 0) {
                return [pscustomobject]@{ item = 'Apple automated device enrollment (ABM/ASM)'; status = 'info'; detail = 'No enrollment program tokens configured.'; action = 'No action needed unless you use Apple Business Manager or Apple School Manager.' }
            }
            foreach ($t in $tokens) {
                $exp = Get-ExpiryStatus -ExpiresUtc $t.tokenExpirationDateTime -WarningDays $WarningDays -CriticalDays $CriticalDays -Now $Now
                $sync = Get-AgeStatus -LastUtc $t.lastSuccessfulSyncDateTime -WarningHours $TokenSyncWarningHours -Now $Now
                $syncError = ($null -ne $t.lastSyncErrorCode -and [int]$t.lastSyncErrorCode -ne 0)
                $status = Get-WorstStatus @($exp.Status, $sync.Status, $(if ($syncError) { 'warning' }))
                $actions = @()
                if ($exp.Status -ne 'ok') { $actions += 'Download a new server token from Apple Business Manager and upload it to the existing token in Intune.' }
                if ($sync.Status -ne 'ok' -or $syncError) { $actions += 'Run a manual sync and check the token in Apple Business Manager.' }
                [pscustomobject]@{
                    item     = "ADE token: $(if ($t.tokenName) { $t.tokenName } else { $t.appleIdentifier })"
                    status   = $status
                    detail   = Join-Detail @("$($exp.Text).", "Last successful sync $($sync.Text).", $(if ($syncError) { "Last sync error code $($t.lastSyncErrorCode)." }), $(if ($t.appleIdentifier) { "Apple ID: $($t.appleIdentifier)." }))
                    expires  = Format-UtcDate $t.tokenExpirationDateTime
                    lastSync = Format-UtcDate $t.lastSuccessfulSyncDateTime
                    action   = $(if ($actions.Count) { $actions -join ' ' } else { 'No action needed.' })
                }
            }
        })) { $appleRows.Add($row) }

foreach ($row in (Invoke-Check -Item 'Apple VPP location tokens' -Permission 'DeviceManagementServiceConfig.Read.All' -Script {
            $tokens = @(Get-GraphCollection -Uri "$base/deviceAppManagement/vppTokens")
            if ($tokens.Count -eq 0) {
                return [pscustomobject]@{ item = 'Apple VPP (apps and books) tokens'; status = 'info'; detail = 'No VPP location tokens configured.'; action = 'No action needed unless you deploy Apple volume-purchased apps.' }
            }
            foreach ($t in $tokens) {
                $exp = Get-ExpiryStatus -ExpiresUtc $t.expirationDateTime -WarningDays $WarningDays -CriticalDays $CriticalDays -Now $Now
                $stateStatus = switch ([string]$t.state) { 'valid' { 'ok' } 'expired' { 'critical' } 'invalid' { 'critical' } 'assignedToExternalMDM' { 'critical' } default { 'warning' } }
                $syncStatus = if ([string]$t.lastSyncStatus -eq 'failed') { 'warning' } else { 'ok' }
                $status = Get-WorstStatus @($exp.Status, $stateStatus, $syncStatus)
                $action = 'No action needed.'
                if ($t.state -eq 'assignedToExternalMDM') { $action = 'This token is claimed by another MDM. Reclaim it in Intune or upload a new token.' }
                elseif ($status -ne 'ok') { $action = 'Download a new location token from Apple Business Manager and upload it to the existing token in Intune.' }
                [pscustomobject]@{
                    item     = "VPP token: $(if ($t.organizationName) { $t.organizationName } else { $t.appleId })"
                    status   = $status
                    detail   = Join-Detail @("$($exp.Text).", "State: $($t.state).", "Last sync: $($t.lastSyncStatus).", $(if ($t.appleId) { "Apple ID: $($t.appleId)." }))
                    expires  = Format-UtcDate $t.expirationDateTime
                    lastSync = Format-UtcDate $t.lastSyncDateTime
                    action   = $action
                }
            }
        })) { $appleRows.Add($row) }

# ---------------------------------------------------------------------------
# Android
# ---------------------------------------------------------------------------
$androidRows = @(Invoke-Check -Item 'Managed Google Play' -Permission 'DeviceManagementConfiguration.Read.All' -Script {
        $s = $null
        try { $s = Invoke-GraphRequest -Uri "$beta/deviceManagement/androidManagedStoreAccountEnterpriseSettings" }
        catch { if (-not (Test-NotFound $_)) { throw } }
        if ($null -eq $s -or [string]$s.bindStatus -eq 'notBound' -or -not $s.bindStatus) {
            return [pscustomobject]@{ item = 'Managed Google Play'; status = 'info'; detail = 'Not connected. Needed only to manage Android Enterprise devices.'; action = 'No action needed unless you manage Android devices.' }
        }
        $syncStatus = switch ([string]$s.lastAppSyncStatus) { 'success' { 'ok' } 'none' { 'ok' } 'credentialsNotValid' { 'critical' } default { 'warning' } }
        $bindStatus = if ([string]$s.bindStatus -in @('bound', 'boundAndValidated')) { 'ok' } else { 'warning' }
        $status = Get-WorstStatus @($syncStatus, $bindStatus)
        [pscustomobject]@{
            item     = 'Managed Google Play'
            status   = $status
            detail   = Join-Detail @("Binding: $($s.bindStatus).", "Last app sync: $($s.lastAppSyncStatus).", $(if ($s.ownerUserPrincipalName) { "Connected by $($s.ownerUserPrincipalName)." }))
            lastSync = Format-UtcDate $s.lastAppSyncDateTime
            action   = $(if ($status -eq 'ok') { 'No action needed.' } elseif ($syncStatus -eq 'critical') { 'The Google account credentials are no longer valid. Reconnect Managed Google Play with the same account.' } else { 'Run a manual app sync and review the connection in Tenant administration > Connectors and tokens.' })
        }
    })

# ---------------------------------------------------------------------------
# Connectors and sync
# ---------------------------------------------------------------------------
$connectorRows = New-Object System.Collections.Generic.List[object]
$knownPartners = @{ 'fc780465-2017-40d4-a0c5-307022471b92' = 'Microsoft Defender for Endpoint' }

foreach ($row in (Invoke-Check -Item 'Mobile Threat Defense connectors' -Permission 'DeviceManagementServiceConfig.Read.All' -Script {
            $connectors = @(Get-GraphCollection -Uri "$base/deviceManagement/mobileThreatDefenseConnectors")
            if ($connectors.Count -eq 0) {
                return [pscustomobject]@{ item = 'Mobile Threat Defense connectors'; status = 'info'; detail = 'None configured.'; action = 'Consider connecting Microsoft Defender for Endpoint so device risk can be used in compliance policies.' }
            }
            foreach ($c in $connectors) {
                $name = if ($knownPartners.ContainsKey([string]$c.id)) { $knownPartners[[string]$c.id] } else { "Partner $($c.id)" }
                $state = [string]$c.partnerState
                $status = switch ($state) { 'enabled' { 'ok' } 'available' { 'info' } 'unresponsive' { 'critical' } 'error' { 'critical' } default { 'warning' } }
                $heartbeat = Get-AgeStatus -LastUtc $c.lastHeartbeatDateTime -WarningHours $ConnectorWarningHours -Now $Now
                if ($state -eq 'enabled') { $status = Get-WorstStatus @($status, $heartbeat.Status) }
                [pscustomobject]@{
                    item     = $name
                    status   = $status
                    detail   = "State: $state. Last heartbeat $($heartbeat.Text)."
                    lastSync = Format-UtcDate $c.lastHeartbeatDateTime
                    action   = $(if ($status -eq 'ok') { 'No action needed.' } else { 'Check the connector in Endpoint security > Microsoft Defender for Endpoint (or the partner console) and reconnect it.' })
                }
            }
        })) { $connectorRows.Add($row) }

foreach ($row in (Invoke-Check -Item 'Certificate connectors (NDES)' -Permission 'DeviceManagementConfiguration.Read.All' -Script {
            $connectors = @(Get-GraphCollection -Uri "$beta/deviceManagement/ndesConnectors")
            if ($connectors.Count -eq 0) {
                return [pscustomobject]@{ item = 'Certificate connectors (NDES)'; status = 'info'; detail = 'None registered.'; action = 'No action needed unless you deploy SCEP certificates through NDES.' }
            }
            foreach ($c in $connectors) {
                $last = Get-AgeStatus -LastUtc $c.lastConnectionDateTime -WarningHours $ConnectorWarningHours -Now $Now
                $status = if ([string]$c.state -eq 'inactive') { 'critical' } else { $last.Status }
                [pscustomobject]@{
                    item     = "Certificate connector: $(if ($c.machineName) { $c.machineName } else { $c.displayName })"
                    status   = $status
                    detail   = "State: $($c.state). Last connection $($last.Text)."
                    lastSync = Format-UtcDate $c.lastConnectionDateTime
                    action   = $(if ($status -eq 'ok') { 'No action needed.' } else { 'Check the Intune Certificate Connector service on the server and its event log.' })
                }
            }
        })) { $connectorRows.Add($row) }

foreach ($row in (Invoke-Check -Item 'Windows Autopilot sync' -Permission 'DeviceManagementServiceConfig.Read.All' -Script {
            $s = Invoke-GraphRequest -Uri "$beta/deviceManagement/windowsAutopilotSettings"
            $status = switch ([string]$s.syncStatus) { 'failed' { 'warning' } default { 'ok' } }
            [pscustomobject]@{
                item     = 'Windows Autopilot sync'
                status   = $status
                detail   = "Last sync status: $($s.syncStatus)."
                lastSync = Format-UtcDate $s.lastSyncDateTime
                action   = $(if ($status -eq 'ok') { 'No action needed.' } else { 'Run a manual sync in Devices > Enrollment > Windows Autopilot devices.' })
            }
        })) { $connectorRows.Add($row) }

# ---------------------------------------------------------------------------
# Tenant settings
# ---------------------------------------------------------------------------
$settingsRows = @(Invoke-Check -Item 'Tenant settings' -Permission 'DeviceManagementServiceConfig.Read.All' -Script {
        $dm = Invoke-GraphRequest -Uri "$base/deviceManagement"
        $state = [string]$dm.subscriptionState
        [pscustomobject]@{
            item   = 'Intune subscription'
            status = $(switch ($state) { 'active' { 'ok' } 'warning' { 'warning' } '' { 'info' } default { 'critical' } })
            detail = "Subscription state: $(if ($state) { $state } else { 'not reported' })."
            action = $(if ($state -eq 'active' -or -not $state) { 'No action needed.' } else { 'Check licensing and the subscription in the Microsoft 365 admin center.' })
        }
        if ($null -ne $dm.settings) {
            $secure = [bool]$dm.settings.secureByDefault
            [pscustomobject]@{
                item   = 'Devices with no compliance policy'
                status = $(if ($secure) { 'ok' } else { 'warning' })
                detail = $(if ($secure) { 'Marked as not compliant.' } else { 'Marked as compliant. A device with no compliance policy assigned passes device-based Conditional Access.' })
                action = $(if ($secure) { 'No action needed.' } else { "In Endpoint security > Device compliance > Compliance policy settings, set 'Mark devices with no compliance policy assigned as' to Not compliant (test the impact first)." })
            }
            $days = $dm.settings.deviceComplianceCheckinThresholdDays
            if ($null -ne $days) {
                [pscustomobject]@{
                    item   = 'Compliance status validity period'
                    status = $(if ([int]$days -gt 30) { 'warning' } else { 'ok' })
                    detail = "Devices that do not check in for $days days are marked non-compliant."
                    action = $(if ([int]$days -gt 30) { 'A long validity period lets inactive devices stay compliant. Consider 30 days or less.' } else { 'No action needed.' })
                }
            }
        }
    })

# ---------------------------------------------------------------------------
# App registration credentials
# ---------------------------------------------------------------------------
$credentialRows = @()
$appCount = 0
if ($IncludeAppCredentials) {
    $credentialRows = @(Invoke-Check -Item 'App registration credentials' -Permission 'Application.Read.All' -Script {
            $apps = @(Get-GraphCollection -Uri "$base/applications?`$select=id,appId,displayName,passwordCredentials,keyCredentials&`$top=999" -Activity 'Downloading app registrations')
            $script:appCount = $apps.Count
            Write-Step ("  {0} reviewed" -f (Format-Count $apps.Count 'app registration'))
            Get-AppCredentialFindings -Applications $apps -WarningDays $WarningDays -CriticalDays $CriticalDays -Now $Now
        })
}

# ---------------------------------------------------------------------------
# Policy and app hygiene
# ---------------------------------------------------------------------------
$hygieneRows = @()
$policyCount = 0
if ($IncludePolicyHygiene) {
    $hygieneItems = New-Object System.Collections.Generic.List[object]
    $hygieneErrors = New-Object System.Collections.Generic.List[object]

    $hygieneSources = @(
        @{ Type = 'Configuration profile'; Uri = "$base/deviceManagement/deviceConfigurations?`$expand=assignments"; NameProp = 'displayName'; Permission = 'DeviceManagementConfiguration.Read.All' },
        @{ Type = 'Settings catalog policy'; Uri = "$beta/deviceManagement/configurationPolicies?`$expand=assignments"; NameProp = 'name'; Permission = 'DeviceManagementConfiguration.Read.All' },
        @{ Type = 'Compliance policy'; Uri = "$base/deviceManagement/deviceCompliancePolicies?`$expand=assignments"; NameProp = 'displayName'; Permission = 'DeviceManagementConfiguration.Read.All' },
        @{ Type = 'App'; Uri = "$base/deviceAppManagement/mobileApps?`$select=id,displayName,isAssigned,lastModifiedDateTime"; NameProp = 'displayName'; Permission = 'DeviceManagementApps.Read.All' }
    )
    foreach ($src in $hygieneSources) {
        $result = @(Invoke-Check -Item "$($src.Type)s" -Permission $src.Permission -Script {
                $items = @(Get-GraphCollection -Uri $src.Uri)
                foreach ($i in $items) {
                    $assigned = if ($src.Type -eq 'App') { [bool]$i.isAssigned } else { @($i.assignments | Where-Object { $null -ne $_ }).Count -gt 0 }
                    [pscustomobject]@{ Name = [string]$i.($src.NameProp); Type = $src.Type; Assigned = $assigned; LastModified = $i.lastModifiedDateTime }
                }
            })
        foreach ($r in $result) {
            if ($r.PSObject.Properties['status'] -and $r.status -eq 'error') { $hygieneErrors.Add($r) } else { $hygieneItems.Add($r) }
        }
    }
    $policyCount = $hygieneItems.Count
    $hygieneRows = @(@(Get-UnassignedItemRows -Items $hygieneItems.ToArray()) + @($hygieneErrors.ToArray()))
}

# ---------------------------------------------------------------------------
# Device posture
# ---------------------------------------------------------------------------
$deviceCount = 0
$postureRows = @(Invoke-Check -Item 'Device compliance posture' -Permission 'DeviceManagementManagedDevices.Read.All' -Script {
        $devices = @(Get-GraphCollection -Uri "$base/deviceManagement/managedDevices?`$select=id,operatingSystem,osVersion,complianceState,lastSyncDateTime" -Activity 'Downloading managed devices')
        $script:deviceCount = $devices.Count
        Get-DevicePostureRows -Devices $devices -InactiveDays $InactiveDays -NonCompliantWarningPercent $NonCompliantWarningPercent -Now $Now
    })

# ---------------------------------------------------------------------------
# Build report
# ---------------------------------------------------------------------------
$sections = @(
    (New-HealthSection -Id 'apple' -Title 'Apple enrollment and apps' -Columns $standardColumns -Rows $appleRows.ToArray() `
        -Description 'The MDM push certificate and Apple tokens expire every year. If the push certificate expires, Intune can no longer manage any Apple device.' `
        -EmptyText 'Nothing to report.'),
    (New-HealthSection -Id 'android' -Title 'Android Enterprise' -Columns $standardColumns -Rows $androidRows `
        -Description 'The Managed Google Play connection is required to manage Android Enterprise devices and deploy Google Play apps.' `
        -EmptyText 'Nothing to report.'),
    (New-HealthSection -Id 'connectors' -Title 'Connectors and sync' -Columns $standardColumns -Rows $connectorRows.ToArray() `
        -Description 'Services that feed Intune: threat defense, certificate connectors and the Windows Autopilot sync.' `
        -EmptyText 'Nothing to report.'),
    (New-HealthSection -Id 'tenant-settings' -Title 'Tenant settings' -Rows $settingsRows `
        -Description 'Tenant-wide settings that quietly weaken compliance when left at their defaults.' `
        -EmptyText 'Nothing to report.' `
        -Columns @(
            (New-ReportColumn 'item' 'Setting'),
            (New-ReportColumn 'status' 'Status' 'status'),
            (New-ReportColumn 'detail' 'Current state' -Wide),
            (New-ReportColumn 'action' 'What to do' -Wide)
        ))
)
if ($IncludeAppCredentials) {
    $sections += New-HealthSection -Id 'app-credentials' -Title 'App registration secrets and certificates' -Rows $credentialRows `
        -Description "Client secrets and certificates that expired or expire within $WarningDays days. When an app's last valid credential expires, the integration that uses it stops working." `
        -EmptyText "No app registration credentials expire within $WarningDays days." `
        -Columns @(
            (New-ReportColumn 'item' 'App registration'),
            (New-ReportColumn 'status' 'Status' 'status'),
            (New-ReportColumn 'detail' 'Detail' -Wide),
            (New-ReportColumn 'expires' 'Expires' 'date'),
            (New-ReportColumn 'action' 'What to do' -Wide),
            (New-ReportColumn 'appId' 'Application ID' 'id')
        )
}
if ($IncludePolicyHygiene) {
    $sections += New-HealthSection -Id 'policy-hygiene' -Title 'Unassigned policies and apps' -Rows $hygieneRows `
        -Description 'Configuration profiles, settings catalog policies, compliance policies and apps that are not assigned to anyone, and policies that share a name.' `
        -EmptyText 'Every policy and app is assigned and every policy name is unique.' `
        -Columns @(
            (New-ReportColumn 'item' 'Name'),
            (New-ReportColumn 'status' 'Status' 'status'),
            (New-ReportColumn 'type' 'Type'),
            (New-ReportColumn 'detail' 'Detail' -Wide),
            (New-ReportColumn 'lastModified' 'Last modified' 'date'),
            (New-ReportColumn 'action' 'What to do' -Wide)
        )
}
$sections += New-HealthSection -Id 'device-posture' -Title 'Device compliance posture' -Rows $postureRows `
    -Description "Compliance by platform. 'Inactive' counts devices with no check-in for $InactiveDays days; the Intune Stale Device Report lists them." `
    -EmptyText 'No managed devices found.' `
    -Columns @(
        (New-ReportColumn 'item' 'Platform'),
        (New-ReportColumn 'status' 'Status' 'status'),
        (New-ReportColumn 'total' 'Devices' 'number'),
        (New-ReportColumn 'compliant' 'Compliant' 'number'),
        (New-ReportColumn 'nonCompliant' 'Not compliant' 'number'),
        (New-ReportColumn 'grace' 'In grace period' 'number'),
        (New-ReportColumn 'inactive' 'Inactive' 'number'),
        (New-ReportColumn 'detail' 'Detail' -Wide)
    )

$allRows = @($sections | ForEach-Object { @($_.rows) })
$count = @{}
foreach ($s in @('critical', 'warning', 'error', 'info', 'ok')) { $count[$s] = @($allRows | Where-Object { $_.status -eq $s }).Count }

if ($count.critical -gt 0) {
    $headline = '{0} and {1} need attention.' -f (Format-Count $count.critical 'critical issue'), (Format-Count $count.warning 'warning')
}
elseif ($count.warning -gt 0) {
    $headline = 'No critical issues. {0} to look at.' -f (Format-Count $count.warning 'warning')
}
else {
    $headline = 'No critical issues or warnings found.'
}
$subhead = "$(Format-Count $allRows.Count 'item') checked across Apple and Android enrollment, connectors, tenant settings$(if ($IncludeAppCredentials) { ', app credentials' })$(if ($IncludePolicyHygiene) { ', policy hygiene' }) and device posture."

$notes = New-Object System.Collections.Generic.List[string]
if ($count.error -gt 0) { $notes.Add("$(Format-Count $count.error 'check') could not run, usually because a Graph permission is missing. See docs/APP_REGISTRATION.md for the full list.") }
$notes.Add("Expiry thresholds: warning within $WarningDays days, critical within $CriticalDays days. Change them in config.json.")
$notes.Add('Some checks use the Microsoft Graph beta endpoint, which Microsoft can change without notice.')

$report = [ordered]@{
    tool         = [ordered]@{ name = $ToolName; version = $ToolVersion; url = $ToolUrl }
    generatedUtc = Format-UtcDate $Now
    tenant       = Protect-TenantId $script:Graph.TenantId
    headline     = $headline
    subhead      = $subhead
    bar          = @(
        [ordered]@{ label = 'Critical'; value = $count.critical; tone = 'critical' },
        [ordered]@{ label = 'Warning'; value = $count.warning; tone = 'warning' },
        [ordered]@{ label = "Couldn't check"; value = $count.error; tone = 'error' },
        [ordered]@{ label = 'Review'; value = $count.info; tone = 'info' },
        [ordered]@{ label = 'OK'; value = $count.ok; tone = 'ok' }
    )
    facts        = @(
        [ordered]@{ label = 'Managed devices'; value = $deviceCount },
        [ordered]@{ label = 'App registrations reviewed'; value = $appCount },
        [ordered]@{ label = 'Policies and apps reviewed'; value = $policyCount },
        [ordered]@{ label = 'Graph requests'; value = $script:Graph.RequestCount }
    )
    indexTitle   = 'Checks'
    sections     = $sections
    notes        = $notes.ToArray()
}

# ---------------------------------------------------------------------------
# Write output
# ---------------------------------------------------------------------------
$stamp = $Now.ToString('yyyyMMdd-HHmmss', [Globalization.CultureInfo]::InvariantCulture)
$runDir = Join-Path $OutputDirectory "tenant-health-check-$stamp"
New-Item -ItemType Directory -Force -Path $runDir | Out-Null
$htmlPath = Join-Path $runDir 'report.html'
New-HtmlReport -Data $report -TemplatePath $TemplatePath -OutputPath $htmlPath
Write-Utf8File -Path (Join-Path $runDir 'report.json') -Content (ConvertTo-ReportJson -Data $report)

Write-Host ''
Write-Host $headline -ForegroundColor $(if ($count.critical) { 'Red' } elseif ($count.warning) { 'Yellow' } else { 'Green' })
foreach ($row in @($allRows | Where-Object { $_.status -in @('critical', 'warning', 'error') })) {
    $color = switch ($row.status) { 'critical' { 'Red' } 'warning' { 'Yellow' } default { 'Magenta' } }
    Write-Host ("  [{0}] {1}: {2}" -f $row.status.ToUpperInvariant(), $row.item, $row.detail) -ForegroundColor $color
}
Write-Host ''
Write-Host "Report: $htmlPath" -ForegroundColor Cyan

if (-not $NoOpen) {
    try { Invoke-Item -LiteralPath $htmlPath } catch { Write-Host 'Open the report manually from the path above.' -ForegroundColor Yellow }
}

if ($FailOn -ne 'None' -and $count.critical -gt 0) { exit 2 }
if ($FailOn -eq 'Warning' -and $count.warning -gt 0) { exit 1 }
exit 0
