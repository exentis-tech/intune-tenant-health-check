# Analysis helpers for the Intune Tenant Health Check.
# Pure functions that turn Graph data into status rows. Requires Common.ps1.

function Get-ExpiryStatus {
    <#
      Classifies an expiry date.
      Returns: Status (critical | warning | ok | info), DaysLeft, Text.
    #>
    param(
        $ExpiresUtc,
        [int]$WarningDays = 30,
        [int]$CriticalDays = 7,
        [datetime]$Now = [datetime]::UtcNow
    )
    $days = Get-DaysUntil $ExpiresUtc $Now
    if ($null -eq $days) {
        return [pscustomobject]@{ Status = 'info'; DaysLeft = $null; Text = 'No expiry date reported' }
    }
    if ($days -lt 0) {
        return [pscustomobject]@{ Status = 'critical'; DaysLeft = $days; Text = ('Expired {0} ago' -f (Format-Count (-$days) 'day')) }
    }
    if ($days -le $CriticalDays) {
        return [pscustomobject]@{ Status = 'critical'; DaysLeft = $days; Text = ('Expires in {0}' -f (Format-Count $days 'day')) }
    }
    if ($days -le $WarningDays) {
        return [pscustomobject]@{ Status = 'warning'; DaysLeft = $days; Text = ('Expires in {0}' -f (Format-Count $days 'day')) }
    }
    return [pscustomobject]@{ Status = 'ok'; DaysLeft = $days; Text = ('Expires in {0}' -f (Format-Count $days 'day')) }
}

function Get-AgeStatus {
    <# Warning when the last activity is older than the threshold (in hours) or missing. #>
    param($LastUtc, [int]$WarningHours = 24, [datetime]$Now = [datetime]::UtcNow)
    $last = ConvertTo-UtcDate $LastUtc
    if ($null -eq $last) { return [pscustomobject]@{ Status = 'warning'; Text = 'Never' } }
    $hours = ($Now - $last).TotalHours
    $text = if ($hours -lt 1) { 'less than an hour ago' }
    elseif ($hours -lt 48) { '{0} ago' -f (Format-Count ([int][math]::Floor($hours)) 'hour') }
    else { '{0} ago' -f (Format-Count ([int][math]::Floor($hours / 24)) 'day') }
    $status = if ($hours -gt $WarningHours) { 'warning' } else { 'ok' }
    return [pscustomobject]@{ Status = $status; Text = $text }
}

function Get-AppCredentialFindings {
    <#
      Reviews client secrets and certificates on app registrations.
      Only problems are returned:
        critical  last valid credential expires within CriticalDays
        warning   last valid credential expires within WarningDays, or every credential has expired
        info      an expiring/expired credential that already has a valid replacement
    #>
    param(
        [object[]]$Applications = @(),
        [int]$WarningDays = 30,
        [int]$CriticalDays = 7,
        [datetime]$Now = [datetime]::UtcNow
    )
    $rows = New-Object System.Collections.Generic.List[object]
    $horizon = $Now.AddDays($WarningDays)

    foreach ($app in @($Applications | Where-Object { $null -ne $_ })) {
        $creds = New-Object System.Collections.Generic.List[object]
        foreach ($c in @($app.passwordCredentials)) {
            if ($null -eq $c) { continue }
            $name = if ($c.displayName) { [string]$c.displayName } elseif ($c.hint) { "starts with $($c.hint)" } else { [string]$c.keyId }
            $creds.Add([pscustomobject]@{ Kind = 'Client secret'; Name = $name; End = (ConvertTo-UtcDate $c.endDateTime) })
        }
        foreach ($c in @($app.keyCredentials)) {
            if ($null -eq $c) { continue }
            $name = if ($c.displayName) { [string]$c.displayName } else { [string]$c.keyId }
            $creds.Add([pscustomobject]@{ Kind = 'Certificate'; Name = $name; End = (ConvertTo-UtcDate $c.endDateTime) })
        }
        if ($creds.Count -eq 0) { continue }

        $valid = @($creds | Where-Object { $null -ne $_.End -and $_.End -gt $Now })
        $latestValid = $null
        foreach ($v in $valid) { if ($null -eq $latestValid -or $v.End -gt $latestValid) { $latestValid = $v.End } }
        $hasLongLivedReplacement = ($null -ne $latestValid) -and ($latestValid -gt $horizon)

        foreach ($c in $creds) {
            if ($null -eq $c.End) { continue }
            $days = [int][math]::Floor(($c.End - $Now).TotalDays)
            $status = $null; $detail = $null; $action = $null

            if ($c.End -le $Now) {
                if ($valid.Count -gt 0) {
                    $status = 'info'
                    $detail = "$($c.Kind) '$($c.Name)' expired $(Format-Count (-$days) 'day') ago. Another credential is still valid."
                    $action = 'Remove the expired credential.'
                }
                else {
                    $status = 'warning'
                    $detail = "$($c.Kind) '$($c.Name)' expired $(Format-Count (-$days) 'day') ago. No valid credential remains."
                    $action = 'If the app is still used, add a new credential. If not, consider deleting the app registration.'
                }
            }
            elseif ($c.End -le $horizon) {
                if ($hasLongLivedReplacement) {
                    $status = 'info'
                    $detail = "$($c.Kind) '$($c.Name)' expires in $(Format-Count $days 'day'). A newer credential is already in place."
                    $action = 'Remove the old credential once everything uses the new one.'
                }
                else {
                    $status = if ($days -le $CriticalDays) { 'critical' } else { 'warning' }
                    $detail = "$($c.Kind) '$($c.Name)' expires in $(Format-Count $days 'day') and no replacement exists."
                    $action = 'Create a new credential, update the app or script that uses it, then remove the old one.'
                }
            }
            if ($status) {
                $rows.Add([pscustomobject]@{
                        item    = [string]$app.displayName
                        status  = $status
                        detail  = $detail
                        expires = Format-UtcDate $c.End
                        action  = $action
                        appId   = [string]$app.appId
                    })
            }
        }
    }
    return $rows.ToArray()
}

