# Pester 5 tests for the health check analysis helpers.
# Run: Invoke-Pester -Path .\tests

BeforeAll {
    . (Join-Path $PSScriptRoot '..\lib\Common.ps1')
    . (Join-Path $PSScriptRoot '..\lib\HealthAnalysis.ps1')
    $now = [datetime]::SpecifyKind([datetime]::ParseExact('2026-10-01T00:00:00', 's', [Globalization.CultureInfo]::InvariantCulture), [DateTimeKind]::Utc)
    function Get-Iso([int]$Days) { return $now.AddDays($Days).ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + 'Z' }
}

Describe 'Get-ExpiryStatus' {
    It 'returns <Expected> for <Days> days' -ForEach @(
        @{ Days = -3; Expected = 'critical' },
        @{ Days = 5; Expected = 'critical' },
        @{ Days = 20; Expected = 'warning' },
        @{ Days = 200; Expected = 'ok' }
    ) {
        (Get-ExpiryStatus -ExpiresUtc (Get-Iso $Days) -WarningDays 30 -CriticalDays 7 -Now $now).Status | Should -Be $Expected
    }
    It 'reports info when there is no date' {
        (Get-ExpiryStatus -ExpiresUtc $null -Now $now).Status | Should -Be 'info'
    }
    It 'describes expired items in the past tense' {
        (Get-ExpiryStatus -ExpiresUtc (Get-Iso -3) -Now $now).Text | Should -Be 'Expired 3 days ago'
    }
}

Describe 'Get-AgeStatus' {
    It 'warns when the last activity is older than the threshold' {
        (Get-AgeStatus -LastUtc (Get-Iso -5) -WarningHours 72 -Now $now).Status | Should -Be 'warning'
    }
    It 'is ok for recent activity' {
        (Get-AgeStatus -LastUtc (Get-Iso -1) -WarningHours 72 -Now $now).Status | Should -Be 'ok'
    }
    It 'warns when there was never any activity' {
        (Get-AgeStatus -LastUtc $null -Now $now).Text | Should -Be 'Never'
    }
}

Describe 'Get-AppCredentialFindings' {
    BeforeAll {
        $apps = @(
            [pscustomobject]@{ displayName = 'Payroll sync'; appId = 'app-1'; keyCredentials = @()
                passwordCredentials = @([pscustomobject]@{ displayName = 'prod'; endDateTime = (Get-Iso 5) }) },
            [pscustomobject]@{ displayName = 'HR connector'; appId = 'app-2'; keyCredentials = @()
                passwordCredentials = @([pscustomobject]@{ displayName = 'old'; endDateTime = (Get-Iso 10) }, [pscustomobject]@{ displayName = 'new'; endDateTime = (Get-Iso 700) }) },
            [pscustomobject]@{ displayName = 'Old script'; appId = 'app-3'; passwordCredentials = @()
                keyCredentials = @([pscustomobject]@{ displayName = 'CN=old'; endDateTime = (Get-Iso -40) }) },
            [pscustomobject]@{ displayName = 'Healthy app'; appId = 'app-4'; keyCredentials = @()
                passwordCredentials = @([pscustomobject]@{ displayName = 'ok'; endDateTime = (Get-Iso 300) }) },
            [pscustomobject]@{ displayName = 'Report bot'; appId = 'app-5'; keyCredentials = @()
                passwordCredentials = @([pscustomobject]@{ displayName = 'soon'; endDateTime = (Get-Iso 20) }) }
        )
        $rows = Get-AppCredentialFindings -Applications $apps -WarningDays 30 -CriticalDays 7 -Now $now
    }
    It 'flags a last credential expiring within the critical window as critical' {
        ($rows | Where-Object { $_.appId -eq 'app-1' }).status | Should -Be 'critical'
    }
    It 'flags a last credential expiring within the warning window as warning' {
        ($rows | Where-Object { $_.appId -eq 'app-5' }).status | Should -Be 'warning'
    }
    It 'treats an expiring credential with a long-lived replacement as info' {
        ($rows | Where-Object { $_.appId -eq 'app-2' }).status | Should -Be 'info'
    }
    It 'warns when every credential has expired' {
        ($rows | Where-Object { $_.appId -eq 'app-3' }).status | Should -Be 'warning'
    }
    It 'does not report healthy apps' {
        @($rows | Where-Object { $_.appId -eq 'app-4' }).Count | Should -Be 0
    }
}

Describe 'Get-DevicePostureRows' {
    BeforeAll {
        $devices = @(
            [pscustomobject]@{ operatingSystem = 'Windows'; osVersion = '10.0.19045.4651'; complianceState = 'noncompliant'; lastSyncDateTime = (Get-Iso -1) },
            [pscustomobject]@{ operatingSystem = 'Windows'; osVersion = '10.0.22631.4317'; complianceState = 'compliant'; lastSyncDateTime = (Get-Iso -1) },
            [pscustomobject]@{ operatingSystem = 'Windows'; osVersion = '10.0.26100.2033'; complianceState = 'compliant'; lastSyncDateTime = (Get-Iso -60) },
            [pscustomobject]@{ operatingSystem = 'iOS'; osVersion = '18.0'; complianceState = 'compliant'; lastSyncDateTime = (Get-Iso -1) }
        )
        $rows = Get-DevicePostureRows -Devices $devices -InactiveDays 30 -NonCompliantWarningPercent 10 -Now $now
    }
    It 'summarises compliance per platform' {
        $win = $rows | Where-Object { $_.item -eq 'Windows' }
        $win.total | Should -Be 3
        $win.nonCompliant | Should -Be 1
        $win.inactive | Should -Be 1
        $win.status | Should -Be 'critical'
    }
    It 'adds a Windows 10 end-of-support row' {
        ($rows | Where-Object { $_.item -like 'Windows 10*' }).total | Should -Be 1
    }
    It 'reads the build number from an OS version' {
        Get-WindowsBuild '10.0.22631.4317' | Should -Be 22631
        Get-WindowsBuild '18.0' | Should -BeNullOrEmpty
    }
}

Describe 'Get-UnassignedItemRows' {
    It 'lists unassigned items and duplicate policy names' {
        $items = @(
            [pscustomobject]@{ Name = 'Wi-Fi'; Type = 'Configuration profile'; Assigned = $true; LastModified = $null },
            [pscustomobject]@{ Name = 'Wi-Fi'; Type = 'Configuration profile'; Assigned = $true; LastModified = $null },
            [pscustomobject]@{ Name = 'Old VPN'; Type = 'Configuration profile'; Assigned = $false; LastModified = (Get-Iso -400) },
            [pscustomobject]@{ Name = 'Calculator'; Type = 'App'; Assigned = $false; LastModified = $null }
        )
        $rows = @(Get-UnassignedItemRows -Items $items)
        @($rows | Where-Object { $_.detail -eq 'Not assigned to any group.' }).Count | Should -Be 2
        ($rows | Where-Object { $_.item -eq 'Wi-Fi' }).detail | Should -Be 'Name shared by 2 policies.'
    }
}
