[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$TaskName = 'CampusPortalAutoLogin'
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Scheduled task '$TaskName' removed." -ForegroundColor Green
} else {
    Write-Host "Scheduled task '$TaskName' does not exist." -ForegroundColor Yellow
}
