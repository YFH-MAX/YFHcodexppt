[CmdletBinding()]
param(
    [int]$PollSeconds = 0,
    [int]$RetrySeconds = 0,
    [int]$RecheckSeconds = 0,
    [int]$MaxCycles = 0
)

$ErrorActionPreference = 'Stop'
$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ProjectDir 'config.json'
$LoginScript = Join-Path $ProjectDir 'login.ps1'
$LogDir = Join-Path $ProjectDir 'logs'
$LogPath = Join-Path $LogDir 'network-watch.log'

if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Missing config: $ConfigPath" }
if (-not (Test-Path -LiteralPath $LoginScript)) { throw "Missing login script: $LoginScript" }
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

function Get-ConfigInt {
    param([string]$Name, [int]$DefaultValue)
    $value = $config.$Name
    if ($null -eq $value) { return $DefaultValue }
    $parsed = 0
    if ([int]::TryParse([string]$value, [ref]$parsed) -and $parsed -gt 0) { return $parsed }
    return $DefaultValue
}

if ($PollSeconds -le 0) { $PollSeconds = Get-ConfigInt -Name 'MonitorPollSeconds' -DefaultValue 2 }
if ($RetrySeconds -le 0) { $RetrySeconds = Get-ConfigInt -Name 'MonitorRetrySeconds' -DefaultValue 5 }
if ($RecheckSeconds -le 0) { $RecheckSeconds = Get-ConfigInt -Name 'MonitorRecheckSeconds' -DefaultValue 300 }

function Write-WatchLog {
    param([string]$Level, [string]$Message)
    if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 1MB) {
        $archive = Join-Path $LogDir ('network-watch-{0}.log' -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
        Move-Item -LiteralPath $LogPath -Destination $archive -Force
    }
    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
}

function Get-NetworkSignature {
    $candidates = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object {
        $_.NetAdapter.Status -eq 'Up' -and
        $_.IPv4Address -and
        $_.IPv4DefaultGateway -and
        $_.IPv4Address.IPAddress -notlike '169.254.*' -and
        $_.InterfaceAlias -notmatch 'Loopback|vEthernet|VirtualBox|VMware'
    })
    if ($candidates.Count -eq 0) { return '' }

    $preferred = $candidates | Where-Object {
        $_.InterfaceAlias -eq $config.PreferredAdapterAlias -or
        $_.InterfaceDescription -match [regex]::Escape([string]$config.PreferredAdapterAlias)
    } | Select-Object -First 1
    $net = if ($preferred) { $preferred } else { $candidates | Sort-Object InterfaceMetric | Select-Object -First 1 }
    $adapter = Get-NetAdapter -InterfaceIndex $net.InterfaceIndex -ErrorAction Stop
    $ip = [string]$net.IPv4Address.IPAddress
    $mac = ($adapter.MacAddress -replace '[:-]', '').ToLowerInvariant()
    return ('{0}|{1}|{2}|{3}' -f $net.InterfaceIndex, $ip, $mac, $adapter.Status)
}

function Invoke-LoginOnce {
    $powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powerShellExe)) { $powerShellExe = 'powershell.exe' }
    & $powerShellExe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File $LoginScript -Once
    return $LASTEXITCODE
}

$lastSignature = $null
$lastAttemptAt = [datetime]::MinValue
$lastExitCode = $null
$cycle = 0

Write-WatchLog 'INFO' ('Watcher started. poll={0}s retry={1}s recheck={2}s.' -f $PollSeconds, $RetrySeconds, $RecheckSeconds)

while ($true) {
    $cycle++

    try {
        $signature = Get-NetworkSignature

        if ([string]::IsNullOrWhiteSpace($signature)) {
            if (-not [string]::IsNullOrWhiteSpace($lastSignature)) {
                Write-WatchLog 'INFO' 'Network became unavailable; waiting for it to return.'
            }
            $lastSignature = ''
            $lastExitCode = $null
            $lastAttemptAt = [datetime]::MinValue
        }
        else {
            $now = Get-Date
            $networkChanged = $signature -ne $lastSignature

            if ($networkChanged) {
                Write-WatchLog 'INFO' ('Network ready or changed: {0}' -f $signature)
                $lastSignature = $signature
                $lastAttemptAt = [datetime]::MinValue
                $lastExitCode = $null
            }

            $attemptDue = $false
            if ($lastAttemptAt -eq [datetime]::MinValue) {
                $attemptDue = $true
            }
            elseif ($null -eq $lastExitCode -or $lastExitCode -ne 0) {
                $attemptDue = ($now - $lastAttemptAt).TotalSeconds -ge $RetrySeconds
            }
            else {
                $attemptDue = ($now - $lastAttemptAt).TotalSeconds -ge $RecheckSeconds
            }

            if ($attemptDue) {
                $lastAttemptAt = Get-Date
                $exitCode = Invoke-LoginOnce
                $lastExitCode = $exitCode

                switch ($exitCode) {
                    0 { Write-WatchLog 'INFO' 'Login attempt succeeded or the portal session is already online.' }
                    2 { Write-WatchLog 'ERROR' 'Login attempt stopped because the portal rejected the account or password.' }
                    default { Write-WatchLog 'WARN' ('Login attempt failed with exit code {0}; it will be retried.' -f $exitCode) }
                }
            }
        }
    }
    catch {
        Write-WatchLog 'ERROR' ('Watcher loop error: {0}' -f $_.Exception.Message)
    }

    if ($MaxCycles -gt 0 -and $cycle -ge $MaxCycles) { break }
    Start-Sleep -Seconds $PollSeconds
}

Write-WatchLog 'INFO' ('Watcher stopped after {0} cycle(s).' -f $cycle)