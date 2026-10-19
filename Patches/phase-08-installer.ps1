# =====================================================================
# HR Auto Attendance Fetcher - PHASE 8 : Downloadable connector installer
#                                         + status alerts + Sync all
# Run from the ROOT of the repo (hr-attendance-fetcher):
#   powershell -ExecutionPolicy Bypass -File .\phase-08-installer.ps1
# =====================================================================
$ErrorActionPreference = "Stop"

function Write-File([string]$Path, [string]$Content) {
    $full = Join-Path (Get-Location) $Path
    $dir  = Split-Path $full -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($full, $Content.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  wrote $Path" -ForegroundColor Green
}

if (-not (Test-Path "worker/src/routes/employees.ts")) {
    throw "Run this from the repo root, after Phase 7 (worker/src/routes/employees.ts not found)."
}

Write-Host "Phase 8: writing connector installer, status alerts, sync all..." -ForegroundColor Cyan

# The connector no longer needs dotenv: its old lock file is removed (npm install recreates it).
if (Test-Path "connector/package-lock.json") { Remove-Item "connector/package-lock.json" -Force; Write-Host "  removed connector/package-lock.json" -ForegroundColor Green }

# ---------------------------------------------------------------- connector/package.json
Write-File "connector/package.json" @'
{
  "name": "zkt-connector",
  "version": "0.8.0",
  "private": true,
  "type": "module",
  "scripts": {
    "start": "node src/index.js",
    "api-test": "node src/api-test.js",
    "read-device": "node src/read-device.js",
    "mock-device": "node test/mock-device.js",
    "test": "node --test test/zk.test.js test/sync.test.js test/env.test.js"
  }
}
'@

# ---------------------------------------------------------------- connector/src/env.js
Write-File "connector/src/env.js" @'
// Loads settings from the .env file next to the connector (no dependencies).
// The file is found relative to this code, not the current folder, so it works
// the same when started by Windows at boot, by a shortcut, or from a terminal.
// Values already set in the environment win over the file.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const CONNECTOR_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const ENV_FILE = path.join(CONNECTOR_DIR, ".env");

export function parseEnv(text) {
  const out = {};
  for (const raw of text.replace(/^\uFEFF/, "").split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq <= 0) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    } else {
      const hash = value.indexOf(" #");
      if (hash >= 0) value = value.slice(0, hash).trim();
    }
    if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) out[key] = value;
  }
  return out;
}

if (fs.existsSync(ENV_FILE)) {
  const values = parseEnv(fs.readFileSync(ENV_FILE, "utf8"));
  for (const [k, v] of Object.entries(values)) {
    if (process.env[k] === undefined) process.env[k] = v;
  }
}
'@

# ---------------------------------------------------------------- connector/src/api.js
Write-File "connector/src/api.js" @'
// HTTP client for the Attendance Fetcher Worker (connector side).
export const CONNECTOR_VERSION = "0.8.0";

export class ApiClient {
  constructor(baseUrl, token) {
    this.baseUrl = baseUrl.replace(/\/+$/, "");
    this.token = token;
  }

  async request(method, path, body) {
    const res = await fetch(this.baseUrl + path, {
      method,
      headers: {
        authorization: `Bearer ${this.token}`,
        "content-type": "application/json",
        "x-connector-version": CONNECTOR_VERSION,
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });

    const text = await res.text();
    let data;
    try {
      data = text ? JSON.parse(text) : {};
    } catch {
      data = { error: text.slice(0, 200) };
    }

    if (!res.ok) {
      const err = new Error(`${method} ${path} -> ${res.status}: ${data.error ?? "request failed"}`);
      err.status = res.status;
      throw err;
    }
    return data;
  }

  getConfig() {
    return this.request("GET", "/api/connector/config");
  }

  claimJob() {
    return this.request("POST", "/api/connector/jobs/claim", {});
  }

  /** records: [{ user_id, timestamp: "YYYY-MM-DD HH:MM:SS", state, verify_mode }] (max 1000 per call) */
  uploadLogs(jobId, records) {
    return this.request("POST", `/api/connector/jobs/${encodeURIComponent(jobId)}/logs`, { records });
  }

  /** users: [{ user_id, name }] from the machine's user list */
  uploadUsers(jobId, users) {
    return this.request("POST", `/api/connector/jobs/${encodeURIComponent(jobId)}/users`, { users });
  }

  /** payload: { status: "success" | "failed", error_message?, device_serial? } */
  completeJob(jobId, payload) {
    return this.request("POST", `/api/connector/jobs/${encodeURIComponent(jobId)}/complete`, payload);
  }
}

export function clientFromEnv() {
  const base = process.env.API_BASE_URL;
  const token = process.env.CONNECTOR_TOKEN;
  if (!base) throw new Error("API_BASE_URL is not set in .env");
  if (!token || !token.startsWith("zkc_")) {
    throw new Error("CONNECTOR_TOKEN is not set in .env (create a connector in the dashboard and paste its token)");
  }
  return new ApiClient(base, token);
}
'@

# ---------------------------------------------------------------- connector/src/index.js
Write-File "connector/src/index.js" @'
// ZKT Connector main loop.
//   npm start                 -> runs continuously: picks up sync jobs and imports attendance
//   npm start -- --once       -> processes at most one pending job, then exits
import "./env.js";
import { CONNECTOR_VERSION, clientFromEnv } from "./api.js";
import { processJob } from "./sync.js";
import { log } from "./log.js";

const once = process.argv.includes("--once");
const pollSeconds = Math.min(Math.max(Number(process.env.POLL_INTERVAL_SECONDS) || 60, 15), 3600);
const timeoutMs = Number(process.env.DEVICE_TIMEOUT_MS) || 10000;

let stopping = false;
process.on("SIGINT", () => {
  if (stopping) process.exit(1);
  stopping = true;
  log.info("Stopping after the current step (press Ctrl+C again to force)...");
});
process.on("SIGTERM", () => { stopping = true; });

async function sleepUnlessStopping(seconds) {
  for (let i = 0; i < seconds && !stopping; i++) await new Promise((r) => setTimeout(r, 1000));
}

async function main() {
  log.info(`ZKT Connector ${CONNECTOR_VERSION} starting${once ? " (single run)" : ""}`);
  const api = clientFromEnv();

  // At Windows start-up the network may not be ready yet: keep trying (except for a bad token).
  let config;
  for (;;) {
    try {
      config = await api.getConfig();
      break;
    } catch (err) {
      if (err.status === 401 || once) throw err;
      log.warn(`Server not reachable yet (${err.message}). Retrying in 30 s`);
      await sleepUnlessStopping(30);
      if (stopping) return;
    }
  }
  log.info(`Connected to ${api.baseUrl} as connector "${config.connector.name}"`);
  if (!config.devices.length) log.warn("No devices assigned to this connector yet (add one in the dashboard).");
  for (const d of config.devices) log.info(`Device "${d.name}" at ${d.ip_address}:${d.port}`);
  if (!once) log.info(`Checking for sync jobs every ${pollSeconds} s. Press Ctrl+C to stop.`);

  while (!stopping) {
    try {
      const { job } = await api.claimJob();
      if (job) {
        await processJob(api, job, { timeoutMs });
        if (once) break;
        continue; // another job may be waiting (e.g. several devices)
      }
      if (once) {
        log.info("No pending sync job. Click 'Sync now' in the dashboard, then run again.");
        break;
      }
    } catch (err) {
      if (err.status === 401) {
        log.error(`${err.message}. Create a new connector token in the dashboard and update .env.`);
        process.exitCode = 1;
        return;
      }
      log.error(`Could not reach the server: ${err.message}`);
      if (once) { process.exitCode = 1; return; }
    }
    await sleepUnlessStopping(pollSeconds);
  }
  log.info("Connector stopped.");
}

main().catch((err) => {
  log.error(err.message);
  process.exitCode = 1;
});
'@

# ---------------------------------------------------------------- connector/src/read-device.js
Write-File "connector/src/read-device.js" @'
// Phase 4: read the attendance log from the machine (READ-ONLY) and show a summary.
// Nothing is uploaded and nothing on the machine is changed or cleared.
//
//   npm run read-device                         -> device from the dashboard (via CONNECTOR_TOKEN)
//   npm run read-device -- --device "K40PIA"    -> pick one when the connector has several
//   npm run read-device -- --ip 192.168.10.21   -> skip the dashboard, connect directly
//   npm run read-device -- --csv                -> also save all punches to output/*.csv
import "./env.js";
import fs from "node:fs";
import path from "node:path";
import { readDevice } from "./zk/client.js";
import { clientFromEnv, CONNECTOR_VERSION } from "./api.js";

const STATES = { 0: "Check-in", 1: "Check-out", 2: "Break-out", 3: "Break-in", 4: "OT-in", 5: "OT-out" };
const VERIFY = { 0: "Password", 1: "Fingerprint", 2: "Card", 15: "Face" };

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) continue;
    const key = a.slice(2);
    const next = argv[i + 1];
    if (next !== undefined && !next.startsWith("--")) { args[key] = next; i++; }
    else args[key] = true;
  }
  return args;
}

async function resolveDevice(args) {
  const timeoutMs = Number(process.env.DEVICE_TIMEOUT_MS) || 10000;
  if (args.ip) {
    return { name: "(command line)", ip: args.ip, port: Number(args.port) || 4370, commKey: Number(args.key) || 0, timeoutMs, source: "command line" };
  }
  if (process.env.CONNECTOR_TOKEN && process.env.CONNECTOR_TOKEN.startsWith("zkc_")) {
    const config = await clientFromEnv().getConfig();
    const devices = config.devices;
    if (!devices.length) throw new Error("No devices are assigned to this connector in the dashboard.");
    let d = devices[0];
    if (args.device) {
      d = devices.find((x) => x.name.toLowerCase() === String(args.device).toLowerCase());
      if (!d) throw new Error(`No device named "${args.device}". Assigned: ${devices.map((x) => x.name).join(", ")}`);
    } else if (devices.length > 1) {
      console.log(`Connector has ${devices.length} devices; using "${d.name}". Use --device "<name>" to choose.`);
    }
    return { name: d.name, ip: d.ip_address, port: d.port, commKey: d.comm_key, timeoutMs, source: "dashboard" };
  }
  if (process.env.DEVICE_IP) {
    return {
      name: "(.env)", ip: process.env.DEVICE_IP, port: Number(process.env.DEVICE_PORT) || 4370,
      commKey: Number(process.env.DEVICE_COMM_KEY) || 0, timeoutMs, source: ".env",
    };
  }
  throw new Error("No device configured. Set CONNECTOR_TOKEN in .env, or pass --ip 192.168.10.21");
}

function clockDifference(deviceTime) {
  if (!deviceTime) return "";
  const dev = new Date(deviceTime.replace(" ", "T")).getTime();
  const diff = Math.round((dev - Date.now()) / 1000);
  const warn = Math.abs(diff) > 120 ? "  <-- machine clock is off, punches will carry this error" : "";
  return `  (difference vs this PC: ${diff >= 0 ? "+" : ""}${diff} s)${warn}`;
}

function toCsv(records) {
  const lines = ["user_id,timestamp,state,state_label,verify_mode,verify_label"];
  for (const r of records) {
    lines.push([r.user_id, r.timestamp, r.state, STATES[r.state] ?? "", r.verify_mode, VERIFY[r.verify_mode] ?? ""]
      .map((v) => `"${String(v).replace(/"/g, '""')}"`).join(","));
  }
  return lines.join("\r\n") + "\r\n";
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  console.log(`ZKT Connector ${CONNECTOR_VERSION} - read device (read-only, nothing is changed on the machine)\n`);

  const device = await resolveDevice(args);
  console.log(`Device       : ${device.name}  ${device.ip}:${device.port}  comm key ${device.commKey}  [from ${device.source}]`);

  const started = Date.now();
  const result = await readDevice(device, (done, total) => {
    process.stdout.write(`\rReading      : ${Math.floor((done / total) * 100)}% (${done}/${total} bytes)`);
  });
  if (result.sizes.records > 0) process.stdout.write("\n");
  const seconds = ((Date.now() - started) / 1000).toFixed(1);

  const { records, sizes } = result;
  console.log(`Serial number: ${result.serialNumber ?? "(not reported)"}`);
  console.log(`Device clock : ${result.deviceTime ?? "(not reported)"}${clockDifference(result.deviceTime)}`);
  console.log(`Stored       : ${sizes.records} punches (capacity ${sizes.recordsCapacity || "?"}), ${sizes.users} users, record format ${result.recordSize || "-"} bytes`);
  console.log(`Read         : ${records.length} punches in ${seconds} s`);

  if (result.users.length) {
    const named = result.users.filter((u) => u.name);
    console.log(`Names        : ${named.length} of ${result.users.length} users have a name on the machine`);
    for (const u of result.users.slice(0, 10)) console.log(`  user ${u.user_id.padEnd(8)} ${u.name || "(no name on machine)"}`);
    if (result.users.length > 10) console.log(`  ... and ${result.users.length - 10} more`);
  } else if (result.usersError) {
    console.log(`Names        : could not read user list (${result.usersError})`);
  }

  if (!records.length) {
    console.log("\nThe machine has no attendance records.");
    return;
  }

  const sorted = [...records].sort((a, b) => a.timestamp.localeCompare(b.timestamp));
  const users = new Set(records.map((r) => r.user_id));
  console.log(`Range        : ${sorted[0].timestamp}  ->  ${sorted.at(-1).timestamp}`);
  console.log(`Users        : ${users.size} distinct user IDs`);

  console.log("\nLatest 10 punches:");
  for (const r of sorted.slice(-10)) {
    console.log(`  ${r.timestamp}  user ${r.user_id.padEnd(8)} ${String(STATES[r.state] ?? `state ${r.state}`).padEnd(10)} ${VERIFY[r.verify_mode] ?? `verify ${r.verify_mode}`}`);
  }

  if (args.csv) {
    const outDir = path.resolve("output");
    fs.mkdirSync(outDir, { recursive: true });
    const stamp = new Date().toISOString().replace(/[-:]/g, "").slice(0, 13);
    const file = typeof args.csv === "string" ? path.resolve(args.csv) : path.join(outDir, `attendance-${result.serialNumber ?? device.ip}-${stamp}.csv`);
    fs.writeFileSync(file, toCsv(sorted));
    console.log(`\nSaved ${sorted.length} punches to ${file}`);
  }
  console.log("\nNothing was uploaded (this command only reads). Use \"npm start\" or Sync now to import.");
}

main().catch((err) => {
  console.error(`\nFAILED: ${err.message}`);
  if (/Cannot (connect|reach)|did not respond/.test(err.message)) {
    console.error("Checks: 1) ping the machine's IP from this PC  2) this PC is on the same network (e.g. 192.168.10.x)");
    console.error("        3) port 4370 is not blocked  4) close ZKTime/ZKBio or other software connected to the machine, then retry");
  }
  process.exitCode = 1;
});
'@

# ---------------------------------------------------------------- connector/src/api-test.js
Write-File "connector/src/api-test.js" @'
// Phase 3 end-to-end test of the connector API, WITHOUT the machine.
// Uploads two fake punches for user "TEST" dated 2000-01-01, then uploads
// them again to prove duplicates are skipped. Run: npm run api-test
import "./env.js";
import { clientFromEnv, CONNECTOR_VERSION } from "./api.js";

const TEST_RECORDS = [
  { user_id: "TEST", timestamp: "2000-01-01 09:00:00", state: 0, verify_mode: 1 },
  { user_id: "TEST", timestamp: "2000-01-01 18:00:00", state: 1, verify_mode: 1 },
];

async function main() {
  console.log(`ZKT Connector ${CONNECTOR_VERSION} - API test`);
  const api = clientFromEnv();

  const config = await api.getConfig();
  console.log(`\n[1] Token OK. Connector: ${config.connector.name}`);
  if (!config.devices.length) {
    console.log("    No devices assigned to this connector. Add one in the dashboard first.");
    return;
  }
  for (const d of config.devices) {
    console.log(`    Device: ${d.name}  ${d.ip_address}:${d.port}  comm key ${d.comm_key}`);
  }

  const claim = await api.claimJob();
  if (!claim.job) {
    console.log("\n[2] No pending job. Click 'Sync now' on the device in the dashboard, then run this again.");
    return;
  }
  const job = claim.job;
  console.log(`\n[2] Claimed job ${job.id} for device "${job.device.name}" (${job.trigger_type})`);

  const first = await api.uploadLogs(job.id, TEST_RECORDS);
  console.log(`\n[3] First upload : inserted ${first.inserted}, duplicates ${first.duplicates}, rejected ${first.rejected}`);

  const second = await api.uploadLogs(job.id, TEST_RECORDS);
  console.log(`[4] Second upload: inserted ${second.inserted}, duplicates ${second.duplicates}  (expected 0 inserted)`);

  const done = await api.completeJob(job.id, { status: "success" });
  console.log(`\n[5] Job ${done.job.status}: fetched ${done.job.records_fetched}, new ${done.job.records_inserted}`);
  console.log("\nAPI test passed.");
}

main().catch((err) => {
  console.error("\nAPI test FAILED:", err.message);
  process.exitCode = 1;
});
'@

# ---------------------------------------------------------------- connector/test/env.test.js
Write-File "connector/test/env.test.js" @'
// Run: npm test
import test from "node:test";
import assert from "node:assert/strict";
import { parseEnv } from "../src/env.js";

test(".env parsing: comments, quotes, CRLF, BOM", () => {
  const text = "\uFEFF# comment\r\nAPI_BASE_URL=https://x.workers.dev\r\nCONNECTOR_TOKEN = zkc_abc  # note\r\nQUOTED=\"a # b\"\r\n\r\nbad line\r\n=x\r\n";
  assert.deepEqual(parseEnv(text), {
    API_BASE_URL: "https://x.workers.dev",
    CONNECTOR_TOKEN: "zkc_abc",
    QUOTED: "a # b",
  });
});
'@

# ---------------------------------------------------------------- connector/scripts/install-autostart.ps1
Write-File "connector/scripts/install-autostart.ps1" @'
# =====================================================================
# ZKT Connector - start automatically with Windows (no login needed).
# Creates a Windows Scheduled Task "ZKT Connector" that runs as SYSTEM at
# start-up and restarts the connector if it ever stops.
#
# Run in PowerShell opened with "Run as administrator", from the connector folder:
#   powershell -ExecutionPolicy Bypass -File .\scripts\install-autostart.ps1
# =====================================================================
$ErrorActionPreference = "Stop"
$TaskName = "ZKT Connector"

$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Please open PowerShell with 'Run as administrator' and run this again."
}

$dir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if (-not (Test-Path (Join-Path $dir ".env")))         { throw ".env not found in $dir - create it first (see .env.example)." }
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { throw "Node.js was not found in PATH." }

$logs    = Join-Path $dir "logs"
$logFile = Join-Path $logs "connector.log"
$script  = Join-Path $dir "src\index.js"
$cmdPath = Join-Path $dir "run-connector.cmd"
New-Item -ItemType Directory -Force -Path $logs | Out-Null

