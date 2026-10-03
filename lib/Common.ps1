# Shared helpers: configuration, dates, report output.
# Compatible with Windows PowerShell 5.1 and PowerShell 7+.

# Windows PowerShell 5.1: an extended type definition on System.Array can make ConvertTo-Json write
# arrays as {"value":[...],"Count":n}. Removing it is the standard fix and does not affect .Count.
if ($PSVersionTable.PSVersion.Major -lt 6) {
    Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue
}

function Read-ToolConfig {
    <# Returns the parsed config, or $null after creating config.json from the example on first run. #>
    param(
        [Parameter(Mandatory = $true)][string]$ConfigPath,
        [Parameter(Mandatory = $true)][string]$ExamplePath
    )
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        if (Test-Path -LiteralPath $ExamplePath) {
            Copy-Item -LiteralPath $ExamplePath -Destination $ConfigPath
            Write-Host "Created config.json from config.example.json." -ForegroundColor Yellow
            Write-Host "Fill in TenantId, ApplicationId and ClientSecret, then run the script again." -ForegroundColor Yellow
            return $null
        }
        throw "Configuration file not found: $ConfigPath"
    }
    try { return (Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json) }
    catch { throw "config.json is not valid JSON: $($_.Exception.Message)" }
}

function Get-ConfigValue {
    param($Config, [string]$Name, $Default)
    $value = $Config.$Name
    if ($null -eq $value) { return $Default }
    if ($value -is [string] -and $value -eq '') { return $Default }
    return $value
}

function ConvertTo-UtcDate {
    <# Accepts an ISO 8601 string or a DateTime. Returns a UTC DateTime, or $null for empty / "never" values. #>
    param($Value)
    if ($null -eq $Value) { return $null }
    $result = $null
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { $result = [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
        else { $result = $Value.ToUniversalTime() }
    }
    else {
        $text = [string]$Value
        if ([string]::IsNullOrWhiteSpace($text)) { return $null }
        $parsed = [datetimeoffset]::MinValue
        $styles = [Globalization.DateTimeStyles]::AssumeUniversal
        if (-not [datetimeoffset]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { return $null }
        $result = $parsed.UtcDateTime
    }
    # Graph uses 0001-01-01 (and sometimes 1601-01-01) to mean "never".
    if ($result.Year -le 1601) { return $null }
    return $result
}

function Format-UtcDate {
    param($Value)
    $date = ConvertTo-UtcDate $Value
    if ($null -eq $date) { return $null }
    return $date.ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + 'Z'
}

function Get-AgeInDays {
    <# Whole days elapsed since the date, or $null when there is no date. #>
    param($Value, [datetime]$Now = [datetime]::UtcNow)
    $date = ConvertTo-UtcDate $Value
    if ($null -eq $date) { return $null }
    return [int][math]::Floor(($Now - $date).TotalDays)
}

function Get-DaysUntil {
    <# Whole days until the date (negative when in the past), or $null when there is no date. #>
    param($Value, [datetime]$Now = [datetime]::UtcNow)
    $date = ConvertTo-UtcDate $Value
    if ($null -eq $date) { return $null }
    return [int][math]::Floor(($date - $Now).TotalDays)
}

function Format-Count {
    param([int]$Count, [string]$Singular, [string]$PluralForm)
    if (-not $PluralForm) { $PluralForm = $Singular + 's' }
    $word = if ($Count -eq 1) { $Singular } else { $PluralForm }
    return ('{0} {1}' -f $Count.ToString('N0', [Globalization.CultureInfo]::InvariantCulture), $word)
}

function Protect-TenantId {
    <# Shows only the start of the tenant ID so screenshots of the report are safe to share. #>
    param([string]$TenantId)
    if ([string]::IsNullOrWhiteSpace($TenantId)) { return '' }
    if ($TenantId.Length -le 8) { return $TenantId }
    return $TenantId.Substring(0, 8) + '...'
}

function New-ReportColumn {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Label,
        [ValidateSet('text', 'date', 'days', 'number', 'bool', 'status', 'id')][string]$Type = 'text',
        [switch]$Wide,
        [switch]$NeverWhenEmpty
    )
    $column = [ordered]@{ key = $Key; label = $Label; type = $Type }
    if ($Wide) { $column['wide'] = $true }
    if ($NeverWhenEmpty) { $column['never'] = $true }
    return [pscustomobject]$column
}

function Get-WorstStatus {
    param([string[]]$Statuses)
    $rank = @{ critical = 5; error = 4; warning = 3; info = 2; ok = 1 }
    $worst = 'ok'
    foreach ($status in $Statuses) {
        if ($status -and $rank.ContainsKey($status) -and $rank[$status] -gt $rank[$worst]) { $worst = $status }
    }
    return $worst
}

function ConvertTo-ReportJson {
    param([Parameter(Mandatory = $true)]$Data, [switch]$Compress)
    if ($Compress) { return ($Data | ConvertTo-Json -Depth 12 -Compress) }
    return ($Data | ConvertTo-Json -Depth 12)
}

function Write-Utf8File {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Content)
    [IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function New-HtmlReport {
    <# Injects the report data into the self-contained HTML template. #>
    param(
        [Parameter(Mandatory = $true)]$Data,
        [Parameter(Mandatory = $true)][string]$TemplatePath,
        [Parameter(Mandatory = $true)][string]$OutputPath
    )
    if (-not (Test-Path -LiteralPath $TemplatePath)) { throw "Report template not found: $TemplatePath" }
    $template = [IO.File]::ReadAllText($TemplatePath, [Text.Encoding]::UTF8)
    if ($template.IndexOf('__REPORT_DATA__') -lt 0) { throw "Report template is missing the __REPORT_DATA__ placeholder." }
    # Escape angle brackets so tenant data can never close the <script> element it is embedded in.
    $json = (ConvertTo-ReportJson -Data $Data -Compress).Replace('<', '\u003c').Replace('>', '\u003e')
    Write-Utf8File -Path $OutputPath -Content $template.Replace('__REPORT_DATA__', $json)
}

function Export-RowsToCsv {
    param($Rows, [Parameter(Mandatory = $true)][string]$Path)
    $list = @($Rows)
    if ($list.Count -eq 0) { return $false }
    $list | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding UTF8
    return $true
}

function Write-Step {
    param([string]$Message)
    Write-Host ("[{0}] {1}" -f (Get-Date).ToString('HH:mm:ss'), $Message)
}
