[CmdletBinding()]
param(
    [switch]$RunNow
)

$ErrorActionPreference = 'Stop'
$ProjectDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ProjectDir 'config.json'
$SecretPath = Join-Path $ProjectDir 'credential.dpapi'
$LoginScript = Join-Path $ProjectDir 'login.ps1'
$WatcherScript = Join-Path $ProjectDir 'watch-network.ps1'
$TaskName = 'CampusPortalAutoLogin'

if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Missing config: $ConfigPath" }
if (-not (Test-Path -LiteralPath $SecretPath)) {
    Write-Host 'No encrypted credential found. Enter the portal password.' -ForegroundColor Yellow
    $secure = Read-Host 'Password' -AsSecureString
    $secure | ConvertFrom-SecureString | Set-Content -LiteralPath $SecretPath -Encoding ascii
}
if (-not (Test-Path -LiteralPath $LoginScript)) { throw "Missing login script: $LoginScript" }
if (-not (Test-Path -LiteralPath $WatcherScript)) { throw "Missing watcher script: $WatcherScript" }

$userId = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $WatcherScript)
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
try { $trigger.Delay = 'PT2S' } catch { }
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)
$description = 'Watches network changes and automatically authenticates the campus portal after user logon.'

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description $description -Force | Out-Null
Write-Host "Scheduled task '$TaskName' installed for $userId." -ForegroundColor Green

if ($RunNow) {
    Start-ScheduledTask -TaskName $TaskName
    Write-Host "Scheduled task '$TaskName' started." -ForegroundColor Green
}