# Stop an older copy started by this task, if any.
Get-CimInstance Win32_Process |
    Where-Object { $_.CommandLine -and ($_.CommandLine -like "*$script*" -or $_.CommandLine -like "*$cmdPath*") } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# Wrapper: runs the connector, appends output to logs\connector.log,
# keeps the log under ~5 MB, and restarts after 60 s if node exits.
$cmd = @"
@echo off
rem Generated by scripts\install-autostart.ps1 - do not edit, run the installer again instead.
cd /d "$dir"
:loop
for %%F in ("$logFile") do if %%~zF GTR 5000000 move /y "$logFile" "$logFile.old" >nul
echo ===== %date% %time% starting connector >> "$logFile"
"$node" "$script" >> "$logFile" 2>&1
ping -n 61 127.0.0.1 >nul
goto loop
"@
# cmd.exe needs Windows (CRLF) line endings for labels/goto to work.
[System.IO.File]::WriteAllText($cmdPath, ($cmd -replace "`r?`n", "`r`n"), [System.Text.Encoding]::ASCII)

$action    = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$cmdPath`"" -WorkingDirectory $dir
$trigger   = New-ScheduledTaskTrigger -AtStartup
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
               -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
               -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description "Imports attendance from the ZKTeco machine into HR Attendance Fetcher ($dir)" -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host "Scheduled task '$TaskName' installed and started." -ForegroundColor Green
Write-Host "Waiting 10 seconds for the first log lines..."
Start-Sleep -Seconds 10
if (Test-Path $logFile) { Get-Content $logFile -Tail 12 } else { Write-Host "No log yet: $logFile" -ForegroundColor Yellow }
Write-Host ""
Write-Host "Log file : $logFile"
Write-Host "Status   : Get-ScheduledTask '$TaskName' | Get-ScheduledTaskInfo"
Write-Host "Remove   : powershell -ExecutionPolicy Bypass -File .\scripts\uninstall-autostart.ps1"
'@

# ---------------------------------------------------------------- connector/package/Install.cmd
Write-File "connector/package/Install.cmd" @'
@echo off
rem ZKT Connector - double-click to install or update (asks for administrator permission).
if not exist "%~dp0scripts\install.ps1" goto notextracted
net session >nul 2>&1
if errorlevel 1 goto elevate
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\install.ps1" & echo. & pause & exit /b

:elevate
echo Asking for administrator permission...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath \"%~f0\" -Verb RunAs"
exit /b

:notextracted
echo.
echo  Please extract the ZIP first:
echo    1. Right-click the downloaded ZIP file and choose "Extract All..."
echo    2. Open the extracted folder and double-click Install.cmd again.
echo.
pause
exit /b 1
'@

# ---------------------------------------------------------------- connector/package/Uninstall.cmd
Write-File "connector/package/Uninstall.cmd" @'
@echo off
rem ZKT Connector - double-click to remove it from this PC (asks for administrator permission).
if not exist "%~dp0scripts\uninstall.ps1" goto missing
net session >nul 2>&1
if errorlevel 1 goto elevate
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\uninstall.ps1" & echo. & pause & exit /b

:elevate
echo Asking for administrator permission...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath \"%~f0\" -Verb RunAs"
exit /b

:missing
echo scripts\uninstall.ps1 not found. Extract the ZIP first.
pause
exit /b 1
'@

# ---------------------------------------------------------------- connector/package/Test-Connection.cmd
Write-File "connector/package/Test-Connection.cmd" @'
@echo off
rem ZKT Connector - reads the attendance machine once and shows what it finds.
rem Read-only: nothing is uploaded and nothing on the machine is changed.
cd /d "%~dp0"
where node >nul 2>&1 && goto run
if exist "%ProgramFiles%\nodejs\node.exe" set "PATH=%ProgramFiles%\nodejs;%PATH%" & goto run
echo.
echo  Node.js is not installed yet. Run Install.cmd first (it installs Node.js).
echo.
pause
exit /b 1

:run
node src\read-device.js & echo. & pause & exit /b
'@

# ---------------------------------------------------------------- connector/package/README.txt
Write-File "connector/package/README.txt" @'
ZKT Connector
=============

The ZKT Connector reads attendance from your ZKTeco machine (K40 / K50) and
sends it to your HR Attendance dashboard. It only READS the machine: it never
changes, clears or restarts it.

This download is already set up for your company. The file ".env" contains
your connector token - keep this folder private.


INSTALL (about 2 minutes)
-------------------------
Use a Windows PC that stays on and is on the same network as the machine.

  1. Right-click the ZIP file and choose "Extract All...".
  2. Open the extracted folder and double-click  Install.cmd
  3. Click "Yes" when Windows asks for administrator permission.
     If Windows shows "Windows protected your PC", click "More info"
     and then "Run anyway".
  4. Wait for "INSTALLED". Node.js is installed automatically if needed.

The connector then runs in the background and starts with Windows, even
before anyone logs in. You can delete the extracted folder afterwards.

Installed to : C:\ProgramData\ZKTConnector
Log file     : C:\ProgramData\ZKTConnector\logs\connector.log


CHECK THE MACHINE CONNECTION
----------------------------
Double-click  Test-Connection.cmd  (in the extracted folder). It reads the
machine once and shows the serial number, number of punches and names.


UPDATE
------
Download the installer again from the dashboard and run Install.cmd.
It replaces the old version automatically.


REMOVE
------
Double-click  Uninstall.cmd


TROUBLESHOOTING
---------------
- "Cannot connect": ping the machine's IP from this PC, and make sure this
  PC is on the same network (for example 192.168.10.x).
- Close ZKTime / ZKBio Time if it is open: the machine often allows only one
  connection at a time.
- "Connector token is not valid": download the installer again from the
  dashboard and run Install.cmd.
'@

# ---------------------------------------------------------------- connector/package/scripts/install.ps1
Write-File "connector/package/scripts/install.ps1" @'
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
    Copy-Item (Join-Path $Source "scripts\uninstall.ps1") (Join-Path $Dest "scripts\uninstall.ps1") -Force
    foreach ($f in @("package.json", ".env", "Uninstall.cmd", "Test-Connection.cmd", "README.txt")) {
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

    # Runs the connector, appends to logs\connector.log (kept under ~5 MB), restarts 60 s after any exit.
    $wrapper = @"
@echo off
rem Generated by the ZKT Connector installer - run Install.cmd again instead of editing.
cd /d "$Dest"
:loop
for %%F in ("$logFile") do if %%~zF GTR 5000000 move /y "$logFile" "$logFile.old" >nul
echo ===== %date% %time% starting connector >> "$logFile"
"$node" "$script" >> "$logFile" 2>&1
ping -n 61 127.0.0.1 >nul
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
    Write-Host "Remove   : double-click Uninstall.cmd"
}
catch {
    Fail $_.Exception.Message
}
'@

# ---------------------------------------------------------------- connector/package/scripts/uninstall.ps1
Write-File "connector/package/scripts/uninstall.ps1" @'
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
'@

# ---------------------------------------------------------------- worker/package.json
Write-File "worker/package.json" @'
{
  "name": "hr-attendance-worker",
  "version": "0.8.0",
  "private": true,
  "scripts": {
    "bundle-connector": "node scripts/bundle-connector.mjs",
    "dev": "npm run bundle-connector && wrangler dev",
    "deploy": "npm run bundle-connector && wrangler deploy",
    "typecheck": "npm run bundle-connector && tsc --noEmit"
  },
  "devDependencies": {
    "@cloudflare/workers-types": "^5.20261001.1",
    "typescript": "^5.6.0",
    "wrangler": "^4.0.0"
  }
}
'@

# ---------------------------------------------------------------- worker/scripts/bundle-connector.mjs
Write-File "worker/scripts/bundle-connector.mjs" @'
// Packs the ZKT Connector into src/generated/connector-files.ts so the Worker
// can serve it as a ready-to-run ZIP. Runs automatically before deploy/typecheck.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const connector = path.resolve(here, "../../connector");
const out = path.resolve(here, "../src/generated/connector-files.ts");

// Code that runs on the customer's PC. (No tests, no mock device, no api-test.)
const CODE = [
  "src/env.js", "src/log.js", "src/api.js", "src/sync.js", "src/index.js", "src/read-device.js",
  "src/zk/protocol.js", "src/zk/client.js",
];
// Windows installer files (CRLF line endings, ASCII only).
const WINDOWS = [
  "Install.cmd", "Uninstall.cmd", "Test-Connection.cmd", "README.txt",
  "scripts/install.ps1", "scripts/uninstall.ps1",
];

const version = /CONNECTOR_VERSION = "([^"]+)"/.exec(fs.readFileSync(path.join(connector, "src/api.js"), "utf8"))?.[1];
if (!version) throw new Error("CONNECTOR_VERSION not found in connector/src/api.js");

// JSON with every non-ASCII character escaped, so the file is plain ASCII.
function asciiJson(value) {
  return JSON.stringify(value, null, 1).replace(/[\u007f-\uffff]/g, (c) => "\\u" + c.charCodeAt(0).toString(16).padStart(4, "0"));
}

const files = {};
for (const f of CODE) {
  files[f] = fs.readFileSync(path.join(connector, f), "utf8").replace(/\r\n/g, "\n");
}
for (const f of WINDOWS) {
  const text = fs.readFileSync(path.join(connector, "package", f), "utf8").replace(/\r?\n/g, "\r\n");
  if (/[^\x00-\x7f]/.test(text)) throw new Error(`${f} must be ASCII only (Windows PowerShell 5.1 / cmd.exe)`);
  files[f] = text;
}
files["package.json"] = JSON.stringify({ name: "zkt-connector", version, private: true, type: "module" }, null, 2) + "\n";

const body =
  "// GENERATED by scripts/bundle-connector.mjs - do not edit. Run: npm run bundle-connector\n" +
  `export const CONNECTOR_VERSION = ${JSON.stringify(version)};\n` +
  `export const CONNECTOR_FILES: Record<string, string> = ${asciiJson(files)};\n`;

fs.mkdirSync(path.dirname(out), { recursive: true });
const previous = fs.existsSync(out) ? fs.readFileSync(out, "utf8") : "";
if (previous !== body) fs.writeFileSync(out, body);
console.log(`connector ${version}: ${Object.keys(files).length} files packed${previous === body ? " (unchanged)" : ""}`);
'@

# ---------------------------------------------------------------- worker/src/generated/connector-files.ts
Write-File "worker/src/generated/connector-files.ts" @'
// GENERATED by scripts/bundle-connector.mjs - do not edit. Run: npm run bundle-connector
export const CONNECTOR_VERSION = "0.8.0";
export const CONNECTOR_FILES: Record<string, string> = {
 "src/env.js": "// Loads settings from the .env file next to the connector (no dependencies).\n// The file is found relative to this code, not the current folder, so it works\n// the same when started by Windows at boot, by a shortcut, or from a terminal.\n// Values already set in the environment win over the file.\nimport fs from \"node:fs\";\nimport path from \"node:path\";\nimport { fileURLToPath } from \"node:url\";\n\nexport const CONNECTOR_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), \"..\");\nexport const ENV_FILE = path.join(CONNECTOR_DIR, \".env\");\n\nexport function parseEnv(text) {\n  const out = {};\n  for (const raw of text.replace(/^\\uFEFF/, \"\").split(/\\r?\\n/)) {\n    const line = raw.trim();\n    if (!line || line.startsWith(\"#\")) continue;\n    const eq = line.indexOf(\"=\");\n    if (eq <= 0) continue;\n    const key = line.slice(0, eq).trim();\n    let value = line.slice(eq + 1).trim();\n    if ((value.startsWith('\"') && value.endsWith('\"')) || (value.startsWith(\"'\") && value.endsWith(\"'\"))) {\n      value = value.slice(1, -1);\n    } else {\n      const hash = value.indexOf(\" #\");\n      if (hash >= 0) value = value.slice(0, hash).trim();\n    }\n    if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) out[key] = value;\n  }\n  return out;\n}\n\nif (fs.existsSync(ENV_FILE)) {\n  const values = parseEnv(fs.readFileSync(ENV_FILE, \"utf8\"));\n  for (const [k, v] of Object.entries(values)) {\n    if (process.env[k] === undefined) process.env[k] = v;\n  }\n}\n",
 "src/log.js": "// Timestamped console logging (Phase 6 will also write these lines to a file).\nfunction stamp() {\n  const d = new Date();\n  const p = (n) => String(n).padStart(2, \"0\");\n  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;\n}\n\nexport const log = {\n  info: (msg) => console.log(`${stamp()}  INFO   ${msg}`),\n  warn: (msg) => console.warn(`${stamp()}  WARN   ${msg}`),\n  error: (msg) => console.error(`${stamp()}  ERROR  ${msg}`),\n};\n",
 "src/api.js": "// HTTP client for the Attendance Fetcher Worker (connector side).\nexport const CONNECTOR_VERSION = \"0.8.0\";\n\nexport class ApiClient {\n  constructor(baseUrl, token) {\n    this.baseUrl = baseUrl.replace(/\\/+$/, \"\");\n    this.token = token;\n  }\n\n  async request(method, path, body) {\n    const res = await fetch(this.baseUrl + path, {\n      method,\n      headers: {\n        authorization: `Bearer ${this.token}`,\n        \"content-type\": \"application/json\",\n        \"x-connector-version\": CONNECTOR_VERSION,\n      },\n      body: body === undefined ? undefined : JSON.stringify(body),\n    });\n\n    const text = await res.text();\n    let data;\n    try {\n      data = text ? JSON.parse(text) : {};\n    } catch {\n      data = { error: text.slice(0, 200) };\n    }\n\n    if (!res.ok) {\n      const err = new Error(`${method} ${path} -> ${res.status}: ${data.error ?? \"request failed\"}`);\n      err.status = res.status;\n      throw err;\n    }\n    return data;\n  }\n\n  getConfig() {\n    return this.request(\"GET\", \"/api/connector/config\");\n  }\n\n  claimJob() {\n    return this.request(\"POST\", \"/api/connector/jobs/claim\", {});\n  }\n\n  /** records: [{ user_id, timestamp: \"YYYY-MM-DD HH:MM:SS\", state, verify_mode }] (max 1000 per call) */\n  uploadLogs(jobId, records) {\n    return this.request(\"POST\", `/api/connector/jobs/${encodeURIComponent(jobId)}/logs`, { records });\n  }\n\n  /** users: [{ user_id, name }] from the machine's user list */\n  uploadUsers(jobId, users) {\n    return this.request(\"POST\", `/api/connector/jobs/${encodeURIComponent(jobId)}/users`, { users });\n  }\n\n  /** payload: { status: \"success\" | \"failed\", error_message?, device_serial? } */\n  completeJob(jobId, payload) {\n    return this.request(\"POST\", `/api/connector/jobs/${encodeURIComponent(jobId)}/complete`, payload);\n  }\n}\n\nexport function clientFromEnv() {\n  const base = process.env.API_BASE_URL;\n  const token = process.env.CONNECTOR_TOKEN;\n  if (!base) throw new Error(\"API_BASE_URL is not set in .env\");\n  if (!token || !token.startsWith(\"zkc_\")) {\n    throw new Error(\"CONNECTOR_TOKEN is not set in .env (create a connector in the dashboard and paste its token)\");\n  }\n  return new ApiClient(base, token);\n}\n",
 "src/sync.js": "// Phase 5: process one sync job end to end.\n// read machine (read-only, with retries) -> filter -> upload in batches -> complete job\nimport { readDevice } from \"./zk/client.js\";\nimport { log } from \"./log.js\";\n\nconst BATCH_SIZE = 1000;\nconst FUTURE_TOLERANCE_MS = 24 * 60 * 60 * 1000; // punches > 1 day after the machine's own clock are skipped\n\nconst sleep = (ms) => new Promise((r) => setTimeout(r, ms));\n\nfunction retryDelaysMs() {\n  const base = Number(process.env.RETRY_DELAY_SECONDS);\n  const s = Number.isFinite(base) && base >= 0 ? base : 10;\n  return [s * 1000, s * 3000]; // wait 10 s, then 30 s (3 attempts in total)\n}\n\n/** \"YYYY-MM-DD HH:MM:SS\" (machine local time) -> Date in this PC's local time zone */\nfunction parseLocal(ts) {\n  return new Date(ts.replace(\" \", \"T\"));\n}\n\nfunction formatLocal(d) {\n  const p = (n) => String(n).padStart(2, \"0\");\n  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;\n}\n\n/** Machine clock minus this PC's clock, in seconds (null if the machine did not report its time). */\nexport function clockOffsetSeconds(deviceTime, now = Date.now()) {\n  if (!deviceTime) return null;\n  const t = parseLocal(deviceTime).getTime();\n  return Number.isFinite(t) ? Math.round((t - now) / 1000) : null;\n}\n\n/**\n * Splits records into ones to import and ones to skip.\n * Skipped: dated more than 1 day after the machine's current clock - these were\n * recorded while the machine clock was set wrong and would show as future attendance.\n */\nexport function filterRecords(records, deviceTime, now = Date.now()) {\n  const ref = deviceTime ? parseLocal(deviceTime).getTime() : now;\n  const limit = formatLocal(new Date((Number.isFinite(ref) ? ref : now) + FUTURE_TOLERANCE_MS));\n  const keep = [];\n  const skipped = [];\n  for (const r of records) (r.timestamp <= limit ? keep : skipped).push(r);\n  keep.sort((a, b) => a.timestamp.localeCompare(b.timestamp));\n  return { keep, skipped, limit };\n}\n\nfunction isRetryable(err) {\n  return !err.status || err.status >= 500 || err.status === 429;\n}\n\nasync function withRetry(label, fn) {\n  const delays = retryDelaysMs();\n  for (let attempt = 1; ; attempt++) {\n    try {\n      return await fn();\n    } catch (err) {\n      if (attempt > delays.length || !isRetryable(err)) throw err;\n      const wait = delays[attempt - 1];\n      log.warn(`${label} failed (attempt ${attempt}/${delays.length + 1}): ${err.message}. Retrying in ${Math.round(wait / 1000)} s`);\n      await sleep(wait);\n    }\n  }\n}\n\nasync function safeFail(api, jobId, message) {\n  try {\n    await api.completeJob(jobId, { status: \"failed\", error_message: message.slice(0, 480) });\n  } catch (err) {\n    log.error(`Could not report failure for job ${jobId}: ${err.message}`);\n  }\n}\n\n/** Returns a summary object; never throws for device/upload problems (they are reported on the job). */\nexport async function processJob(api, job, { timeoutMs = 10000 } = {}) {\n  const d = job.device;\n  const started = Date.now();\n  log.info(`Job ${job.id.slice(0, 8)} (${job.trigger_type}): reading \"${d.name}\" at ${d.ip_address}:${d.port}`);\n\n  // 1) Read the machine (read-only)\n  let result;\n  try {\n    result = await withRetry(\"Reading machine\", () =>\n      readDevice({ ip: d.ip_address, port: d.port, commKey: d.comm_key, timeoutMs }));\n  } catch (err) {\n    const msg = `Could not read machine ${d.ip_address}:${d.port}: ${err.message}`;\n    log.error(msg);\n    await safeFail(api, job.id, msg);\n    return { ok: false, error: msg };\n  }\n\n  const offset = clockOffsetSeconds(result.deviceTime);\n  const { keep, skipped, limit } = filterRecords(result.records, result.deviceTime);\n  log.info(`Read ${result.records.length} punches (serial ${result.serialNumber ?? \"?\"}, clock offset ${offset ?? \"?\"} s)`);\n  if (offset !== null && Math.abs(offset) > 60) {\n    log.warn(`Machine clock is ${Math.abs(offset)} s ${offset < 0 ? \"behind\" : \"ahead\"}. Correct the time on the machine.`);\n  }\n  if (skipped.length) {\n    const sample = skipped.slice(0, 3).map((r) => `${r.timestamp} (user ${r.user_id})`).join(\", \");\n    log.warn(`Skipping ${skipped.length} punch(es) dated after ${limit}: ${sample}${skipped.length > 3 ? \", ...\" : \"\"}`);\n  }\n\n  // 2) Upload in batches (duplicates are ignored by the server)\n  let inserted = 0;\n  let duplicates = 0;\n  let rejected = 0;\n  try {\n    for (let i = 0; i < keep.length; i += BATCH_SIZE) {\n      const batch = keep.slice(i, i + BATCH_SIZE);\n      const res = await withRetry(\"Upload\", () => api.uploadLogs(job.id, batch));\n      inserted += res.inserted;\n      duplicates += res.duplicates;\n      rejected += res.rejected;\n    }\n  } catch (err) {\n    const msg = `Upload failed: ${err.message}`;\n    log.error(msg);\n    if (err.status !== 409) await safeFail(api, job.id, msg); // 409 = job already closed by the server\n    return { ok: false, error: msg };\n  }\n\n  // 3) Employee names from the machine (best effort: never fails the sync)\n  if (result.users.length) {\n    try {\n      const res = await withRetry(\"Uploading names\", () => api.uploadUsers(job.id, result.users));\n      log.info(`Names: ${result.users.length} users on machine, ${res.named} with a name (${res.added} new employees)`);\n    } catch (err) {\n      log.warn(`Could not upload employee names: ${err.message}`);\n    }\n  } else if (result.usersError) {\n    log.warn(`Could not read user names from the machine: ${result.usersError}`);\n  }\n\n  // 4) Complete\n  try {\n    await withRetry(\"Completing job\", () => api.completeJob(job.id, {\n      status: \"success\",\n      device_serial: result.serialNumber ?? undefined,\n      records_skipped: skipped.length + rejected,\n      clock_offset_seconds: offset ?? undefined,\n    }));\n  } catch (err) {\n    log.error(`Could not complete job: ${err.message}`);\n    return { ok: false, error: err.message };\n  }\n\n  const secs = ((Date.now() - started) / 1000).toFixed(1);\n  log.info(`Job ${job.id.slice(0, 8)} done in ${secs} s: ${inserted} new, ${duplicates} already imported, ${skipped.length + rejected} skipped`);\n  return { ok: true, read: result.records.length, inserted, duplicates, skipped: skipped.length + rejected };\n}\n",
 "src/index.js": "// ZKT Connector main loop.\n//   npm start                 -> runs continuously: picks up sync jobs and imports attendance\n//   npm start -- --once       -> processes at most one pending job, then exits\nimport \"./env.js\";\nimport { CONNECTOR_VERSION, clientFromEnv } from \"./api.js\";\nimport { processJob } from \"./sync.js\";\nimport { log } from \"./log.js\";\n\nconst once = process.argv.includes(\"--once\");\nconst pollSeconds = Math.min(Math.max(Number(process.env.POLL_INTERVAL_SECONDS) || 60, 15), 3600);\nconst timeoutMs = Number(process.env.DEVICE_TIMEOUT_MS) || 10000;\n\nlet stopping = false;\nprocess.on(\"SIGINT\", () => {\n  if (stopping) process.exit(1);\n  stopping = true;\n  log.info(\"Stopping after the current step (press Ctrl+C again to force)...\");\n});\nprocess.on(\"SIGTERM\", () => { stopping = true; });\n\nasync function sleepUnlessStopping(seconds) {\n  for (let i = 0; i < seconds && !stopping; i++) await new Promise((r) => setTimeout(r, 1000));\n}\n\nasync function main() {\n  log.info(`ZKT Connector ${CONNECTOR_VERSION} starting${once ? \" (single run)\" : \"\"}`);\n  const api = clientFromEnv();\n\n  // At Windows start-up the network may not be ready yet: keep trying (except for a bad token).\n  let config;\n  for (;;) {\n    try {\n      config = await api.getConfig();\n      break;\n    } catch (err) {\n      if (err.status === 401 || once) throw err;\n      log.warn(`Server not reachable yet (${err.message}). Retrying in 30 s`);\n      await sleepUnlessStopping(30);\n      if (stopping) return;\n    }\n  }\n  log.info(`Connected to ${api.baseUrl} as connector \"${config.connector.name}\"`);\n  if (!config.devices.length) log.warn(\"No devices assigned to this connector yet (add one in the dashboard).\");\n  for (const d of config.devices) log.info(`Device \"${d.name}\" at ${d.ip_address}:${d.port}`);\n  if (!once) log.info(`Checking for sync jobs every ${pollSeconds} s. Press Ctrl+C to stop.`);\n\n  while (!stopping) {\n    try {\n      const { job } = await api.claimJob();\n      if (job) {\n        await processJob(api, job, { timeoutMs });\n        if (once) break;\n        continue; // another job may be waiting (e.g. several devices)\n      }\n      if (once) {\n        log.info(\"No pending sync job. Click 'Sync now' in the dashboard, then run again.\");\n        break;\n      }\n    } catch (err) {\n      if (err.status === 401) {\n        log.error(`${err.message}. Create a new connector token in the dashboard and update .env.`);\n        process.exitCode = 1;\n        return;\n      }\n      log.error(`Could not reach the server: ${err.message}`);\n      if (once) { process.exitCode = 1; return; }\n    }\n    await sleepUnlessStopping(pollSeconds);\n  }\n  log.info(\"Connector stopped.\");\n}\n\nmain().catch((err) => {\n  log.error(err.message);\n  process.exitCode = 1;\n});\n",
 "src/read-device.js": "// Phase 4: read the attendance log from the machine (READ-ONLY) and show a summary.\n// Nothing is uploaded and nothing on the machine is changed or cleared.\n//\n//   npm run read-device                         -> device from the dashboard (via CONNECTOR_TOKEN)\n//   npm run read-device -- --device \"K40PIA\"    -> pick one when the connector has several\n//   npm run read-device -- --ip 192.168.10.21   -> skip the dashboard, connect directly\n//   npm run read-device -- --csv                -> also save all punches to output/*.csv\nimport \"./env.js\";\nimport fs from \"node:fs\";\nimport path from \"node:path\";\nimport { readDevice } from \"./zk/client.js\";\nimport { clientFromEnv, CONNECTOR_VERSION } from \"./api.js\";\n\nconst STATES = { 0: \"Check-in\", 1: \"Check-out\", 2: \"Break-out\", 3: \"Break-in\", 4: \"OT-in\", 5: \"OT-out\" };\nconst VERIFY = { 0: \"Password\", 1: \"Fingerprint\", 2: \"Card\", 15: \"Face\" };\n\nfunction parseArgs(argv) {\n  const args = {};\n  for (let i = 0; i < argv.length; i++) {\n    const a = argv[i];\n    if (!a.startsWith(\"--\")) continue;\n    const key = a.slice(2);\n    const next = argv[i + 1];\n    if (next !== undefined && !next.startsWith(\"--\")) { args[key] = next; i++; }\n    else args[key] = true;\n  }\n  return args;\n}\n\nasync function resolveDevice(args) {\n  const timeoutMs = Number(process.env.DEVICE_TIMEOUT_MS) || 10000;\n  if (args.ip) {\n    return { name: \"(command line)\", ip: args.ip, port: Number(args.port) || 4370, commKey: Number(args.key) || 0, timeoutMs, source: \"command line\" };\n  }\n  if (process.env.CONNECTOR_TOKEN && process.env.CONNECTOR_TOKEN.startsWith(\"zkc_\")) {\n    const config = await clientFromEnv().getConfig();\n    const devices = config.devices;\n    if (!devices.length) throw new Error(\"No devices are assigned to this connector in the dashboard.\");\n    let d = devices[0];\n    if (args.device) {\n      d = devices.find((x) => x.name.toLowerCase() === String(args.device).toLowerCase());\n      if (!d) throw new Error(`No device named \"${args.device}\". Assigned: ${devices.map((x) => x.name).join(\", \")}`);\n    } else if (devices.length > 1) {\n      console.log(`Connector has ${devices.length} devices; using \"${d.name}\". Use --device \"<name>\" to choose.`);\n    }\n    return { name: d.name, ip: d.ip_address, port: d.port, commKey: d.comm_key, timeoutMs, source: \"dashboard\" };\n  }\n  if (process.env.DEVICE_IP) {\n    return {\n      name: \"(.env)\", ip: process.env.DEVICE_IP, port: Number(process.env.DEVICE_PORT) || 4370,\n      commKey: Number(process.env.DEVICE_COMM_KEY) || 0, timeoutMs, source: \".env\",\n    };\n  }\n  throw new Error(\"No device configured. Set CONNECTOR_TOKEN in .env, or pass --ip 192.168.10.21\");\n}\n\nfunction clockDifference(deviceTime) {\n  if (!deviceTime) return \"\";\n  const dev = new Date(deviceTime.replace(\" \", \"T\")).getTime();\n  const diff = Math.round((dev - Date.now()) / 1000);\n  const warn = Math.abs(diff) > 120 ? \"  <-- machine clock is off, punches will carry this error\" : \"\";\n  return `  (difference vs this PC: ${diff >= 0 ? \"+\" : \"\"}${diff} s)${warn}`;\n}\n\nfunction toCsv(records) {\n  const lines = [\"user_id,timestamp,state,state_label,verify_mode,verify_label\"];\n  for (const r of records) {\n    lines.push([r.user_id, r.timestamp, r.state, STATES[r.state] ?? \"\", r.verify_mode, VERIFY[r.verify_mode] ?? \"\"]\n      .map((v) => `\"${String(v).replace(/\"/g, '\"\"')}\"`).join(\",\"));\n  }\n  return lines.join(\"\\r\\n\") + \"\\r\\n\";\n}\n\nasync function main() {\n  const args = parseArgs(process.argv.slice(2));\n  console.log(`ZKT Connector ${CONNECTOR_VERSION} - read device (read-only, nothing is changed on the machine)\\n`);\n\n  const device = await resolveDevice(args);\n  console.log(`Device       : ${device.name}  ${device.ip}:${device.port}  comm key ${device.commKey}  [from ${device.source}]`);\n\n  const started = Date.now();\n  const result = await readDevice(device, (done, total) => {\n    process.stdout.write(`\\rReading      : ${Math.floor((done / total) * 100)}% (${done}/${total} bytes)`);\n  });\n  if (result.sizes.records > 0) process.stdout.write(\"\\n\");\n  const seconds = ((Date.now() - started) / 1000).toFixed(1);\n\n  const { records, sizes } = result;\n  console.log(`Serial number: ${result.serialNumber ?? \"(not reported)\"}`);\n  console.log(`Device clock : ${result.deviceTime ?? \"(not reported)\"}${clockDifference(result.deviceTime)}`);\n  console.log(`Stored       : ${sizes.records} punches (capacity ${sizes.recordsCapacity || \"?\"}), ${sizes.users} users, record format ${result.recordSize || \"-\"} bytes`);\n  console.log(`Read         : ${records.length} punches in ${seconds} s`);\n\n  if (result.users.length) {\n    const named = result.users.filter((u) => u.name);\n    console.log(`Names        : ${named.length} of ${result.users.length} users have a name on the machine`);\n    for (const u of result.users.slice(0, 10)) console.log(`  user ${u.user_id.padEnd(8)} ${u.name || \"(no name on machine)\"}`);\n    if (result.users.length > 10) console.log(`  ... and ${result.users.length - 10} more`);\n  } else if (result.usersError) {\n    console.log(`Names        : could not read user list (${result.usersError})`);\n  }\n\n  if (!records.length) {\n    console.log(\"\\nThe machine has no attendance records.\");\n    return;\n  }\n\n  const sorted = [...records].sort((a, b) => a.timestamp.localeCompare(b.timestamp));\n  const users = new Set(records.map((r) => r.user_id));\n  console.log(`Range        : ${sorted[0].timestamp}  ->  ${sorted.at(-1).timestamp}`);\n  console.log(`Users        : ${users.size} distinct user IDs`);\n\n  console.log(\"\\nLatest 10 punches:\");\n  for (const r of sorted.slice(-10)) {\n    console.log(`  ${r.timestamp}  user ${r.user_id.padEnd(8)} ${String(STATES[r.state] ?? `state ${r.state}`).padEnd(10)} ${VERIFY[r.verify_mode] ?? `verify ${r.verify_mode}`}`);\n  }\n\n  if (args.csv) {\n    const outDir = path.resolve(\"output\");\n    fs.mkdirSync(outDir, { recursive: true });\n    const stamp = new Date().toISOString().replace(/[-:]/g, \"\").slice(0, 13);\n    const file = typeof args.csv === \"string\" ? path.resolve(args.csv) : path.join(outDir, `attendance-${result.serialNumber ?? device.ip}-${stamp}.csv`);\n    fs.writeFileSync(file, toCsv(sorted));\n    console.log(`\\nSaved ${sorted.length} punches to ${file}`);\n  }\n  console.log(\"\\nNothing was uploaded (this command only reads). Use \\\"npm start\\\" or Sync now to import.\");\n}\n\nmain().catch((err) => {\n  console.error(`\\nFAILED: ${err.message}`);\n  if (/Cannot (connect|reach)|did not respond/.test(err.message)) {\n    console.error(\"Checks: 1) ping the machine's IP from this PC  2) this PC is on the same network (e.g. 192.168.10.x)\");\n    console.error(\"        3) port 4370 is not blocked  4) close ZKTime/ZKBio or other software connected to the machine, then retry\");\n  }\n  process.exitCode = 1;\n});\n",
 "src/zk/protocol.js": "// ZKTeco \"ZK6\" TCP protocol helpers (port 4370).\n// Packet layout, checksum, comm-key scrambling and time decoding follow the\n// public pyzk / zkemsdk implementations.\n\nexport const CMD = Object.freeze({\n  USERTEMP_RRQ: 9,       // read user list (with FCT_USER)\n  OPTIONS_RRQ: 11,       // read a device option, e.g. ~SerialNumber\n  ATTLOG_RRQ: 13,        // read all attendance records\n  GET_FREE_SIZES: 50,    // read record counts / capacity\n  GET_TIME: 201,         // read device clock\n  CONNECT: 1000,\n  EXIT: 1001,\n  AUTH: 1102,            // send comm key\n  PREPARE_DATA: 1500,    // device -> \"large data follows\"\n  DATA: 1501,            // device -> data packet\n  FREE_DATA: 1502,       // release the device's read buffer\n  PREPARE_BUFFER: 1503,  // ask device to buffer a dataset\n  READ_BUFFER: 1504,     // read a chunk of that buffer\n  ACK_OK: 2000,\n  ACK_ERROR: 2001,\n  ACK_DATA: 2002,\n  ACK_UNAUTH: 2005,\n});\n\n/**\n * The ONLY commands the connector is allowed to send. None of them change\n * anything on the machine: no clearing logs, no users, no time, no restart.\n */\nexport const READ_ONLY_COMMANDS = new Set([\n  CMD.CONNECT, CMD.EXIT, CMD.AUTH,\n  CMD.GET_FREE_SIZES, CMD.OPTIONS_RRQ, CMD.GET_TIME,\n  CMD.PREPARE_BUFFER, CMD.READ_BUFFER, CMD.FREE_DATA,\n]);\n\n/** Datasets the connector may read through PREPARE_BUFFER: attendance log and user list only. */\nexport const FCT_USER = 5;\nexport const READ_ONLY_DATASETS = new Map([\n  [CMD.ATTLOG_RRQ, 0],\n  [CMD.USERTEMP_RRQ, FCT_USER],\n]);\n\nexport const USHRT_MAX = 65535;\nconst TCP_MAGIC_1 = 0x5050;\nconst TCP_MAGIC_2 = 0x7d82;\n\nexport function checksum(buf) {\n  let sum = 0;\n  let i = 0;\n  for (; i + 1 < buf.length; i += 2) {\n    sum += buf[i] | (buf[i + 1] << 8);\n    if (sum > USHRT_MAX) sum -= USHRT_MAX;\n  }\n  if (i < buf.length) sum += buf[buf.length - 1];\n  while (sum > USHRT_MAX) sum -= USHRT_MAX;\n  sum = ~sum;\n  while (sum < 0) sum += USHRT_MAX;\n  return sum & 0xffff;\n}\n\n/** Builds one TCP frame. Returns the bytes and the reply id that was used. */\nexport function buildFrame(command, sessionId, replyId, data = Buffer.alloc(0)) {\n  const body = Buffer.alloc(8 + data.length);\n  body.writeUInt16LE(command, 0);\n  body.writeUInt16LE(0, 2);\n  body.writeUInt16LE(sessionId, 4);\n  body.writeUInt16LE(replyId, 6);\n  data.copy(body, 8);\n\n  const cs = checksum(body);\n  let nextReply = replyId + 1;\n  if (nextReply >= USHRT_MAX) nextReply -= USHRT_MAX;\n  body.writeUInt16LE(cs, 2);\n  body.writeUInt16LE(nextReply, 6);\n\n  const top = Buffer.alloc(8);\n  top.writeUInt16LE(TCP_MAGIC_1, 0);\n  top.writeUInt16LE(TCP_MAGIC_2, 2);\n  top.writeUInt32LE(body.length, 4);\n  return Buffer.concat([top, body]);\n}\n\n/**\n * Splits a byte stream into frames. Returns { frames, rest }.\n * Throws if the stream is not ZKTeco TCP.\n */\nexport function parseFrames(buffer) {\n  const frames = [];\n  let buf = buffer;\n  while (buf.length >= 8) {\n    if (buf.readUInt16LE(0) !== TCP_MAGIC_1 || buf.readUInt16LE(2) !== TCP_MAGIC_2) {\n      throw new Error(\"Invalid packet from device (not a ZKTeco TCP response)\");\n    }\n    const len = buf.readUInt32LE(4);\n    if (len < 8 || len > 64 * 1024 * 1024) throw new Error(`Invalid packet length from device: ${len}`);\n    if (buf.length < 8 + len) break;\n    const p = buf.subarray(8, 8 + len);\n    frames.push({\n      command: p.readUInt16LE(0),\n      sessionId: p.readUInt16LE(4),\n      replyId: p.readUInt16LE(6),\n      data: Buffer.from(p.subarray(8)),\n    });\n    buf = buf.subarray(8 + len);\n  }\n  return { frames, rest: buf };\n}\n\n/** Scrambles the numeric comm key with the session id (zkemsdk MakeKey). */\nexport function makeCommKey(key, sessionId, ticks = 50) {\n  const k0 = Number(key) >>> 0;\n  let k = 0;\n  for (let i = 0; i < 32; i++) {\n    k = ((k2(k) | ((k0 >>> i) & 1)) >>> 0);\n  }\n  k = (k + Number(sessionId)) % 0x100000000;\n\n  const b = Buffer.alloc(4);\n  b.writeUInt32LE(k >>> 0, 0);\n  const x = [b[0] ^ 0x5a, b[1] ^ 0x4b, b[2] ^ 0x53, b[3] ^ 0x4f]; // 'Z','K','S','O'\n  const swapped = [x[2], x[3], x[0], x[1]];                          // swap the two 16-bit halves\n  const B = ticks & 0xff;\n  return Buffer.from([swapped[0] ^ B, swapped[1] ^ B, B, swapped[3] ^ B]);\n\n  function k2(v) { return (v << 1) >>> 0; }\n}\n\n/** Device timestamps are packed local times (zkemsdk DecodeTime). */\nexport function decodeTime(t) {\n  let v = t >>> 0;\n  const second = v % 60; v = Math.floor(v / 60);\n  const minute = v % 60; v = Math.floor(v / 60);\n  const hour = v % 24; v = Math.floor(v / 24);\n  const day = (v % 31) + 1; v = Math.floor(v / 31);\n  const month = (v % 12) + 1; v = Math.floor(v / 12);\n  const year = v + 2000;\n  const p = (n) => String(n).padStart(2, \"0\");\n  return `${year}-${p(month)}-${p(day)} ${p(hour)}:${p(minute)}:${p(second)}`;\n}\n\n/** Inverse of decodeTime (used by the mock device in tests). */\nexport function encodeTime(ts) {\n  const m = /^(\\d{4})-(\\d{2})-(\\d{2}) (\\d{2}):(\\d{2}):(\\d{2})$/.exec(ts);\n  if (!m) throw new Error(`Bad timestamp ${ts}`);\n  const [y, mo, d, h, mi, s] = m.slice(1).map(Number);\n  return ((((y - 2000) * 12 * 31 + (mo - 1) * 31 + (d - 1)) * 24 + h) * 60 + mi) * 60 + s;\n}\n\n/**\n * Parses the attendance buffer. Record layout depends on firmware:\n *  40 bytes (TFT devices such as K40/K50), 16 bytes, or 8 bytes (old models).\n */\nexport function parseAttendance(buffer, recordCount) {\n  if (buffer.length < 4 || recordCount <= 0) return { recordSize: 0, records: [] };\n  const total = buffer.readUInt32LE(0);\n  const body = buffer.subarray(4, 4 + total);\n  const ratio = total / recordCount;\n  const recordSize = ratio === 8 ? 8 : ratio === 16 ? 16 : 40;\n\n  const records = [];\n  for (let off = 0; off + recordSize <= body.length; off += recordSize) {\n    const r = body.subarray(off, off + recordSize);\n    if (recordSize === 40) {\n      const uid = r.readUInt16LE(0);\n      const userId = r.subarray(2, 26).toString(\"latin1\").split(\"\\0\")[0].trim();\n      records.push({\n        user_id: userId || String(uid),\n        timestamp: decodeTime(r.readUInt32LE(27)),\n        state: r.readUInt8(31),\n        verify_mode: r.readUInt8(26),\n      });\n    } else if (recordSize === 16) {\n      records.push({\n        user_id: String(r.readUInt32LE(0)),\n        timestamp: decodeTime(r.readUInt32LE(4)),\n        state: r.readUInt8(9),\n        verify_mode: r.readUInt8(8),\n      });\n    } else {\n      records.push({\n        user_id: String(r.readUInt16LE(0)), // 8-byte format only stores the internal uid\n        timestamp: decodeTime(r.readUInt32LE(3)),\n        state: r.readUInt8(7),\n        verify_mode: r.readUInt8(2),\n      });\n    }\n  }\n  return { recordSize, records };\n}\n\n/**\n * Parses the user list. Only the user ID and name are kept; passwords and\n * card numbers stored on the machine are never read out of the buffer.\n * Record layout: 72 bytes (TFT devices such as K40/K50) or 28 bytes (old models).\n */\nexport function parseUsers(buffer, userCount) {\n  if (buffer.length < 4 || userCount <= 0) return { recordSize: 0, users: [] };\n  const total = buffer.readUInt32LE(0);\n  const body = buffer.subarray(4, 4 + total);\n  const recordSize = total / userCount === 28 ? 28 : 72;\n  const text = (b) => b.toString(\"utf8\").split(\"\\0\")[0].replace(/\\uFFFD/g, \"\").trim();\n\n  const users = [];\n  for (let off = 0; off + recordSize <= body.length; off += recordSize) {\n    const r = body.subarray(off, off + recordSize);\n    if (recordSize === 72) {\n      users.push({ uid: r.readUInt16LE(0), user_id: text(r.subarray(48, 72)) || String(r.readUInt16LE(0)), name: text(r.subarray(11, 35)) });\n    } else {\n      users.push({ uid: r.readUInt16LE(0), user_id: String(r.readUInt32LE(24)), name: text(r.subarray(8, 16)) });\n    }\n  }\n  return { recordSize, users };\n}\n",
 "src/zk/client.js": "// Read-only ZKTeco TCP client. Every outgoing command is checked against\n// READ_ONLY_COMMANDS, so this client cannot clear logs or change the machine.\nimport net from \"node:net\";\nimport {\n  CMD, READ_ONLY_COMMANDS, READ_ONLY_DATASETS, USHRT_MAX,\n  buildFrame, makeCommKey, parseFrames, parseAttendance, parseUsers, decodeTime,\n} from \"./protocol.js\";\n\nconst MAX_CHUNK = 0xffc0; // max bytes per READ_BUFFER request over TCP\n\nclass FrameReader {\n  constructor(socket) {\n    this.buf = Buffer.alloc(0);\n    this.frames = [];\n    this.waiters = [];\n    this.error = null;\n    socket.on(\"data\", (chunk) => {\n      this.buf = Buffer.concat([this.buf, chunk]);\n      try {\n        const { frames, rest } = parseFrames(this.buf);\n        this.buf = rest;\n        for (const f of frames) {\n          const w = this.waiters.shift();\n          if (w) w.resolve(f);\n          else this.frames.push(f);\n        }\n      } catch (err) {\n        this.fail(err);\n        socket.destroy();\n      }\n    });\n    socket.on(\"error\", (err) => this.fail(err));\n    socket.on(\"close\", () => this.fail(new Error(\"Connection closed by device\")));\n  }\n\n  fail(err) {\n    if (this.error) return;\n    this.error = err;\n    for (const w of this.waiters.splice(0)) w.reject(err);\n  }\n\n  next(timeoutMs) {\n    if (this.frames.length) return Promise.resolve(this.frames.shift());\n    if (this.error) return Promise.reject(this.error);\n    return new Promise((resolve, reject) => {\n      const w = {\n        resolve: (f) => { clearTimeout(timer); resolve(f); },\n        reject: (e) => { clearTimeout(timer); reject(e); },\n      };\n      const timer = setTimeout(() => {\n        const i = this.waiters.indexOf(w);\n        if (i >= 0) this.waiters.splice(i, 1);\n        reject(new Error(`Device did not respond within ${timeoutMs} ms`));\n      }, timeoutMs);\n      this.waiters.push(w);\n    });\n  }\n}\n\nexport class ZkClient {\n  constructor({ ip, port = 4370, commKey = 0, timeoutMs = 10000 }) {\n    this.ip = ip;\n    this.port = Number(port);\n    this.commKey = Number(commKey) || 0;\n    this.timeoutMs = Number(timeoutMs) || 10000;\n    this.socket = null;\n    this.reader = null;\n    this.sessionId = 0;\n    this.replyId = USHRT_MAX - 1;\n  }\n\n  async connect() {\n    this.socket = await new Promise((resolve, reject) => {\n      const s = net.createConnection({ host: this.ip, port: this.port });\n      const timer = setTimeout(() => {\n        s.destroy();\n        reject(new Error(`Cannot reach ${this.ip}:${this.port} (timeout after ${this.timeoutMs} ms). Check the IP, cable/Wi-Fi and that this PC is on the same network.`));\n      }, this.timeoutMs);\n      s.once(\"connect\", () => { clearTimeout(timer); resolve(s); });\n      s.once(\"error\", (err) => {\n        clearTimeout(timer);\n        reject(new Error(`Cannot connect to ${this.ip}:${this.port}: ${err.code ?? err.message}`));\n      });\n    });\n    this.socket.setNoDelay(true);\n    this.reader = new FrameReader(this.socket);\n\n    const res = await this.command(CMD.CONNECT);\n    this.sessionId = res.sessionId;\n    if (res.command === CMD.ACK_UNAUTH) {\n      const auth = await this.command(CMD.AUTH, makeCommKey(this.commKey, this.sessionId));\n      if (auth.command !== CMD.ACK_OK) {\n        throw new Error(\"Device rejected the comm key. Check Menu > COMM > Comm Key on the machine and the device settings in the dashboard.\");\n      }\n    } else if (res.command !== CMD.ACK_OK) {\n      throw new Error(`Device refused the connection (response ${res.command})`);\n    }\n  }\n\n  async command(cmd, data = Buffer.alloc(0)) {\n    if (!READ_ONLY_COMMANDS.has(cmd)) {\n      throw new Error(`Blocked: command ${cmd} is not on the read-only allowlist`);\n    }\n    if (!this.socket || !this.reader) throw new Error(\"Not connected\");\n    this.socket.write(buildFrame(cmd, this.sessionId, this.replyId, data));\n    const res = await this.reader.next(this.timeoutMs);\n    this.replyId = res.replyId;\n    return res;\n  }\n\n  async getSizes() {\n    const res = await this.command(CMD.GET_FREE_SIZES);\n    if (res.command !== CMD.ACK_OK || res.data.length < 80) {\n      throw new Error(`Could not read record counts (response ${res.command})`);\n    }\n    const f = (i) => res.data.readInt32LE(i * 4);\n    return { users: f(4), fingerprints: f(6), records: f(8), recordsCapacity: f(16) };\n  }\n\n  async getSerialNumber() {\n    const res = await this.command(CMD.OPTIONS_RRQ, Buffer.from(\"~SerialNumber\\0\", \"latin1\"));\n    if (res.command !== CMD.ACK_OK) return null;\n    const text = res.data.toString(\"latin1\").split(\"\\0\")[0];\n    const eq = text.indexOf(\"=\");\n    return eq >= 0 ? text.slice(eq + 1).trim() || null : null;\n  }\n\n  async getTime() {\n    const res = await this.command(CMD.GET_TIME);\n    if (res.command !== CMD.ACK_OK || res.data.length < 4) return null;\n    return decodeTime(res.data.readUInt32LE(0));\n  }\n\n  async readChunk(start, size) {\n    const req = Buffer.alloc(8);\n    req.writeInt32LE(start, 0);\n    req.writeInt32LE(size, 4);\n    const res = await this.command(CMD.READ_BUFFER, req);\n\n    if (res.command === CMD.DATA) return res.data;\n    if (res.command === CMD.PREPARE_DATA) {\n      const expected = res.data.readUInt32LE(0);\n      const parts = [];\n      let got = 0;\n      while (got < expected) {\n        const f = await this.reader.next(this.timeoutMs);\n        if (f.command !== CMD.DATA) throw new Error(`Unexpected packet ${f.command} while reading data`);\n        parts.push(f.data);\n        got += f.data.length;\n      }\n      const ack = await this.reader.next(this.timeoutMs);\n      if (ack.command !== CMD.ACK_OK) throw new Error(`Device did not confirm chunk (response ${ack.command})`);\n      return Buffer.concat(parts).subarray(0, expected);\n    }\n    throw new Error(`Device refused chunk read (response ${res.command})`);\n  }\n\n  async readWithBuffer(dataCommand, onProgress) {\n    if (!READ_ONLY_DATASETS.has(dataCommand)) {\n      throw new Error(`Blocked: dataset ${dataCommand} is not on the read-only allowlist`);\n    }\n    const req = Buffer.alloc(11);\n    req.writeInt8(1, 0);\n    req.writeInt16LE(dataCommand, 1);\n    req.writeInt32LE(READ_ONLY_DATASETS.get(dataCommand), 3);\n    req.writeInt32LE(0, 7);\n    const res = await this.command(CMD.PREPARE_BUFFER, req);\n\n    if (res.command === CMD.DATA) return res.data; // small dataset sent directly\n    if (res.command !== CMD.ACK_OK || res.data.length < 5) {\n      throw new Error(`Device does not support buffered reads (response ${res.command})`);\n    }\n\n    const size = res.data.readUInt32LE(1);\n    const parts = [];\n    let start = 0;\n    while (start < size) {\n      const len = Math.min(MAX_CHUNK, size - start);\n      parts.push(await this.readChunk(start, len));\n      start += len;\n      if (onProgress) onProgress(start, size);\n    }\n    await this.command(CMD.FREE_DATA);\n    return Buffer.concat(parts);\n  }\n\n  /** Reads every attendance record stored on the machine. Nothing is deleted. */\n  async getAttendance(onProgress, sizes) {\n    const s = sizes ?? (await this.getSizes());\n    if (s.records <= 0) return { sizes: s, recordSize: 0, records: [] };\n    const buffer = await this.readWithBuffer(CMD.ATTLOG_RRQ, onProgress);\n    const { recordSize, records } = parseAttendance(buffer, s.records);\n    return { sizes: s, recordSize, records };\n  }\n\n  /** Reads the user list (user ID + name only). */\n  async getUsers(sizes) {\n    const s = sizes ?? (await this.getSizes());\n    if (s.users <= 0) return [];\n    const buffer = await this.readWithBuffer(CMD.USERTEMP_RRQ);\n    return parseUsers(buffer, s.users).users;\n  }\n\n  async disconnect() {\n    if (!this.socket) return;\n    try {\n      if (!this.reader.error) {\n        this.socket.write(buildFrame(CMD.EXIT, this.sessionId, this.replyId));\n        await Promise.race([this.reader.next(2000), new Promise((r) => setTimeout(r, 2000))]).catch(() => {});\n      }\n    } finally {\n      this.socket.destroy();\n      this.socket = null;\n    }\n  }\n}\n\n/**\n * Connect, read everything we need, always disconnect.\n * The user list is optional: if the machine refuses it, attendance is still returned\n * (usersError explains why the names are missing).\n */\nexport async function readDevice(options, onProgress) {\n  const client = new ZkClient(options);\n  try {\n    await client.connect();\n    const serialNumber = await client.getSerialNumber();\n    const deviceTime = await client.getTime();\n    const sizes = await client.getSizes();\n\n    let users = [];\n    let usersError = null;\n    try {\n      users = await client.getUsers(sizes);\n    } catch (err) {\n      usersError = err.message;\n    }\n\n    const { recordSize, records } = await client.getAttendance(onProgress, sizes);\n\n    // Old 8-byte records only store the machine's internal number: map it to the user ID.\n    if (recordSize === 8 && users.length) {\n      const byUid = new Map(users.map((u) => [String(u.uid), u.user_id]));\n      for (const r of records) r.user_id = byUid.get(r.user_id) ?? r.user_id;\n    }\n\n    return {\n      serialNumber, deviceTime, sizes, recordSize, records,\n      users: users.map((u) => ({ user_id: u.user_id, name: u.name })),\n      usersError,\n    };\n  } finally {\n    await client.disconnect();\n  }\n}\n",
 "Install.cmd": "@echo off\r\nrem ZKT Connector - double-click to install or update (asks for administrator permission).\r\nif not exist \"%~dp0scripts\\install.ps1\" goto notextracted\r\nnet session >nul 2>&1\r\nif errorlevel 1 goto elevate\r\npowershell -NoProfile -ExecutionPolicy Bypass -File \"%~dp0scripts\\install.ps1\" & echo. & pause & exit /b\r\n\r\n:elevate\r\necho Asking for administrator permission...\r\npowershell -NoProfile -ExecutionPolicy Bypass -Command \"Start-Process -FilePath \\\"%~f0\\\" -Verb RunAs\"\r\nexit /b\r\n\r\n:notextracted\r\necho.\r\necho  Please extract the ZIP first:\r\necho    1. Right-click the downloaded ZIP file and choose \"Extract All...\"\r\necho    2. Open the extracted folder and double-click Install.cmd again.\r\necho.\r\npause\r\nexit /b 1\r\n",
 "Uninstall.cmd": "@echo off\r\nrem ZKT Connector - double-click to remove it from this PC (asks for administrator permission).\r\nif not exist \"%~dp0scripts\\uninstall.ps1\" goto missing\r\nnet session >nul 2>&1\r\nif errorlevel 1 goto elevate\r\npowershell -NoProfile -ExecutionPolicy Bypass -File \"%~dp0scripts\\uninstall.ps1\" & echo. & pause & exit /b\r\n\r\n:elevate\r\necho Asking for administrator permission...\r\npowershell -NoProfile -ExecutionPolicy Bypass -Command \"Start-Process -FilePath \\\"%~f0\\\" -Verb RunAs\"\r\nexit /b\r\n\r\n:missing\r\necho scripts\\uninstall.ps1 not found. Extract the ZIP first.\r\npause\r\nexit /b 1\r\n",
 "Test-Connection.cmd": "@echo off\r\nrem ZKT Connector - reads the attendance machine once and shows what it finds.\r\nrem Read-only: nothing is uploaded and nothing on the machine is changed.\r\ncd /d \"%~dp0\"\r\nwhere node >nul 2>&1 && goto run\r\nif exist \"%ProgramFiles%\\nodejs\\node.exe\" set \"PATH=%ProgramFiles%\\nodejs;%PATH%\" & goto run\r\necho.\r\necho  Node.js is not installed yet. Run Install.cmd first (it installs Node.js).\r\necho.\r\npause\r\nexit /b 1\r\n\r\n:run\r\nnode src\\read-device.js & echo. & pause & exit /b\r\n",
 "README.txt": "ZKT Connector\r\n=============\r\n\r\nThe ZKT Connector reads attendance from your ZKTeco machine (K40 / K50) and\r\nsends it to your HR Attendance dashboard. It only READS the machine: it never\r\nchanges, clears or restarts it.\r\n\r\nThis download is already set up for your company. The file \".env\" contains\r\nyour connector token - keep this folder private.\r\n\r\n\r\nINSTALL (about 2 minutes)\r\n-------------------------\r\nUse a Windows PC that stays on and is on the same network as the machine.\r\n\r\n  1. Right-click the ZIP file and choose \"Extract All...\".\r\n  2. Open the extracted folder and double-click  Install.cmd\r\n  3. Click \"Yes\" when Windows asks for administrator permission.\r\n     If Windows shows \"Windows protected your PC\", click \"More info\"\r\n     and then \"Run anyway\".\r\n  4. Wait for \"INSTALLED\". Node.js is installed automatically if needed.\r\n\r\nThe connector then runs in the background and starts with Windows, even\r\nbefore anyone logs in. You can delete the extracted folder afterwards.\r\n\r\nInstalled to : C:\\ProgramData\\ZKTConnector\r\nLog file     : C:\\ProgramData\\ZKTConnector\\logs\\connector.log\r\n\r\n\r\nCHECK THE MACHINE CONNECTION\r\n----------------------------\r\nDouble-click  Test-Connection.cmd  (in the extracted folder). It reads the\r\nmachine once and shows the serial number, number of punches and names.\r\n\r\n\r\nUPDATE\r\n------\r\nDownload the installer again from the dashboard and run Install.cmd.\r\nIt replaces the old version automatically.\r\n\r\n\r\nREMOVE\r\n------\r\nDouble-click  Uninstall.cmd\r\n\r\n\r\nTROUBLESHOOTING\r\n---------------\r\n- \"Cannot connect\": ping the machine's IP from this PC, and make sure this\r\n  PC is on the same network (for example 192.168.10.x).\r\n- Close ZKTime / ZKBio Time if it is open: the machine often allows only one\r\n  connection at a time.\r\n- \"Connector token is not valid\": download the installer again from the\r\n  dashboard and run Install.cmd.\r\n",
 "scripts/install.ps1": "# ZKT Connector installer. Started by Install.cmd (as administrator).\r\n# Installs Node.js if needed, copies the connector to C:\\ProgramData\\ZKTConnector,\r\n# and registers a Windows task that runs it at start-up (as SYSTEM) and keeps it running.\r\n$ErrorActionPreference = \"Stop\"\r\n$TaskName = \"ZKT Connector\"\r\n$Dest     = Join-Path $env:ProgramData \"ZKTConnector\"\r\n$Source   = (Resolve-Path (Join-Path $PSScriptRoot \"..\")).Path\r\n\r\nfunction Step([string]$Text) { Write-Host \"\"; Write-Host \"==> $Text\" -ForegroundColor Cyan }\r\nfunction Fail([string]$Text) {\r\n    Write-Host \"\"\r\n    Write-Host \"INSTALL FAILED: $Text\" -ForegroundColor Red\r\n    exit 1\r\n}\r\n\r\nfunction Find-Node {\r\n    $cmd = Get-Command node.exe -ErrorAction SilentlyContinue\r\n    if ($cmd) { return $cmd.Source }\r\n    foreach ($p in @(\"$env:ProgramFiles\\nodejs\\node.exe\", \"${env:ProgramFiles(x86)}\\nodejs\\node.exe\")) {\r\n        if ($p -and (Test-Path $p)) { return $p }\r\n    }\r\n    return $null\r\n}\r\n\r\n# Stops connector processes started from any of the given folders (never anything else).\r\nfunction Stop-ConnectorProcesses([string[]]$Dirs) {\r\n    $procs = Get-CimInstance Win32_Process -Filter \"Name='node.exe' OR Name='cmd.exe'\" -ErrorAction SilentlyContinue\r\n    foreach ($p in $procs) {\r\n        $cl = [string]$p.CommandLine\r\n        if (-not $cl) { continue }\r\n        $isConnector = ($cl.IndexOf(\"run-connector.cmd\", [StringComparison]::OrdinalIgnoreCase) -ge 0) -or\r\n                       ($cl.IndexOf(\"src\\index.js\", [StringComparison]::OrdinalIgnoreCase) -ge 0)\r\n        if (-not $isConnector) { continue }\r\n        foreach ($d in $Dirs) {\r\n            if ($d -and $cl.IndexOf($d, [StringComparison]::OrdinalIgnoreCase) -ge 0) {\r\n                Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue\r\n                break\r\n            }\r\n        }\r\n    }\r\n}\r\n\r\ntry {\r\n    $version = (Get-Content (Join-Path $Source \"package.json\") -Raw | ConvertFrom-Json).version\r\n    Write-Host \"ZKT Connector $version - setup\" -ForegroundColor White\r\n\r\n    $me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())\r\n    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {\r\n        Fail \"Administrator permission is needed. Double-click Install.cmd and click Yes.\"\r\n    }\r\n    if (-not (Test-Path (Join-Path $Source \".env\"))) {\r\n        Fail \"The settings file (.env) is missing. Download the installer again from the dashboard.\"\r\n    }\r\n    if ($Source.TrimEnd(\"\\\") -ieq $Dest.TrimEnd(\"\\\")) {\r\n        Fail \"Run Install.cmd from the extracted download folder, not from $Dest.\"\r\n    }\r\n\r\n    # ------------------------------------------------------------ Node.js\r\n    Step \"Checking Node.js\"\r\n    $node = Find-Node\r\n    if (-not $node) {\r\n        if (Get-Command winget.exe -ErrorAction SilentlyContinue) {\r\n            Write-Host \"Node.js not found. Installing Node.js LTS (this can take a few minutes)...\"\r\n            & winget.exe install -e --id OpenJS.NodeJS.LTS --scope machine --silent --accept-package-agreements --accept-source-agreements | Out-Host\r\n            $node = Find-Node\r\n        }\r\n    }\r\n    if (-not $node) {\r\n        Start-Process \"https://nodejs.org/en/download\"\r\n        Fail \"Node.js is required. Install the LTS version from nodejs.org (the page has been opened), then run Install.cmd again.\"\r\n    }\r\n    $nodeVersion = (& $node -v).Trim()\r\n    $major = [int](($nodeVersion.TrimStart(\"v\")).Split(\".\")[0])\r\n    if ($major -lt 18) {\r\n        Start-Process \"https://nodejs.org/en/download\"\r\n        Fail \"Node.js $nodeVersion is too old (18 or newer is needed). Install the LTS version from nodejs.org, then run Install.cmd again.\"\r\n    }\r\n    Write-Host \"Node.js $nodeVersion at $node\"\r\n\r\n    # ------------------------------------------------------------ stop the previous version\r\n    Step \"Stopping any previous version\"\r\n    $dirs = @($Dest)\r\n    $old = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue\r\n    if ($old) {\r\n        foreach ($a in $old.Actions) { if ($a.WorkingDirectory) { $dirs += $a.WorkingDirectory } }\r\n        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue\r\n        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false\r\n        Write-Host \"Removed the previous start-up task.\"\r\n    }\r\n    Stop-ConnectorProcesses $dirs\r\n    Start-Sleep -Seconds 2\r\n\r\n    # ------------------------------------------------------------ copy files\r\n    Step \"Copying files to $Dest\"\r\n    New-Item -ItemType Directory -Force -Path $Dest | Out-Null\r\n    foreach ($sub in @(\"src\", \"scripts\")) {\r\n        $p = Join-Path $Dest $sub\r\n        if (Test-Path $p) { Remove-Item $p -Recurse -Force }\r\n    }\r\n    Copy-Item (Join-Path $Source \"src\") (Join-Path $Dest \"src\") -Recurse -Force\r\n    New-Item -ItemType Directory -Force -Path (Join-Path $Dest \"scripts\") | Out-Null\r\n    Copy-Item (Join-Path $Source \"scripts\\uninstall.ps1\") (Join-Path $Dest \"scripts\\uninstall.ps1\") -Force\r\n    foreach ($f in @(\"package.json\", \".env\", \"Uninstall.cmd\", \"Test-Connection.cmd\", \"README.txt\")) {\r\n        Copy-Item (Join-Path $Source $f) (Join-Path $Dest $f) -Force\r\n    }\r\n    Get-ChildItem $Dest -Recurse -File | Unblock-File -ErrorAction SilentlyContinue\r\n\r\n    # The .env file holds the connector token: only administrators and SYSTEM may read this folder.\r\n    & icacls.exe $Dest /inheritance:r /grant:r \"*S-1-5-32-544:(OI)(CI)F\" \"*S-1-5-18:(OI)(CI)F\" /T /Q | Out-Null\r\n\r\n    $logs    = Join-Path $Dest \"logs\"\r\n    $logFile = Join-Path $logs \"connector.log\"\r\n    $script  = Join-Path $Dest \"src\\index.js\"\r\n    $cmdPath = Join-Path $Dest \"run-connector.cmd\"\r\n    New-Item -ItemType Directory -Force -Path $logs | Out-Null\r\n\r\n    # Runs the connector, appends to logs\\connector.log (kept under ~5 MB), restarts 60 s after any exit.\r\n    $wrapper = @\"\r\n@echo off\r\nrem Generated by the ZKT Connector installer - run Install.cmd again instead of editing.\r\ncd /d \"$Dest\"\r\n:loop\r\nfor %%F in (\"$logFile\") do if %%~zF GTR 5000000 move /y \"$logFile\" \"$logFile.old\" >nul\r\necho ===== %date% %time% starting connector >> \"$logFile\"\r\n\"$node\" \"$script\" >> \"$logFile\" 2>&1\r\nping -n 61 127.0.0.1 >nul\r\ngoto loop\r\n\"@\r\n    [System.IO.File]::WriteAllText($cmdPath, ($wrapper -replace \"`r?`n\", \"`r`n\"), [System.Text.Encoding]::ASCII)\r\n\r\n    # ------------------------------------------------------------ start-up task\r\n    Step \"Registering the start-up task\"\r\n    $action    = New-ScheduledTaskAction -Execute \"cmd.exe\" -Argument \"/c `\"$cmdPath`\"\" -WorkingDirectory $Dest\r\n    $trigger   = New-ScheduledTaskTrigger -AtStartup\r\n    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `\r\n                   -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `\r\n                   -MultipleInstances IgnoreNew\r\n    $principal = New-ScheduledTaskPrincipal -UserId \"SYSTEM\" -LogonType ServiceAccount -RunLevel Highest\r\n    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `\r\n        -Description \"Imports attendance from the ZKTeco machine into HR Attendance ($Dest)\" -Force | Out-Null\r\n\r\n    $startedAt = (Get-Item $logFile -ErrorAction SilentlyContinue).Length\r\n    if (-not $startedAt) { $startedAt = 0 }\r\n    Start-ScheduledTask -TaskName $TaskName\r\n\r\n    # ------------------------------------------------------------ check it connected\r\n    Step \"Checking the connection to the server\"\r\n    $ok = $false\r\n    $newLines = @()\r\n    for ($i = 0; $i -lt 30 -and -not $ok; $i++) {\r\n        Start-Sleep -Seconds 1\r\n        if (Test-Path $logFile) {\r\n            $fs = [System.IO.File]::Open($logFile, \"Open\", \"Read\", \"ReadWrite\")\r\n            try {\r\n                [void]$fs.Seek($startedAt, \"Begin\")\r\n                $text = (New-Object System.IO.StreamReader($fs)).ReadToEnd()\r\n            } finally { $fs.Close() }\r\n            $newLines = $text -split \"`r?`n\" | Where-Object { $_ }\r\n            if ($text -match \"Connected to \") { $ok = $true }\r\n            elseif ($text -match \"ERROR\") { break }\r\n        }\r\n    }\r\n    $newLines | Select-Object -Last 8 | ForEach-Object { Write-Host \"  $_\" }\r\n\r\n    Write-Host \"\"\r\n    if ($ok) {\r\n        Write-Host \"INSTALLED. ZKT Connector $version is running and starts automatically with Windows.\" -ForegroundColor Green\r\n        Write-Host \"Check the dashboard: the connector shows a 'Last seen' time and version $version.\"\r\n    } else {\r\n        Write-Host \"Installed, but the connector has not connected to the server yet.\" -ForegroundColor Yellow\r\n        Write-Host \"Check the internet connection and the log: $logFile\"\r\n    }\r\n    Write-Host \"Log file : $logFile\"\r\n    Write-Host \"Remove   : double-click Uninstall.cmd\"\r\n}\r\ncatch {\r\n    Fail $_.Exception.Message\r\n}\r\n",
 "scripts/uninstall.ps1": "# ZKT Connector uninstaller. Started by Uninstall.cmd (as administrator).\r\n$ErrorActionPreference = \"Stop\"\r\n$TaskName = \"ZKT Connector\"\r\n$Dest     = Join-Path $env:ProgramData \"ZKTConnector\"\r\n\r\ntry {\r\n    $me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())\r\n    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {\r\n        throw \"Administrator permission is needed. Double-click Uninstall.cmd and click Yes.\"\r\n    }\r\n\r\n    $dirs = @($Dest)\r\n    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue\r\n    if ($task) {\r\n        foreach ($a in $task.Actions) { if ($a.WorkingDirectory) { $dirs += $a.WorkingDirectory } }\r\n        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue\r\n        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false\r\n        Write-Host \"Start-up task removed.\"\r\n    } else {\r\n        Write-Host \"Start-up task was not installed.\"\r\n    }\r\n\r\n    $procs = Get-CimInstance Win32_Process -Filter \"Name='node.exe' OR Name='cmd.exe'\" -ErrorAction SilentlyContinue\r\n    foreach ($p in $procs) {\r\n        $cl = [string]$p.CommandLine\r\n        if (-not $cl) { continue }\r\n        $isConnector = ($cl.IndexOf(\"run-connector.cmd\", [StringComparison]::OrdinalIgnoreCase) -ge 0) -or\r\n                       ($cl.IndexOf(\"src\\index.js\", [StringComparison]::OrdinalIgnoreCase) -ge 0)\r\n        if (-not $isConnector) { continue }\r\n        foreach ($d in $dirs) {\r\n            if ($d -and $cl.IndexOf($d, [StringComparison]::OrdinalIgnoreCase) -ge 0) {\r\n                Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue\r\n                Write-Host \"Stopped connector process $($p.ProcessId).\"\r\n                break\r\n            }\r\n        }\r\n    }\r\n\r\n    if (Test-Path $Dest) {\r\n        # Delete a few seconds later, so this window (which may run from that folder) can finish.\r\n        Start-Process -FilePath \"cmd.exe\" -ArgumentList \"/c ping -n 4 127.0.0.1 >nul & rmdir /s /q `\"$Dest`\"\" -WindowStyle Hidden\r\n        Write-Host \"Removing $Dest ...\"\r\n    }\r\n    Write-Host \"\"\r\n    Write-Host \"ZKT Connector has been removed from this PC.\" -ForegroundColor Green\r\n    Write-Host \"To stop it being used anywhere, also click Revoke on the connector in the dashboard.\"\r\n}\r\ncatch {\r\n    Write-Host \"\"\r\n    Write-Host \"UNINSTALL FAILED: $($_.Exception.Message)\" -ForegroundColor Red\r\n    exit 1\r\n}\r\n",
 "package.json": "{\n  \"name\": \"zkt-connector\",\n  \"version\": \"0.8.0\",\n  \"private\": true,\n  \"type\": \"module\"\n}\n"
};
'@

