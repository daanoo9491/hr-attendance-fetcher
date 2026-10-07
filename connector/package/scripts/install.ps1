# ZKT Connector installer. Started by Install.cmd (as administrator).
# Installs Node.js if needed, copies the connector to C:\ProgramData\ZKTConnector,
# and registers a Windows task that runs it at start-up (as SYSTEM) and keeps it running.
$ErrorActionPreference = "Stop"
$TaskName = "ZKT Connector"
$Dest     = Join-Path $env:ProgramData "ZKTConnector"
$Source   = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

function Step([string]$Text) { Write-Host ""; Write-Host "==> $Text" -ForegroundColor Cyan }
function Fail([string]$Text) {
    Write-Host ""
    Write-Host "INSTALL FAILED: $Text" -ForegroundColor Red
    exit 1
}

function Find-Node {
    $cmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @("$env:ProgramFiles\nodejs\node.exe", "${env:ProgramFiles(x86)}\nodejs\node.exe")) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

# Stops connector processes started from any of the given folders (never anything else).
function Stop-ConnectorProcesses([string[]]$Dirs) {
    $procs = Get-CimInstance Win32_Process -Filter "Name='node.exe' OR Name='cmd.exe'" -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        $cl = [string]$p.CommandLine
        if (-not $cl) { continue }
        $isConnector = ($cl.IndexOf("run-connector.cmd", [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
                       ($cl.IndexOf("src\index.js", [StringComparison]::OrdinalIgnoreCase) -ge 0)
        if (-not $isConnector) { continue }
        foreach ($d in $Dirs) {
            if ($d -and $cl.IndexOf($d, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
                break
            }
        }
    }
}

try {
    $version = (Get-Content (Join-Path $Source "package.json") -Raw | ConvertFrom-Json).version
    Write-Host "ZKT Connector $version - setup" -ForegroundColor White

    $me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Fail "Administrator permission is needed. Double-click Install.cmd and click Yes."
    }
    if (-not (Test-Path (Join-Path $Source ".env"))) {
        Fail "The settings file (.env) is missing. Download the installer again from the dashboard."
    }
    if ($Source.TrimEnd("\") -ieq $Dest.TrimEnd("\")) {
        Fail "Run Install.cmd from the extracted download folder, not from $Dest."
    }

    # ------------------------------------------------------------ Node.js
    Step "Checking Node.js"
    $node = Find-Node
    if (-not $node) {
        if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
            Write-Host "Node.js not found. Installing Node.js LTS (this can take a few minutes)..."
            & winget.exe install -e --id OpenJS.NodeJS.LTS --scope machine --silent --accept-package-agreements --accept-source-agreements | Out-Host
            $node = Find-Node
        }
    }
    if (-not $node) {
        Start-Process "https://nodejs.org/en/download"
        Fail "Node.js is required. Install the LTS version from nodejs.org (the page has been opened), then run Install.cmd again."
    }
    $nodeVersion = (& $node -v).Trim()
    $major = [int](($nodeVersion.TrimStart("v")).Split(".")[0])
    if ($major -lt 18) {
        Start-Process "https://nodejs.org/en/download"
        Fail "Node.js $nodeVersion is too old (18 or newer is needed). Install the LTS version from nodejs.org, then run Install.cmd again."
    }
    Write-Host "Node.js $nodeVersion at $node"

    # ------------------------------------------------------------ stop the previous version
    Step "Stopping any previous version"
    $dirs = @($Dest)
    $old = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($old) {
        foreach ($a in $old.Actions) { if ($a.WorkingDirectory) { $dirs += $a.WorkingDirectory } }
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed the previous start-up task."
    }
    Stop-ConnectorProcesses $dirs
    Start-Sleep -Seconds 2

    # ------------------------------------------------------------ copy files
    Step "Copying files to $Dest"
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    foreach ($sub in @("src", "scripts")) {
        $p = Join-Path $Dest $sub
        if (Test-Path $p) { Remove-Item $p -Recurse -Force }
    }
    Copy-Item (Join-Path $Source "src") (Join-Path $Dest "src") -Recurse -Force
    New-Item -ItemType Directory -Force -Path (Join-Path $Dest "scripts") | Out-Null
    foreach ($f in @("uninstall.ps1", "service.ps1")) {
        Copy-Item (Join-Path $Source "scripts\$f") (Join-Path $Dest "scripts\$f") -Force
    }
    foreach ($f in @("package.json", ".env", "Uninstall.cmd", "Test-Connection.cmd", "README.txt",
                     "Start-Connector.cmd", "Stop-Connector.cmd", "Connector-Status.cmd")) {
        Copy-Item (Join-Path $Source $f) (Join-Path $Dest $f) -Force
    }
    Get-ChildItem $Dest -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

    # The .env file holds the connector token: only administrators and SYSTEM may read this folder.
    & icacls.exe $Dest /inheritance:r /grant:r "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" /T /Q | Out-Null

    $logs    = Join-Path $Dest "logs"
    $logFile = Join-Path $logs "connector.log"
    $script  = Join-Path $Dest "src\index.js"
    $cmdPath = Join-Path $Dest "run-connector.cmd"
    New-Item -ItemType Directory -Force -Path $logs | Out-Null

    # Runs the connector, appends to logs\connector.log (kept under ~5 MB), restarts 15 s after any exit.
    $wrapper = @"
@echo off
rem Generated by the ZKT Connector installer - run Install.cmd again instead of editing.
cd /d "$Dest"
:loop
for %%F in ("$logFile") do if %%~zF GTR 5000000 move /y "$logFile" "$logFile.old" >nul
echo ===== %date% %time% starting connector >> "$logFile"
"$node" "$script" >> "$logFile" 2>&1
ping -n 16 127.0.0.1 >nul
goto loop
"@
    [System.IO.File]::WriteAllText($cmdPath, ($wrapper -replace "`r?`n", "`r`n"), [System.Text.Encoding]::ASCII)

    # ------------------------------------------------------------ start-up task
    Step "Registering the start-up task"
    $action    = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$cmdPath`"" -WorkingDirectory $Dest
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
                   -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
                   -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description "Imports attendance from the ZKTeco machine into HR Attendance ($Dest)" -Force | Out-Null

    # ------------------------------------------------------------ Start Menu shortcuts (all users)
    $menu = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\ZKT Connector"
    if (Test-Path $menu) { Remove-Item $menu -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $menu | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    foreach ($s in @(
        @("Start ZKT Connector", "Start-Connector.cmd"),
        @("Stop ZKT Connector", "Stop-Connector.cmd"),
        @("ZKT Connector status", "Connector-Status.cmd"),
        @("Test machine connection", "Test-Connection.cmd"),
        @("Uninstall ZKT Connector", "Uninstall.cmd"))) {
        $lnk = $shell.CreateShortcut((Join-Path $menu ($s[0] + ".lnk")))
        $lnk.TargetPath = Join-Path $Dest $s[1]
        $lnk.WorkingDirectory = $Dest
        $lnk.Save()
    }
    Write-Host "Added Start Menu shortcuts: Start menu > ZKT Connector"

    $startedAt = (Get-Item $logFile -ErrorAction SilentlyContinue).Length
    if (-not $startedAt) { $startedAt = 0 }
    Start-ScheduledTask -TaskName $TaskName

    # ------------------------------------------------------------ check it connected
    Step "Checking the connection to the server"
    $ok = $false
    $newLines = @()
    for ($i = 0; $i -lt 30 -and -not $ok; $i++) {
        Start-Sleep -Seconds 1
        if (Test-Path $logFile) {
            $fs = [System.IO.File]::Open($logFile, "Open", "Read", "ReadWrite")
            try {
                [void]$fs.Seek($startedAt, "Begin")
                $text = (New-Object System.IO.StreamReader($fs)).ReadToEnd()
            } finally { $fs.Close() }
            $newLines = $text -split "`r?`n" | Where-Object { $_ }
            if ($text -match "Connected to ") { $ok = $true }
            elseif ($text -match "ERROR") { break }
        }
    }
    $newLines | Select-Object -Last 8 | ForEach-Object { Write-Host "  $_" }

    Write-Host ""
    if ($ok) {
        Write-Host "INSTALLED. ZKT Connector $version is running and starts automatically with Windows." -ForegroundColor Green
        Write-Host "Check the dashboard: the connector shows a 'Last seen' time and version $version."
    } else {
        Write-Host "Installed, but the connector has not connected to the server yet." -ForegroundColor Yellow
        Write-Host "Check the internet connection and the log: $logFile"
    }
    Write-Host "Log file : $logFile"
    Write-Host "Start / stop / status: Start menu > ZKT Connector, or the Start-Connector, Stop-Connector"
    Write-Host "                       and Connector-Status files in $Dest"
    Write-Host "Remove   : double-click Uninstall.cmd"
}
catch {
    Fail $_.Exception.Message
}