# ZKT Connector uninstaller. Started by Uninstall.cmd (as administrator).
$ErrorActionPreference = "Stop"
$TaskName = "ZKT Connector"
$Dest     = Join-Path $env:ProgramData "ZKTConnector"

try {
    $me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Administrator permission is needed. Double-click Uninstall.cmd and click Yes."
    }

    $dirs = @($Dest)
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        foreach ($a in $task.Actions) { if ($a.WorkingDirectory) { $dirs += $a.WorkingDirectory } }
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Start-up task removed."
    } else {
        Write-Host "Start-up task was not installed."
    }

    $procs = Get-CimInstance Win32_Process -Filter "Name='node.exe' OR Name='cmd.exe'" -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        $cl = [string]$p.CommandLine
        if (-not $cl) { continue }
        $isConnector = ($cl.IndexOf("run-connector.cmd", [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                       ($cl.IndexOf("src\index.js", [StringComparison]::OrdinalIgnoreCase) -ge 0)
        if (-not $isConnector) { continue }
        foreach ($d in $dirs) {
            if ($d -and $cl.IndexOf($d, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
                Write-Host "Stopped connector process $($p.ProcessId)."
                break
            }
        }
    }

    if (Test-Path $Dest) {
        # Delete a few seconds later, so this window (which may run from that folder) can finish.
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c ping -n 4 127.0.0.1 >nul & rmdir /s /q `"$Dest`"" -WindowStyle Hidden
        Write-Host "Removing $Dest ..."
    }
    Write-Host ""
    Write-Host "ZKT Connector has been removed from this PC." -ForegroundColor Green
    Write-Host "To stop it being used anywhere, also click Revoke on the connector in the dashboard."
}
catch {
    Write-Host ""
    Write-Host "UNINSTALL FAILED: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}