# ---------------------------------------------------------------- worker/src/env.ts
Write-File "worker/src/env.ts" @'
export interface Env {
  DB: D1Database;
  /** Optional. When set, sign-up requires this code (set with: wrangler secret put SIGNUP_CODE). */
  SIGNUP_CODE?: string;
}

export const VERSION = "0.8.0-phase8";

/** Number of files in worker/migrations. The health check reports "degraded" until all are applied. */
export const EXPECTED_MIGRATIONS = 5;
'@

# ---------------------------------------------------------------- worker/src/lib/zip.ts
Write-File "worker/src/lib/zip.ts" @'
// Minimal ZIP writer ("stored", no compression) - used for .xlsx files and the connector download.
const enc = new TextEncoder();

export interface ZipEntry {
  name: string;
  data: Uint8Array | string;
}


const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

function crc32(data: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < data.length; i++) c = CRC_TABLE[(c ^ data[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

export function zipStore(input: ZipEntry[]): Uint8Array {
  const entries = input.map((e) => ({ name: e.name, data: typeof e.data === "string" ? enc.encode(e.data) : e.data }));
  const now = new Date();
  const dosTime = (now.getUTCHours() << 11) | (now.getUTCMinutes() << 5) | Math.floor(now.getUTCSeconds() / 2);
  const dosDate = ((now.getUTCFullYear() - 1980) << 9) | ((now.getUTCMonth() + 1) << 5) | now.getUTCDate();

  const chunks: Uint8Array[] = [];
  const central: Uint8Array[] = [];
  let offset = 0;

  for (const e of entries) {
    const name = enc.encode(e.name);
    const crc = crc32(e.data);

    const local = new DataView(new ArrayBuffer(30));
    local.setUint32(0, 0x04034b50, true);
    local.setUint16(4, 20, true);
    local.setUint16(6, 0x0800, true); // UTF-8 names
    local.setUint16(8, 0, true);      // stored
    local.setUint16(10, dosTime, true);
    local.setUint16(12, dosDate, true);
    local.setUint32(14, crc, true);
    local.setUint32(18, e.data.length, true);
    local.setUint32(22, e.data.length, true);
    local.setUint16(26, name.length, true);
    local.setUint16(28, 0, true);
    chunks.push(new Uint8Array(local.buffer), name, e.data);

    const cd = new DataView(new ArrayBuffer(46));
    cd.setUint32(0, 0x02014b50, true);
    cd.setUint16(4, 20, true);
    cd.setUint16(6, 20, true);
    cd.setUint16(8, 0x0800, true);
    cd.setUint16(10, 0, true);
    cd.setUint16(12, dosTime, true);
    cd.setUint16(14, dosDate, true);
    cd.setUint32(16, crc, true);
    cd.setUint32(20, e.data.length, true);
    cd.setUint32(24, e.data.length, true);
    cd.setUint16(28, name.length, true);
    cd.setUint16(30, 0, true);
    cd.setUint16(32, 0, true);
    cd.setUint16(34, 0, true);
    cd.setUint16(36, 0, true);
    cd.setUint32(38, 0, true);
    cd.setUint32(42, offset, true);
    central.push(new Uint8Array(cd.buffer), name);

    offset += 30 + name.length + e.data.length;
  }

  const cdSize = central.reduce((n, c) => n + c.length, 0);
  const end = new DataView(new ArrayBuffer(22));
  end.setUint32(0, 0x06054b50, true);
  end.setUint16(8, entries.length, true);
  end.setUint16(10, entries.length, true);
  end.setUint32(12, cdSize, true);
  end.setUint32(16, offset, true);

  const all = [...chunks, ...central, new Uint8Array(end.buffer)];
  const out = new Uint8Array(all.reduce((n, c) => n + c.length, 0));
  let p = 0;
  for (const c of all) { out.set(c, p); p += c.length; }
  return out;
}
'@

# ---------------------------------------------------------------- worker/src/lib/xlsx.ts
Write-File "worker/src/lib/xlsx.ts" @'
// Minimal, dependency-free .xlsx writer for Workers.
// Produces a standard Office Open XML workbook (stored zip, inline strings).

export const STYLE = {
  normal: 0,
  header: 1,   // bold on light blue
  date: 2,     // dd-mmm-yyyy
  time: 3,     // hh:mm
  duration: 4, // [h]:mm
  bold: 5,
} as const;

export type CellValue = string | number | null | undefined | { v: string | number; s: number };

export interface SheetSpec {
  name: string;
  widths: number[];
  rows: CellValue[][];
  /** First row is a header: bold, frozen, with filter buttons. */
  header?: boolean;
}

import { zipStore } from "./zip";

const enc = new TextEncoder();

function xmlEscape(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    // strip control characters Excel rejects
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, "");
}

function colName(index: number): string {
  let n = index + 1;
  let s = "";
  while (n > 0) {
    const m = (n - 1) % 26;
    s = String.fromCharCode(65 + m) + s;
    n = Math.floor((n - 1) / 26);
  }
  return s;
}

function safeSheetName(name: string): string {
  return name.replace(/[\[\]:*?/\\]/g, " ").slice(0, 31) || "Sheet";
}

function cellXml(ref: string, cell: CellValue, defaultStyle: number): string {
  if (cell === null || cell === undefined || cell === "") return "";
  let value: string | number;
  let style = defaultStyle;
  if (typeof cell === "object") {
    value = cell.v;
    style = cell.s;
  } else {
    value = cell;
  }
  const s = style ? ` s="${style}"` : "";
  if (typeof value === "number" && Number.isFinite(value)) {
    return `<c r="${ref}"${s}><v>${value}</v></c>`;
  }
  return `<c r="${ref}"${s} t="inlineStr"><is><t xml:space="preserve">${xmlEscape(String(value))}</t></is></c>`;
}

function sheetXml(sheet: SheetSpec): string {
  const lastCol = colName(Math.max(sheet.widths.length, 1) - 1);
  const lastRow = Math.max(sheet.rows.length, 1);
  const parts: string[] = [];
  parts.push(`<?xml version="1.0" encoding="UTF-8" standalone="yes"?>`);
  parts.push(`<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">`);
  if (sheet.header) {
    parts.push(`<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>`);
  } else {
    parts.push(`<sheetViews><sheetView workbookViewId="0"/></sheetViews>`);
  }
  parts.push(`<cols>`);
  sheet.widths.forEach((w, i) => parts.push(`<col min="${i + 1}" max="${i + 1}" width="${w}" customWidth="1"/>`));
  parts.push(`</cols><sheetData>`);
  sheet.rows.forEach((row, r) => {
    const defaultStyle = sheet.header && r === 0 ? STYLE.header : STYLE.normal;
    const cells = row.map((c, i) => cellXml(`${colName(i)}${r + 1}`, c, defaultStyle)).join("");
    parts.push(`<row r="${r + 1}">${cells}</row>`);
  });
  parts.push(`</sheetData>`);
  if (sheet.header && sheet.rows.length > 0) parts.push(`<autoFilter ref="A1:${lastCol}${lastRow}"/>`);
  parts.push(`</worksheet>`);
  return parts.join("");
}

const STYLES_XML = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<numFmts count="3"><numFmt numFmtId="164" formatCode="dd\\-mmm\\-yyyy"/><numFmt numFmtId="165" formatCode="hh:mm"/><numFmt numFmtId="166" formatCode="[h]:mm"/></numFmts>
<fonts count="2"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font><font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts>
<fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFDCE6F1"/><bgColor indexed="64"/></patternFill></fill></fills>
<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="6">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/>
<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="165" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="166" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>
<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>
</cellXfs>
<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>`;

export function buildXlsx(sheets: SheetSpec[]): Uint8Array {
  const names = sheets.map((s) => safeSheetName(s.name));
  const files: Array<[string, string]> = [];

  files.push(["[Content_Types].xml",
    `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
    `<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">` +
    `<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>` +
    `<Default Extension="xml" ContentType="application/xml"/>` +
    `<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>` +
    `<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>` +
    sheets.map((_, i) => `<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join("") +
    `</Types>`]);

  files.push(["_rels/.rels",
    `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
    `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` +
    `<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>` +
    `</Relationships>`]);

  const definedNames = sheets
    .map((s, i) => (s.header && s.rows.length > 0
      ? `<definedName name="_xlnm._FilterDatabase" localSheetId="${i}" hidden="1">'${xmlEscape(names[i].replace(/'/g, "''"))}'!$A$1:$${colName(Math.max(s.widths.length, 1) - 1)}$${s.rows.length}</definedName>`
      : ""))
    .join("");

  files.push(["xl/workbook.xml",
    `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
    `<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">` +
    `<bookViews><workbookView/></bookViews><sheets>` +
    names.map((n, i) => `<sheet name="${xmlEscape(n)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>`).join("") +
    `</sheets>` + (definedNames ? `<definedNames>${definedNames}</definedNames>` : "") + `</workbook>`]);

  files.push(["xl/_rels/workbook.xml.rels",
    `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>` +
    `<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">` +
    sheets.map((_, i) => `<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>`).join("") +
    `<Relationship Id="rId${sheets.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>` +
    `</Relationships>`]);

  files.push(["xl/styles.xml", STYLES_XML]);
  sheets.forEach((s, i) => files.push([`xl/worksheets/sheet${i + 1}.xml`, sheetXml({ ...s, name: names[i] })]));

  return zipStore(files.map(([name, text]) => ({ name, data: enc.encode(text) })));
}
'@

