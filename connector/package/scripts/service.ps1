# ZKT Connector - start, stop or check the background connector.
# Used by Start-Connector.cmd, Stop-Connector.cmd and Connector-Status.cmd (as administrator).
param([ValidateSet("Start", "Stop", "Status")][string]$Action = "Status")
$ErrorActionPreference = "Stop"
$TaskName = "ZKT Connector"
$Dest     = Join-Path $env:ProgramData "ZKTConnector"
$LogFile  = Join-Path $Dest "logs\connector.log"

# Locks the folder to Administrators + SYSTEM (it holds the connector token) in a way that
# keeps every file readable by the connector: set the rule once on the folder, then let
# everything inside inherit it. (Setting rules on each file with /T can leave files unreadable.)
function Set-ConnectorPermissions([string]$Path) {
    & icacls.exe $Path /inheritance:r /grant:r "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not set permissions on $Path (icacls exit code $LASTEXITCODE)." }
    & icacls.exe (Join-Path $Path "*") /reset /T /C /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not reset permissions inside $Path (icacls exit code $LASTEXITCODE)." }
    $main = Join-Path $Path "src\index.js"
    if (Test-Path $main) {
        $ok = $false
        foreach ($ace in (Get-Acl $main).Access) {
            try { $sid = $ace.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { continue }
            if ($sid -eq "S-1-5-18" -and $ace.AccessControlType -eq "Allow" -and ($ace.FileSystemRights.ToString() -match "FullControl|Read")) { $ok = $true }
        }
        if (-not $ok) { throw "Windows did not give the connector (SYSTEM) read access to $main." }
    }
}

function Show-Log([int]$Lines) {
    if (Test-Path $LogFile) {
        Get-Content $LogFile -Tail $Lines | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Host "  (no log yet)"
    }
}

function Get-ConnectorProcesses {
    $procs = Get-CimInstance Win32_Process -Filter "Name='node.exe' OR Name='cmd.exe'" -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        $cl = [string]$p.CommandLine
        if (-not $cl) { continue }
        if ($cl.IndexOf($Dest, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        if (($cl.IndexOf("run-connector.cmd", [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
            ($cl.IndexOf("src\index.js", [StringComparison]::OrdinalIgnoreCase) -ge 0)) { $p }
    }
}

function Stop-Connector {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    foreach ($p in @(Get-ConnectorProcesses)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
}

function Read-NewLog([long]$From) {
    if (-not (Test-Path $LogFile)) { return "" }
    $fs = [System.IO.File]::Open($LogFile, "Open", "Read", "ReadWrite")
    try {
        if ($fs.Length -lt $From) { $From = 0 }
        [void]$fs.Seek($From, "Begin")
        return (New-Object System.IO.StreamReader($fs)).ReadToEnd()
    } finally { $fs.Close() }
}

try {
    $me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Administrator permission is needed. Double-click the .cmd file again and click Yes."
    }
    if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {
        throw "The ZKT Connector is not installed on this PC. Run Install.cmd first."
    }

    switch ($Action) {
        "Start" {
            Write-Host "Starting the ZKT Connector..." -ForegroundColor Cyan
            Stop-Connector   # a clean restart if it was already running or stuck
            Set-ConnectorPermissions $Dest   # repairs folders left unreadable by an older installer
            $from = 0
            if (Test-Path $LogFile) { $from = (Get-Item $LogFile).Length }
            Start-ScheduledTask -TaskName $TaskName
            $ok = $false; $failed = $false; $text = ""
            for ($i = 0; $i -lt 30 -and -not $ok -and -not $failed; $i++) {
                Start-Sleep -Seconds 1
                $text = Read-NewLog $from
                if ($text -match "Connected to ") { $ok = $true }
                elseif ($text -match "ERROR|EPERM|EACCES|Error:") { $failed = $true }
            }
            ($text -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 8) | ForEach-Object { Write-Host "  $_" }
            Write-Host ""
            if ($ok) {
                Write-Host "RUNNING. The connector is connected and waiting for syncs." -ForegroundColor Green
            } elseif ($failed -and $text -match "EPERM|EACCES") {
                Write-Host "Windows blocked the connector from reading its files." -ForegroundColor Red
                Write-Host "Run Install.cmd again from a fresh download (Download installer in the dashboard)."
            } elseif ($failed) {
                Write-Host "The connector started but reported an error (see above)." -ForegroundColor Red
                Write-Host "It retries by itself. Check the internet connection, or download the installer again if the token is not valid."
            } else {
                Write-Host "Started, but it has not connected to the server yet. It keeps retrying by itself." -ForegroundColor Yellow
            }
        }
        "Stop" {
            Stop-Connector
            if (@(Get-ConnectorProcesses).Count) {
                Write-Host "Some connector processes are still running. Try again in a few seconds." -ForegroundColor Yellow
            } else {
                Write-Host "STOPPED. Attendance is not synced until you run Start-Connector.cmd." -ForegroundColor Yellow
                Write-Host "It also starts again automatically when Windows restarts."
            }
        }
        "Status" {
            $node = @(Get-ConnectorProcesses | Where-Object { $_.Name -eq "node.exe" })
            $info = Get-ScheduledTaskInfo -TaskName $TaskName
            if ($node.Count) {
                $since = $node[0].CreationDate
                Write-Host "RUNNING since $since" -ForegroundColor Green
            } else {
                Write-Host "NOT RUNNING. Double-click Start-Connector.cmd to start it." -ForegroundColor Red
            }
            Write-Host "Start-up task last run: $($info.LastRunTime)"
            Write-Host "Folder   : $Dest"
            Write-Host "Log file : $LogFile"
            Write-Host ""
            Write-Host "Latest log lines:"
            Show-Log 15
        }
    }
}
catch {
    Write-Host ""
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}