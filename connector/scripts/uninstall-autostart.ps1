# Removes the "ZKT Connector" start-up task and stops the running connector.
# Run in PowerShell opened with "Run as administrator", from the connector folder:
#   powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-autostart.ps1
$ErrorActionPreference = "Stop"
$TaskName = "ZKT Connector"
$dir     = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$script  = Join-Path $dir "src\index.js"
$cmdPath = Join-Path $dir "run-connector.cmd"

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Scheduled task '$TaskName' removed." -ForegroundColor Green
} else {
    Write-Host "Scheduled task '$TaskName' was not installed."
}

Get-CimInstance Win32_Process |
    Where-Object { $_.CommandLine -and ($_.CommandLine -like "*$script*" -or $_.CommandLine -like "*$cmdPath*") } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host "Stopped process $($_.ProcessId)" }

if (Test-Path $cmdPath) { Remove-Item $cmdPath -Force }
Write-Host "Done. Logs are kept in $(Join-Path $dir 'logs')."