# ---------------------------------------------------------------- worker/src/routes/download.ts
Write-File "worker/src/routes/download.ts" @'
// "Download installer": a ZIP with the ZKT Connector, already configured for this
// company and connector (server address + token in .env). Owner/admin only.
import type { Env } from "../env";
import { HttpError, readJson } from "../lib/http";
import { requireAuth, requireRole } from "../lib/auth";
import { randomToken, sha256Hex } from "../lib/crypto";
import { zipStore, type ZipEntry } from "../lib/zip";
import { CONNECTOR_FILES, CONNECTOR_VERSION } from "../generated/connector-files";

const FOLDER = "ZKT-Connector";
const TOKEN_RE = /^zkc_[A-Za-z0-9_-]{20,}$/;

function ascii(s: string): string {
  return s.replace(/[^\x20-\x7e]/g, "").replace(/[\r\n]/g, " ").trim();
}

function envFile(apiBase: string, token: string, companyName: string, connectorName: string): string {
  const lines = [
    "# ZKT Connector settings",
    `# Company   : ${ascii(companyName) || "-"}`,
    `# Connector : ${ascii(connectorName) || "-"}`,
    `# Created   : ${new Date().toISOString().slice(0, 16).replace("T", " ")} UTC`,
    "# Keep this file private: the token allows uploading attendance for your company.",
    "",
    `API_BASE_URL=${apiBase}`,
    `CONNECTOR_TOKEN=${token}`,
    "",
    "# How long to wait for the machine (ms), how often to check for sync jobs (s),",
    "# and the first retry delay when the machine or server fails (s).",
    "DEVICE_TIMEOUT_MS=10000",
    "POLL_INTERVAL_SECONDS=60",
    "RETRY_DELAY_SECONDS=10",
    "",
  ];
  return lines.join("\r\n");
}

