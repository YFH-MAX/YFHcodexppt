[CmdletBinding()]
param(
    [int]$MaxAttempts = 0,
    [int]$RetryDelaySeconds = 0,
    [int]$InitialDelaySeconds = -1,
    [switch]$Once
)

$ErrorActionPreference = 'Stop'
$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ProjectDir 'config.json'
$SecretPath = Join-Path $ProjectDir 'credential.dpapi'
$LogDir = Join-Path $ProjectDir 'logs'
$LogPath = Join-Path $LogDir 'auto-login.log'

if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

if (-not ('CampusAutoLogin.BoundHttpRequest' -as [type])) {
    Add-Type -TypeDefinition @"
using System;
using System.Net;

namespace CampusAutoLogin
{
    public static class BoundHttpRequest
    {
        public static string LocalIp;
        public static readonly BindIPEndPoint BindDelegate = Bind;

        public static IPEndPoint Bind(ServicePoint servicePoint, IPEndPoint remoteEndPoint, int retryCount)
        {
            return new IPEndPoint(IPAddress.Parse(LocalIp), 0);
        }
    }
}
"@
}

function Write-Log {
    param([string]$Level, [string]$Message)
    if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 1MB) {
        $archive = Join-Path $LogDir ('auto-login-{0}.log' -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
        Move-Item -LiteralPath $LogPath -Destination $archive -Force
    }
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Get-PlainSecret {
    if (-not (Test-Path -LiteralPath $SecretPath)) { throw "Credential file not found: $SecretPath" }
    $encrypted = (Get-Content -LiteralPath $SecretPath -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($encrypted)) { throw 'Credential file is empty.' }
    $secure = ConvertTo-SecureString $encrypted
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Get-NetworkInterface {
    $candidates = @(Get-NetIPConfiguration | Where-Object {
        $_.NetAdapter.Status -eq 'Up' -and
        $_.IPv4Address -and
        $_.IPv4DefaultGateway -and
        $_.IPv4Address.IPAddress -notlike '169.254.*' -and
        $_.InterfaceAlias -notmatch 'Loopback|vEthernet|VirtualBox|VMware'
    })
    if ($candidates.Count -eq 0) { return $null }
    $preferred = $candidates | Where-Object {
        $_.InterfaceAlias -eq $config.PreferredAdapterAlias -or
        $_.InterfaceDescription -match [regex]::Escape([string]$config.PreferredAdapterAlias)
    } | Select-Object -First 1
    if ($preferred) { return $preferred }
    return $candidates | Sort-Object InterfaceMetric | Select-Object -First 1
}

function Get-ResponseField {
    param([string]$Content, [string]$Name)
    $pattern = '"' + [regex]::Escape($Name) + '"\s*:\s*"?([^",}\]]+)'
    $match = [regex]::Match($Content, $pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return $null
}

function Invoke-LoginAttempt {
    param([string]$Password)

    $net = Get-NetworkInterface
    if (-not $net) {
        return [pscustomobject]@{ Success=$false; Fatal=$false; Ip=''; Mac=''; Result=''; RetCode=''; Message='No active default network interface.' }
    }

    $adapter = Get-NetAdapter -InterfaceIndex $net.InterfaceIndex -ErrorAction Stop
    $ip = [string]$net.IPv4Address.IPAddress
    $mac = ($adapter.MacAddress -replace '[:-]', '').ToLowerInvariant()
    $account = ([string]$config.UserAccountPrefix) + ([string]$config.Username)

    $parameters = [ordered]@{
        callback        = 'dr1003'
        login_method    = '1'
        user_account    = $account
        user_password   = $Password
        wlan_user_ip    = $ip
        wlan_user_ipv6  = ''
        wlan_user_mac   = $mac
        wlan_ac_ip      = [string]$config.WlanAcIp
        wlan_ac_name    = ''
        jsVersion       = '4.2'
        terminal_type   = '1'
        lang            = 'zh-cn'
        v               = '4004'
    }

    $queryParts = foreach ($key in $parameters.Keys) {
        '{0}={1}' -f [Uri]::EscapeDataString([string]$key), [Uri]::EscapeDataString([string]$parameters[$key])
    }
    $uri = ([string]$config.PortalBaseUrl).TrimEnd('?') + '?' + ($queryParts -join '&')

    try {
        [CampusAutoLogin.BoundHttpRequest]::LocalIp = $ip

        $request = [System.Net.HttpWebRequest]::Create($uri)
        $request.Method = 'GET'
        $request.UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124 Safari/537.36'
        $request.Referer = 'http://10.1.1.10:801/eportal/'
        $request.Accept = '*/*'
        $timeoutMs = [Math]::Max(1000, ([int]$config.RequestTimeoutSeconds * 1000))
        $request.Timeout = $timeoutMs
        $request.ReadWriteTimeout = $timeoutMs
        $request.ServicePoint.BindIPEndPointDelegate = [CampusAutoLogin.BoundHttpRequest]::BindDelegate

        $response = $request.GetResponse()
        try {
            $stream = $response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::UTF8)
            try { $content = [string]$reader.ReadToEnd() }
            finally { $reader.Dispose() }
        }
        finally {
            $response.Close()
        }

        $result = Get-ResponseField -Content $content -Name 'result'
        $retCode = Get-ResponseField -Content $content -Name 'ret_code'
        $message = Get-ResponseField -Content $content -Name 'msg'
        if ([string]::IsNullOrWhiteSpace($message)) { $message = $content.Trim() }

        $success = $false
        if ($retCode -eq '0' -or $retCode -eq '2') { $success = $true }
        if ($result -eq '1') { $success = $true }
        if ($message -match '成功|已经在线|已在线|success|online') { $success = $true }

        $fatal = $false
        if ($message -match '密码错误|密码不正确|账号不存在|用户不存在|认证失败|invalid password|invalid user') { $fatal = $true }

        return [pscustomobject]@{
            Success = $success
            Fatal = $fatal
            Ip = $ip
            Mac = $mac
            Result = $result
            RetCode = $retCode
            Message = $message
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            Fatal = $false
            Ip = $ip
            Mac = $mac
            Result = ''
            RetCode = ''
            Message = $_.Exception.Message
        }
    }
}

$mutex = New-Object Threading.Mutex($false, 'CampusPortalAutoLogin')
$lockTaken = $false
try {
    $lockTaken = $mutex.WaitOne(0)
    if (-not $lockTaken) {
        Write-Log 'INFO' 'Another auto-login instance is already running.'
        exit 3
    }

    $password = Get-PlainSecret
    if ($MaxAttempts -le 0) { $MaxAttempts = [int]$config.MaxAttempts }
    if ($RetryDelaySeconds -le 0) { $RetryDelaySeconds = [int]$config.RetryDelaySeconds }
    if ($InitialDelaySeconds -lt 0) { $InitialDelaySeconds = [int]$config.InitialDelaySeconds }
    if ($Once) { $MaxAttempts = 1; $InitialDelaySeconds = 0 }

    if ($InitialDelaySeconds -gt 0) { Start-Sleep -Seconds $InitialDelaySeconds }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $r = Invoke-LoginAttempt -Password $password
        Write-Log 'INFO' ('Attempt {0}/{1} ip={2} mac={3} result={4} ret_code={5} success={6} msg={7}' -f $attempt, $MaxAttempts, $r.Ip, $r.Mac, $r.Result, $r.RetCode, $r.Success, $r.Message)
        if ($r.Success) { exit 0 }
        if ($r.Fatal) {
            Write-Log 'ERROR' 'Portal returned a credential or account error; retries stopped.'
            exit 2
        }
        if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds $RetryDelaySeconds }
    }

    Write-Log 'WARN' 'Auto-login attempts exhausted without success.'
    exit 1
}
finally {
    if ($lockTaken) { [void]$mutex.ReleaseMutex() }
    $mutex.Dispose()
}