function Get-WindowsBuild {
    <# Returns the build number from an OS version such as 10.0.22631.4317, or $null. #>
    param([string]$OsVersion)
    if ([string]::IsNullOrWhiteSpace($OsVersion)) { return $null }
    $parts = $OsVersion.Split('.')
    if ($parts.Count -lt 3) { return $null }
    $build = 0
    if ([int]::TryParse($parts[2], [ref]$build)) { return $build }
    return $null
}

function Get-DevicePostureRows {
    <# Compliance summary per platform plus a Windows 10 end-of-support row. #>
    param(
        [object[]]$Devices = @(),
        [int]$InactiveDays = 30,
        [int]$NonCompliantWarningPercent = 10,
        [datetime]$Now = [datetime]::UtcNow
    )
    $Devices = @($Devices | Where-Object { $null -ne $_ })
    $rows = New-Object System.Collections.Generic.List[object]
    $cutoff = $Now.AddDays(-$InactiveDays)

    $groups = $Devices | Group-Object -Property { if ($_.operatingSystem) { [string]$_.operatingSystem } else { 'Unknown' } } | Sort-Object -Property Count -Descending
    foreach ($group in $groups) {
        $items = @($group.Group)
        $total = $items.Count
        $compliant = @($items | Where-Object { $_.complianceState -eq 'compliant' }).Count
        $nonCompliant = @($items | Where-Object { $_.complianceState -eq 'noncompliant' }).Count
        $grace = @($items | Where-Object { $_.complianceState -eq 'inGracePeriod' }).Count
        $inactive = @($items | Where-Object { $t = ConvertTo-UtcDate $_.lastSyncDateTime; ($null -eq $t) -or ($t -lt $cutoff) }).Count
        $pct = if ($total -gt 0) { [math]::Round(($nonCompliant / $total) * 100, 1) } else { 0 }
        $status = if ($pct -ge ($NonCompliantWarningPercent * 2)) { 'critical' } elseif ($pct -ge $NonCompliantWarningPercent) { 'warning' } else { 'ok' }
        $rows.Add([pscustomobject]@{
                item         = $group.Name
                status       = $status
                total        = $total
                compliant    = $compliant
                nonCompliant = $nonCompliant
                grace        = $grace
                inactive     = $inactive
                detail       = ('{0}% non-compliant' -f $pct.ToString([Globalization.CultureInfo]::InvariantCulture))
            })
    }

    $windows10 = @($Devices | Where-Object {
            $_.operatingSystem -eq 'Windows' -and ($b = Get-WindowsBuild ([string]$_.osVersion)) -and $b -ge 10240 -and $b -lt 22000
        })
    if ($windows10.Count -gt 0) {
        $rows.Add([pscustomobject]@{
                item         = 'Windows 10 (end of support)'
                status       = 'warning'
                total        = $windows10.Count
                compliant    = @($windows10 | Where-Object { $_.complianceState -eq 'compliant' }).Count
                nonCompliant = @($windows10 | Where-Object { $_.complianceState -eq 'noncompliant' }).Count
                grace        = @($windows10 | Where-Object { $_.complianceState -eq 'inGracePeriod' }).Count
                inactive     = @($windows10 | Where-Object { $t = ConvertTo-UtcDate $_.lastSyncDateTime; ($null -eq $t) -or ($t -lt $cutoff) }).Count
                detail       = 'Windows 10 reached end of support on 14 October 2025. Upgrade to Windows 11 or confirm these devices are covered by Extended Security Updates.'
            })
    }
    return $rows.ToArray()
}

function Get-UnassignedItemRows {
    <# Policies or apps with no assignments, plus names shared by more than one item. #>
    param([object[]]$Items = @())
    $rows = New-Object System.Collections.Generic.List[object]
    $Items = @($Items | Where-Object { $null -ne $_ })
    foreach ($i in $Items) {
        if (-not $i.Assigned) {
            $rows.Add([pscustomobject]@{
                    item         = $i.Name
                    status       = 'info'
                    type         = $i.Type
                    detail       = 'Not assigned to any group.'
                    lastModified = Format-UtcDate $i.LastModified
                    action       = 'Assign it, or delete it if it is no longer needed.'
                })
        }
    }
    $dupes = $Items | Where-Object { $_.Type -ne 'App' -and $_.Name } | Group-Object -Property Name | Where-Object { $_.Count -gt 1 }
    foreach ($d in $dupes) {
        $rows.Add([pscustomobject]@{
                item         = $d.Name
                status       = 'info'
                type         = (@($d.Group | Select-Object -ExpandProperty Type -Unique) -join ', ')
                detail       = ('Name shared by {0}.' -f (Format-Count $d.Count 'policy' 'policies'))
                lastModified = $null
                action       = 'Rename or consolidate so admins can tell them apart.'
            })
    }
    return $rows.ToArray()
}