/**
 * POST /api/connectors/:id/package   { token?: "zkc_..." }
 * With the token just shown after "Create connector": that token is packed as-is.
 * Without a token: a NEW token is issued (the old one stops working) and packed.
 */
export async function downloadConnector(request: Request, env: Env, id: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  const body = await readJson<{ token?: unknown }>(request);

  const connector = await env.DB.prepare(
    "SELECT id, name, token_hash FROM connectors WHERE id = ? AND company_id = ? AND is_active = 1",
  ).bind(id, auth.companyId).first<{ id: string; name: string; token_hash: string }>();
  if (!connector) throw new HttpError(404, "Connector not found or revoked");

  let token: string;
  let rotated = false;
  if (typeof body.token === "string" && body.token) {
    if (!TOKEN_RE.test(body.token) || (await sha256Hex(body.token)) !== connector.token_hash) {
      throw new HttpError(403, "That token does not belong to this connector");
    }
    token = body.token;
  } else {
    token = `zkc_${randomToken(32)}`;
    await env.DB.prepare("UPDATE connectors SET token_hash = ?, token_hint = ? WHERE id = ? AND company_id = ?")
      .bind(await sha256Hex(token), token.slice(-4), connector.id, auth.companyId).run();
    rotated = true;
  }

  const apiBase = new URL(request.url).origin;
  const entries: ZipEntry[] = Object.entries(CONNECTOR_FILES).map(([name, data]) => ({ name: `${FOLDER}/${name}`, data }));
  entries.push({ name: `${FOLDER}/.env`, data: envFile(apiBase, token, auth.companyName, connector.name) });
  entries.sort((a, b) => a.name.localeCompare(b.name));

  const slug = ascii(connector.name).replace(/[^A-Za-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40) || "connector";
  const filename = `ZKT-Connector-${CONNECTOR_VERSION}-${slug}.zip`;

  return new Response(zipStore(entries), {
    headers: {
      "content-type": "application/zip",
      "content-disposition": `attachment; filename="${filename}"`,
      "cache-control": "no-store",
      "x-connector-version": CONNECTOR_VERSION,
      "x-token-rotated": rotated ? "1" : "0",
    },
  });
}
'@

# ---------------------------------------------------------------- worker/src/routes/status.ts
Write-File "worker/src/routes/status.ts" @'
// Dashboard status: problems that need attention, worst first.
import type { Env } from "../env";
import { json } from "../lib/http";
import { requireAuth } from "../lib/auth";
import { CONNECTOR_VERSION } from "../generated/connector-files";

const OFFLINE_MINUTES = 10;
const CLOCK_WARN_SECONDS = 120;

type Level = "error" | "warning" | "info";
interface Alert { level: Level; text: string }

function versionLess(a: string, b: string): boolean {
  const pa = a.split(".").map((n) => parseInt(n, 10) || 0);
  const pb = b.split(".").map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < 3; i++) if ((pa[i] ?? 0) !== (pb[i] ?? 0)) return (pa[i] ?? 0) < (pb[i] ?? 0);
  return false;
}

