# Minimal Microsoft Graph client used by the tool scripts.
# - App-only (client credentials) authentication with token caching
# - Automatic paging (@odata.nextLink)
# - Retries with Retry-After / exponential backoff for throttling (429) and transient errors (5xx)
# Compatible with Windows PowerShell 5.1 and PowerShell 7+. Read-only: only GET requests are issued.

$script:Graph = @{
    TenantId                   = $null
    ClientId                   = $null
    ClientSecret               = $null
    LoginBaseUrl               = 'https://login.microsoftonline.com'
    BaseUrl                    = 'https://graph.microsoft.com/v1.0'
    BetaUrl                    = 'https://graph.microsoft.com/beta'
    Scope                      = 'https://graph.microsoft.com/.default'
    Token                      = $null
    TokenExpiresUtc            = [datetime]::MinValue
    TimeoutSec                 = 120
    MaxRetry                   = 5
    ProxyUrl                   = ''
    UseDefaultProxyCredentials = $false
    RequestCount               = 0
}

function Initialize-GraphClient {
    param([Parameter(Mandatory = $true)]$Config)

    foreach ($name in @('TenantId', 'ApplicationId', 'ClientSecret')) {
        $value = [string]$Config.$name
        if ([string]::IsNullOrWhiteSpace($value) -or $value -like 'YOUR_*' -or $value -like 'PASTE_*') {
            throw "config.json: '$name' is not set. Edit config.json and run again."
        }
    }

    $script:Graph.TenantId = ([string]$Config.TenantId).Trim()
    $script:Graph.ClientId = ([string]$Config.ApplicationId).Trim()
    $script:Graph.ClientSecret = [string]$Config.ClientSecret

    if ($Config.GraphBaseUrl) { $script:Graph.BaseUrl = ([string]$Config.GraphBaseUrl).TrimEnd('/') }
    if ($Config.GraphBetaBaseUrl) { $script:Graph.BetaUrl = ([string]$Config.GraphBetaBaseUrl).TrimEnd('/') }
    if ($Config.LoginBaseUrl) { $script:Graph.LoginBaseUrl = ([string]$Config.LoginBaseUrl).TrimEnd('/') }
    $script:Graph.Scope = ([Uri]$script:Graph.BaseUrl).GetLeftPart([UriPartial]::Authority) + '/.default'

    if ($Config.RequestTimeoutSeconds) { $script:Graph.TimeoutSec = [int]$Config.RequestTimeoutSeconds }
    if ($null -ne $Config.GraphMaxRetryCount) { $script:Graph.MaxRetry = [math]::Max(0, [math]::Min(10, [int]$Config.GraphMaxRetryCount)) }
    if ($Config.ProxyUrl) { $script:Graph.ProxyUrl = [string]$Config.ProxyUrl }
    if ($Config.UseDefaultProxyCredentials) { $script:Graph.UseDefaultProxyCredentials = $true }

    # Older Windows PowerShell hosts may not enable TLS 1.2 by default.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

function Add-ProxyParameter {
    param([hashtable]$Params)
    if ($script:Graph.ProxyUrl) {
        $Params['Proxy'] = $script:Graph.ProxyUrl
        if ($script:Graph.UseDefaultProxyCredentials) { $Params['ProxyUseDefaultCredentials'] = $true }
    }
}

function Get-HttpStatusCode {
    param($ErrorRecord)
    try {
        $response = $ErrorRecord.Exception.Response
        if ($null -ne $response) { return [int]$response.StatusCode }
    }
    catch { }
    return 0
}

function Get-RetryAfterSecond {
    param($ErrorRecord)
    try {
        $response = $ErrorRecord.Exception.Response
        if ($null -eq $response) { return 0 }
        if ($response.GetType().FullName -eq 'System.Net.Http.HttpResponseMessage') {
            # PowerShell 7
            $retryAfter = $response.Headers.RetryAfter
            if ($retryAfter -and $retryAfter.Delta) { return [int][math]::Ceiling($retryAfter.Delta.TotalSeconds) }
        }
        else {
            # Windows PowerShell 5.1 (HttpWebResponse)
            $value = $response.Headers['Retry-After']
            if ($value) { return [int]$value }
        }
    }
    catch { }
    return 0
}

function Get-GraphErrorMessage {
    param($ErrorRecord)
    $raw = $null
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { $raw = [string]$ErrorRecord.ErrorDetails.Message }
    if ($raw) {
        try {
            $parsed = $raw | ConvertFrom-Json
            if ($parsed.error -and $parsed.error.message) { return [string]$parsed.error.message }
            if ($parsed.error_description) { return ([string]$parsed.error_description).Split([char]13, [char]10)[0] }
        }
        catch { }
        return $raw
    }
    return $ErrorRecord.Exception.Message
}

function Get-GraphAccessToken {
    if ($script:Graph.Token -and [datetime]::UtcNow -lt $script:Graph.TokenExpiresUtc) {
        return $script:Graph.Token
    }

    $params = @{
        Method      = 'Post'
        Uri         = "$($script:Graph.LoginBaseUrl)/$($script:Graph.TenantId)/oauth2/v2.0/token"
        ContentType = 'application/x-www-form-urlencoded'
        Body        = @{
            client_id     = $script:Graph.ClientId
            client_secret = $script:Graph.ClientSecret
            scope         = $script:Graph.Scope
            grant_type    = 'client_credentials'
        }
        TimeoutSec  = $script:Graph.TimeoutSec
        ErrorAction = 'Stop'
    }
    Add-ProxyParameter -Params $params

    try { $response = Invoke-RestMethod @params }
    catch { throw "Authentication to Microsoft Entra ID failed: $(Get-GraphErrorMessage $_)" }

    $script:Graph.Token = [string]$response.access_token
    $script:Graph.TokenExpiresUtc = [datetime]::UtcNow.AddSeconds([int]$response.expires_in - 300)
    return $script:Graph.Token
}

function Invoke-GraphRequest {
    <#
      Sends one GET request to Microsoft Graph and returns the parsed response.
      On failure, throws an exception whose .Data['StatusCode'] holds the HTTP status code.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [hashtable]$ExtraHeaders
    )

    $attempt = 0
    while ($true) {
        $attempt++
        $headers = @{ Authorization = "Bearer $(Get-GraphAccessToken)" }
        if ($ExtraHeaders) { foreach ($key in $ExtraHeaders.Keys) { $headers[$key] = $ExtraHeaders[$key] } }

        $params = @{
            Method      = 'Get'
            Uri         = $Uri
            Headers     = $headers
            TimeoutSec  = $script:Graph.TimeoutSec
            ErrorAction = 'Stop'
        }
        Add-ProxyParameter -Params $params

        try {
            $script:Graph.RequestCount++
            return Invoke-RestMethod @params
        }
        catch {
            $status = Get-HttpStatusCode $_
            $retryable = ($status -eq 429) -or ($status -ge 500) -or ($status -eq 0)
            if ($retryable -and $attempt -le $script:Graph.MaxRetry) {
                $delay = Get-RetryAfterSecond $_
                if ($delay -le 0) { $delay = [int][math]::Min(60, [math]::Pow(2, $attempt)) }
                Write-Verbose "Graph returned $status. Retrying in $delay s (attempt $attempt of $($script:Graph.MaxRetry))."
                Start-Sleep -Seconds $delay
                continue
            }
            if ($status -eq 401 -and $attempt -eq 1) {
                $script:Graph.Token = $null
                continue
            }

            $path = $Uri
            try { $path = ([Uri]$Uri).AbsolutePath } catch { }
            $exception = New-Object System.Exception ("Graph request failed (HTTP {0}) for {1}: {2}" -f $status, $path, (Get-GraphErrorMessage $_))
            $exception.Data['StatusCode'] = $status
            throw $exception
        }
    }
}

function Get-GraphCollection {
    <# Returns every item of a Graph collection, following @odata.nextLink. #>
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [hashtable]$ExtraHeaders,
        [string]$Activity
    )

    $items = New-Object System.Collections.Generic.List[object]
    $next = $Uri
    while ($next) {
        $response = Invoke-GraphRequest -Uri $next -ExtraHeaders $ExtraHeaders
        if ($null -ne $response.value) {
            foreach ($item in @($response.value)) { $items.Add($item) }
        }
        $next = [string]$response.'@odata.nextLink'
        if ($Activity) { Write-Progress -Activity $Activity -Status ("{0} records" -f $items.Count) }
    }
    if ($Activity) { Write-Progress -Activity $Activity -Completed }
    return $items.ToArray()
}