function ago(iso: string, now: number): string {
  const min = Math.round((now - Date.parse(iso)) / 60000);
  if (min < 60) return `${min} min ago`;
  if (min < 48 * 60) return `${Math.round(min / 60)} h ago`;
  return `${Math.round(min / 1440)} days ago`;
}

/** GET /api/status */
export async function status(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  const now = Date.now();
  const alerts: Alert[] = [];

  const { results: connectors } = await env.DB.prepare(
    `SELECT c.id, c.name, c.version, c.last_seen_at,
            (SELECT COUNT(*) FROM devices d WHERE d.connector_id = c.id AND d.is_active = 1) AS devices
       FROM connectors c WHERE c.company_id = ? AND c.is_active = 1`,
  ).bind(auth.companyId).all<{ id: string; name: string; version: string | null; last_seen_at: string | null; devices: number }>();

  const { results: devices } = await env.DB.prepare(
    `SELECT d.id, d.name, d.connector_id, d.clock_offset_seconds,
            (SELECT j.status FROM sync_jobs j WHERE j.device_id = d.id ORDER BY j.requested_at DESC LIMIT 1) AS last_status,
            (SELECT j.error_message FROM sync_jobs j WHERE j.device_id = d.id ORDER BY j.requested_at DESC LIMIT 1) AS last_error
       FROM devices d WHERE d.company_id = ? AND d.is_active = 1`,
  ).bind(auth.companyId).all<{
    id: string; name: string; connector_id: string | null; clock_offset_seconds: number | null;
    last_status: string | null; last_error: string | null;
  }>();

  const cs = connectors ?? [];
  const ds = devices ?? [];

  if (!cs.length) {
    alerts.push({ level: "info", text: "Get started: create a connector below, then click Download installer and run it on a PC on the machine's network." });
  }
  for (const c of cs) {
    if (!c.last_seen_at) {
      alerts.push({ level: "warning", text: `Connector "${c.name}" has not connected yet. Download the installer and run Install.cmd on the office PC.` });
    } else if (now - Date.parse(c.last_seen_at) > OFFLINE_MINUTES * 60000) {
      alerts.push({ level: "error", text: `Connector "${c.name}" is offline (last seen ${ago(c.last_seen_at, now)}). Check that the office PC is on and connected to the internet.` });
    } else if (c.version && versionLess(c.version, CONNECTOR_VERSION)) {
      alerts.push({ level: "info", text: `Connector "${c.name}" runs version ${c.version}; ${CONNECTOR_VERSION} is available. Click Download installer and run Install.cmd to update.` });
    }
    if (c.devices === 0) {
      alerts.push({ level: "info", text: `Connector "${c.name}" has no machine assigned. Add a device below.` });
    }
  }
  for (const d of ds) {
    if (!d.connector_id || !cs.some((c) => c.id === d.connector_id)) {
      alerts.push({ level: "warning", text: `Machine "${d.name}" has no active connector, so it cannot sync.` });
    }
    if (d.last_status === "failed") {
      alerts.push({ level: "error", text: `Last sync of "${d.name}" failed: ${d.last_error ?? "unknown error"}` });
    }
    if (d.clock_offset_seconds !== null && Math.abs(d.clock_offset_seconds) > CLOCK_WARN_SECONDS) {
      const sec = Math.abs(d.clock_offset_seconds);
      const amount = sec < 5400 ? `${Math.round(sec / 60)} min` : sec < 172800 ? `${Math.round(sec / 3600)} h` : `${Math.round(sec / 86400)} days`;
      alerts.push({ level: "warning", text: `The clock on "${d.name}" is ${amount} ${d.clock_offset_seconds < 0 ? "slow" : "fast"}. Set the correct time on the machine (Menu > System > Date/Time).` });
    }
  }

  const order: Record<Level, number> = { error: 0, warning: 1, info: 2 };
  alerts.sort((a, b) => order[a.level] - order[b.level]);
  return json({ alerts, latest_connector_version: CONNECTOR_VERSION });
}
'@

# ---------------------------------------------------------------- worker/src/routes/manage.ts
Write-File "worker/src/routes/manage.ts" @'
// Dashboard (session-authenticated) API: connectors, devices, sync jobs.
// Every query is filtered by auth.companyId, so tenants never see each other's data.
import type { Env } from "../env";
import { HttpError, json, readJson } from "../lib/http";
import { requireAuth, requireRole } from "../lib/auth";
import { randomToken, sha256Hex } from "../lib/crypto";

const IPV4 = /^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$/;

function cleanText(value: unknown, field: string, max = 80): string {
  const v = typeof value === "string" ? value.trim() : "";
  if (v.length < 2) throw new HttpError(400, `${field} is required`);
  if (v.length > max) throw new HttpError(400, `${field} is too long`);
  return v;
}

function cleanInt(value: unknown, field: string, min: number, max: number, fallback: number): number {
  if (value === undefined || value === null || value === "") return fallback;
  const n = Number(value);
  if (!Number.isInteger(n) || n < min || n > max) {
    throw new HttpError(400, `${field} must be a whole number between ${min} and ${max}`);
  }
  return n;
}

// ------------------------------------------------------------------ connectors

/** GET /api/connectors */
export async function listConnectors(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  const { results } = await env.DB.prepare(
    `SELECT c.id, c.name, c.token_hint, c.version, c.last_seen_at, c.is_active, c.created_at,
            (SELECT COUNT(*) FROM devices d WHERE d.connector_id = c.id AND d.is_active = 1) AS device_count
       FROM connectors c
      WHERE c.company_id = ?
      ORDER BY c.is_active DESC, c.created_at DESC`,
  ).bind(auth.companyId).all();
  return json({ connectors: results ?? [] });
}

/** POST /api/connectors  { name } -> returns the token ONCE */
export async function createConnector(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  const body = await readJson<Record<string, unknown>>(request);
  const name = cleanText(body.name, "Connector name");

  const id = crypto.randomUUID();
  const token = `zkc_${randomToken(32)}`;
  await env.DB.prepare(
    "INSERT INTO connectors (id, company_id, name, token_hash, token_hint) VALUES (?, ?, ?, ?, ?)",
  ).bind(id, auth.companyId, name, await sha256Hex(token), token.slice(-4)).run();

  return json(
    {
      connector: { id, name },
      token,
      note: "Copy this token into connector/.env as CONNECTOR_TOKEN. It will not be shown again.",
    },
    201,
  );
}

/** POST /api/connectors/:id/revoke */
export async function revokeConnector(request: Request, env: Env, id: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  const res = await env.DB.prepare("UPDATE connectors SET is_active = 0 WHERE id = ? AND company_id = ?")
    .bind(id, auth.companyId).run();
  if (!res.meta.changes) throw new HttpError(404, "Connector not found");
  return json({ ok: true });
}

// ------------------------------------------------------------------ devices

/** GET /api/devices */
export async function listDevices(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  const { results } = await env.DB.prepare(
    `SELECT d.id, d.name, d.model, d.ip_address, d.port, d.comm_key, d.serial_number,
            d.connector_id, c.name AS connector_name, c.is_active AS connector_active,
            d.last_sync_at, d.clock_offset_seconds, d.clock_checked_at, d.is_active, d.created_at,
            (SELECT COUNT(*) FROM attendance_logs l WHERE l.device_id = d.id) AS log_count,
            (SELECT j.status FROM sync_jobs j WHERE j.device_id = d.id ORDER BY j.requested_at DESC LIMIT 1) AS last_job_status
       FROM devices d
       LEFT JOIN connectors c ON c.id = d.connector_id
      WHERE d.company_id = ?
      ORDER BY d.is_active DESC, d.created_at DESC`,
  ).bind(auth.companyId).all();
  return json({ devices: results ?? [] });
}

/** POST /api/devices  { name, ip_address, port?, comm_key?, model?, connector_id? } */
export async function createDevice(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  const body = await readJson<Record<string, unknown>>(request);

  const name = cleanText(body.name, "Device name");
  const ip = typeof body.ip_address === "string" ? body.ip_address.trim() : "";
  if (!IPV4.test(ip)) throw new HttpError(400, "A valid IPv4 address is required (e.g. 192.168.10.21)");
  const port = cleanInt(body.port, "Port", 1, 65535, 4370);
  const commKey = cleanInt(body.comm_key, "Comm key", 0, 999999, 0);
  const model = typeof body.model === "string" && body.model.trim() ? cleanText(body.model, "Model", 40) : "K50";

  let connectorId: string | null = null;
  if (typeof body.connector_id === "string" && body.connector_id) {
    const ok = await env.DB.prepare("SELECT 1 FROM connectors WHERE id = ? AND company_id = ? AND is_active = 1")
      .bind(body.connector_id, auth.companyId).first();
    if (!ok) throw new HttpError(400, "Connector not found or revoked");
    connectorId = body.connector_id;
  }

  const id = crypto.randomUUID();
  await env.DB.prepare(
    `INSERT INTO devices (id, company_id, connector_id, name, model, ip_address, port, comm_key)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind(id, auth.companyId, connectorId, name, model, ip, port, commKey).run();

  return json({ device: { id, name } }, 201);
}

/** POST /api/devices/:id/deactivate (data is kept; pending jobs are cancelled) */
export async function deactivateDevice(request: Request, env: Env, id: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  const now = new Date().toISOString();
  const [res] = await env.DB.batch([
    env.DB.prepare("UPDATE devices SET is_active = 0 WHERE id = ? AND company_id = ?").bind(id, auth.companyId),
    env.DB.prepare(
      `UPDATE sync_jobs SET status = 'failed', finished_at = ?, error_message = 'Device deactivated'
        WHERE device_id = ? AND company_id = ? AND status = 'pending'`,
    ).bind(now, id, auth.companyId),
  ]);
  if (!res.meta.changes) throw new HttpError(404, "Device not found");
  return json({ ok: true });
}

// ------------------------------------------------------------------ sync jobs

/** POST /api/devices/:id/sync - queue a manual sync (one open job per device). */
export async function queueSync(request: Request, env: Env, id: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);

  const device = await env.DB.prepare(
    `SELECT d.id, d.is_active, d.connector_id, c.is_active AS connector_active
       FROM devices d LEFT JOIN connectors c ON c.id = d.connector_id
      WHERE d.id = ? AND d.company_id = ?`,
  ).bind(id, auth.companyId).first<{ id: string; is_active: number; connector_id: string | null; connector_active: number | null }>();

  if (!device) throw new HttpError(404, "Device not found");
  if (device.is_active !== 1) throw new HttpError(409, "Device is deactivated");
  if (!device.connector_id || device.connector_active !== 1) {
    throw new HttpError(409, "Assign an active connector to this device first");
  }

  const open = await env.DB.prepare(
    "SELECT id, status FROM sync_jobs WHERE device_id = ? AND status IN ('pending','running') LIMIT 1",
  ).bind(id).first<{ id: string; status: string }>();
  if (open) return json({ job: open, already_queued: true });

  const jobId = crypto.randomUUID();
  await env.DB.prepare(
    "INSERT INTO sync_jobs (id, company_id, device_id, trigger_type, status) VALUES (?, ?, ?, 'manual', 'pending')",
  ).bind(jobId, auth.companyId, id).run();
  return json({ job: { id: jobId, status: "pending" }, already_queued: false }, 201);
}

/** GET /api/sync-jobs?limit=20 */
export async function listSyncJobs(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  const limit = Math.min(Math.max(Number(new URL(request.url).searchParams.get("limit")) || 20, 1), 100);
  const { results } = await env.DB.prepare(
    `SELECT j.id, j.device_id, d.name AS device_name, j.trigger_type, j.status,
            j.requested_at, j.started_at, j.finished_at, j.records_fetched, j.records_inserted, j.records_skipped, j.error_message
       FROM sync_jobs j JOIN devices d ON d.id = j.device_id
      WHERE j.company_id = ?
      ORDER BY j.requested_at DESC
      LIMIT ?`,
  ).bind(auth.companyId, limit).all();
  return json({ jobs: results ?? [] });
}

/** POST /api/devices/sync-all - queue a manual sync for every active device that has an active connector. */
export async function syncAll(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  const { results } = await env.DB.prepare(
    `SELECT d.id,
            (SELECT 1 FROM sync_jobs j WHERE j.device_id = d.id AND j.status IN ('pending','running') LIMIT 1) AS open
       FROM devices d JOIN connectors c ON c.id = d.connector_id
      WHERE d.company_id = ? AND d.is_active = 1 AND c.is_active = 1`,
  ).bind(auth.companyId).all<{ id: string; open: number | null }>();

  const devices = results ?? [];
  const toQueue = devices.filter((d) => !d.open);
  if (toQueue.length) {
    await env.DB.batch(toQueue.map((d) =>
      env.DB.prepare(
        "INSERT INTO sync_jobs (id, company_id, device_id, trigger_type, status) VALUES (?, ?, ?, 'manual', 'pending')",
      ).bind(crypto.randomUUID(), auth.companyId, d.id)));
  }
  return json({ devices: devices.length, queued: toQueue.length, already_queued: devices.length - toQueue.length });
}
'@

# ---------------------------------------------------------------- worker/src/pages.ts
Write-File "worker/src/pages.ts" @'
import { VERSION } from "./env";
import type { AuthContext } from "./lib/auth";
import { escapeHtml } from "./lib/http";

const STYLE = `
:root { --bg:#f5f6f8; --card:#ffffff; --text:#1c2330; --muted:#667085; --border:#d9dde3; --accent:#1f6feb; --error:#c62828; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#0f1318; --card:#171c23; --text:#e6e9ee; --muted:#98a2b3; --border:#2a313b; --accent:#4c8dff; --error:#ff6b6b; }
}
* { box-sizing:border-box; }
body { margin:0; font-family:system-ui,-apple-system,"Segoe UI",sans-serif; background:var(--bg); color:var(--text); }
.wrap { max-width:420px; margin:8vh auto; padding:0 16px; }
.wide { max-width:860px; }
.card { background:var(--card); border:1px solid var(--border); border-radius:12px; padding:28px; }
h1 { font-size:20px; margin:0 0 4px; }
p.sub { color:var(--muted); margin:0 0 20px; font-size:14px; }
label { display:block; font-size:13px; margin:14px 0 6px; color:var(--muted); }
input { width:100%; padding:10px 12px; border:1px solid var(--border); border-radius:8px; background:var(--bg); color:var(--text); font-size:15px; }
button { margin-top:20px; width:100%; padding:11px; border:0; border-radius:8px; background:var(--accent); color:#fff; font-size:15px; cursor:pointer; }
button:disabled { opacity:.6; cursor:default; }
.msg { color:var(--error); font-size:14px; min-height:20px; margin-top:12px; }
.alt { text-align:center; font-size:14px; margin-top:16px; color:var(--muted); }
a { color:var(--accent); }
.top { display:flex; justify-content:space-between; align-items:center; margin-bottom:20px; }
.top button { width:auto; margin:0; padding:8px 14px; background:transparent; color:var(--text); border:1px solid var(--border); }
dl { display:grid; grid-template-columns:140px 1fr; gap:10px 16px; margin:0; font-size:15px; }
dt { color:var(--muted); }
dd { margin:0; word-break:break-word; }
.foot { color:var(--muted); font-size:12px; text-align:center; margin-top:16px; }
.dash { max-width:1100px; margin:24px auto; padding:0 16px; }
.dash .card { margin-bottom:20px; padding:20px; }
.dash h2 { font-size:16px; margin:0 0 4px; }
.dash p.sub { margin-bottom:14px; }
.row { display:flex; flex-wrap:wrap; gap:10px; align-items:flex-end; }
.row .f { display:flex; flex-direction:column; flex:1 1 140px; }
.row .f label { margin:0 0 4px; }
.row input, .row select { padding:8px 10px; border:1px solid var(--border); border-radius:8px; background:var(--bg); color:var(--text); font-size:14px; width:100%; }
.row button, .sm { width:auto; margin:0; padding:9px 14px; font-size:14px; }
.sm { padding:5px 10px; font-size:13px; margin-left:4px; background:transparent; color:var(--text); border:1px solid var(--border); }
.sm.primary { background:var(--accent); color:#fff; border-color:var(--accent); }
.tbl { overflow-x:auto; margin-top:14px; }
table { width:100%; border-collapse:collapse; font-size:13px; }
th, td { text-align:left; padding:8px 6px; border-bottom:1px solid var(--border); white-space:nowrap; }
th { color:var(--muted); font-weight:500; }
td.err { white-space:normal; color:var(--error); max-width:280px; }
td.warn { color:#b26b00; }
.badge { display:inline-block; padding:2px 8px; border-radius:999px; font-size:12px; border:1px solid var(--border); }
.b-success, .b-active, .b-ready { color:#1a7f37; border-color:#1a7f37; }
.b-collecting { color:#b26b00; border-color:#b26b00; }
a.dl { display:inline-block; text-decoration:none; border-radius:8px; }
.b-failed, .b-revoked, .b-inactive { color:var(--error); border-color:var(--error); }
.b-running, .b-pending { color:#b26b00; border-color:#b26b00; }
.token { margin-top:14px; padding:12px; border:1px dashed var(--accent); border-radius:8px; font-size:13px; }
.token code { display:block; margin:8px 0; padding:8px; background:var(--bg); border-radius:6px; word-break:break-all; font-size:13px; }
.empty { color:var(--muted); font-size:13px; padding:10px 0; }
.dash .msg { margin-top:8px; min-height:0; }
.alert { padding:12px 14px; border-radius:10px; margin-bottom:10px; font-size:14px; border:1px solid; }
.a-error { color:var(--error); border-color:var(--error); }
.a-warning { color:#b26b00; border-color:#b26b00; }
.a-info { color:var(--muted); border-color:var(--border); }
ol.steps { margin:8px 0 12px; padding-left:20px; font-size:14px; line-height:1.6; }
.token details { margin-top:12px; font-size:13px; color:var(--muted); }
.token summary { cursor:pointer; }
.sm.primary:disabled { opacity:.3; }
input.cell { padding:6px 8px; border:1px solid var(--border); border-radius:6px; background:var(--bg); color:var(--text); font-size:13px; width:100%; min-width:140px; }
`;

function layout(title: string, body: string): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
<style>${STYLE}</style>
</head>
<body>${body}</body>
</html>`;
}

/** Shared client script: posts the form as JSON and follows the redirect. */
function formScript(endpoint: string): string {
  return `<script>
document.getElementById("f").addEventListener("submit", async function (e) {
  e.preventDefault();
  var btn = this.querySelector("button");
  var msg = document.getElementById("msg");
  msg.textContent = "";
  btn.disabled = true;
  try {
    var data = Object.fromEntries(new FormData(this));
    var res = await fetch("${endpoint}", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(data)
    });
    var out = await res.json().catch(function () { return {}; });
    if (res.ok) { location.href = out.redirect || "/app"; return; }
    msg.textContent = out.error || "Something went wrong";
  } catch (err) {
    msg.textContent = "Network error, please try again";
  }
  btn.disabled = false;
});
</script>`;
}

export function loginPage(): string {
  return layout("Sign in", `
<div class="wrap"><div class="card">
  <h1>HR Attendance</h1>
  <p class="sub">Sign in to your company account</p>
  <form id="f">
    <label for="email">Email</label>
    <input id="email" name="email" type="email" autocomplete="email" required>
    <label for="password">Password</label>
    <input id="password" name="password" type="password" autocomplete="current-password" required>
    <button type="submit">Sign in</button>
    <div class="msg" id="msg"></div>
  </form>
  <div class="alt">New company? <a href="/signup">Create an account</a></div>
</div><div class="foot">${VERSION}</div></div>
${formScript("/api/auth/login")}`);
}

export function signupPage(requireCode: boolean): string {
  const codeField = requireCode
    ? `<label for="signup_code">Sign-up code</label>
    <input id="signup_code" name="signup_code" type="text" autocomplete="off" required>`
    : "";
  return layout("Create account", `
<div class="wrap"><div class="card">
  <h1>Create your company account</h1>
  <p class="sub">You will be the owner of this company workspace</p>
  <form id="f">
    <label for="company_name">Company name</label>
    <input id="company_name" name="company_name" type="text" required>
    <label for="full_name">Your full name</label>
    <input id="full_name" name="full_name" type="text" autocomplete="name" required>
    <label for="email">Email</label>
    <input id="email" name="email" type="email" autocomplete="email" required>
    <label for="password">Password (min 8 characters)</label>
    <input id="password" name="password" type="password" autocomplete="new-password" minlength="8" required>
    ${codeField}
    <button type="submit">Create account</button>
    <div class="msg" id="msg"></div>
  </form>
  <div class="alt">Already have an account? <a href="/login">Sign in</a></div>
</div><div class="foot">${VERSION}</div></div>
${formScript("/api/auth/signup")}`);
}

export function appPage(auth: AuthContext): string {
  const e = escapeHtml;
  const canManage = auth.role === "owner" || auth.role === "admin";
  const hide = canManage ? "" : ` style="display:none"`;
  return layout("Dashboard", `
<div class="dash">
  <div class="top">
    <div>
      <h1>${e(auth.companyName)}</h1>
      <p class="sub" style="margin:0">${e(auth.fullName)} &middot; ${e(auth.role)}</p>
    </div>
    <button id="logout" type="button">Sign out</button>
  </div>

  <div id="alerts"></div>

  <div class="card">
    <h2>Attendance reports</h2>
    <p class="sub" id="r_sched">Every 2 days an Excel report of the previous 2 days is prepared automatically.</p>
    <div class="tbl"><table>
      <thead><tr><th>Period</th><th>Status</th><th>Machines synced</th><th>Employees</th><th>Punches</th><th>Ready at</th><th>Note</th><th></th></tr></thead>
      <tbody id="r_rows"></tbody>
    </table></div>
    <div class="row" style="margin-top:16px">
      <div class="f" style="flex:0 1 170px"><label for="x_from">Custom export from</label><input id="x_from" type="date"></div>
      <div class="f" style="flex:0 1 170px"><label for="x_to">to</label><input id="x_to" type="date"></div>
      <button id="x_go" type="button">Download Excel</button>
      <button id="sync_all" type="button" class="sm"${hide} style="margin-left:auto">Sync all machines now</button>
    </div>
    <div class="msg" id="x_msg"></div>
  </div>

  <div class="card">
    <h2>Employees</h2>
    <p class="sub" id="e_sub">Names are read from the machine's user list on every sync. Type a name here to override it, or leave it blank to use the machine's name.</p>
    <div class="tbl"><table>
      <thead><tr><th>User ID</th><th>Name</th><th>Department</th><th>Name source</th><th>Last punch</th><th></th></tr></thead>
      <tbody id="e_rows"></tbody>
    </table></div>
    <div class="msg" id="e_msg"></div>
  </div>

  <div class="card">
    <h2>1. Connectors</h2>
    <p class="sub">The ZKT Connector runs on a Windows PC on the same network as the machine and sends its attendance here. Create one, click <b>Download installer</b>, extract the ZIP on that PC and double-click <b>Install.cmd</b>. It is already set up for your company.</p>
    <div class="row"${hide}>
      <div class="f"><label for="c_name">Connector name</label><input id="c_name" placeholder="Office PC - Lahore"></div>
      <button id="c_add" type="button">Create connector</button>
    </div>
    <div class="msg" id="c_msg"></div>
    <div id="c_token"></div>
    <div class="tbl"><table>
      <thead><tr><th>Name</th><th>Token</th><th>Status</th><th>Version</th><th>Last seen</th><th>Devices</th><th></th></tr></thead>
      <tbody id="c_rows"></tbody>
    </table></div>
  </div>

  <div class="card">
    <h2>2. Devices</h2>
    <p class="sub">Attendance machines on your LAN, each assigned to the connector that reads it.</p>
    <div class="row"${hide}>
      <div class="f"><label for="d_name">Device name</label><input id="d_name" placeholder="Main entrance K50"></div>
      <div class="f"><label for="d_ip">IP address</label><input id="d_ip" placeholder="192.168.10.21"></div>
      <div class="f" style="flex:0 1 90px"><label for="d_port">Port</label><input id="d_port" value="4370"></div>
      <div class="f" style="flex:0 1 90px"><label for="d_key">Comm key</label><input id="d_key" value="0"></div>
      <div class="f"><label for="d_conn">Connector</label><select id="d_conn"></select></div>
      <button id="d_add" type="button">Add device</button>
    </div>
    <div class="msg" id="d_msg"></div>
    <div class="tbl"><table>
      <thead><tr><th>Name</th><th>Address</th><th>Connector</th><th>Serial</th><th>Clock</th><th>Last sync</th><th>Logs</th><th>Last job</th><th></th></tr></thead>
      <tbody id="d_rows"></tbody>
    </table></div>
  </div>

  <div class="card">
    <h2>3. Sync jobs</h2>
    <p class="sub">Each import run. The connector picks up pending jobs and uploads the machine's attendance logs.</p>
    <div class="tbl"><table>
      <thead><tr><th>Requested</th><th>Device</th><th>Trigger</th><th>Status</th><th>Read</th><th>New</th><th>Skipped</th><th>Finished</th><th>Error</th></tr></thead>
      <tbody id="j_rows"></tbody>
    </table></div>
  </div>

  <div class="foot">${VERSION}</div>
</div>
<script>
var CAN_MANAGE = ${canManage ? "true" : "false"};

async function api(method, path, body) {
  var opts = { method: method, headers: {} };
  if (body !== undefined) { opts.headers["content-type"] = "application/json"; opts.body = JSON.stringify(body); }
  var res = await fetch(path, opts);
  var data = await res.json().catch(function () { return {}; });
  if (res.status === 401) { location.href = "/login"; throw new Error("Signed out"); }
  if (!res.ok) throw new Error(data.error || ("Request failed (" + res.status + ")"));
  return data;
}

function when(v) { return v ? new Date(v).toLocaleString() : "\\u2014"; }
function td(text, cls) { var c = document.createElement("td"); c.textContent = (text === null || text === undefined || text === "") ? "\\u2014" : String(text); if (cls) c.className = cls; return c; }
function badge(text) { var c = document.createElement("td"); if (!text) { c.textContent = "\\u2014"; return c; } var s = document.createElement("span"); s.className = "badge b-" + text; s.textContent = text; c.appendChild(s); return c; }
function btn(label, primary, onClick) { var b = document.createElement("button"); b.type = "button"; b.className = primary ? "sm primary" : "sm"; b.textContent = label; b.addEventListener("click", onClick); return b; }
function clockCell(sec) {
  var c = document.createElement("td");
  if (sec === null || sec === undefined) { c.textContent = "\\u2014"; return c; }
  var a = Math.abs(sec);
  var txt = a < 60 ? a + " s" : a < 3600 ? Math.round(a / 60) + " min" : a < 86400 ? (a / 3600).toFixed(1) + " h" : Math.round(a / 86400) + " days";
  c.textContent = a <= 60 ? "OK" : (sec < 0 ? txt + " slow" : txt + " fast");
  if (a > 60) { c.className = "warn"; c.title = "The machine clock is off. Correct the time on the machine so punches are recorded at the right time."; }
  return c;
}
function emptyRow(tbody, cols, text) { var tr = document.createElement("tr"); var c = document.createElement("td"); c.colSpan = cols; c.className = "empty"; c.textContent = text; tr.appendChild(c); tbody.appendChild(tr); }
function showMsg(id, text) { document.getElementById(id).textContent = text || ""; }

function fmtDate(d) { var p = d.split("-"); var m = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][Number(p[1]) - 1]; return p[2] + " " + m + " " + p[0]; }
function period(a, b) { return a === b ? fmtDate(a) : fmtDate(a) + " \\u2013 " + fmtDate(b); }
function isoLocal(offsetDays) { var d = new Date(); d.setDate(d.getDate() + offsetDays); var p = function (n) { return String(n).padStart(2, "0"); }; return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate()); }

async function loadReports() {
  var data = await api("GET", "/api/reports");
  var s = data.schedule;
  document.getElementById("r_sched").textContent =
    "Every " + s.every_days + " days an Excel report of the previous " + s.every_days + " days is prepared automatically. Next: " +
    period(s.next_start, s.next_end) + ", ready on " + fmtDate(s.next_due) + " after " + String(s.hour).padStart(2, "0") + ":00 (" + s.timezone + ").";
  var tbody = document.getElementById("r_rows");
  tbody.textContent = "";
  if (!data.reports.length) emptyRow(tbody, 8, "No reports yet. The first one is created at the next scheduled time.");
  data.reports.forEach(function (r) {
    var tr = document.createElement("tr");
    tr.appendChild(td(period(r.period_start, r.period_end)));
    tr.appendChild(badge(r.status === "ready" ? "ready" : "collecting"));
    tr.appendChild(td(r.devices_synced + " / " + r.devices_total));
    tr.appendChild(td(r.status === "ready" ? r.employee_count : ""));
    tr.appendChild(td(r.status === "ready" ? r.punch_count : ""));
    tr.appendChild(td(when(r.ready_at)));
    tr.appendChild(td(r.note, r.note ? "warn" : ""));
    var actions = document.createElement("td");
    var a = document.createElement("a");
    a.href = "/api/reports/" + r.id + "/download";
    a.className = "sm primary dl";
    a.textContent = "Download Excel";
    actions.appendChild(a);
    tr.appendChild(actions);
    tbody.appendChild(tr);
  });
}

var empEditing = false;

function input(value, placeholder, maxLength) {
  var i = document.createElement("input");
  i.value = value || "";
  i.placeholder = placeholder || "";
  i.maxLength = maxLength;
  i.className = "cell";
  return i;
}

async function loadEmployees() {
  if (empEditing) return; // don't wipe what someone is typing
  var data = await api("GET", "/api/employees");
  document.getElementById("e_sub").textContent =
    data.total + " employee(s), " + data.unnamed + " without a name. Names are read from the machine's user list on every sync. " +
    (CAN_MANAGE ? "Type a name to override it, or leave it blank to use the machine's name." : "");
  var tbody = document.getElementById("e_rows");
  tbody.textContent = "";
  if (!data.employees.length) emptyRow(tbody, 6, "No employees yet. They appear after the first sync.");
  data.employees.forEach(function (e) {
    var tr = document.createElement("tr");
    tr.appendChild(td(e.user_id));
    var source = e.name_edited ? "Edited" : (e.machine_name ? "Machine" : "");
    if (!CAN_MANAGE) {
      tr.appendChild(td(e.name, e.name ? "" : "warn"));
      tr.appendChild(td(e.department));
      tr.appendChild(td(source));
      tr.appendChild(td(e.last_punch));
      tr.appendChild(document.createElement("td"));
      tbody.appendChild(tr);
      return;
    }
    var nameIn = input(e.name_edited ? e.name : "", e.machine_name || "Enter name", 80);
    var deptIn = input(e.department, "Department", 60);
    var c1 = document.createElement("td"); c1.appendChild(nameIn); tr.appendChild(c1);
    var c2 = document.createElement("td"); c2.appendChild(deptIn); tr.appendChild(c2);
    tr.appendChild(td(source, source ? "" : "warn"));
    tr.appendChild(td(e.last_punch));
    var save = btn("Save", true, async function () {
      save.disabled = true;
      try {
        await api("PUT", "/api/employees/" + encodeURIComponent(e.user_id), { name: nameIn.value, department: deptIn.value });
        showMsg("e_msg", "");
        empEditing = false;
        await loadEmployees();
      } catch (err) { showMsg("e_msg", err.message); save.disabled = false; }
    });
    save.disabled = true;
    var orig = nameIn.value + "|" + deptIn.value;
    [nameIn, deptIn].forEach(function (el) {
      el.addEventListener("input", function () { save.disabled = (nameIn.value + "|" + deptIn.value) === orig; empEditing = !save.disabled; });
      el.addEventListener("keydown", function (ev) { if (ev.key === "Enter" && !save.disabled) save.click(); });
    });
    var c3 = document.createElement("td"); c3.appendChild(save); tr.appendChild(c3);
    tbody.appendChild(tr);
  });
}

async function downloadInstaller(connectorId, token) {
  var res = await fetch("/api/connectors/" + connectorId + "/package", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(token ? { token: token } : {})
  });
  if (res.status === 401) { location.href = "/login"; throw new Error("Signed out"); }
  if (!res.ok) {
    var d = await res.json().catch(function () { return {}; });
    throw new Error(d.error || ("Download failed (" + res.status + ")"));
  }
  var blob = await res.blob();
  var m = /filename="([^"]+)"/.exec(res.headers.get("content-disposition") || "");
  var a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = m ? m[1] : "ZKT-Connector.zip";
  document.body.appendChild(a);
  a.click();
  setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 2000);
}

async function loadStatus() {
  var data = await api("GET", "/api/status");
  var box = document.getElementById("alerts");
  box.textContent = "";
  data.alerts.forEach(function (al) {
    var div = document.createElement("div");
    div.className = "alert a-" + al.level;
    div.textContent = al.text;
    box.appendChild(div);
  });
}

async function loadConnectors() {
  var data = await api("GET", "/api/connectors");
  var tbody = document.getElementById("c_rows");
  var select = document.getElementById("d_conn");
  tbody.textContent = ""; select.textContent = "";
  var none = document.createElement("option"); none.value = ""; none.textContent = "(none yet)"; select.appendChild(none);
  if (!data.connectors.length) emptyRow(tbody, 7, "No connectors yet. Create one first.");
  data.connectors.forEach(function (c) {
    var tr = document.createElement("tr");
    tr.appendChild(td(c.name));
    tr.appendChild(td(c.token_hint ? "zkc_\\u2026" + c.token_hint : ""));
    tr.appendChild(badge(c.is_active ? "active" : "revoked"));
    tr.appendChild(td(c.version));
    tr.appendChild(td(when(c.last_seen_at)));
    tr.appendChild(td(c.device_count));
    var actions = document.createElement("td");
    if (CAN_MANAGE && c.is_active) {
      actions.appendChild(btn("Download installer", true, async function () {
        var msg = "Download a new installer for '" + c.name + "'?\\n\\nThis creates a new token. A PC already running this connector stops syncing until you run Install.cmd from the new download on it.";
        if (c.last_seen_at && !confirm(msg)) return;
        try { await downloadInstaller(c.id, null); showMsg("c_msg", ""); await refresh(); }
        catch (err) { showMsg("c_msg", err.message); }
      }));
      actions.appendChild(btn("Revoke", false, async function () {
        if (!confirm("Revoke connector '" + c.name + "'? It will stop working immediately.")) return;
        try { await api("POST", "/api/connectors/" + c.id + "/revoke", {}); await refresh(); } catch (err) { alert(err.message); }
      }));
    }
    tr.appendChild(actions);
    tbody.appendChild(tr);
    if (c.is_active) { var o = document.createElement("option"); o.value = c.id; o.textContent = c.name; select.appendChild(o); }
  });
  if (select.options.length > 1) select.selectedIndex = 1;
}

async function loadDevices() {
  var data = await api("GET", "/api/devices");
  var tbody = document.getElementById("d_rows");
  tbody.textContent = "";
  if (!data.devices.length) emptyRow(tbody, 9, "No devices yet.");
  data.devices.forEach(function (d) {
    var tr = document.createElement("tr");
    tr.appendChild(td(d.name + (d.is_active ? "" : " (inactive)")));
    tr.appendChild(td(d.ip_address + ":" + d.port));
    tr.appendChild(td(d.connector_name));
    tr.appendChild(td(d.serial_number));
    tr.appendChild(clockCell(d.clock_offset_seconds));
    tr.appendChild(td(when(d.last_sync_at)));
    tr.appendChild(td(d.log_count));
    tr.appendChild(badge(d.last_job_status));
    var actions = document.createElement("td");
    if (CAN_MANAGE && d.is_active) {
      actions.appendChild(btn("Sync now", true, async function () {
        try {
          var r = await api("POST", "/api/devices/" + d.id + "/sync", {});
          showMsg("d_msg", r.already_queued ? "A sync for this device is already " + r.job.status + "." : "");
          await refresh();
        } catch (err) { alert(err.message); }
      }));
      actions.appendChild(btn("Deactivate", false, async function () {
        if (!confirm("Deactivate device '" + d.name + "'? Its attendance data is kept.")) return;
        try { await api("POST", "/api/devices/" + d.id + "/deactivate", {}); await refresh(); } catch (err) { alert(err.message); }
      }));
    }
    tr.appendChild(actions);
    tbody.appendChild(tr);
  });
}

async function loadJobs() {
  var data = await api("GET", "/api/sync-jobs?limit=20");
  var tbody = document.getElementById("j_rows");
  tbody.textContent = "";
  if (!data.jobs.length) emptyRow(tbody, 9, "No sync jobs yet.");
  data.jobs.forEach(function (j) {
    var tr = document.createElement("tr");
    tr.appendChild(td(when(j.requested_at)));
    tr.appendChild(td(j.device_name));
    tr.appendChild(td(j.trigger_type));
    tr.appendChild(badge(j.status));
    tr.appendChild(td(j.records_fetched + (j.records_skipped || 0)));
    tr.appendChild(td(j.records_inserted));
    tr.appendChild(td(j.records_skipped, j.records_skipped ? "warn" : ""));
    tr.appendChild(td(when(j.finished_at)));
    tr.appendChild(td(j.error_message, j.error_message ? "err" : ""));
    tbody.appendChild(tr);
  });
}

async function refresh() {
  try { await Promise.all([loadStatus(), loadReports(), loadEmployees(), loadConnectors(), loadDevices(), loadJobs()]); }
  catch (err) { showMsg("d_msg", err.message); }
}

document.getElementById("c_add").addEventListener("click", async function () {
  showMsg("c_msg", "");
  var box = document.getElementById("c_token"); box.textContent = "";
  try {
    var r = await api("POST", "/api/connectors", { name: document.getElementById("c_name").value });
    var wrap = document.createElement("div"); wrap.className = "token";
    var title = document.createElement("strong"); title.textContent = "Connector '" + r.connector.name + "' created";
    var steps = document.createElement("ol"); steps.className = "steps";
    ["Click Download installer (the ZIP is already set up for your company).",
     "Copy the ZIP to a Windows PC on the same network as the machine.",
     "Right-click it, choose Extract All, then double-click Install.cmd and click Yes."].forEach(function (t) {
      var li = document.createElement("li"); li.textContent = t; steps.appendChild(li);
    });
    var dl = btn("Download installer", true, async function () {
      dl.disabled = true;
      try { await downloadInstaller(r.connector.id, r.token); dl.textContent = "Downloaded"; }
      catch (err) { showMsg("c_msg", err.message); dl.disabled = false; }
    });
    var adv = document.createElement("details");
    var sum = document.createElement("summary"); sum.textContent = "Show token (for manual setup)";
    var code = document.createElement("code"); code.textContent = r.token;
    var copy = btn("Copy token", false, function () { navigator.clipboard.writeText(r.token); copy.textContent = "Copied"; });
    adv.appendChild(sum); adv.appendChild(code); adv.appendChild(copy);
    wrap.appendChild(title); wrap.appendChild(steps); wrap.appendChild(dl); wrap.appendChild(adv);
    box.appendChild(wrap);
    document.getElementById("c_name").value = "";
    await refresh();
  } catch (err) { showMsg("c_msg", err.message); }
});

document.getElementById("sync_all").addEventListener("click", async function () {
  var b = this;
  b.disabled = true;
  try {
    var r = await api("POST", "/api/devices/sync-all", {});
    showMsg("x_msg", r.devices ? (r.queued + " machine(s) queued" + (r.already_queued ? ", " + r.already_queued + " already syncing" : "") + ". The connector picks them up within a minute.") : "No machine with an active connector.");
    await refresh();
  } catch (err) { showMsg("x_msg", err.message); }
  b.disabled = false;
});

document.getElementById("d_add").addEventListener("click", async function () {
  showMsg("d_msg", "");
  try {
    await api("POST", "/api/devices", {
      name: document.getElementById("d_name").value,
      ip_address: document.getElementById("d_ip").value,
      port: document.getElementById("d_port").value,
      comm_key: document.getElementById("d_key").value,
      connector_id: document.getElementById("d_conn").value
    });
    document.getElementById("d_name").value = "";
    document.getElementById("d_ip").value = "";
    await refresh();
  } catch (err) { showMsg("d_msg", err.message); }
});

document.getElementById("x_from").value = isoLocal(-2);
document.getElementById("x_to").value = isoLocal(-1);
document.getElementById("x_go").addEventListener("click", function () {
  var from = document.getElementById("x_from").value;
  var to = document.getElementById("x_to").value;
  if (!from || !to) { showMsg("x_msg", "Choose both dates."); return; }
  if (to < from) { showMsg("x_msg", "'to' must be on or after 'from'."); return; }
  showMsg("x_msg", "");
  location.href = "/api/export.xlsx?from=" + encodeURIComponent(from) + "&to=" + encodeURIComponent(to);
});

document.getElementById("logout").addEventListener("click", async function () {
  await fetch("/api/auth/logout", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" });
  location.href = "/login";
});

refresh();
setInterval(function () { loadJobs(); loadReports(); loadStatus().catch(function () {}); }, 15000);
</script>`);
}
'@

# ---------------------------------------------------------------- worker/src/index.ts
Write-File "worker/src/index.ts" @'
import type { Env } from "./env";
import { HttpError, html, json, redirect } from "./lib/http";
import { getAuth } from "./lib/auth";
import { health } from "./routes/health";
import { login, logout, me, signup } from "./routes/auth";
import {
  createConnector, createDevice, deactivateDevice, listConnectors,
  listDevices, listSyncJobs, queueSync, revokeConnector, syncAll,
} from "./routes/manage";
import { downloadConnector } from "./routes/download";
import { status } from "./routes/status";
import { claimJob, completeJob, connectorConfig, uploadLogs, uploadUsers } from "./routes/connector";
import { listEmployees, saveEmployee } from "./routes/employees";
import { downloadReport, exportRange, listReports } from "./routes/reports";
import { runScheduler } from "./scheduler";
import { appPage, loginPage, signupPage } from "./pages";

export type { Env };

const ID = "([0-9a-f-]{36})";
const R_CONNECTOR_REVOKE = new RegExp(`^/api/connectors/${ID}/revoke$`);
const R_DEVICE_DEACTIVATE = new RegExp(`^/api/devices/${ID}/deactivate$`);
const R_DEVICE_SYNC = new RegExp(`^/api/devices/${ID}/sync$`);
const R_JOB_LOGS = new RegExp(`^/api/connector/jobs/${ID}/logs$`);
const R_JOB_COMPLETE = new RegExp(`^/api/connector/jobs/${ID}/complete$`);
const R_REPORT_DOWNLOAD = new RegExp(`^/api/reports/${ID}/download$`);
const R_JOB_USERS = new RegExp(`^/api/connector/jobs/${ID}/users$`);
const R_EMPLOYEE = /^\/api\/employees\/([^/]{1,100})$/;
const R_CONNECTOR_PACKAGE = new RegExp(`^/api/connectors/${ID}/package$`);

function safeDecode(s: string): string {
  try {
    return decodeURIComponent(s);
  } catch {
    throw new HttpError(400, "Invalid URL");
  }
}

async function route(request: Request, env: Env): Promise<Response> {
  const { pathname } = new URL(request.url);
  const method = request.method;
  let m: RegExpExecArray | null;

  // ---- Public / auth
  if (pathname === "/api/health" && method === "GET") return health(env);
  if (pathname === "/api/auth/signup" && method === "POST") return signup(request, env);
  if (pathname === "/api/auth/login" && method === "POST") return login(request, env);
  if (pathname === "/api/auth/logout" && method === "POST") return logout(request, env);
  if (pathname === "/api/auth/me" && method === "GET") return me(request, env);

  // ---- Dashboard API (browser session)
  if (pathname === "/api/connectors" && method === "GET") return listConnectors(request, env);
  if (pathname === "/api/connectors" && method === "POST") return createConnector(request, env);
  if (method === "POST" && (m = R_CONNECTOR_REVOKE.exec(pathname))) return revokeConnector(request, env, m[1]);
  if (method === "POST" && (m = R_CONNECTOR_PACKAGE.exec(pathname))) return downloadConnector(request, env, m[1]);
  if (pathname === "/api/devices" && method === "GET") return listDevices(request, env);
  if (pathname === "/api/devices" && method === "POST") return createDevice(request, env);
  if (pathname === "/api/devices/sync-all" && method === "POST") return syncAll(request, env);
  if (method === "POST" && (m = R_DEVICE_DEACTIVATE.exec(pathname))) return deactivateDevice(request, env, m[1]);
  if (method === "POST" && (m = R_DEVICE_SYNC.exec(pathname))) return queueSync(request, env, m[1]);
  if (pathname === "/api/sync-jobs" && method === "GET") return listSyncJobs(request, env);
  if (pathname === "/api/status" && method === "GET") return status(request, env);
  if (pathname === "/api/reports" && method === "GET") return listReports(request, env);
  if (method === "GET" && (m = R_REPORT_DOWNLOAD.exec(pathname))) return downloadReport(request, env, m[1]);
  if (pathname === "/api/export.xlsx" && method === "GET") return exportRange(request, env);
  if (pathname === "/api/employees" && method === "GET") return listEmployees(request, env);
  if (method === "PUT" && (m = R_EMPLOYEE.exec(pathname))) return saveEmployee(request, env, safeDecode(m[1]));

  // ---- ZKT Connector API (Bearer token)
  if (pathname === "/api/connector/config" && method === "GET") return connectorConfig(request, env);
  if (pathname === "/api/connector/jobs/claim" && method === "POST") return claimJob(request, env);
  if (method === "POST" && (m = R_JOB_LOGS.exec(pathname))) return uploadLogs(request, env, m[1]);
  if (method === "POST" && (m = R_JOB_USERS.exec(pathname))) return uploadUsers(request, env, m[1]);
  if (method === "POST" && (m = R_JOB_COMPLETE.exec(pathname))) return completeJob(request, env, m[1]);

  if (pathname.startsWith("/api/")) return json({ error: "Not found" }, 404);

  // ---- Pages
  if (method === "GET") {
    if (pathname === "/") {
      return redirect((await getAuth(request, env)) ? "/app" : "/login");
    }
    if (pathname === "/login") {
      return (await getAuth(request, env)) ? redirect("/app") : html(loginPage());
    }
    if (pathname === "/signup") {
      return (await getAuth(request, env)) ? redirect("/app") : html(signupPage(Boolean(env.SIGNUP_CODE)));
    }
    if (pathname === "/app") {
      const auth = await getAuth(request, env);
      return auth ? html(appPage(auth)) : redirect("/login");
    }
  }

  return json({ error: "Not found" }, 404);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await route(request, env);
    } catch (err) {
      if (err instanceof HttpError) return json({ error: err.message }, err.status);
      console.error(err);
      return json({ error: "Internal server error" }, 500);
    }
  },

  // Cloudflare cron (see [triggers] in wrangler.toml): runs every hour.
  async scheduled(controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(runScheduler(env, new Date(controller.scheduledTime)));
  },
};
'@

Write-Host ""
Write-Host "Phase 8 files written. Next steps are listed in the chat." -ForegroundColor Cyan
