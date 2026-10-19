# =====================================================================
# HR Auto Attendance Fetcher - PHASE 11 : fast syncs, live progress, Stop,
# automatic time-outs, and Start / Stop / Status for the connector.
# Run from the ROOT of the repo (hr-attendance-fetcher):
#   powershell -ExecutionPolicy Bypass -File .\phase-11-progress.ps1
# =====================================================================
$ErrorActionPreference = "Stop"

function Write-File([string]$Path, [string]$Content) {
    $full = Join-Path (Get-Location) $Path
    $dir  = Split-Path $full -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($full, $Content.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  wrote $Path" -ForegroundColor Green
}

if (-not (Test-Path "worker/src/routes/overview.ts")) {
    throw "Run this from the repo root, after Phase 10 (worker/src/routes/overview.ts not found)."
}

Write-Host "Phase 11: writing progress, stop and service files..." -ForegroundColor Cyan

# ---------------------------------------------------------------- connector/package.json
Write-File "connector/package.json" @'
{
  "name": "zkt-connector",
  "version": "0.9.0",
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

# ---------------------------------------------------------------- connector/src/api.js
Write-File "connector/src/api.js" @'
// HTTP client for the Attendance Fetcher Worker (connector side).
// Every request has a time limit, so a bad network can never freeze the connector.
export const CONNECTOR_VERSION = "0.9.0";

const DEFAULT_TIMEOUT_MS = 30000;
export const CLAIM_WAIT_SECONDS = 20;

export class ApiClient {
  constructor(baseUrl, token) {
    this.baseUrl = baseUrl.replace(/\/+$/, "");
    this.token = token;
  }

  async request(method, path, body, timeoutMs = DEFAULT_TIMEOUT_MS) {
    let res;
    try {
      res = await fetch(this.baseUrl + path, {
        method,
        headers: {
          authorization: `Bearer ${this.token}`,
          "content-type": "application/json",
          "x-connector-version": CONNECTOR_VERSION,
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch (err) {
      const timedOut = err && (err.name === "TimeoutError" || err.name === "AbortError");
      const e = new Error(timedOut
        ? `${method} ${path}: no answer from the server within ${Math.round(timeoutMs / 1000)} s`
        : `${method} ${path}: cannot reach the server (${err.cause?.code ?? err.message})`);
      e.network = true;
      throw e;
    }

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

  /** Waits up to `waitSeconds` on the server for a job (long poll). */
  claimJob(waitSeconds = CLAIM_WAIT_SECONDS) {
    return this.request("POST", `/api/connector/jobs/claim?wait=${waitSeconds}`, {}, (waitSeconds + 20) * 1000);
  }

  /** Reports what the connector is doing. Resolves to { stop: true } when the job was cancelled. */
  reportProgress(jobId, stage, pct, message) {
    return this.request("POST", `/api/connector/jobs/${encodeURIComponent(jobId)}/progress`, { stage, pct, message }, 15000);
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

# ---------------------------------------------------------------- connector/src/sync.js
Write-File "connector/src/sync.js" @'
// Phase 5: process one sync job end to end.
// read machine (read-only, with retries) -> filter -> upload in batches -> complete job
import { readDevice } from "./zk/client.js";
import { log } from "./log.js";

const BATCH_SIZE = 1000;
const FUTURE_TOLERANCE_MS = 24 * 60 * 60 * 1000; // punches > 1 day after the machine's own clock are skipped

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function retryDelaysMs() {
  const base = Number(process.env.RETRY_DELAY_SECONDS);
  const s = Number.isFinite(base) && base >= 0 ? base : 5;
  return [s * 1000, s * 3000]; // wait 5 s, then 15 s (3 attempts in total)
}

/** "YYYY-MM-DD HH:MM:SS" (machine local time) -> Date in this PC's local time zone */
function parseLocal(ts) {
  return new Date(ts.replace(" ", "T"));
}

function formatLocal(d) {
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

/** Machine clock minus this PC's clock, in seconds (null if the machine did not report its time). */
export function clockOffsetSeconds(deviceTime, now = Date.now()) {
  if (!deviceTime) return null;
  const t = parseLocal(deviceTime).getTime();
  return Number.isFinite(t) ? Math.round((t - now) / 1000) : null;
}

/**
 * Splits records into ones to import and ones to skip.
 * Skipped: dated more than 1 day after the machine's current clock - these were
 * recorded while the machine clock was set wrong and would show as future attendance.
 */
export function filterRecords(records, deviceTime, now = Date.now()) {
  const ref = deviceTime ? parseLocal(deviceTime).getTime() : now;
  const limit = formatLocal(new Date((Number.isFinite(ref) ? ref : now) + FUTURE_TOLERANCE_MS));
  const keep = [];
  const skipped = [];
  for (const r of records) (r.timestamp <= limit ? keep : skipped).push(r);
  keep.sort((a, b) => a.timestamp.localeCompare(b.timestamp));
  return { keep, skipped, limit };
}

function isRetryable(err) {
  return !err.status || err.status >= 500 || err.status === 429;
}

/** Thrown when the sync was stopped from the dashboard (or timed out on the server). */
export class StopSync extends Error {}

/** A whole sync may take at most this long; then it stops with a clear error. */
const JOB_LIMIT_MS = 10 * 60 * 1000;

/**
 * Reports progress to the dashboard (at most every 1.5 s unless forced) and remembers
 * if the server says to stop. Network problems while reporting never break the sync.
 */
class Progress {
  constructor(api, jobId) {
    this.api = api;
    this.jobId = jobId;
    this.stopped = false;
    this.last = 0;
    this.started = Date.now();
  }
  async send(stage, pct, message, force = false) {
    const now = Date.now();
    if (!force && now - this.last < 1500) return;
    this.last = now;
    try {
      const r = await this.api.reportProgress(this.jobId, stage, pct, message);
      if (r && r.stop) this.stopped = true;
    } catch (err) {
      if (err.status === 404 || err.status === 409) this.stopped = true;
    }
    this.check();
  }
  check() {
    if (this.stopped) throw new StopSync("Sync was stopped from the dashboard");
    if (Date.now() - this.started > JOB_LIMIT_MS) {
      throw new Error(`The sync took longer than ${JOB_LIMIT_MS / 60000} minutes and was stopped`);
    }
  }
}

async function withRetry(label, fn, progress) {
  const delays = retryDelaysMs();
  for (let attempt = 1; ; attempt++) {
    try {
      return await fn();
    } catch (err) {
      if (err instanceof StopSync || attempt > delays.length || !isRetryable(err)) throw err;
      const wait = delays[attempt - 1];
      const msg = `${label} failed (attempt ${attempt} of ${delays.length + 1}): ${err.message}. Retrying in ${Math.round(wait / 1000)} s`;
      log.warn(msg);
      if (progress) await progress.send("retrying", null, msg, true);
      await sleep(wait);
      if (progress) progress.check();
    }
  }
}

async function safeFail(api, jobId, message) {
  try {
    await api.completeJob(jobId, { status: "failed", error_message: message.slice(0, 480) });
  } catch (err) {
    if (err.status !== 409) log.error(`Could not report failure for job ${jobId}: ${err.message}`);
  }
}

/** Returns a summary object; never throws (problems are reported on the job and in the log). */
export async function processJob(api, job, { timeoutMs = 10000 } = {}) {
  const d = job.device;
  const started = Date.now();
  const progress = new Progress(api, job.id);
  log.info(`Job ${job.id.slice(0, 8)} (${job.trigger_type}): reading "${d.name}" at ${d.ip_address}:${d.port}`);

  try {
    // 1) Read the machine (read-only)
    let result;
    try {
      await progress.send("connecting", 0, `Connecting to the machine at ${d.ip_address}:${d.port}`, true);
      result = await withRetry("Reading machine", () =>
        readDevice({ ip: d.ip_address, port: d.port, commKey: d.comm_key, timeoutMs }, (done, total) => {
          // Throwing here aborts the read at the next chunk and disconnects from the machine.
          if (progress.stopped) throw new StopSync("Sync was stopped from the dashboard");
          const pct = Math.floor((done / total) * 100);
          progress.send("reading", pct, `Reading punches from the machine: ${pct}%`).catch(() => {});
        }), progress);
    } catch (err) {
      if (err instanceof StopSync) throw err;
      const msg = `Could not read the machine at ${d.ip_address}:${d.port}: ${err.message}`;
      log.error(msg);
      await safeFail(api, job.id, msg);
      return { ok: false, error: msg };
    }
    progress.check();

    const offset = clockOffsetSeconds(result.deviceTime);
    const { keep, skipped, limit } = filterRecords(result.records, result.deviceTime);
    log.info(`Read ${result.records.length} punches (serial ${result.serialNumber ?? "?"}, clock offset ${offset ?? "?"} s)`);
    if (offset !== null && Math.abs(offset) > 60) {
      log.warn(`Machine clock is ${Math.abs(offset)} s ${offset < 0 ? "behind" : "ahead"}. Correct the time on the machine.`);
    }
    if (skipped.length) {
      const sample = skipped.slice(0, 3).map((r) => `${r.timestamp} (user ${r.user_id})`).join(", ");
      log.warn(`Skipping ${skipped.length} punch(es) dated after ${limit}: ${sample}${skipped.length > 3 ? ", ..." : ""}`);
    }

    // 2) Upload in batches (duplicates are ignored by the server)
    let inserted = 0;
    let duplicates = 0;
    let rejected = 0;
    try {
      await progress.send("uploading", 0, `Read ${result.records.length} punches. Uploading...`, true);
      for (let i = 0; i < keep.length; i += BATCH_SIZE) {
        const batch = keep.slice(i, i + BATCH_SIZE);
        const res = await withRetry("Upload", () => api.uploadLogs(job.id, batch), progress);
        inserted += res.inserted;
        duplicates += res.duplicates;
        rejected += res.rejected;
        const sent = Math.min(i + BATCH_SIZE, keep.length);
        await progress.send("uploading", Math.floor((sent / keep.length) * 100), `Uploaded ${sent} of ${keep.length} punches (${inserted} new)`, sent === keep.length);
      }
    } catch (err) {
      if (err instanceof StopSync || err.status === 409) throw new StopSync(err.message);
      const msg = `Upload failed: ${err.message}`;
      log.error(msg);
      await safeFail(api, job.id, msg);
      return { ok: false, error: msg };
    }

    // 3) Employee names from the machine (best effort: never fails the sync)
    if (result.users.length) {
      try {
        await progress.send("names", 100, `Updating ${result.users.length} employee names`, true);
        const res = await withRetry("Uploading names", () => api.uploadUsers(job.id, result.users), progress);
        log.info(`Names: ${result.users.length} users on machine, ${res.named} with a name (${res.added} new employees)`);
      } catch (err) {
        if (err instanceof StopSync || err.status === 409) throw new StopSync(err.message);
        log.warn(`Could not upload employee names: ${err.message}`);
      }
    } else if (result.usersError) {
      log.warn(`Could not read user names from the machine: ${result.usersError}`);
    }

    // 4) Complete
    try {
      await withRetry("Completing job", () => api.completeJob(job.id, {
        status: "success",
        device_serial: result.serialNumber ?? undefined,
        records_skipped: skipped.length + rejected,
        clock_offset_seconds: offset ?? undefined,
      }), progress);
    } catch (err) {
      if (err instanceof StopSync || err.status === 409) throw new StopSync(err.message);
      log.error(`Could not complete job: ${err.message}`);
      return { ok: false, error: err.message };
    }

    const secs = ((Date.now() - started) / 1000).toFixed(1);
    log.info(`Job ${job.id.slice(0, 8)} done in ${secs} s: ${inserted} new, ${duplicates} already imported, ${skipped.length + rejected} skipped`);
    return { ok: true, read: result.records.length, inserted, duplicates, skipped: skipped.length + rejected };
  } catch (err) {
    if (err instanceof StopSync) {
      log.warn(`Job ${job.id.slice(0, 8)} stopped: the sync was cancelled from the dashboard or timed out.`);
      return { ok: false, stopped: true };
    }
    const msg = err.message || String(err);
    log.error(`Job ${job.id.slice(0, 8)} failed: ${msg}`);
    await safeFail(api, job.id, msg);
    return { ok: false, error: msg };
  }
}
'@

# ---------------------------------------------------------------- connector/src/index.js
Write-File "connector/src/index.js" @'
// ZKT Connector main loop.
//   npm start                 -> runs continuously: picks up sync jobs and imports attendance
//   npm start -- --once       -> processes at most one pending job, then exits
import "./env.js";
import { CLAIM_WAIT_SECONDS, CONNECTOR_VERSION, clientFromEnv } from "./api.js";
import { processJob } from "./sync.js";
import { log } from "./log.js";

const once = process.argv.includes("--once");
// Only used when the server answers at once (no long poll): keep it short so "Sync now" stays quick.
const pollSeconds = Math.min(Math.max(Number(process.env.POLL_INTERVAL_SECONDS) || 10, 5), 15);
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
  if (!once) log.info("Waiting for sync jobs (they start within a few seconds). Press Ctrl+C to stop.");

  let failures = 0;
  while (!stopping) {
    const asked = Date.now();
    try {
      const { job } = await api.claimJob(once ? 0 : CLAIM_WAIT_SECONDS);
      if (failures) log.info("Server reachable again.");
      failures = 0;
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
      failures++;
      // First failure: retry almost at once (e.g. the server was just updated). Then back off.
      const wait = failures === 1 ? 2 : Math.min(15 * (failures - 1), 60);
      log.error(`Could not reach the server: ${err.message}. Retrying in ${wait} s`);
      if (once) { process.exitCode = 1; return; }
      await sleepUnlessStopping(wait);
      continue;
    }
    // The server held the request while waiting for a job; only pause if it answered at once.
    if (Date.now() - asked < 3000) await sleepUnlessStopping(pollSeconds);
  }
  log.info("Connector stopped.");
}

main().catch((err) => {
  log.error(err.message);
  process.exitCode = 1;
});
'@

# ---------------------------------------------------------------- connector/test/mock-device.js
Write-File "connector/test/mock-device.js" @'
// A fake ZKTeco machine for testing without hardware.
//   npm run mock-device              -> listens on 127.0.0.1:4370 with 500 sample punches
//   then: npm run read-device -- --ip 127.0.0.1
import net from "node:net";
import { pathToFileURL } from "node:url";
import { CMD, buildFrame, parseFrames, makeCommKey, encodeTime } from "../src/zk/protocol.js";

export function sampleRecords(count, startDay = "2026-09-01") {
  const base = new Date(`${startDay}T00:00:00Z`).getTime();
  const p = (n) => String(n).padStart(2, "0");
  const out = [];
  for (let i = 0; i < count; i++) {
    const day = Math.floor(i / 50);
    const user = (i % 25) + 1;
    const isOut = (i % 50) >= 25;
    const d = new Date(base + day * 86400000);
    const h = isOut ? 17 + (user % 2) : 8 + (user % 2);
    const mi = (user * 7 + day) % 60;
    out.push({
      user_id: String(user),
      timestamp: `${d.getUTCFullYear()}-${p(d.getUTCMonth() + 1)}-${p(d.getUTCDate())} ${p(h)}:${p(mi)}:${p(i % 60)}`,
      state: isOut ? 1 : 0,
      verify_mode: 1,
    });
  }
  return out;
}

/** Users for the mock: one per distinct user ID in the records, named "Employee <id>". */
export function sampleUsers(records) {
  const ids = [...new Set(records.map((r) => r.user_id))];
  return ids.map((id, i) => ({ uid: i + 1, user_id: id, name: `Employee ${id}`, password: "1234", card: 99887766 }));
}

export function encodeUsers(users, recordSize = 72) {
  const body = Buffer.alloc(users.length * recordSize);
  users.forEach((u, i) => {
    const o = i * recordSize;
    if (recordSize === 72) {
      body.writeUInt16LE(u.uid, o);
      body.writeUInt8(0, o + 2);
      body.write(u.password ?? "", o + 3, 8, "utf8");
      body.write(u.name ?? "", o + 11, 24, "utf8");
      body.writeUInt32LE(u.card ?? 0, o + 35);
      body.write("1", o + 40, 7, "utf8");
      body.write(u.user_id, o + 48, 24, "utf8");
    } else {
      body.writeUInt16LE(u.uid, o);
      body.write(u.password ?? "", o + 3, 5, "utf8");
      body.write(u.name ?? "", o + 8, 8, "utf8");
      body.writeUInt32LE(u.card ?? 0, o + 16);
      body.writeUInt8(1, o + 21);
      body.writeUInt32LE(Number(u.user_id), o + 24);
    }
  });
  const total = Buffer.alloc(4);
  total.writeUInt32LE(body.length, 0);
  return Buffer.concat([total, body]);
}

export function encodeRecords(records, recordSize = 40) {
  const body = Buffer.alloc(records.length * recordSize);
  records.forEach((r, i) => {
    const o = i * recordSize;
    if (recordSize === 40) {
      body.writeUInt16LE(Number(r.user_id) || i + 1, o);
      body.write(r.user_id, o + 2, 24, "latin1");
      body.writeUInt8(r.verify_mode, o + 26);
      body.writeUInt32LE(encodeTime(r.timestamp), o + 27);
      body.writeUInt8(r.state, o + 31);
    } else if (recordSize === 16) {
      body.writeUInt32LE(Number(r.user_id), o);
      body.writeUInt32LE(encodeTime(r.timestamp), o + 4);
      body.writeUInt8(r.verify_mode, o + 8);
      body.writeUInt8(r.state, o + 9);
    } else {
      body.writeUInt16LE(Number(r.user_id), o);
      body.writeUInt8(r.verify_mode, o + 2);
      body.writeUInt32LE(encodeTime(r.timestamp), o + 3);
      body.writeUInt8(r.state, o + 7);
    }
  });
  const total = Buffer.alloc(4);
  total.writeUInt32LE(body.length, 0);
  return Buffer.concat([total, body]);
}

/**
 * options: { records, recordSize=40, users, userRecordSize=72, refuseUsers, commKey=0, directLimit=1024, dataFrameSize=Infinity, serial, chunkDelayMs=0 }
 * Returns { server, port, received } - received lists every command code the client sent.
 */
export function startMockDevice(options = {}) {
  const records = options.records ?? sampleRecords(500);
  const recordSize = options.recordSize ?? 40;
  const commKey = options.commKey ?? 0;
  const directLimit = options.directLimit ?? 1024;
  const dataFrameSize = options.dataFrameSize ?? Infinity; // real devices send each chunk as one DATA packet
  const serial = options.serial ?? "MOCK0000K50";
  const users = options.users ?? sampleUsers(records);
  const userRecordSize = options.userRecordSize ?? 72;
  const received = [];
  const SESSION = 0x2a3b;

  const server = net.createServer((sock) => {
    let buf = Buffer.alloc(0);
    let authed = commKey === 0;
    let buffered = null;

    const reply = (command, replyId, data = Buffer.alloc(0)) => {
      // buildFrame bumps the reply id; pass replyId - 1 so the device echoes the client's id.
      const prev = replyId === 0 ? 65534 : replyId - 1;
      return buildFrame(command, SESSION, prev, data);
    };

    sock.on("data", (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      const { frames, rest } = parseFrames(buf);
      buf = rest;
      for (const f of frames) {
        received.push(f.command);
        const out = [];
        if (f.command === CMD.CONNECT) {
          out.push(reply(authed ? CMD.ACK_OK : CMD.ACK_UNAUTH, f.replyId));
        } else if (f.command === CMD.AUTH) {
          authed = f.data.equals(makeCommKey(commKey, SESSION));
          out.push(reply(authed ? CMD.ACK_OK : CMD.ACK_UNAUTH, f.replyId));
        } else if (!authed) {
          out.push(reply(CMD.ACK_UNAUTH, f.replyId));
        } else if (f.command === CMD.GET_FREE_SIZES) {
          const d = Buffer.alloc(92);
          d.writeInt32LE(users.length, 4 * 4);
          d.writeInt32LE(50, 6 * 4);
          d.writeInt32LE(records.length, 8 * 4);
          d.writeInt32LE(100000, 16 * 4);
          out.push(reply(CMD.ACK_OK, f.replyId, d));
        } else if (f.command === CMD.OPTIONS_RRQ) {
          out.push(reply(CMD.ACK_OK, f.replyId, Buffer.from(`~SerialNumber=${serial}\0`, "latin1")));
        } else if (f.command === CMD.GET_TIME) {
          const d = Buffer.alloc(4);
          d.writeUInt32LE(encodeTime("2026-10-05 20:30:00"), 0);
          out.push(reply(CMD.ACK_OK, f.replyId, d));
        } else if (f.command === CMD.PREPARE_BUFFER) {
          const dataset = f.data.readInt16LE(1);
          received.push(`buffer:${dataset}`);
          if (dataset === CMD.ATTLOG_RRQ) {
            buffered = encodeRecords(records, recordSize);
          } else if (dataset === CMD.USERTEMP_RRQ && f.data.readInt32LE(3) === 5 && !options.refuseUsers) {
            buffered = encodeUsers(users, userRecordSize);
          } else {
            out.push(reply(CMD.ACK_ERROR, f.replyId));
            sock.write(Buffer.concat(out));
            continue;
          }
          if (buffered.length <= directLimit) {
            out.push(reply(CMD.DATA, f.replyId, buffered));
          } else {
            const d = Buffer.alloc(9);
            d.writeUInt32LE(buffered.length, 1);
            out.push(reply(CMD.ACK_OK, f.replyId, d));
          }
        } else if (f.command === CMD.READ_BUFFER) {
          const start = f.data.readInt32LE(0);
          const len = f.data.readInt32LE(4);
          const slice = buffered.subarray(start, start + len);
          const head = Buffer.alloc(8);
          head.writeUInt32LE(slice.length, 0);
          out.push(reply(CMD.PREPARE_DATA, f.replyId, head));
          for (let o = 0; o < slice.length; o += dataFrameSize) {
            out.push(reply(CMD.DATA, f.replyId, slice.subarray(o, o + dataFrameSize)));
          }
          out.push(reply(CMD.ACK_OK, f.replyId));
        } else if (f.command === CMD.FREE_DATA) {
          buffered = null;
          out.push(reply(CMD.ACK_OK, f.replyId));
        } else if (f.command === CMD.EXIT) {
          sock.end(reply(CMD.ACK_OK, f.replyId));
          continue;
        } else {
          out.push(reply(CMD.ACK_ERROR, f.replyId)); // anything else is refused (and recorded)
        }
        // Coalesce into one write, like real devices often do. Optional delay simulates a slow machine.
        const delay = f.command === CMD.READ_BUFFER ? (options.chunkDelayMs ?? 0) : 0;
        if (delay) setTimeout(() => sock.write(Buffer.concat(out)), delay);
        else sock.write(Buffer.concat(out));
      }
    });
    sock.on("error", () => {});
  });

  return new Promise((resolve) => {
    server.listen(options.port ?? 0, "127.0.0.1", () => {
      resolve({ server, port: server.address().port, received, records });
    });
  });
}

// CLI
if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const port = Number(process.argv[2]) || 4370;
  const { records } = await startMockDevice({ port, records: sampleRecords(500) });
  console.log(`Mock ZKTeco device on 127.0.0.1:${port} with ${records.length} punches (comm key 0). Ctrl+C to stop.`);
}
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


START, STOP AND STATUS
----------------------
After installing, use Start menu > ZKT Connector, or these files:
  Start-Connector.cmd   start (or restart) the connector
  Stop-Connector.cmd    stop it (it starts again when Windows restarts)
  Connector-Status.cmd  is it running? shows the latest log lines


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

# ---------------------------------------------------------------- connector/package/Test-Connection.cmd
Write-File "connector/package/Test-Connection.cmd" @'
@echo off
rem ZKT Connector - reads the attendance machine once and shows what it finds.
rem Read-only: nothing is uploaded and nothing on the machine is changed.
net session >nul 2>&1
if errorlevel 1 goto elevate
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

:elevate
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath \"%~f0\" -Verb RunAs"
exit /b
'@

# ---------------------------------------------------------------- connector/package/Start-Connector.cmd
Write-File "connector/package/Start-Connector.cmd" @'
@echo off
rem ZKT Connector - start (or restart) the connector in the background
if not exist "%~dp0scripts\service.ps1" goto missing
net session >nul 2>&1
if errorlevel 1 goto elevate
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\service.ps1" -Action Start & echo. & pause & exit /b

:elevate
echo Asking for administrator permission...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath \"%~f0\" -Verb RunAs"
exit /b

:missing
echo scripts\service.ps1 not found. Extract the whole ZIP first, then try again.
pause
exit /b 1
'@

# ---------------------------------------------------------------- connector/package/Stop-Connector.cmd
Write-File "connector/package/Stop-Connector.cmd" @'
@echo off
rem ZKT Connector - stop the connector (it starts again when Windows restarts)
if not exist "%~dp0scripts\service.ps1" goto missing
net session >nul 2>&1
if errorlevel 1 goto elevate
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\service.ps1" -Action Stop & echo. & pause & exit /b

:elevate
echo Asking for administrator permission...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath \"%~f0\" -Verb RunAs"
exit /b

:missing
echo scripts\service.ps1 not found. Extract the whole ZIP first, then try again.
pause
exit /b 1
'@

# ---------------------------------------------------------------- connector/package/Connector-Status.cmd
Write-File "connector/package/Connector-Status.cmd" @'
@echo off
rem ZKT Connector - show whether the connector is running and its latest log lines
if not exist "%~dp0scripts\service.ps1" goto missing
net session >nul 2>&1
if errorlevel 1 goto elevate
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\service.ps1" -Action Status & echo. & pause & exit /b

:elevate
echo Asking for administrator permission...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath \"%~f0\" -Verb RunAs"
exit /b

:missing
echo scripts\service.ps1 not found. Extract the whole ZIP first, then try again.
pause
exit /b 1
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

    $menu = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\ZKT Connector"
    if (Test-Path $menu) { Remove-Item $menu -Recurse -Force; Write-Host "Start Menu shortcuts removed." }

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

# ---------------------------------------------------------------- connector/package/scripts/service.ps1
Write-File "connector/package/scripts/service.ps1" @'
# ZKT Connector - start, stop or check the background connector.
# Used by Start-Connector.cmd, Stop-Connector.cmd and Connector-Status.cmd (as administrator).
param([ValidateSet("Start", "Stop", "Status")][string]$Action = "Status")
$ErrorActionPreference = "Stop"
$TaskName = "ZKT Connector"
$Dest     = Join-Path $env:ProgramData "ZKTConnector"
$LogFile  = Join-Path $Dest "logs\connector.log"

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
            $from = 0
            if (Test-Path $LogFile) { $from = (Get-Item $LogFile).Length }
            Start-ScheduledTask -TaskName $TaskName
            $ok = $false; $failed = $false; $text = ""
            for ($i = 0; $i -lt 30 -and -not $ok -and -not $failed; $i++) {
                Start-Sleep -Seconds 1
                $text = Read-NewLog $from
                if ($text -match "Connected to ") { $ok = $true }
                elseif ($text -match "ERROR") { $failed = $true }
            }
            ($text -split "`r?`n" | Where-Object { $_ } | Select-Object -Last 8) | ForEach-Object { Write-Host "  $_" }
            Write-Host ""
            if ($ok) {
                Write-Host "RUNNING. The connector is connected and waiting for syncs." -ForegroundColor Green
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
'@

# ---------------------------------------------------------------- worker/package.json
Write-File "worker/package.json" @'
{
  "name": "hr-attendance-worker",
  "version": "0.11.0",
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

# ---------------------------------------------------------------- worker/migrations/0006_sync_progress.sql
Write-File "worker/migrations/0006_sync_progress.sql" @'
-- =============================================================
-- Phase 11 - live sync progress, heartbeats and cancelling
-- =============================================================
ALTER TABLE sync_jobs ADD COLUMN progress_stage TEXT;     -- connecting | reading | uploading | names | finishing
ALTER TABLE sync_jobs ADD COLUMN progress_pct INTEGER;    -- 0-100 for the current stage
ALTER TABLE sync_jobs ADD COLUMN progress_msg TEXT;       -- short human-readable status line
ALTER TABLE sync_jobs ADD COLUMN heartbeat_at TEXT;       -- last time the connector reported on this job
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
  "Start-Connector.cmd", "Stop-Connector.cmd", "Connector-Status.cmd",
  "scripts/install.ps1", "scripts/uninstall.ps1", "scripts/service.ps1",
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
export const CONNECTOR_VERSION = "0.9.0";
export const CONNECTOR_FILES: Record<string, string> = {
 "src/env.js": "// Loads settings from the .env file next to the connector (no dependencies).\n// The file is found relative to this code, not the current folder, so it works\n// the same when started by Windows at boot, by a shortcut, or from a terminal.\n// Values already set in the environment win over the file.\nimport fs from \"node:fs\";\nimport path from \"node:path\";\nimport { fileURLToPath } from \"node:url\";\n\nexport const CONNECTOR_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), \"..\");\nexport const ENV_FILE = path.join(CONNECTOR_DIR, \".env\");\n\nexport function parseEnv(text) {\n  const out = {};\n  for (const raw of text.replace(/^\\uFEFF/, \"\").split(/\\r?\\n/)) {\n    const line = raw.trim();\n    if (!line || line.startsWith(\"#\")) continue;\n    const eq = line.indexOf(\"=\");\n    if (eq <= 0) continue;\n    const key = line.slice(0, eq).trim();\n    let value = line.slice(eq + 1).trim();\n    if ((value.startsWith('\"') && value.endsWith('\"')) || (value.startsWith(\"'\") && value.endsWith(\"'\"))) {\n      value = value.slice(1, -1);\n    } else {\n      const hash = value.indexOf(\" #\");\n      if (hash >= 0) value = value.slice(0, hash).trim();\n    }\n    if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) out[key] = value;\n  }\n  return out;\n}\n\nif (fs.existsSync(ENV_FILE)) {\n  const values = parseEnv(fs.readFileSync(ENV_FILE, \"utf8\"));\n  for (const [k, v] of Object.entries(values)) {\n    if (process.env[k] === undefined) process.env[k] = v;\n  }\n}\n",
 "src/log.js": "// Timestamped console logging (Phase 6 will also write these lines to a file).\nfunction stamp() {\n  const d = new Date();\n  const p = (n) => String(n).padStart(2, \"0\");\n  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;\n}\n\nexport const log = {\n  info: (msg) => console.log(`${stamp()}  INFO   ${msg}`),\n  warn: (msg) => console.warn(`${stamp()}  WARN   ${msg}`),\n  error: (msg) => console.error(`${stamp()}  ERROR  ${msg}`),\n};\n",
 "src/api.js": "// HTTP client for the Attendance Fetcher Worker (connector side).\n// Every request has a time limit, so a bad network can never freeze the connector.\nexport const CONNECTOR_VERSION = \"0.9.0\";\n\nconst DEFAULT_TIMEOUT_MS = 30000;\nexport const CLAIM_WAIT_SECONDS = 20;\n\nexport class ApiClient {\n  constructor(baseUrl, token) {\n    this.baseUrl = baseUrl.replace(/\\/+$/, \"\");\n    this.token = token;\n  }\n\n  async request(method, path, body, timeoutMs = DEFAULT_TIMEOUT_MS) {\n    let res;\n    try {\n      res = await fetch(this.baseUrl + path, {\n        method,\n        headers: {\n          authorization: `Bearer ${this.token}`,\n          \"content-type\": \"application/json\",\n          \"x-connector-version\": CONNECTOR_VERSION,\n        },\n        body: body === undefined ? undefined : JSON.stringify(body),\n        signal: AbortSignal.timeout(timeoutMs),\n      });\n    } catch (err) {\n      const timedOut = err && (err.name === \"TimeoutError\" || err.name === \"AbortError\");\n      const e = new Error(timedOut\n        ? `${method} ${path}: no answer from the server within ${Math.round(timeoutMs / 1000)} s`\n        : `${method} ${path}: cannot reach the server (${err.cause?.code ?? err.message})`);\n      e.network = true;\n      throw e;\n    }\n\n    const text = await res.text();\n    let data;\n    try {\n      data = text ? JSON.parse(text) : {};\n    } catch {\n      data = { error: text.slice(0, 200) };\n    }\n\n    if (!res.ok) {\n      const err = new Error(`${method} ${path} -> ${res.status}: ${data.error ?? \"request failed\"}`);\n      err.status = res.status;\n      throw err;\n    }\n    return data;\n  }\n\n  getConfig() {\n    return this.request(\"GET\", \"/api/connector/config\");\n  }\n\n  /** Waits up to `waitSeconds` on the server for a job (long poll). */\n  claimJob(waitSeconds = CLAIM_WAIT_SECONDS) {\n    return this.request(\"POST\", `/api/connector/jobs/claim?wait=${waitSeconds}`, {}, (waitSeconds + 20) * 1000);\n  }\n\n  /** Reports what the connector is doing. Resolves to { stop: true } when the job was cancelled. */\n  reportProgress(jobId, stage, pct, message) {\n    return this.request(\"POST\", `/api/connector/jobs/${encodeURIComponent(jobId)}/progress`, { stage, pct, message }, 15000);\n  }\n\n  /** records: [{ user_id, timestamp: \"YYYY-MM-DD HH:MM:SS\", state, verify_mode }] (max 1000 per call) */\n  uploadLogs(jobId, records) {\n    return this.request(\"POST\", `/api/connector/jobs/${encodeURIComponent(jobId)}/logs`, { records });\n  }\n\n  /** users: [{ user_id, name }] from the machine's user list */\n  uploadUsers(jobId, users) {\n    return this.request(\"POST\", `/api/connector/jobs/${encodeURIComponent(jobId)}/users`, { users });\n  }\n\n  /** payload: { status: \"success\" | \"failed\", error_message?, device_serial? } */\n  completeJob(jobId, payload) {\n    return this.request(\"POST\", `/api/connector/jobs/${encodeURIComponent(jobId)}/complete`, payload);\n  }\n}\n\nexport function clientFromEnv() {\n  const base = process.env.API_BASE_URL;\n  const token = process.env.CONNECTOR_TOKEN;\n  if (!base) throw new Error(\"API_BASE_URL is not set in .env\");\n  if (!token || !token.startsWith(\"zkc_\")) {\n    throw new Error(\"CONNECTOR_TOKEN is not set in .env (create a connector in the dashboard and paste its token)\");\n  }\n  return new ApiClient(base, token);\n}\n",
 "src/sync.js": "// Phase 5: process one sync job end to end.\n// read machine (read-only, with retries) -> filter -> upload in batches -> complete job\nimport { readDevice } from \"./zk/client.js\";\nimport { log } from \"./log.js\";\n\nconst BATCH_SIZE = 1000;\nconst FUTURE_TOLERANCE_MS = 24 * 60 * 60 * 1000; // punches > 1 day after the machine's own clock are skipped\n\nconst sleep = (ms) => new Promise((r) => setTimeout(r, ms));\n\nfunction retryDelaysMs() {\n  const base = Number(process.env.RETRY_DELAY_SECONDS);\n  const s = Number.isFinite(base) && base >= 0 ? base : 5;\n  return [s * 1000, s * 3000]; // wait 5 s, then 15 s (3 attempts in total)\n}\n\n/** \"YYYY-MM-DD HH:MM:SS\" (machine local time) -> Date in this PC's local time zone */\nfunction parseLocal(ts) {\n  return new Date(ts.replace(\" \", \"T\"));\n}\n\nfunction formatLocal(d) {\n  const p = (n) => String(n).padStart(2, \"0\");\n  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;\n}\n\n/** Machine clock minus this PC's clock, in seconds (null if the machine did not report its time). */\nexport function clockOffsetSeconds(deviceTime, now = Date.now()) {\n  if (!deviceTime) return null;\n  const t = parseLocal(deviceTime).getTime();\n  return Number.isFinite(t) ? Math.round((t - now) / 1000) : null;\n}\n\n/**\n * Splits records into ones to import and ones to skip.\n * Skipped: dated more than 1 day after the machine's current clock - these were\n * recorded while the machine clock was set wrong and would show as future attendance.\n */\nexport function filterRecords(records, deviceTime, now = Date.now()) {\n  const ref = deviceTime ? parseLocal(deviceTime).getTime() : now;\n  const limit = formatLocal(new Date((Number.isFinite(ref) ? ref : now) + FUTURE_TOLERANCE_MS));\n  const keep = [];\n  const skipped = [];\n  for (const r of records) (r.timestamp <= limit ? keep : skipped).push(r);\n  keep.sort((a, b) => a.timestamp.localeCompare(b.timestamp));\n  return { keep, skipped, limit };\n}\n\nfunction isRetryable(err) {\n  return !err.status || err.status >= 500 || err.status === 429;\n}\n\n/** Thrown when the sync was stopped from the dashboard (or timed out on the server). */\nexport class StopSync extends Error {}\n\n/** A whole sync may take at most this long; then it stops with a clear error. */\nconst JOB_LIMIT_MS = 10 * 60 * 1000;\n\n/**\n * Reports progress to the dashboard (at most every 1.5 s unless forced) and remembers\n * if the server says to stop. Network problems while reporting never break the sync.\n */\nclass Progress {\n  constructor(api, jobId) {\n    this.api = api;\n    this.jobId = jobId;\n    this.stopped = false;\n    this.last = 0;\n    this.started = Date.now();\n  }\n  async send(stage, pct, message, force = false) {\n    const now = Date.now();\n    if (!force && now - this.last < 1500) return;\n    this.last = now;\n    try {\n      const r = await this.api.reportProgress(this.jobId, stage, pct, message);\n      if (r && r.stop) this.stopped = true;\n    } catch (err) {\n      if (err.status === 404 || err.status === 409) this.stopped = true;\n    }\n    this.check();\n  }\n  check() {\n    if (this.stopped) throw new StopSync(\"Sync was stopped from the dashboard\");\n    if (Date.now() - this.started > JOB_LIMIT_MS) {\n      throw new Error(`The sync took longer than ${JOB_LIMIT_MS / 60000} minutes and was stopped`);\n    }\n  }\n}\n\nasync function withRetry(label, fn, progress) {\n  const delays = retryDelaysMs();\n  for (let attempt = 1; ; attempt++) {\n    try {\n      return await fn();\n    } catch (err) {\n      if (err instanceof StopSync || attempt > delays.length || !isRetryable(err)) throw err;\n      const wait = delays[attempt - 1];\n      const msg = `${label} failed (attempt ${attempt} of ${delays.length + 1}): ${err.message}. Retrying in ${Math.round(wait / 1000)} s`;\n      log.warn(msg);\n      if (progress) await progress.send(\"retrying\", null, msg, true);\n      await sleep(wait);\n      if (progress) progress.check();\n    }\n  }\n}\n\nasync function safeFail(api, jobId, message) {\n  try {\n    await api.completeJob(jobId, { status: \"failed\", error_message: message.slice(0, 480) });\n  } catch (err) {\n    if (err.status !== 409) log.error(`Could not report failure for job ${jobId}: ${err.message}`);\n  }\n}\n\n/** Returns a summary object; never throws (problems are reported on the job and in the log). */\nexport async function processJob(api, job, { timeoutMs = 10000 } = {}) {\n  const d = job.device;\n  const started = Date.now();\n  const progress = new Progress(api, job.id);\n  log.info(`Job ${job.id.slice(0, 8)} (${job.trigger_type}): reading \"${d.name}\" at ${d.ip_address}:${d.port}`);\n\n  try {\n    // 1) Read the machine (read-only)\n    let result;\n    try {\n      await progress.send(\"connecting\", 0, `Connecting to the machine at ${d.ip_address}:${d.port}`, true);\n      result = await withRetry(\"Reading machine\", () =>\n        readDevice({ ip: d.ip_address, port: d.port, commKey: d.comm_key, timeoutMs }, (done, total) => {\n          // Throwing here aborts the read at the next chunk and disconnects from the machine.\n          if (progress.stopped) throw new StopSync(\"Sync was stopped from the dashboard\");\n          const pct = Math.floor((done / total) * 100);\n          progress.send(\"reading\", pct, `Reading punches from the machine: ${pct}%`).catch(() => {});\n        }), progress);\n    } catch (err) {\n      if (err instanceof StopSync) throw err;\n      const msg = `Could not read the machine at ${d.ip_address}:${d.port}: ${err.message}`;\n      log.error(msg);\n      await safeFail(api, job.id, msg);\n      return { ok: false, error: msg };\n    }\n    progress.check();\n\n    const offset = clockOffsetSeconds(result.deviceTime);\n    const { keep, skipped, limit } = filterRecords(result.records, result.deviceTime);\n    log.info(`Read ${result.records.length} punches (serial ${result.serialNumber ?? \"?\"}, clock offset ${offset ?? \"?\"} s)`);\n    if (offset !== null && Math.abs(offset) > 60) {\n      log.warn(`Machine clock is ${Math.abs(offset)} s ${offset < 0 ? \"behind\" : \"ahead\"}. Correct the time on the machine.`);\n    }\n    if (skipped.length) {\n      const sample = skipped.slice(0, 3).map((r) => `${r.timestamp} (user ${r.user_id})`).join(\", \");\n      log.warn(`Skipping ${skipped.length} punch(es) dated after ${limit}: ${sample}${skipped.length > 3 ? \", ...\" : \"\"}`);\n    }\n\n    // 2) Upload in batches (duplicates are ignored by the server)\n    let inserted = 0;\n    let duplicates = 0;\n    let rejected = 0;\n    try {\n      await progress.send(\"uploading\", 0, `Read ${result.records.length} punches. Uploading...`, true);\n      for (let i = 0; i < keep.length; i += BATCH_SIZE) {\n        const batch = keep.slice(i, i + BATCH_SIZE);\n        const res = await withRetry(\"Upload\", () => api.uploadLogs(job.id, batch), progress);\n        inserted += res.inserted;\n        duplicates += res.duplicates;\n        rejected += res.rejected;\n        const sent = Math.min(i + BATCH_SIZE, keep.length);\n        await progress.send(\"uploading\", Math.floor((sent / keep.length) * 100), `Uploaded ${sent} of ${keep.length} punches (${inserted} new)`, sent === keep.length);\n      }\n    } catch (err) {\n      if (err instanceof StopSync || err.status === 409) throw new StopSync(err.message);\n      const msg = `Upload failed: ${err.message}`;\n      log.error(msg);\n      await safeFail(api, job.id, msg);\n      return { ok: false, error: msg };\n    }\n\n    // 3) Employee names from the machine (best effort: never fails the sync)\n    if (result.users.length) {\n      try {\n        await progress.send(\"names\", 100, `Updating ${result.users.length} employee names`, true);\n        const res = await withRetry(\"Uploading names\", () => api.uploadUsers(job.id, result.users), progress);\n        log.info(`Names: ${result.users.length} users on machine, ${res.named} with a name (${res.added} new employees)`);\n      } catch (err) {\n        if (err instanceof StopSync || err.status === 409) throw new StopSync(err.message);\n        log.warn(`Could not upload employee names: ${err.message}`);\n      }\n    } else if (result.usersError) {\n      log.warn(`Could not read user names from the machine: ${result.usersError}`);\n    }\n\n    // 4) Complete\n    try {\n      await withRetry(\"Completing job\", () => api.completeJob(job.id, {\n        status: \"success\",\n        device_serial: result.serialNumber ?? undefined,\n        records_skipped: skipped.length + rejected,\n        clock_offset_seconds: offset ?? undefined,\n      }), progress);\n    } catch (err) {\n      if (err instanceof StopSync || err.status === 409) throw new StopSync(err.message);\n      log.error(`Could not complete job: ${err.message}`);\n      return { ok: false, error: err.message };\n    }\n\n    const secs = ((Date.now() - started) / 1000).toFixed(1);\n    log.info(`Job ${job.id.slice(0, 8)} done in ${secs} s: ${inserted} new, ${duplicates} already imported, ${skipped.length + rejected} skipped`);\n    return { ok: true, read: result.records.length, inserted, duplicates, skipped: skipped.length + rejected };\n  } catch (err) {\n    if (err instanceof StopSync) {\n      log.warn(`Job ${job.id.slice(0, 8)} stopped: the sync was cancelled from the dashboard or timed out.`);\n      return { ok: false, stopped: true };\n    }\n    const msg = err.message || String(err);\n    log.error(`Job ${job.id.slice(0, 8)} failed: ${msg}`);\n    await safeFail(api, job.id, msg);\n    return { ok: false, error: msg };\n  }\n}\n",
 "src/index.js": "// ZKT Connector main loop.\n//   npm start                 -> runs continuously: picks up sync jobs and imports attendance\n//   npm start -- --once       -> processes at most one pending job, then exits\nimport \"./env.js\";\nimport { CLAIM_WAIT_SECONDS, CONNECTOR_VERSION, clientFromEnv } from \"./api.js\";\nimport { processJob } from \"./sync.js\";\nimport { log } from \"./log.js\";\n\nconst once = process.argv.includes(\"--once\");\n// Only used when the server answers at once (no long poll): keep it short so \"Sync now\" stays quick.\nconst pollSeconds = Math.min(Math.max(Number(process.env.POLL_INTERVAL_SECONDS) || 10, 5), 15);\nconst timeoutMs = Number(process.env.DEVICE_TIMEOUT_MS) || 10000;\n\nlet stopping = false;\nprocess.on(\"SIGINT\", () => {\n  if (stopping) process.exit(1);\n  stopping = true;\n  log.info(\"Stopping after the current step (press Ctrl+C again to force)...\");\n});\nprocess.on(\"SIGTERM\", () => { stopping = true; });\n\nasync function sleepUnlessStopping(seconds) {\n  for (let i = 0; i < seconds && !stopping; i++) await new Promise((r) => setTimeout(r, 1000));\n}\n\nasync function main() {\n  log.info(`ZKT Connector ${CONNECTOR_VERSION} starting${once ? \" (single run)\" : \"\"}`);\n  const api = clientFromEnv();\n\n  // At Windows start-up the network may not be ready yet: keep trying (except for a bad token).\n  let config;\n  for (;;) {\n    try {\n      config = await api.getConfig();\n      break;\n    } catch (err) {\n      if (err.status === 401 || once) throw err;\n      log.warn(`Server not reachable yet (${err.message}). Retrying in 30 s`);\n      await sleepUnlessStopping(30);\n      if (stopping) return;\n    }\n  }\n  log.info(`Connected to ${api.baseUrl} as connector \"${config.connector.name}\"`);\n  if (!config.devices.length) log.warn(\"No devices assigned to this connector yet (add one in the dashboard).\");\n  for (const d of config.devices) log.info(`Device \"${d.name}\" at ${d.ip_address}:${d.port}`);\n  if (!once) log.info(\"Waiting for sync jobs (they start within a few seconds). Press Ctrl+C to stop.\");\n\n  let failures = 0;\n  while (!stopping) {\n    const asked = Date.now();\n    try {\n      const { job } = await api.claimJob(once ? 0 : CLAIM_WAIT_SECONDS);\n      if (failures) log.info(\"Server reachable again.\");\n      failures = 0;\n      if (job) {\n        await processJob(api, job, { timeoutMs });\n        if (once) break;\n        continue; // another job may be waiting (e.g. several devices)\n      }\n      if (once) {\n        log.info(\"No pending sync job. Click 'Sync now' in the dashboard, then run again.\");\n        break;\n      }\n    } catch (err) {\n      if (err.status === 401) {\n        log.error(`${err.message}. Create a new connector token in the dashboard and update .env.`);\n        process.exitCode = 1;\n        return;\n      }\n      failures++;\n      // First failure: retry almost at once (e.g. the server was just updated). Then back off.\n      const wait = failures === 1 ? 2 : Math.min(15 * (failures - 1), 60);\n      log.error(`Could not reach the server: ${err.message}. Retrying in ${wait} s`);\n      if (once) { process.exitCode = 1; return; }\n      await sleepUnlessStopping(wait);\n      continue;\n    }\n    // The server held the request while waiting for a job; only pause if it answered at once.\n    if (Date.now() - asked < 3000) await sleepUnlessStopping(pollSeconds);\n  }\n  log.info(\"Connector stopped.\");\n}\n\nmain().catch((err) => {\n  log.error(err.message);\n  process.exitCode = 1;\n});\n",
 "src/read-device.js": "// Phase 4: read the attendance log from the machine (READ-ONLY) and show a summary.\n// Nothing is uploaded and nothing on the machine is changed or cleared.\n//\n//   npm run read-device                         -> device from the dashboard (via CONNECTOR_TOKEN)\n//   npm run read-device -- --device \"K40PIA\"    -> pick one when the connector has several\n//   npm run read-device -- --ip 192.168.10.21   -> skip the dashboard, connect directly\n//   npm run read-device -- --csv                -> also save all punches to output/*.csv\nimport \"./env.js\";\nimport fs from \"node:fs\";\nimport path from \"node:path\";\nimport { readDevice } from \"./zk/client.js\";\nimport { clientFromEnv, CONNECTOR_VERSION } from \"./api.js\";\n\nconst STATES = { 0: \"Check-in\", 1: \"Check-out\", 2: \"Break-out\", 3: \"Break-in\", 4: \"OT-in\", 5: \"OT-out\" };\nconst VERIFY = { 0: \"Password\", 1: \"Fingerprint\", 2: \"Card\", 15: \"Face\" };\n\nfunction parseArgs(argv) {\n  const args = {};\n  for (let i = 0; i < argv.length; i++) {\n    const a = argv[i];\n    if (!a.startsWith(\"--\")) continue;\n    const key = a.slice(2);\n    const next = argv[i + 1];\n    if (next !== undefined && !next.startsWith(\"--\")) { args[key] = next; i++; }\n    else args[key] = true;\n  }\n  return args;\n}\n\nasync function resolveDevice(args) {\n  const timeoutMs = Number(process.env.DEVICE_TIMEOUT_MS) || 10000;\n  if (args.ip) {\n    return { name: \"(command line)\", ip: args.ip, port: Number(args.port) || 4370, commKey: Number(args.key) || 0, timeoutMs, source: \"command line\" };\n  }\n  if (process.env.CONNECTOR_TOKEN && process.env.CONNECTOR_TOKEN.startsWith(\"zkc_\")) {\n    const config = await clientFromEnv().getConfig();\n    const devices = config.devices;\n    if (!devices.length) throw new Error(\"No devices are assigned to this connector in the dashboard.\");\n    let d = devices[0];\n    if (args.device) {\n      d = devices.find((x) => x.name.toLowerCase() === String(args.device).toLowerCase());\n      if (!d) throw new Error(`No device named \"${args.device}\". Assigned: ${devices.map((x) => x.name).join(\", \")}`);\n    } else if (devices.length > 1) {\n      console.log(`Connector has ${devices.length} devices; using \"${d.name}\". Use --device \"<name>\" to choose.`);\n    }\n    return { name: d.name, ip: d.ip_address, port: d.port, commKey: d.comm_key, timeoutMs, source: \"dashboard\" };\n  }\n  if (process.env.DEVICE_IP) {\n    return {\n      name: \"(.env)\", ip: process.env.DEVICE_IP, port: Number(process.env.DEVICE_PORT) || 4370,\n      commKey: Number(process.env.DEVICE_COMM_KEY) || 0, timeoutMs, source: \".env\",\n    };\n  }\n  throw new Error(\"No device configured. Set CONNECTOR_TOKEN in .env, or pass --ip 192.168.10.21\");\n}\n\nfunction clockDifference(deviceTime) {\n  if (!deviceTime) return \"\";\n  const dev = new Date(deviceTime.replace(\" \", \"T\")).getTime();\n  const diff = Math.round((dev - Date.now()) / 1000);\n  const warn = Math.abs(diff) > 120 ? \"  <-- machine clock is off, punches will carry this error\" : \"\";\n  return `  (difference vs this PC: ${diff >= 0 ? \"+\" : \"\"}${diff} s)${warn}`;\n}\n\nfunction toCsv(records) {\n  const lines = [\"user_id,timestamp,state,state_label,verify_mode,verify_label\"];\n  for (const r of records) {\n    lines.push([r.user_id, r.timestamp, r.state, STATES[r.state] ?? \"\", r.verify_mode, VERIFY[r.verify_mode] ?? \"\"]\n      .map((v) => `\"${String(v).replace(/\"/g, '\"\"')}\"`).join(\",\"));\n  }\n  return lines.join(\"\\r\\n\") + \"\\r\\n\";\n}\n\nasync function main() {\n  const args = parseArgs(process.argv.slice(2));\n  console.log(`ZKT Connector ${CONNECTOR_VERSION} - read device (read-only, nothing is changed on the machine)\\n`);\n\n  const device = await resolveDevice(args);\n  console.log(`Device       : ${device.name}  ${device.ip}:${device.port}  comm key ${device.commKey}  [from ${device.source}]`);\n\n  const started = Date.now();\n  const result = await readDevice(device, (done, total) => {\n    process.stdout.write(`\\rReading      : ${Math.floor((done / total) * 100)}% (${done}/${total} bytes)`);\n  });\n  if (result.sizes.records > 0) process.stdout.write(\"\\n\");\n  const seconds = ((Date.now() - started) / 1000).toFixed(1);\n\n  const { records, sizes } = result;\n  console.log(`Serial number: ${result.serialNumber ?? \"(not reported)\"}`);\n  console.log(`Device clock : ${result.deviceTime ?? \"(not reported)\"}${clockDifference(result.deviceTime)}`);\n  console.log(`Stored       : ${sizes.records} punches (capacity ${sizes.recordsCapacity || \"?\"}), ${sizes.users} users, record format ${result.recordSize || \"-\"} bytes`);\n  console.log(`Read         : ${records.length} punches in ${seconds} s`);\n\n  if (result.users.length) {\n    const named = result.users.filter((u) => u.name);\n    console.log(`Names        : ${named.length} of ${result.users.length} users have a name on the machine`);\n    for (const u of result.users.slice(0, 10)) console.log(`  user ${u.user_id.padEnd(8)} ${u.name || \"(no name on machine)\"}`);\n    if (result.users.length > 10) console.log(`  ... and ${result.users.length - 10} more`);\n  } else if (result.usersError) {\n    console.log(`Names        : could not read user list (${result.usersError})`);\n  }\n\n  if (!records.length) {\n    console.log(\"\\nThe machine has no attendance records.\");\n    return;\n  }\n\n  const sorted = [...records].sort((a, b) => a.timestamp.localeCompare(b.timestamp));\n  const users = new Set(records.map((r) => r.user_id));\n  console.log(`Range        : ${sorted[0].timestamp}  ->  ${sorted.at(-1).timestamp}`);\n  console.log(`Users        : ${users.size} distinct user IDs`);\n\n  console.log(\"\\nLatest 10 punches:\");\n  for (const r of sorted.slice(-10)) {\n    console.log(`  ${r.timestamp}  user ${r.user_id.padEnd(8)} ${String(STATES[r.state] ?? `state ${r.state}`).padEnd(10)} ${VERIFY[r.verify_mode] ?? `verify ${r.verify_mode}`}`);\n  }\n\n  if (args.csv) {\n    const outDir = path.resolve(\"output\");\n    fs.mkdirSync(outDir, { recursive: true });\n    const stamp = new Date().toISOString().replace(/[-:]/g, \"\").slice(0, 13);\n    const file = typeof args.csv === \"string\" ? path.resolve(args.csv) : path.join(outDir, `attendance-${result.serialNumber ?? device.ip}-${stamp}.csv`);\n    fs.writeFileSync(file, toCsv(sorted));\n    console.log(`\\nSaved ${sorted.length} punches to ${file}`);\n  }\n  console.log(\"\\nNothing was uploaded (this command only reads). Use \\\"npm start\\\" or Sync now to import.\");\n}\n\nmain().catch((err) => {\n  console.error(`\\nFAILED: ${err.message}`);\n  if (/Cannot (connect|reach)|did not respond/.test(err.message)) {\n    console.error(\"Checks: 1) ping the machine's IP from this PC  2) this PC is on the same network (e.g. 192.168.10.x)\");\n    console.error(\"        3) port 4370 is not blocked  4) close ZKTime/ZKBio or other software connected to the machine, then retry\");\n  }\n  process.exitCode = 1;\n});\n",
 "src/zk/protocol.js": "// ZKTeco \"ZK6\" TCP protocol helpers (port 4370).\n// Packet layout, checksum, comm-key scrambling and time decoding follow the\n// public pyzk / zkemsdk implementations.\n\nexport const CMD = Object.freeze({\n  USERTEMP_RRQ: 9,       // read user list (with FCT_USER)\n  OPTIONS_RRQ: 11,       // read a device option, e.g. ~SerialNumber\n  ATTLOG_RRQ: 13,        // read all attendance records\n  GET_FREE_SIZES: 50,    // read record counts / capacity\n  GET_TIME: 201,         // read device clock\n  CONNECT: 1000,\n  EXIT: 1001,\n  AUTH: 1102,            // send comm key\n  PREPARE_DATA: 1500,    // device -> \"large data follows\"\n  DATA: 1501,            // device -> data packet\n  FREE_DATA: 1502,       // release the device's read buffer\n  PREPARE_BUFFER: 1503,  // ask device to buffer a dataset\n  READ_BUFFER: 1504,     // read a chunk of that buffer\n  ACK_OK: 2000,\n  ACK_ERROR: 2001,\n  ACK_DATA: 2002,\n  ACK_UNAUTH: 2005,\n});\n\n/**\n * The ONLY commands the connector is allowed to send. None of them change\n * anything on the machine: no clearing logs, no users, no time, no restart.\n */\nexport const READ_ONLY_COMMANDS = new Set([\n  CMD.CONNECT, CMD.EXIT, CMD.AUTH,\n  CMD.GET_FREE_SIZES, CMD.OPTIONS_RRQ, CMD.GET_TIME,\n  CMD.PREPARE_BUFFER, CMD.READ_BUFFER, CMD.FREE_DATA,\n]);\n\n/** Datasets the connector may read through PREPARE_BUFFER: attendance log and user list only. */\nexport const FCT_USER = 5;\nexport const READ_ONLY_DATASETS = new Map([\n  [CMD.ATTLOG_RRQ, 0],\n  [CMD.USERTEMP_RRQ, FCT_USER],\n]);\n\nexport const USHRT_MAX = 65535;\nconst TCP_MAGIC_1 = 0x5050;\nconst TCP_MAGIC_2 = 0x7d82;\n\nexport function checksum(buf) {\n  let sum = 0;\n  let i = 0;\n  for (; i + 1 < buf.length; i += 2) {\n    sum += buf[i] | (buf[i + 1] << 8);\n    if (sum > USHRT_MAX) sum -= USHRT_MAX;\n  }\n  if (i < buf.length) sum += buf[buf.length - 1];\n  while (sum > USHRT_MAX) sum -= USHRT_MAX;\n  sum = ~sum;\n  while (sum < 0) sum += USHRT_MAX;\n  return sum & 0xffff;\n}\n\n/** Builds one TCP frame. Returns the bytes and the reply id that was used. */\nexport function buildFrame(command, sessionId, replyId, data = Buffer.alloc(0)) {\n  const body = Buffer.alloc(8 + data.length);\n  body.writeUInt16LE(command, 0);\n  body.writeUInt16LE(0, 2);\n  body.writeUInt16LE(sessionId, 4);\n  body.writeUInt16LE(replyId, 6);\n  data.copy(body, 8);\n\n  const cs = checksum(body);\n  let nextReply = replyId + 1;\n  if (nextReply >= USHRT_MAX) nextReply -= USHRT_MAX;\n  body.writeUInt16LE(cs, 2);\n  body.writeUInt16LE(nextReply, 6);\n\n  const top = Buffer.alloc(8);\n  top.writeUInt16LE(TCP_MAGIC_1, 0);\n  top.writeUInt16LE(TCP_MAGIC_2, 2);\n  top.writeUInt32LE(body.length, 4);\n  return Buffer.concat([top, body]);\n}\n\n/**\n * Splits a byte stream into frames. Returns { frames, rest }.\n * Throws if the stream is not ZKTeco TCP.\n */\nexport function parseFrames(buffer) {\n  const frames = [];\n  let buf = buffer;\n  while (buf.length >= 8) {\n    if (buf.readUInt16LE(0) !== TCP_MAGIC_1 || buf.readUInt16LE(2) !== TCP_MAGIC_2) {\n      throw new Error(\"Invalid packet from device (not a ZKTeco TCP response)\");\n    }\n    const len = buf.readUInt32LE(4);\n    if (len < 8 || len > 64 * 1024 * 1024) throw new Error(`Invalid packet length from device: ${len}`);\n    if (buf.length < 8 + len) break;\n    const p = buf.subarray(8, 8 + len);\n    frames.push({\n      command: p.readUInt16LE(0),\n      sessionId: p.readUInt16LE(4),\n      replyId: p.readUInt16LE(6),\n      data: Buffer.from(p.subarray(8)),\n    });\n    buf = buf.subarray(8 + len);\n  }\n  return { frames, rest: buf };\n}\n\n/** Scrambles the numeric comm key with the session id (zkemsdk MakeKey). */\nexport function makeCommKey(key, sessionId, ticks = 50) {\n  const k0 = Number(key) >>> 0;\n  let k = 0;\n  for (let i = 0; i < 32; i++) {\n    k = ((k2(k) | ((k0 >>> i) & 1)) >>> 0);\n  }\n  k = (k + Number(sessionId)) % 0x100000000;\n\n  const b = Buffer.alloc(4);\n  b.writeUInt32LE(k >>> 0, 0);\n  const x = [b[0] ^ 0x5a, b[1] ^ 0x4b, b[2] ^ 0x53, b[3] ^ 0x4f]; // 'Z','K','S','O'\n  const swapped = [x[2], x[3], x[0], x[1]];                          // swap the two 16-bit halves\n  const B = ticks & 0xff;\n  return Buffer.from([swapped[0] ^ B, swapped[1] ^ B, B, swapped[3] ^ B]);\n\n  function k2(v) { return (v << 1) >>> 0; }\n}\n\n/** Device timestamps are packed local times (zkemsdk DecodeTime). */\nexport function decodeTime(t) {\n  let v = t >>> 0;\n  const second = v % 60; v = Math.floor(v / 60);\n  const minute = v % 60; v = Math.floor(v / 60);\n  const hour = v % 24; v = Math.floor(v / 24);\n  const day = (v % 31) + 1; v = Math.floor(v / 31);\n  const month = (v % 12) + 1; v = Math.floor(v / 12);\n  const year = v + 2000;\n  const p = (n) => String(n).padStart(2, \"0\");\n  return `${year}-${p(month)}-${p(day)} ${p(hour)}:${p(minute)}:${p(second)}`;\n}\n\n/** Inverse of decodeTime (used by the mock device in tests). */\nexport function encodeTime(ts) {\n  const m = /^(\\d{4})-(\\d{2})-(\\d{2}) (\\d{2}):(\\d{2}):(\\d{2})$/.exec(ts);\n  if (!m) throw new Error(`Bad timestamp ${ts}`);\n  const [y, mo, d, h, mi, s] = m.slice(1).map(Number);\n  return ((((y - 2000) * 12 * 31 + (mo - 1) * 31 + (d - 1)) * 24 + h) * 60 + mi) * 60 + s;\n}\n\n/**\n * Parses the attendance buffer. Record layout depends on firmware:\n *  40 bytes (TFT devices such as K40/K50), 16 bytes, or 8 bytes (old models).\n */\nexport function parseAttendance(buffer, recordCount) {\n  if (buffer.length < 4 || recordCount <= 0) return { recordSize: 0, records: [] };\n  const total = buffer.readUInt32LE(0);\n  const body = buffer.subarray(4, 4 + total);\n  const ratio = total / recordCount;\n  const recordSize = ratio === 8 ? 8 : ratio === 16 ? 16 : 40;\n\n  const records = [];\n  for (let off = 0; off + recordSize <= body.length; off += recordSize) {\n    const r = body.subarray(off, off + recordSize);\n    if (recordSize === 40) {\n      const uid = r.readUInt16LE(0);\n      const userId = r.subarray(2, 26).toString(\"latin1\").split(\"\\0\")[0].trim();\n      records.push({\n        user_id: userId || String(uid),\n        timestamp: decodeTime(r.readUInt32LE(27)),\n        state: r.readUInt8(31),\n        verify_mode: r.readUInt8(26),\n      });\n    } else if (recordSize === 16) {\n      records.push({\n        user_id: String(r.readUInt32LE(0)),\n        timestamp: decodeTime(r.readUInt32LE(4)),\n        state: r.readUInt8(9),\n        verify_mode: r.readUInt8(8),\n      });\n    } else {\n      records.push({\n        user_id: String(r.readUInt16LE(0)), // 8-byte format only stores the internal uid\n        timestamp: decodeTime(r.readUInt32LE(3)),\n        state: r.readUInt8(7),\n        verify_mode: r.readUInt8(2),\n      });\n    }\n  }\n  return { recordSize, records };\n}\n\n/**\n * Parses the user list. Only the user ID and name are kept; passwords and\n * card numbers stored on the machine are never read out of the buffer.\n * Record layout: 72 bytes (TFT devices such as K40/K50) or 28 bytes (old models).\n */\nexport function parseUsers(buffer, userCount) {\n  if (buffer.length < 4 || userCount <= 0) return { recordSize: 0, users: [] };\n  const total = buffer.readUInt32LE(0);\n  const body = buffer.subarray(4, 4 + total);\n  const recordSize = total / userCount === 28 ? 28 : 72;\n  const text = (b) => b.toString(\"utf8\").split(\"\\0\")[0].replace(/\\uFFFD/g, \"\").trim();\n\n  const users = [];\n  for (let off = 0; off + recordSize <= body.length; off += recordSize) {\n    const r = body.subarray(off, off + recordSize);\n    if (recordSize === 72) {\n      users.push({ uid: r.readUInt16LE(0), user_id: text(r.subarray(48, 72)) || String(r.readUInt16LE(0)), name: text(r.subarray(11, 35)) });\n    } else {\n      users.push({ uid: r.readUInt16LE(0), user_id: String(r.readUInt32LE(24)), name: text(r.subarray(8, 16)) });\n    }\n  }\n  return { recordSize, users };\n}\n",
 "src/zk/client.js": "// Read-only ZKTeco TCP client. Every outgoing command is checked against\n// READ_ONLY_COMMANDS, so this client cannot clear logs or change the machine.\nimport net from \"node:net\";\nimport {\n  CMD, READ_ONLY_COMMANDS, READ_ONLY_DATASETS, USHRT_MAX,\n  buildFrame, makeCommKey, parseFrames, parseAttendance, parseUsers, decodeTime,\n} from \"./protocol.js\";\n\nconst MAX_CHUNK = 0xffc0; // max bytes per READ_BUFFER request over TCP\n\nclass FrameReader {\n  constructor(socket) {\n    this.buf = Buffer.alloc(0);\n    this.frames = [];\n    this.waiters = [];\n    this.error = null;\n    socket.on(\"data\", (chunk) => {\n      this.buf = Buffer.concat([this.buf, chunk]);\n      try {\n        const { frames, rest } = parseFrames(this.buf);\n        this.buf = rest;\n        for (const f of frames) {\n          const w = this.waiters.shift();\n          if (w) w.resolve(f);\n          else this.frames.push(f);\n        }\n      } catch (err) {\n        this.fail(err);\n        socket.destroy();\n      }\n    });\n    socket.on(\"error\", (err) => this.fail(err));\n    socket.on(\"close\", () => this.fail(new Error(\"Connection closed by device\")));\n  }\n\n  fail(err) {\n    if (this.error) return;\n    this.error = err;\n    for (const w of this.waiters.splice(0)) w.reject(err);\n  }\n\n  next(timeoutMs) {\n    if (this.frames.length) return Promise.resolve(this.frames.shift());\n    if (this.error) return Promise.reject(this.error);\n    return new Promise((resolve, reject) => {\n      const w = {\n        resolve: (f) => { clearTimeout(timer); resolve(f); },\n        reject: (e) => { clearTimeout(timer); reject(e); },\n      };\n      const timer = setTimeout(() => {\n        const i = this.waiters.indexOf(w);\n        if (i >= 0) this.waiters.splice(i, 1);\n        reject(new Error(`Device did not respond within ${timeoutMs} ms`));\n      }, timeoutMs);\n      this.waiters.push(w);\n    });\n  }\n}\n\nexport class ZkClient {\n  constructor({ ip, port = 4370, commKey = 0, timeoutMs = 10000 }) {\n    this.ip = ip;\n    this.port = Number(port);\n    this.commKey = Number(commKey) || 0;\n    this.timeoutMs = Number(timeoutMs) || 10000;\n    this.socket = null;\n    this.reader = null;\n    this.sessionId = 0;\n    this.replyId = USHRT_MAX - 1;\n  }\n\n  async connect() {\n    this.socket = await new Promise((resolve, reject) => {\n      const s = net.createConnection({ host: this.ip, port: this.port });\n      const timer = setTimeout(() => {\n        s.destroy();\n        reject(new Error(`Cannot reach ${this.ip}:${this.port} (timeout after ${this.timeoutMs} ms). Check the IP, cable/Wi-Fi and that this PC is on the same network.`));\n      }, this.timeoutMs);\n      s.once(\"connect\", () => { clearTimeout(timer); resolve(s); });\n      s.once(\"error\", (err) => {\n        clearTimeout(timer);\n        reject(new Error(`Cannot connect to ${this.ip}:${this.port}: ${err.code ?? err.message}`));\n      });\n    });\n    this.socket.setNoDelay(true);\n    this.reader = new FrameReader(this.socket);\n\n    const res = await this.command(CMD.CONNECT);\n    this.sessionId = res.sessionId;\n    if (res.command === CMD.ACK_UNAUTH) {\n      const auth = await this.command(CMD.AUTH, makeCommKey(this.commKey, this.sessionId));\n      if (auth.command !== CMD.ACK_OK) {\n        throw new Error(\"Device rejected the comm key. Check Menu > COMM > Comm Key on the machine and the device settings in the dashboard.\");\n      }\n    } else if (res.command !== CMD.ACK_OK) {\n      throw new Error(`Device refused the connection (response ${res.command})`);\n    }\n  }\n\n  async command(cmd, data = Buffer.alloc(0)) {\n    if (!READ_ONLY_COMMANDS.has(cmd)) {\n      throw new Error(`Blocked: command ${cmd} is not on the read-only allowlist`);\n    }\n    if (!this.socket || !this.reader) throw new Error(\"Not connected\");\n    this.socket.write(buildFrame(cmd, this.sessionId, this.replyId, data));\n    const res = await this.reader.next(this.timeoutMs);\n    this.replyId = res.replyId;\n    return res;\n  }\n\n  async getSizes() {\n    const res = await this.command(CMD.GET_FREE_SIZES);\n    if (res.command !== CMD.ACK_OK || res.data.length < 80) {\n      throw new Error(`Could not read record counts (response ${res.command})`);\n    }\n    const f = (i) => res.data.readInt32LE(i * 4);\n    return { users: f(4), fingerprints: f(6), records: f(8), recordsCapacity: f(16) };\n  }\n\n  async getSerialNumber() {\n    const res = await this.command(CMD.OPTIONS_RRQ, Buffer.from(\"~SerialNumber\\0\", \"latin1\"));\n    if (res.command !== CMD.ACK_OK) return null;\n    const text = res.data.toString(\"latin1\").split(\"\\0\")[0];\n    const eq = text.indexOf(\"=\");\n    return eq >= 0 ? text.slice(eq + 1).trim() || null : null;\n  }\n\n  async getTime() {\n    const res = await this.command(CMD.GET_TIME);\n    if (res.command !== CMD.ACK_OK || res.data.length < 4) return null;\n    return decodeTime(res.data.readUInt32LE(0));\n  }\n\n  async readChunk(start, size) {\n    const req = Buffer.alloc(8);\n    req.writeInt32LE(start, 0);\n    req.writeInt32LE(size, 4);\n    const res = await this.command(CMD.READ_BUFFER, req);\n\n    if (res.command === CMD.DATA) return res.data;\n    if (res.command === CMD.PREPARE_DATA) {\n      const expected = res.data.readUInt32LE(0);\n      const parts = [];\n      let got = 0;\n      while (got < expected) {\n        const f = await this.reader.next(this.timeoutMs);\n        if (f.command !== CMD.DATA) throw new Error(`Unexpected packet ${f.command} while reading data`);\n        parts.push(f.data);\n        got += f.data.length;\n      }\n      const ack = await this.reader.next(this.timeoutMs);\n      if (ack.command !== CMD.ACK_OK) throw new Error(`Device did not confirm chunk (response ${ack.command})`);\n      return Buffer.concat(parts).subarray(0, expected);\n    }\n    throw new Error(`Device refused chunk read (response ${res.command})`);\n  }\n\n  async readWithBuffer(dataCommand, onProgress) {\n    if (!READ_ONLY_DATASETS.has(dataCommand)) {\n      throw new Error(`Blocked: dataset ${dataCommand} is not on the read-only allowlist`);\n    }\n    const req = Buffer.alloc(11);\n    req.writeInt8(1, 0);\n    req.writeInt16LE(dataCommand, 1);\n    req.writeInt32LE(READ_ONLY_DATASETS.get(dataCommand), 3);\n    req.writeInt32LE(0, 7);\n    const res = await this.command(CMD.PREPARE_BUFFER, req);\n\n    if (res.command === CMD.DATA) return res.data; // small dataset sent directly\n    if (res.command !== CMD.ACK_OK || res.data.length < 5) {\n      throw new Error(`Device does not support buffered reads (response ${res.command})`);\n    }\n\n    const size = res.data.readUInt32LE(1);\n    const parts = [];\n    let start = 0;\n    while (start < size) {\n      const len = Math.min(MAX_CHUNK, size - start);\n      parts.push(await this.readChunk(start, len));\n      start += len;\n      if (onProgress) onProgress(start, size);\n    }\n    await this.command(CMD.FREE_DATA);\n    return Buffer.concat(parts);\n  }\n\n  /** Reads every attendance record stored on the machine. Nothing is deleted. */\n  async getAttendance(onProgress, sizes) {\n    const s = sizes ?? (await this.getSizes());\n    if (s.records <= 0) return { sizes: s, recordSize: 0, records: [] };\n    const buffer = await this.readWithBuffer(CMD.ATTLOG_RRQ, onProgress);\n    const { recordSize, records } = parseAttendance(buffer, s.records);\n    return { sizes: s, recordSize, records };\n  }\n\n  /** Reads the user list (user ID + name only). */\n  async getUsers(sizes) {\n    const s = sizes ?? (await this.getSizes());\n    if (s.users <= 0) return [];\n    const buffer = await this.readWithBuffer(CMD.USERTEMP_RRQ);\n    return parseUsers(buffer, s.users).users;\n  }\n\n  async disconnect() {\n    if (!this.socket) return;\n    try {\n      if (!this.reader.error) {\n        this.socket.write(buildFrame(CMD.EXIT, this.sessionId, this.replyId));\n        await Promise.race([this.reader.next(2000), new Promise((r) => setTimeout(r, 2000))]).catch(() => {});\n      }\n    } finally {\n      this.socket.destroy();\n      this.socket = null;\n    }\n  }\n}\n\n/**\n * Connect, read everything we need, always disconnect.\n * The user list is optional: if the machine refuses it, attendance is still returned\n * (usersError explains why the names are missing).\n */\nexport async function readDevice(options, onProgress) {\n  const client = new ZkClient(options);\n  try {\n    await client.connect();\n    const serialNumber = await client.getSerialNumber();\n    const deviceTime = await client.getTime();\n    const sizes = await client.getSizes();\n\n    let users = [];\n    let usersError = null;\n    try {\n      users = await client.getUsers(sizes);\n    } catch (err) {\n      usersError = err.message;\n    }\n\n    const { recordSize, records } = await client.getAttendance(onProgress, sizes);\n\n    // Old 8-byte records only store the machine's internal number: map it to the user ID.\n    if (recordSize === 8 && users.length) {\n      const byUid = new Map(users.map((u) => [String(u.uid), u.user_id]));\n      for (const r of records) r.user_id = byUid.get(r.user_id) ?? r.user_id;\n    }\n\n    return {\n      serialNumber, deviceTime, sizes, recordSize, records,\n      users: users.map((u) => ({ user_id: u.user_id, name: u.name })),\n      usersError,\n    };\n  } finally {\n    await client.disconnect();\n  }\n}\n",
 "Install.cmd": "@echo off\r\nrem ZKT Connector - double-click to install or update (asks for administrator permission).\r\nif not exist \"%~dp0scripts\\install.ps1\" goto notextracted\r\nnet session >nul 2>&1\r\nif errorlevel 1 goto elevate\r\npowershell -NoProfile -ExecutionPolicy Bypass -File \"%~dp0scripts\\install.ps1\" & echo. & pause & exit /b\r\n\r\n:elevate\r\necho Asking for administrator permission...\r\npowershell -NoProfile -ExecutionPolicy Bypass -Command \"Start-Process -FilePath \\\"%~f0\\\" -Verb RunAs\"\r\nexit /b\r\n\r\n:notextracted\r\necho.\r\necho  Please extract the ZIP first:\r\necho    1. Right-click the downloaded ZIP file and choose \"Extract All...\"\r\necho    2. Open the extracted folder and double-click Install.cmd again.\r\necho.\r\npause\r\nexit /b 1\r\n",
 "Uninstall.cmd": "@echo off\r\nrem ZKT Connector - double-click to remove it from this PC (asks for administrator permission).\r\nif not exist \"%~dp0scripts\\uninstall.ps1\" goto missing\r\nnet session >nul 2>&1\r\nif errorlevel 1 goto elevate\r\npowershell -NoProfile -ExecutionPolicy Bypass -File \"%~dp0scripts\\uninstall.ps1\" & echo. & pause & exit /b\r\n\r\n:elevate\r\necho Asking for administrator permission...\r\npowershell -NoProfile -ExecutionPolicy Bypass -Command \"Start-Process -FilePath \\\"%~f0\\\" -Verb RunAs\"\r\nexit /b\r\n\r\n:missing\r\necho scripts\\uninstall.ps1 not found. Extract the ZIP first.\r\npause\r\nexit /b 1\r\n",
 "Test-Connection.cmd": "@echo off\r\nrem ZKT Connector - reads the attendance machine once and shows what it finds.\r\nrem Read-only: nothing is uploaded and nothing on the machine is changed.\r\nnet session >nul 2>&1\r\nif errorlevel 1 goto elevate\r\ncd /d \"%~dp0\"\r\nwhere node >nul 2>&1 && goto run\r\nif exist \"%ProgramFiles%\\nodejs\\node.exe\" set \"PATH=%ProgramFiles%\\nodejs;%PATH%\" & goto run\r\necho.\r\necho  Node.js is not installed yet. Run Install.cmd first (it installs Node.js).\r\necho.\r\npause\r\nexit /b 1\r\n\r\n:run\r\nnode src\\read-device.js & echo. & pause & exit /b\r\n\r\n:elevate\r\npowershell -NoProfile -ExecutionPolicy Bypass -Command \"Start-Process -FilePath \\\"%~f0\\\" -Verb RunAs\"\r\nexit /b\r\n",
 "README.txt": "ZKT Connector\r\n=============\r\n\r\nThe ZKT Connector reads attendance from your ZKTeco machine (K40 / K50) and\r\nsends it to your HR Attendance dashboard. It only READS the machine: it never\r\nchanges, clears or restarts it.\r\n\r\nThis download is already set up for your company. The file \".env\" contains\r\nyour connector token - keep this folder private.\r\n\r\n\r\nINSTALL (about 2 minutes)\r\n-------------------------\r\nUse a Windows PC that stays on and is on the same network as the machine.\r\n\r\n  1. Right-click the ZIP file and choose \"Extract All...\".\r\n  2. Open the extracted folder and double-click  Install.cmd\r\n  3. Click \"Yes\" when Windows asks for administrator permission.\r\n     If Windows shows \"Windows protected your PC\", click \"More info\"\r\n     and then \"Run anyway\".\r\n  4. Wait for \"INSTALLED\". Node.js is installed automatically if needed.\r\n\r\nThe connector then runs in the background and starts with Windows, even\r\nbefore anyone logs in. You can delete the extracted folder afterwards.\r\n\r\nInstalled to : C:\\ProgramData\\ZKTConnector\r\nLog file     : C:\\ProgramData\\ZKTConnector\\logs\\connector.log\r\n\r\n\r\nSTART, STOP AND STATUS\r\n----------------------\r\nAfter installing, use Start menu > ZKT Connector, or these files:\r\n  Start-Connector.cmd   start (or restart) the connector\r\n  Stop-Connector.cmd    stop it (it starts again when Windows restarts)\r\n  Connector-Status.cmd  is it running? shows the latest log lines\r\n\r\n\r\nCHECK THE MACHINE CONNECTION\r\n----------------------------\r\nDouble-click  Test-Connection.cmd  (in the extracted folder). It reads the\r\nmachine once and shows the serial number, number of punches and names.\r\n\r\n\r\nUPDATE\r\n------\r\nDownload the installer again from the dashboard and run Install.cmd.\r\nIt replaces the old version automatically.\r\n\r\n\r\nREMOVE\r\n------\r\nDouble-click  Uninstall.cmd\r\n\r\n\r\nTROUBLESHOOTING\r\n---------------\r\n- \"Cannot connect\": ping the machine's IP from this PC, and make sure this\r\n  PC is on the same network (for example 192.168.10.x).\r\n- Close ZKTime / ZKBio Time if it is open: the machine often allows only one\r\n  connection at a time.\r\n- \"Connector token is not valid\": download the installer again from the\r\n  dashboard and run Install.cmd.\r\n",
 "Start-Connector.cmd": "@echo off\r\nrem ZKT Connector - start (or restart) the connector in the background\r\nif not exist \"%~dp0scripts\\service.ps1\" goto missing\r\nnet session >nul 2>&1\r\nif errorlevel 1 goto elevate\r\npowershell -NoProfile -ExecutionPolicy Bypass -File \"%~dp0scripts\\service.ps1\" -Action Start & echo. & pause & exit /b\r\n\r\n:elevate\r\necho Asking for administrator permission...\r\npowershell -NoProfile -ExecutionPolicy Bypass -Command \"Start-Process -FilePath \\\"%~f0\\\" -Verb RunAs\"\r\nexit /b\r\n\r\n:missing\r\necho scripts\\service.ps1 not found. Extract the whole ZIP first, then try again.\r\npause\r\nexit /b 1\r\n",
 "Stop-Connector.cmd": "@echo off\r\nrem ZKT Connector - stop the connector (it starts again when Windows restarts)\r\nif not exist \"%~dp0scripts\\service.ps1\" goto missing\r\nnet session >nul 2>&1\r\nif errorlevel 1 goto elevate\r\npowershell -NoProfile -ExecutionPolicy Bypass -File \"%~dp0scripts\\service.ps1\" -Action Stop & echo. & pause & exit /b\r\n\r\n:elevate\r\necho Asking for administrator permission...\r\npowershell -NoProfile -ExecutionPolicy Bypass -Command \"Start-Process -FilePath \\\"%~f0\\\" -Verb RunAs\"\r\nexit /b\r\n\r\n:missing\r\necho scripts\\service.ps1 not found. Extract the whole ZIP first, then try again.\r\npause\r\nexit /b 1\r\n",
 "Connector-Status.cmd": "@echo off\r\nrem ZKT Connector - show whether the connector is running and its latest log lines\r\nif not exist \"%~dp0scripts\\service.ps1\" goto missing\r\nnet session >nul 2>&1\r\nif errorlevel 1 goto elevate\r\npowershell -NoProfile -ExecutionPolicy Bypass -File \"%~dp0scripts\\service.ps1\" -Action Status & echo. & pause & exit /b\r\n\r\n:elevate\r\necho Asking for administrator permission...\r\npowershell -NoProfile -ExecutionPolicy Bypass -Command \"Start-Process -FilePath \\\"%~f0\\\" -Verb RunAs\"\r\nexit /b\r\n\r\n:missing\r\necho scripts\\service.ps1 not found. Extract the whole ZIP first, then try again.\r\npause\r\nexit /b 1\r\n",
 "scripts/install.ps1": "# ZKT Connector installer. Started by Install.cmd (as administrator).\r\n# Installs Node.js if needed, copies the connector to C:\\ProgramData\\ZKTConnector,\r\n# and registers a Windows task that runs it at start-up (as SYSTEM) and keeps it running.\r\n$ErrorActionPreference = \"Stop\"\r\n$TaskName = \"ZKT Connector\"\r\n$Dest     = Join-Path $env:ProgramData \"ZKTConnector\"\r\n$Source   = (Resolve-Path (Join-Path $PSScriptRoot \"..\")).Path\r\n\r\nfunction Step([string]$Text) { Write-Host \"\"; Write-Host \"==> $Text\" -ForegroundColor Cyan }\r\nfunction Fail([string]$Text) {\r\n    Write-Host \"\"\r\n    Write-Host \"INSTALL FAILED: $Text\" -ForegroundColor Red\r\n    exit 1\r\n}\r\n\r\nfunction Find-Node {\r\n    $cmd = Get-Command node.exe -ErrorAction SilentlyContinue\r\n    if ($cmd) { return $cmd.Source }\r\n    foreach ($p in @(\"$env:ProgramFiles\\nodejs\\node.exe\", \"${env:ProgramFiles(x86)}\\nodejs\\node.exe\")) {\r\n        if ($p -and (Test-Path $p)) { return $p }\r\n    }\r\n    return $null\r\n}\r\n\r\n# Stops connector processes started from any of the given folders (never anything else).\r\nfunction Stop-ConnectorProcesses([string[]]$Dirs) {\r\n    $procs = Get-CimInstance Win32_Process -Filter \"Name='node.exe' OR Name='cmd.exe'\" -ErrorAction SilentlyContinue\r\n    foreach ($p in $procs) {\r\n        $cl = [string]$p.CommandLine\r\n        if (-not $cl) { continue }\r\n        $isConnector = ($cl.IndexOf(\"run-connector.cmd\", [StringComparison]::OrdinalIgnoreCase) -ge 0) -or\r\n                       ($cl.IndexOf(\"src\\index.js\", [StringComparison]::OrdinalIgnoreCase) -ge 0)\r\n        if (-not $isConnector) { continue }\r\n        foreach ($d in $Dirs) {\r\n            if ($d -and $cl.IndexOf($d, [StringComparison]::OrdinalIgnoreCase) -ge 0) {\r\n                Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue\r\n                break\r\n            }\r\n        }\r\n    }\r\n}\r\n\r\ntry {\r\n    $version = (Get-Content (Join-Path $Source \"package.json\") -Raw | ConvertFrom-Json).version\r\n    Write-Host \"ZKT Connector $version - setup\" -ForegroundColor White\r\n\r\n    $me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())\r\n    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {\r\n        Fail \"Administrator permission is needed. Double-click Install.cmd and click Yes.\"\r\n    }\r\n    if (-not (Test-Path (Join-Path $Source \".env\"))) {\r\n        Fail \"The settings file (.env) is missing. Download the installer again from the dashboard.\"\r\n    }\r\n    if ($Source.TrimEnd(\"\\\") -ieq $Dest.TrimEnd(\"\\\")) {\r\n        Fail \"Run Install.cmd from the extracted download folder, not from $Dest.\"\r\n    }\r\n\r\n    # ------------------------------------------------------------ Node.js\r\n    Step \"Checking Node.js\"\r\n    $node = Find-Node\r\n    if (-not $node) {\r\n        if (Get-Command winget.exe -ErrorAction SilentlyContinue) {\r\n            Write-Host \"Node.js not found. Installing Node.js LTS (this can take a few minutes)...\"\r\n            & winget.exe install -e --id OpenJS.NodeJS.LTS --scope machine --silent --accept-package-agreements --accept-source-agreements | Out-Host\r\n            $node = Find-Node\r\n        }\r\n    }\r\n    if (-not $node) {\r\n        Start-Process \"https://nodejs.org/en/download\"\r\n        Fail \"Node.js is required. Install the LTS version from nodejs.org (the page has been opened), then run Install.cmd again.\"\r\n    }\r\n    $nodeVersion = (& $node -v).Trim()\r\n    $major = [int](($nodeVersion.TrimStart(\"v\")).Split(\".\")[0])\r\n    if ($major -lt 18) {\r\n        Start-Process \"https://nodejs.org/en/download\"\r\n        Fail \"Node.js $nodeVersion is too old (18 or newer is needed). Install the LTS version from nodejs.org, then run Install.cmd again.\"\r\n    }\r\n    Write-Host \"Node.js $nodeVersion at $node\"\r\n\r\n    # ------------------------------------------------------------ stop the previous version\r\n    Step \"Stopping any previous version\"\r\n    $dirs = @($Dest)\r\n    $old = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue\r\n    if ($old) {\r\n        foreach ($a in $old.Actions) { if ($a.WorkingDirectory) { $dirs += $a.WorkingDirectory } }\r\n        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue\r\n        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false\r\n        Write-Host \"Removed the previous start-up task.\"\r\n    }\r\n    Stop-ConnectorProcesses $dirs\r\n    Start-Sleep -Seconds 2\r\n\r\n    # ------------------------------------------------------------ copy files\r\n    Step \"Copying files to $Dest\"\r\n    New-Item -ItemType Directory -Force -Path $Dest | Out-Null\r\n    foreach ($sub in @(\"src\", \"scripts\")) {\r\n        $p = Join-Path $Dest $sub\r\n        if (Test-Path $p) { Remove-Item $p -Recurse -Force }\r\n    }\r\n    Copy-Item (Join-Path $Source \"src\") (Join-Path $Dest \"src\") -Recurse -Force\r\n    New-Item -ItemType Directory -Force -Path (Join-Path $Dest \"scripts\") | Out-Null\r\n    foreach ($f in @(\"uninstall.ps1\", \"service.ps1\")) {\r\n        Copy-Item (Join-Path $Source \"scripts\\$f\") (Join-Path $Dest \"scripts\\$f\") -Force\r\n    }\r\n    foreach ($f in @(\"package.json\", \".env\", \"Uninstall.cmd\", \"Test-Connection.cmd\", \"README.txt\",\r\n                     \"Start-Connector.cmd\", \"Stop-Connector.cmd\", \"Connector-Status.cmd\")) {\r\n        Copy-Item (Join-Path $Source $f) (Join-Path $Dest $f) -Force\r\n    }\r\n    Get-ChildItem $Dest -Recurse -File | Unblock-File -ErrorAction SilentlyContinue\r\n\r\n    # The .env file holds the connector token: only administrators and SYSTEM may read this folder.\r\n    & icacls.exe $Dest /inheritance:r /grant:r \"*S-1-5-32-544:(OI)(CI)F\" \"*S-1-5-18:(OI)(CI)F\" /T /Q | Out-Null\r\n\r\n    $logs    = Join-Path $Dest \"logs\"\r\n    $logFile = Join-Path $logs \"connector.log\"\r\n    $script  = Join-Path $Dest \"src\\index.js\"\r\n    $cmdPath = Join-Path $Dest \"run-connector.cmd\"\r\n    New-Item -ItemType Directory -Force -Path $logs | Out-Null\r\n\r\n    # Runs the connector, appends to logs\\connector.log (kept under ~5 MB), restarts 15 s after any exit.\r\n    $wrapper = @\"\r\n@echo off\r\nrem Generated by the ZKT Connector installer - run Install.cmd again instead of editing.\r\ncd /d \"$Dest\"\r\n:loop\r\nfor %%F in (\"$logFile\") do if %%~zF GTR 5000000 move /y \"$logFile\" \"$logFile.old\" >nul\r\necho ===== %date% %time% starting connector >> \"$logFile\"\r\n\"$node\" \"$script\" >> \"$logFile\" 2>&1\r\nping -n 16 127.0.0.1 >nul\r\ngoto loop\r\n\"@\r\n    [System.IO.File]::WriteAllText($cmdPath, ($wrapper -replace \"`r?`n\", \"`r`n\"), [System.Text.Encoding]::ASCII)\r\n\r\n    # ------------------------------------------------------------ start-up task\r\n    Step \"Registering the start-up task\"\r\n    $action    = New-ScheduledTaskAction -Execute \"cmd.exe\" -Argument \"/c `\"$cmdPath`\"\" -WorkingDirectory $Dest\r\n    $trigger   = New-ScheduledTaskTrigger -AtStartup\r\n    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `\r\n                   -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `\r\n                   -MultipleInstances IgnoreNew\r\n    $principal = New-ScheduledTaskPrincipal -UserId \"SYSTEM\" -LogonType ServiceAccount -RunLevel Highest\r\n    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `\r\n        -Description \"Imports attendance from the ZKTeco machine into HR Attendance ($Dest)\" -Force | Out-Null\r\n\r\n    # ------------------------------------------------------------ Start Menu shortcuts (all users)\r\n    $menu = Join-Path $env:ProgramData \"Microsoft\\Windows\\Start Menu\\Programs\\ZKT Connector\"\r\n    if (Test-Path $menu) { Remove-Item $menu -Recurse -Force }\r\n    New-Item -ItemType Directory -Force -Path $menu | Out-Null\r\n    $shell = New-Object -ComObject WScript.Shell\r\n    foreach ($s in @(\r\n        @(\"Start ZKT Connector\", \"Start-Connector.cmd\"),\r\n        @(\"Stop ZKT Connector\", \"Stop-Connector.cmd\"),\r\n        @(\"ZKT Connector status\", \"Connector-Status.cmd\"),\r\n        @(\"Test machine connection\", \"Test-Connection.cmd\"),\r\n        @(\"Uninstall ZKT Connector\", \"Uninstall.cmd\"))) {\r\n        $lnk = $shell.CreateShortcut((Join-Path $menu ($s[0] + \".lnk\")))\r\n        $lnk.TargetPath = Join-Path $Dest $s[1]\r\n        $lnk.WorkingDirectory = $Dest\r\n        $lnk.Save()\r\n    }\r\n    Write-Host \"Added Start Menu shortcuts: Start menu > ZKT Connector\"\r\n\r\n    $startedAt = (Get-Item $logFile -ErrorAction SilentlyContinue).Length\r\n    if (-not $startedAt) { $startedAt = 0 }\r\n    Start-ScheduledTask -TaskName $TaskName\r\n\r\n    # ------------------------------------------------------------ check it connected\r\n    Step \"Checking the connection to the server\"\r\n    $ok = $false\r\n    $newLines = @()\r\n    for ($i = 0; $i -lt 30 -and -not $ok; $i++) {\r\n        Start-Sleep -Seconds 1\r\n        if (Test-Path $logFile) {\r\n            $fs = [System.IO.File]::Open($logFile, \"Open\", \"Read\", \"ReadWrite\")\r\n            try {\r\n                [void]$fs.Seek($startedAt, \"Begin\")\r\n                $text = (New-Object System.IO.StreamReader($fs)).ReadToEnd()\r\n            } finally { $fs.Close() }\r\n            $newLines = $text -split \"`r?`n\" | Where-Object { $_ }\r\n            if ($text -match \"Connected to \") { $ok = $true }\r\n            elseif ($text -match \"ERROR\") { break }\r\n        }\r\n    }\r\n    $newLines | Select-Object -Last 8 | ForEach-Object { Write-Host \"  $_\" }\r\n\r\n    Write-Host \"\"\r\n    if ($ok) {\r\n        Write-Host \"INSTALLED. ZKT Connector $version is running and starts automatically with Windows.\" -ForegroundColor Green\r\n        Write-Host \"Check the dashboard: the connector shows a 'Last seen' time and version $version.\"\r\n    } else {\r\n        Write-Host \"Installed, but the connector has not connected to the server yet.\" -ForegroundColor Yellow\r\n        Write-Host \"Check the internet connection and the log: $logFile\"\r\n    }\r\n    Write-Host \"Log file : $logFile\"\r\n    Write-Host \"Start / stop / status: Start menu > ZKT Connector, or the Start-Connector, Stop-Connector\"\r\n    Write-Host \"                       and Connector-Status files in $Dest\"\r\n    Write-Host \"Remove   : double-click Uninstall.cmd\"\r\n}\r\ncatch {\r\n    Fail $_.Exception.Message\r\n}\r\n",
 "scripts/uninstall.ps1": "# ZKT Connector uninstaller. Started by Uninstall.cmd (as administrator).\r\n$ErrorActionPreference = \"Stop\"\r\n$TaskName = \"ZKT Connector\"\r\n$Dest     = Join-Path $env:ProgramData \"ZKTConnector\"\r\n\r\ntry {\r\n    $me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())\r\n    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {\r\n        throw \"Administrator permission is needed. Double-click Uninstall.cmd and click Yes.\"\r\n    }\r\n\r\n    $dirs = @($Dest)\r\n    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue\r\n    if ($task) {\r\n        foreach ($a in $task.Actions) { if ($a.WorkingDirectory) { $dirs += $a.WorkingDirectory } }\r\n        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue\r\n        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false\r\n        Write-Host \"Start-up task removed.\"\r\n    } else {\r\n        Write-Host \"Start-up task was not installed.\"\r\n    }\r\n\r\n    $procs = Get-CimInstance Win32_Process -Filter \"Name='node.exe' OR Name='cmd.exe'\" -ErrorAction SilentlyContinue\r\n    foreach ($p in $procs) {\r\n        $cl = [string]$p.CommandLine\r\n        if (-not $cl) { continue }\r\n        $isConnector = ($cl.IndexOf(\"run-connector.cmd\", [StringComparison]::OrdinalIgnoreCase) -ge 0) -or\r\n                       ($cl.IndexOf(\"src\\index.js\", [StringComparison]::OrdinalIgnoreCase) -ge 0)\r\n        if (-not $isConnector) { continue }\r\n        foreach ($d in $dirs) {\r\n            if ($d -and $cl.IndexOf($d, [StringComparison]::OrdinalIgnoreCase) -ge 0) {\r\n                Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue\r\n                Write-Host \"Stopped connector process $($p.ProcessId).\"\r\n                break\r\n            }\r\n        }\r\n    }\r\n\r\n    $menu = Join-Path $env:ProgramData \"Microsoft\\Windows\\Start Menu\\Programs\\ZKT Connector\"\r\n    if (Test-Path $menu) { Remove-Item $menu -Recurse -Force; Write-Host \"Start Menu shortcuts removed.\" }\r\n\r\n    if (Test-Path $Dest) {\r\n        # Delete a few seconds later, so this window (which may run from that folder) can finish.\r\n        Start-Process -FilePath \"cmd.exe\" -ArgumentList \"/c ping -n 4 127.0.0.1 >nul & rmdir /s /q `\"$Dest`\"\" -WindowStyle Hidden\r\n        Write-Host \"Removing $Dest ...\"\r\n    }\r\n    Write-Host \"\"\r\n    Write-Host \"ZKT Connector has been removed from this PC.\" -ForegroundColor Green\r\n    Write-Host \"To stop it being used anywhere, also click Revoke on the connector in the dashboard.\"\r\n}\r\ncatch {\r\n    Write-Host \"\"\r\n    Write-Host \"UNINSTALL FAILED: $($_.Exception.Message)\" -ForegroundColor Red\r\n    exit 1\r\n}\r\n",
 "scripts/service.ps1": "# ZKT Connector - start, stop or check the background connector.\r\n# Used by Start-Connector.cmd, Stop-Connector.cmd and Connector-Status.cmd (as administrator).\r\nparam([ValidateSet(\"Start\", \"Stop\", \"Status\")][string]$Action = \"Status\")\r\n$ErrorActionPreference = \"Stop\"\r\n$TaskName = \"ZKT Connector\"\r\n$Dest     = Join-Path $env:ProgramData \"ZKTConnector\"\r\n$LogFile  = Join-Path $Dest \"logs\\connector.log\"\r\n\r\nfunction Show-Log([int]$Lines) {\r\n    if (Test-Path $LogFile) {\r\n        Get-Content $LogFile -Tail $Lines | ForEach-Object { Write-Host \"  $_\" }\r\n    } else {\r\n        Write-Host \"  (no log yet)\"\r\n    }\r\n}\r\n\r\nfunction Get-ConnectorProcesses {\r\n    $procs = Get-CimInstance Win32_Process -Filter \"Name='node.exe' OR Name='cmd.exe'\" -ErrorAction SilentlyContinue\r\n    foreach ($p in $procs) {\r\n        $cl = [string]$p.CommandLine\r\n        if (-not $cl) { continue }\r\n        if ($cl.IndexOf($Dest, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }\r\n        if (($cl.IndexOf(\"run-connector.cmd\", [StringComparison]::OrdinalIgnoreCase) -ge 0) -or\r\n            ($cl.IndexOf(\"src\\index.js\", [StringComparison]::OrdinalIgnoreCase) -ge 0)) { $p }\r\n    }\r\n}\r\n\r\nfunction Stop-Connector {\r\n    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue\r\n    foreach ($p in @(Get-ConnectorProcesses)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }\r\n    Start-Sleep -Seconds 1\r\n}\r\n\r\nfunction Read-NewLog([long]$From) {\r\n    if (-not (Test-Path $LogFile)) { return \"\" }\r\n    $fs = [System.IO.File]::Open($LogFile, \"Open\", \"Read\", \"ReadWrite\")\r\n    try {\r\n        if ($fs.Length -lt $From) { $From = 0 }\r\n        [void]$fs.Seek($From, \"Begin\")\r\n        return (New-Object System.IO.StreamReader($fs)).ReadToEnd()\r\n    } finally { $fs.Close() }\r\n}\r\n\r\ntry {\r\n    $me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())\r\n    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {\r\n        throw \"Administrator permission is needed. Double-click the .cmd file again and click Yes.\"\r\n    }\r\n    if (-not (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)) {\r\n        throw \"The ZKT Connector is not installed on this PC. Run Install.cmd first.\"\r\n    }\r\n\r\n    switch ($Action) {\r\n        \"Start\" {\r\n            Write-Host \"Starting the ZKT Connector...\" -ForegroundColor Cyan\r\n            Stop-Connector   # a clean restart if it was already running or stuck\r\n            $from = 0\r\n            if (Test-Path $LogFile) { $from = (Get-Item $LogFile).Length }\r\n            Start-ScheduledTask -TaskName $TaskName\r\n            $ok = $false; $failed = $false; $text = \"\"\r\n            for ($i = 0; $i -lt 30 -and -not $ok -and -not $failed; $i++) {\r\n                Start-Sleep -Seconds 1\r\n                $text = Read-NewLog $from\r\n                if ($text -match \"Connected to \") { $ok = $true }\r\n                elseif ($text -match \"ERROR\") { $failed = $true }\r\n            }\r\n            ($text -split \"`r?`n\" | Where-Object { $_ } | Select-Object -Last 8) | ForEach-Object { Write-Host \"  $_\" }\r\n            Write-Host \"\"\r\n            if ($ok) {\r\n                Write-Host \"RUNNING. The connector is connected and waiting for syncs.\" -ForegroundColor Green\r\n            } elseif ($failed) {\r\n                Write-Host \"The connector started but reported an error (see above).\" -ForegroundColor Red\r\n                Write-Host \"It retries by itself. Check the internet connection, or download the installer again if the token is not valid.\"\r\n            } else {\r\n                Write-Host \"Started, but it has not connected to the server yet. It keeps retrying by itself.\" -ForegroundColor Yellow\r\n            }\r\n        }\r\n        \"Stop\" {\r\n            Stop-Connector\r\n            if (@(Get-ConnectorProcesses).Count) {\r\n                Write-Host \"Some connector processes are still running. Try again in a few seconds.\" -ForegroundColor Yellow\r\n            } else {\r\n                Write-Host \"STOPPED. Attendance is not synced until you run Start-Connector.cmd.\" -ForegroundColor Yellow\r\n                Write-Host \"It also starts again automatically when Windows restarts.\"\r\n            }\r\n        }\r\n        \"Status\" {\r\n            $node = @(Get-ConnectorProcesses | Where-Object { $_.Name -eq \"node.exe\" })\r\n            $info = Get-ScheduledTaskInfo -TaskName $TaskName\r\n            if ($node.Count) {\r\n                $since = $node[0].CreationDate\r\n                Write-Host \"RUNNING since $since\" -ForegroundColor Green\r\n            } else {\r\n                Write-Host \"NOT RUNNING. Double-click Start-Connector.cmd to start it.\" -ForegroundColor Red\r\n            }\r\n            Write-Host \"Start-up task last run: $($info.LastRunTime)\"\r\n            Write-Host \"Folder   : $Dest\"\r\n            Write-Host \"Log file : $LogFile\"\r\n            Write-Host \"\"\r\n            Write-Host \"Latest log lines:\"\r\n            Show-Log 15\r\n        }\r\n    }\r\n}\r\ncatch {\r\n    Write-Host \"\"\r\n    Write-Host \"ERROR: $($_.Exception.Message)\" -ForegroundColor Red\r\n    exit 1\r\n}\r\n",
 "package.json": "{\n  \"name\": \"zkt-connector\",\n  \"version\": \"0.9.0\",\n  \"private\": true,\n  \"type\": \"module\"\n}\n"
};
'@

# ---------------------------------------------------------------- worker/src/env.ts
Write-File "worker/src/env.ts" @'
export interface Env {
  DB: D1Database;
  /** Optional. When set, sign-up requires this code (set with: wrangler secret put SIGNUP_CODE). */
  SIGNUP_CODE?: string;
}

export const VERSION = "0.11.0-phase11";

/** Number of files in worker/migrations. The health check reports "degraded" until all are applied. */
export const EXPECTED_MIGRATIONS = 6;
'@

# ---------------------------------------------------------------- worker/src/lib/jobs.ts
Write-File "worker/src/lib/jobs.ts" @'
// Sync-job housekeeping: a sync never stays "Waiting" or "Syncing" forever.
import type { Env } from "../env";

/** A manual sync not picked up within this time fails (connector PC is probably off). */
export const PENDING_MANUAL_MINUTES = 10;
/** Scheduled syncs (for the 2-day report) wait as long as the report does. */
export const PENDING_SCHEDULED_MINUTES = 180;
/** A running sync whose connector has not reported for this long fails. */
export const SILENT_RUNNING_MINUTES = 3;

function minutesAgo(now: Date, m: number): string {
  return new Date(now.getTime() - m * 60_000).toISOString();
}

/** Marks stuck jobs as failed with a clear reason. Optional scope: one company or one connector. */
export async function expireStaleJobs(env: Env, scope: { companyId?: string; connectorId?: string } = {}, now = new Date()) {
  const ts = now.toISOString();
  const where = scope.connectorId
    ? " AND device_id IN (SELECT id FROM devices WHERE connector_id = ?)"
    : scope.companyId ? " AND company_id = ?" : "";
  const extra = scope.connectorId ?? scope.companyId;
  const bind = (...v: unknown[]) => (extra ? [...v, extra] : v);

  await env.DB.batch([
    env.DB.prepare(
      `UPDATE sync_jobs SET status = 'failed', finished_at = ?, progress_msg = NULL,
              error_message = 'The connector did not start this sync within ${PENDING_MANUAL_MINUTES} minutes. Check that the connector PC is on and connected to the internet.'
        WHERE status = 'pending' AND trigger_type = 'manual' AND requested_at < ?${where}`,
    ).bind(...bind(ts, minutesAgo(now, PENDING_MANUAL_MINUTES))),
    env.DB.prepare(
      `UPDATE sync_jobs SET status = 'failed', finished_at = ?, progress_msg = NULL,
              error_message = 'The connector did not start this scheduled sync within ${PENDING_SCHEDULED_MINUTES / 60} hours. Check that the connector PC is on.'
        WHERE status = 'pending' AND trigger_type = 'scheduled' AND requested_at < ?${where}`,
    ).bind(...bind(ts, minutesAgo(now, PENDING_SCHEDULED_MINUTES))),
    env.DB.prepare(
      `UPDATE sync_jobs SET status = 'failed', finished_at = ?, progress_msg = NULL,
              error_message = 'The connector stopped responding during this sync (no update for ${SILENT_RUNNING_MINUTES} minutes). It may have been closed or lost its internet connection.'
        WHERE status = 'running' AND COALESCE(heartbeat_at, started_at) < ?${where}`,
    ).bind(...bind(ts, minutesAgo(now, SILENT_RUNNING_MINUTES))),
  ]);
}
'@

# ---------------------------------------------------------------- worker/src/scheduler.ts
Write-File "worker/src/scheduler.ts" @'
// Runs every hour (Cloudflare cron). For each company:
//  1. A "collecting" report becomes "ready" once its sync jobs have finished (or after 3 hours).
//  2. When a report period has ended (default: every 2 days, after 01:00 local time),
//     create the report and a scheduled sync job for every active machine.
import type { Env } from "./env";
import { localNow, nextPeriod } from "./lib/dates";
import { attendanceStats } from "./report";
import { expireStaleJobs } from "./lib/jobs";

const MAX_COLLECT_MINUTES = 180;

interface CompanyRow {
  id: string;
  timezone: string;
  report_every_days: number;
  report_hour: number;
}

interface ReportRow {
  id: string;
  company_id: string;
  period_start: string;
  period_end: string;
  created_at: string;
}

export async function runScheduler(env: Env, now = new Date()): Promise<void> {
  await expireStaleJobs(env, {}, now);
  const { results } = await env.DB.prepare(
    "SELECT id, timezone, report_every_days, report_hour FROM companies WHERE status = 'active'",
  ).all<CompanyRow>();

  for (const company of results ?? []) {
    try {
      await finishCollecting(env, company, now);
      await startDuePeriod(env, company, now);
    } catch (err) {
      console.error(`scheduler: company ${company.id}: ${String(err)}`);
    }
  }
}

async function finishCollecting(env: Env, company: CompanyRow, now: Date): Promise<void> {
  const { results } = await env.DB.prepare(
    "SELECT id FROM reports WHERE company_id = ? AND status = 'collecting'",
  ).bind(company.id).all<{ id: string }>();
  for (const r of results ?? []) await finalizeReportIfDone(env, r.id, now);
}

/**
 * Marks a collecting report "ready" when none of its sync jobs are still open,
 * or when it has waited MAX_COLLECT_MINUTES. Called hourly and whenever a linked job completes.
 */
export async function finalizeReportIfDone(env: Env, reportId: string, now = new Date()): Promise<boolean> {
  const report = await env.DB.prepare(
    "SELECT id, company_id, period_start, period_end, created_at FROM reports WHERE id = ? AND status = 'collecting'",
  ).bind(reportId).first<ReportRow>();
  if (!report) return false;

  const jobs = await env.DB.prepare(
    `SELECT SUM(CASE WHEN status IN ('pending','running') THEN 1 ELSE 0 END) AS open,
            SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END) AS ok,
            SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS failed
       FROM sync_jobs WHERE report_id = ?`,
  ).bind(report.id).first<{ open: number | null; ok: number | null; failed: number | null }>();

  const open = jobs?.open ?? 0;
  const minutes = (now.getTime() - Date.parse(report.created_at)) / 60000;
  if (open > 0 && minutes < MAX_COLLECT_MINUTES) return false;

  const notes: string[] = [];
  if (jobs?.failed) notes.push(`${jobs.failed} machine sync(s) failed`);
  if (open > 0) notes.push(`${open} machine(s) had not synced after ${MAX_COLLECT_MINUTES / 60} hours - is the connector PC on?`);
  const stats = await attendanceStats(env, report.company_id, report.period_start, report.period_end);

  const res = await env.DB.prepare(
    `UPDATE reports
        SET status = 'ready', ready_at = ?, devices_synced = ?, punch_count = ?, employee_count = ?, note = ?
      WHERE id = ? AND status = 'collecting'`,
  ).bind(now.toISOString(), jobs?.ok ?? 0, stats.punches, stats.employees, notes.join("; ") || null, report.id).run();
  return (res.meta.changes ?? 0) > 0;
}

async function startDuePeriod(env: Env, company: CompanyRow, now: Date): Promise<void> {
  // Only one report collects at a time.
  const collecting = await env.DB.prepare(
    "SELECT 1 FROM reports WHERE company_id = ? AND status = 'collecting' LIMIT 1",
  ).bind(company.id).first();
  if (collecting) return;

  const local = localNow(now, company.timezone);
  const last = await env.DB.prepare(
    "SELECT period_end FROM reports WHERE company_id = ? ORDER BY period_end DESC LIMIT 1",
  ).bind(company.id).first<{ period_end: string }>();
  const period = nextPeriod(last?.period_end ?? null, local.date, company.report_every_days);

  // Due once the period's last day is over and it's past the report hour.
  if (local.date < period.dueDate) return;
  if (local.date === period.dueDate && local.hour < company.report_hour) return;

  const reportId = crypto.randomUUID();
  const inserted = await env.DB.prepare(
    "INSERT OR IGNORE INTO reports (id, company_id, period_start, period_end, created_at) VALUES (?, ?, ?, ?, ?)",
  ).bind(reportId, company.id, period.start, period.end, now.toISOString()).run();
  if (!inserted.meta.changes) return;

  const { results: devices } = await env.DB.prepare(
    `SELECT d.id FROM devices d JOIN connectors c ON c.id = d.connector_id
      WHERE d.company_id = ? AND d.is_active = 1 AND c.is_active = 1`,
  ).bind(company.id).all<{ id: string }>();

  const statements: D1PreparedStatement[] = [
    env.DB.prepare("UPDATE reports SET devices_total = ? WHERE id = ?").bind(devices?.length ?? 0, reportId),
  ];
  for (const d of devices ?? []) {
    const open = await env.DB.prepare(
      "SELECT id FROM sync_jobs WHERE device_id = ? AND status IN ('pending','running') LIMIT 1",
    ).bind(d.id).first<{ id: string }>();
    if (open) {
      statements.push(env.DB.prepare("UPDATE sync_jobs SET report_id = ? WHERE id = ?").bind(reportId, open.id));
    } else {
      statements.push(
        env.DB.prepare(
          `INSERT INTO sync_jobs (id, company_id, device_id, trigger_type, status, report_id, requested_at)
           VALUES (?, ?, ?, 'scheduled', 'pending', ?, ?)`,
        ).bind(crypto.randomUUID(), company.id, d.id, reportId, now.toISOString()),
      );
    }
  }
  await env.DB.batch(statements);

  // No machines: nothing to wait for.
  if (!devices?.length) await finalizeReportIfDone(env, reportId, now);
}
'@

# ---------------------------------------------------------------- worker/src/routes/connector.ts
Write-File "worker/src/routes/connector.ts" @'
// ZKT Connector API. Authenticated with "Authorization: Bearer zkc_..." (not a browser session).
// A connector can only see devices assigned to it, and jobs of those devices.
import type { Env } from "../env";
import { HttpError, json, readJson } from "../lib/http";
import { sha256Hex } from "../lib/crypto";
import { finalizeReportIfDone } from "../scheduler";
import { expireStaleJobs } from "../lib/jobs";

const MAX_RECORDS_PER_UPLOAD = 1000;
const MAX_WAIT_SECONDS = 25;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const TOKEN_RE = /^Bearer\s+(zkc_[A-Za-z0-9_-]{20,})$/;
const TIMESTAMP_RE = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})$/;

interface ConnectorContext {
  connectorId: string;
  connectorName: string;
  companyId: string;
  companyTimezone: string;
}

async function requireConnector(request: Request, env: Env): Promise<ConnectorContext> {
  const match = TOKEN_RE.exec(request.headers.get("authorization") ?? "");
  if (!match) throw new HttpError(401, "Missing or invalid connector token");

  const row = await env.DB.prepare(
    `SELECT c.id, c.name, c.company_id, co.timezone
       FROM connectors c JOIN companies co ON co.id = c.company_id
      WHERE c.token_hash = ? AND c.is_active = 1 AND co.status = 'active'`,
  ).bind(await sha256Hex(match[1])).first<{ id: string; name: string; company_id: string; timezone: string }>();
  if (!row) throw new HttpError(401, "Connector token is not valid or has been revoked");

  const version = (request.headers.get("x-connector-version") ?? "").trim().slice(0, 40) || null;
  await env.DB.prepare("UPDATE connectors SET last_seen_at = ?, version = COALESCE(?, version) WHERE id = ?")
    .bind(new Date().toISOString(), version, row.id).run();

  return { connectorId: row.id, connectorName: row.name, companyId: row.company_id, companyTimezone: row.timezone };
}

/** Loads a job only if it belongs to one of this connector's devices. */
async function loadOwnJob(env: Env, ctx: ConnectorContext, jobId: string) {
  const job = await env.DB.prepare(
    `SELECT j.id, j.status, j.device_id, j.company_id, j.report_id
       FROM sync_jobs j JOIN devices d ON d.id = j.device_id
      WHERE j.id = ? AND j.company_id = ? AND d.connector_id = ?`,
  ).bind(jobId, ctx.companyId, ctx.connectorId)
    .first<{ id: string; status: string; device_id: string; company_id: string; report_id: string | null }>();
  if (!job) throw new HttpError(404, "Job not found");
  return job;
}

// ------------------------------------------------------------------ GET /api/connector/config
export async function connectorConfig(request: Request, env: Env): Promise<Response> {
  const ctx = await requireConnector(request, env);
  const { results } = await env.DB.prepare(
    `SELECT id, name, model, ip_address, port, comm_key, serial_number, last_sync_at
       FROM devices
      WHERE connector_id = ? AND company_id = ? AND is_active = 1
      ORDER BY name`,
  ).bind(ctx.connectorId, ctx.companyId).all();

  return json({
    connector: { id: ctx.connectorId, name: ctx.connectorName },
    company: { timezone: ctx.companyTimezone },
    devices: results ?? [],
    server_time: new Date().toISOString(),
  });
}

// ------------------------------------------------------------------ POST /api/connector/jobs/claim?wait=20
// Long poll: when nothing is waiting, the request is held for up to `wait` seconds and
// returns as soon as a job appears, so "Sync now" starts within about 2 seconds.
async function takeJob(env: Env, ctx: ConnectorContext) {
  const now = new Date().toISOString();
  return env.DB.prepare(
    `UPDATE sync_jobs
        SET status = 'running', started_at = ?1, heartbeat_at = ?1,
            progress_stage = 'connecting', progress_pct = 0, progress_msg = 'Connector picked up the sync'
      WHERE status = 'pending'
        AND id = (
          SELECT j.id FROM sync_jobs j JOIN devices d ON d.id = j.device_id
           WHERE j.status = 'pending' AND j.company_id = ?2 AND d.connector_id = ?3 AND d.is_active = 1
           ORDER BY j.requested_at
           LIMIT 1)
      RETURNING id, device_id, trigger_type, requested_at, started_at`,
  ).bind(now, ctx.companyId, ctx.connectorId)
    .first<{ id: string; device_id: string; trigger_type: string; requested_at: string; started_at: string }>();
}

export async function claimJob(request: Request, env: Env): Promise<Response> {
  const ctx = await requireConnector(request, env);
  const wait = Math.min(Math.max(Number(new URL(request.url).searchParams.get("wait")) || 0, 0), MAX_WAIT_SECONDS);
  const deadline = Date.now() + wait * 1000;

  await expireStaleJobs(env, { connectorId: ctx.connectorId });

  let job = await takeJob(env, ctx);
  while (!job && Date.now() < deadline) {
    await sleep(2000);
    job = await takeJob(env, ctx);
  }
  if (!job) return json({ job: null, waited: wait });

  const device = await env.DB.prepare(
    "SELECT id, name, model, ip_address, port, comm_key, last_sync_at FROM devices WHERE id = ?",
  ).bind(job.device_id).first();

  return json({ job: { ...job, device } });
}

// ------------------------------------------------------------------ POST /api/connector/jobs/:id/progress
// The connector reports what it is doing. The answer tells it whether to stop (job cancelled or timed out).
export async function jobProgress(request: Request, env: Env, jobId: string): Promise<Response> {
  const ctx = await requireConnector(request, env);
  const job = await loadOwnJob(env, ctx, jobId);
  if (job.status !== "running") return json({ ok: false, stop: true, status: job.status });

  const body = await readJson<Record<string, unknown>>(request);
  const stage = typeof body.stage === "string" ? body.stage.slice(0, 20) : null;
  const pct = Number.isFinite(body.pct) ? Math.max(0, Math.min(100, Math.round(body.pct as number))) : null;
  const message = typeof body.message === "string" ? body.message.replace(/[\u0000-\u001f]/g, " ").slice(0, 200) : null;

  await env.DB.prepare(
    `UPDATE sync_jobs SET heartbeat_at = ?, progress_stage = COALESCE(?, progress_stage), progress_pct = ?, progress_msg = COALESCE(?, progress_msg)
      WHERE id = ? AND status = 'running'`,
  ).bind(new Date().toISOString(), stage, pct, message, job.id).run();
  return json({ ok: true, stop: false });
}

// ------------------------------------------------------------------ POST /api/connector/jobs/:id/logs
interface CleanRecord { u: string; t: string; s: number | null; v: number | null }

function cleanRecord(raw: unknown): CleanRecord | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;

  const userId = String(r.user_id ?? "").trim();
  if (!userId || userId.length > 32) return null;

  const m = TIMESTAMP_RE.exec(typeof r.timestamp === "string" ? r.timestamp.trim() : "");
  if (!m) return null;
  const [mo, d, h, mi, s] = [m[2], m[3], m[4], m[5], m[6]].map(Number);
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || s > 59) return null;

  const state = Number.isInteger(r.state) ? (r.state as number) : null;
  const verify = Number.isInteger(r.verify_mode) ? (r.verify_mode as number) : null;
  return { u: userId, t: `${m[1]}-${m[2]}-${m[3]} ${m[4]}:${m[5]}:${m[6]}`, s: state, v: verify };
}

export async function uploadLogs(request: Request, env: Env, jobId: string): Promise<Response> {
  const ctx = await requireConnector(request, env);
  const job = await loadOwnJob(env, ctx, jobId);
  if (job.status !== "running") throw new HttpError(409, `Job is ${job.status}, not running`);

  const body = await readJson<{ records?: unknown }>(request);
  if (!Array.isArray(body.records)) throw new HttpError(400, "Body must be { records: [...] }");
  if (body.records.length > MAX_RECORDS_PER_UPLOAD) {
    throw new HttpError(413, `Send at most ${MAX_RECORDS_PER_UPLOAD} records per request`);
  }

  const clean = body.records.map(cleanRecord).filter((r): r is CleanRecord => r !== null);
  const rejected = body.records.length - clean.length;

  let inserted = 0;
  if (clean.length > 0) {
    // One statement for the whole chunk; duplicates are skipped by the UNIQUE key.
    const res = await env.DB.prepare(
      `INSERT OR IGNORE INTO attendance_logs
         (company_id, device_id, device_user_id, punch_time, punch_state, verify_mode, sync_job_id)
       SELECT ?1, ?2,
              json_extract(value, '$.u'), json_extract(value, '$.t'),
              json_extract(value, '$.s'), json_extract(value, '$.v'), ?3
         FROM json_each(?4)`,
    ).bind(job.company_id, job.device_id, job.id, JSON.stringify(clean)).run();
    inserted = res.meta.changes ?? 0;
  }

  await env.DB.prepare(
    "UPDATE sync_jobs SET records_fetched = records_fetched + ?, records_inserted = records_inserted + ?, heartbeat_at = ? WHERE id = ?",
  ).bind(clean.length, inserted, new Date().toISOString(), job.id).run();

  return json({
    received: body.records.length,
    accepted: clean.length,
    rejected,
    inserted,
    duplicates: clean.length - inserted,
  });
}

// ------------------------------------------------------------------ POST /api/connector/jobs/:id/complete
export async function completeJob(request: Request, env: Env, jobId: string): Promise<Response> {
  const ctx = await requireConnector(request, env);
  const job = await loadOwnJob(env, ctx, jobId);
  if (job.status !== "running") throw new HttpError(409, `Job is ${job.status}, not running`);

  const body = await readJson<Record<string, unknown>>(request);
  const status = body.status;
  if (status !== "success" && status !== "failed") throw new HttpError(400, "status must be 'success' or 'failed'");
  const errorMessage = status === "failed"
    ? (typeof body.error_message === "string" && body.error_message.trim() ? body.error_message.trim().slice(0, 500) : "Unknown error")
    : null;
  const serial = typeof body.device_serial === "string" && body.device_serial.trim()
    ? body.device_serial.trim().slice(0, 64)
    : null;
  const skipped = Number.isInteger(body.records_skipped) && (body.records_skipped as number) >= 0
    ? (body.records_skipped as number)
    : 0;
  const clockOffset = Number.isInteger(body.clock_offset_seconds) && Math.abs(body.clock_offset_seconds as number) < 20 * 365 * 86400
    ? (body.clock_offset_seconds as number)
    : null;

  const now = new Date().toISOString();
  const statements = [
    env.DB.prepare(
      `UPDATE sync_jobs SET status = ?, finished_at = ?, error_message = ?, records_skipped = ?,
              progress_stage = NULL, progress_pct = NULL, progress_msg = NULL, heartbeat_at = ?
        WHERE id = ?`,
    ).bind(status, now, errorMessage, skipped, now, job.id),
  ];
  if (status === "success") {
    statements.push(
      env.DB.prepare(
        `UPDATE devices
            SET last_sync_at = ?, serial_number = COALESCE(?, serial_number),
                clock_offset_seconds = COALESCE(?, clock_offset_seconds),
                clock_checked_at = CASE WHEN ? IS NULL THEN clock_checked_at ELSE ? END
          WHERE id = ?`,
      ).bind(now, serial, clockOffset, clockOffset, now, job.device_id),
    );
  }
  await env.DB.batch(statements);

  // If this was the last machine for a scheduled report, the report is ready now.
  if (job.report_id) await finalizeReportIfDone(env, job.report_id);

  const summary = await env.DB.prepare(
    `SELECT id, status, records_fetched, records_inserted, records_skipped, finished_at, error_message
       FROM sync_jobs WHERE id = ?`,
  ).bind(job.id).first();
  return json({ job: summary });
}

// ------------------------------------------------------------------ POST /api/connector/jobs/:id/users
const MAX_USERS_PER_UPLOAD = 5000;
const USER_ID_RE = /^[A-Za-z0-9_.-]{1,32}$/;

/**
 * Receives the machine's user list ({ users: [{ user_id, name }] }).
 * New user IDs become employees; the machine name is stored and shown in
 * reports unless someone has edited that employee's name in the dashboard.
 */
export async function uploadUsers(request: Request, env: Env, jobId: string): Promise<Response> {
  const ctx = await requireConnector(request, env);
  const job = await loadOwnJob(env, ctx, jobId);
  if (job.status !== "running") throw new HttpError(409, `Job is ${job.status}, not running`);

  const body = await readJson<{ users?: unknown }>(request);
  if (!Array.isArray(body.users)) throw new HttpError(400, "Body must be { users: [...] }");
  if (body.users.length > MAX_USERS_PER_UPLOAD) throw new HttpError(413, `Send at most ${MAX_USERS_PER_UPLOAD} users`);

  const clean = new Map<string, string>();
  for (const raw of body.users) {
    if (!raw || typeof raw !== "object") continue;
    const u = raw as Record<string, unknown>;
    const id = String(u.user_id ?? "").trim();
    if (!USER_ID_RE.test(id)) continue;
    const name = typeof u.name === "string"
      ? u.name.replace(/[\u0000-\u001f\u007f]/g, "").replace(/\s+/g, " ").trim().slice(0, 80)
      : "";
    clean.set(id, name);
  }
  const rows = [...clean].map(([u, n]) => ({ u, n }));
  if (!rows.length) return json({ received: body.users.length, accepted: 0, named: 0, added: 0 });

  const before = await env.DB.prepare("SELECT COUNT(*) AS n FROM employees WHERE company_id = ?")
    .bind(job.company_id).first<{ n: number }>();

  // A blank name on the machine never wipes a name we already have.
  await env.DB.prepare(
    `INSERT INTO employees (id, company_id, device_user_id, full_name, machine_name, updated_at)
     SELECT lower(hex(randomblob(16))), ?1, json_extract(value, '$.u'),
            json_extract(value, '$.n'), NULLIF(json_extract(value, '$.n'), ''), ?2
       FROM json_each(?3) WHERE true
     ON CONFLICT (company_id, device_user_id) DO UPDATE SET
       machine_name = COALESCE(excluded.machine_name, employees.machine_name),
       full_name    = CASE
                        WHEN employees.name_edited = 1 THEN employees.full_name
                        WHEN excluded.machine_name IS NOT NULL THEN excluded.machine_name
                        ELSE employees.full_name
                      END,
       updated_at   = CASE
                        WHEN COALESCE(excluded.machine_name, '') <> COALESCE(employees.machine_name, '') THEN excluded.updated_at
                        ELSE employees.updated_at
                      END`,
  ).bind(job.company_id, new Date().toISOString(), JSON.stringify(rows)).run();

  const after = await env.DB.prepare("SELECT COUNT(*) AS n FROM employees WHERE company_id = ?")
    .bind(job.company_id).first<{ n: number }>();

  return json({
    received: body.users.length,
    accepted: rows.length,
    named: rows.filter((r) => r.n).length,
    added: (after?.n ?? 0) - (before?.n ?? 0),
  });
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
import { expireStaleJobs } from "../lib/jobs";

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

/** GET /api/devices - includes the latest sync of each machine, with live progress. */
export async function listDevices(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  await expireStaleJobs(env, { companyId: auth.companyId });
  const { results } = await env.DB.prepare(
    `SELECT d.id, d.name, d.model, d.ip_address, d.port, d.comm_key, d.serial_number,
            d.connector_id, c.name AS connector_name, c.is_active AS connector_active, c.last_seen_at AS connector_seen,
            d.last_sync_at, d.clock_offset_seconds, d.clock_checked_at, d.is_active, d.created_at,
            (SELECT COUNT(*) FROM attendance_logs l WHERE l.device_id = d.id) AS log_count,
            j.id AS job_id, j.status AS last_job_status, j.trigger_type AS job_trigger, j.requested_at AS job_requested_at,
            j.progress_stage AS job_stage, j.progress_pct AS job_pct, j.progress_msg AS job_msg,
            j.error_message AS job_error, j.finished_at AS job_finished_at, j.records_inserted AS job_new
       FROM devices d
       LEFT JOIN connectors c ON c.id = d.connector_id
       LEFT JOIN sync_jobs j ON j.id = (SELECT id FROM sync_jobs WHERE device_id = d.id ORDER BY requested_at DESC LIMIT 1)
      WHERE d.company_id = ?
      ORDER BY d.is_active DESC, d.created_at DESC`,
  ).bind(auth.companyId).all();
  return json({ devices: results ?? [], server_time: new Date().toISOString() });
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
  await expireStaleJobs(env, { companyId: auth.companyId });
  const limit = Math.min(Math.max(Number(new URL(request.url).searchParams.get("limit")) || 20, 1), 100);
  const { results } = await env.DB.prepare(
    `SELECT j.id, j.device_id, d.name AS device_name, j.trigger_type, j.status,
            j.requested_at, j.started_at, j.finished_at, j.records_fetched, j.records_inserted, j.records_skipped, j.error_message,
            j.progress_stage, j.progress_pct, j.progress_msg
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

// ------------------------------------------------------------------ delete (clean-up of unused items)

/**
 * DELETE /api/devices/:id   { move_to?: deviceId, delete_punches?: true }
 * Only deactivated machines. If it has punches, the caller must either move them
 * to another machine of the company or explicitly delete them.
 */
export async function deleteDevice(request: Request, env: Env, id: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  const body = await readJson<{ move_to?: unknown; delete_punches?: unknown }>(request);

  const device = await env.DB.prepare("SELECT id, name, is_active FROM devices WHERE id = ? AND company_id = ?")
    .bind(id, auth.companyId).first<{ id: string; name: string; is_active: number }>();
  if (!device) throw new HttpError(404, "Machine not found");
  if (device.is_active === 1) throw new HttpError(409, "Deactivate the machine before deleting it");

  const count = (await env.DB.prepare("SELECT COUNT(*) AS n FROM attendance_logs WHERE device_id = ?")
    .bind(id).first<{ n: number }>())?.n ?? 0;

  const statements: D1PreparedStatement[] = [];
  let moved = 0;
  if (count > 0) {
    if (typeof body.move_to === "string" && body.move_to) {
      if (body.move_to === id) throw new HttpError(400, "Choose a different machine to move the punches to");
      const target = await env.DB.prepare("SELECT id FROM devices WHERE id = ? AND company_id = ?")
        .bind(body.move_to, auth.companyId).first();
      if (!target) throw new HttpError(400, "The machine to move the punches to was not found");
      // Punches the target already has (same person, same time) are dropped as duplicates.
      statements.push(
        env.DB.prepare("UPDATE OR IGNORE attendance_logs SET device_id = ?, sync_job_id = NULL WHERE device_id = ?")
          .bind(body.move_to, id),
      );
      moved = count;
    } else if (body.delete_punches !== true) {
      throw new HttpError(409, `This machine has ${count} punches. Move them to another machine or confirm deleting them.`);
    }
  }
  statements.push(
    env.DB.prepare("DELETE FROM attendance_logs WHERE device_id = ?").bind(id),
    env.DB.prepare("DELETE FROM sync_jobs WHERE device_id = ?").bind(id),
    env.DB.prepare("DELETE FROM devices WHERE id = ? AND company_id = ?").bind(id, auth.companyId),
  );
  const results = await env.DB.batch(statements);
  const movedRows = moved ? (results[0].meta.changes ?? 0) : 0;

  return json({ ok: true, punches: count, moved: movedRows, deleted_punches: count - movedRows });
}

/**
 * DELETE /api/connectors/:id
 * Allowed for revoked connectors, and for connectors that never connected and have no machines.
 */
export async function deleteConnector(request: Request, env: Env, id: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);

  const c = await env.DB.prepare(
    `SELECT c.id, c.is_active, c.last_seen_at,
            (SELECT COUNT(*) FROM devices d WHERE d.connector_id = c.id AND d.is_active = 1) AS devices
       FROM connectors c WHERE c.id = ? AND c.company_id = ?`,
  ).bind(id, auth.companyId).first<{ id: string; is_active: number; last_seen_at: string | null; devices: number }>();
  if (!c) throw new HttpError(404, "Connector not found");
  if (c.is_active === 1 && (c.last_seen_at || c.devices > 0)) {
    throw new HttpError(409, c.devices > 0
      ? "This connector still reads a machine. Revoke it (or move the machine to another connector) first."
      : "This connector has been used. Revoke it first, then delete it.");
  }

  await env.DB.batch([
    env.DB.prepare("UPDATE devices SET connector_id = NULL WHERE connector_id = ? AND company_id = ?").bind(id, auth.companyId),
    env.DB.prepare("DELETE FROM connectors WHERE id = ? AND company_id = ?").bind(id, auth.companyId),
  ]);
  return json({ ok: true });
}

/** POST /api/sync-jobs/:id/cancel - stop a waiting or running sync. The connector stops at its next step. */
export async function cancelJob(request: Request, env: Env, id: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  const now = new Date().toISOString();
  const res = await env.DB.prepare(
    `UPDATE sync_jobs SET status = 'failed', finished_at = ?, progress_stage = NULL, progress_pct = NULL, progress_msg = NULL,
            error_message = ?
      WHERE id = ? AND company_id = ? AND status IN ('pending','running')`,
  ).bind(now, `Stopped by ${auth.fullName}`, id, auth.companyId).run();
  if (!res.meta.changes) throw new HttpError(409, "This sync has already finished");
  return json({ ok: true });
}
'@

# ---------------------------------------------------------------- worker/src/routes/status.ts
Write-File "worker/src/routes/status.ts" @'
// Dashboard status: problems that need attention, worst first.
import type { Env } from "../env";
import { json } from "../lib/http";
import { requireAuth } from "../lib/auth";
import { CONNECTOR_VERSION } from "../generated/connector-files";
import { expireStaleJobs } from "../lib/jobs";

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
  await expireStaleJobs(env, { companyId: auth.companyId });
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
    alerts.push({ level: "info", text: "Get started: under Machines, create a connector, download its installer and run it on a PC on the machine's network." });
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
      alerts.push({ level: "info", text: `Connector "${c.name}" has no machine assigned yet. Add one under Machines.` });
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
    "# How long to wait for the machine (ms), and the first retry delay when",
    "# the machine or server fails (s). Syncs start within a few seconds.",
    "DEVICE_TIMEOUT_MS=10000",
    "RETRY_DELAY_SECONDS=5",
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

# ---------------------------------------------------------------- worker/src/index.ts
Write-File "worker/src/index.ts" @'
import type { Env } from "./env";
import { HttpError, html, json, redirect } from "./lib/http";
import { getAuth } from "./lib/auth";
import { health } from "./routes/health";
import { login, logout, me, signup } from "./routes/auth";
import {
  createConnector, createDevice, deactivateDevice, listConnectors,
  listDevices, listSyncJobs, queueSync, revokeConnector, syncAll, deleteDevice, deleteConnector, cancelJob,
} from "./routes/manage";
import { downloadConnector } from "./routes/download";
import { status } from "./routes/status";
import { overview } from "./routes/overview";
import { claimJob, completeJob, connectorConfig, jobProgress, uploadLogs, uploadUsers } from "./routes/connector";
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
const R_DEVICE = new RegExp(`^/api/devices/${ID}$`);
const R_CONNECTOR = new RegExp(`^/api/connectors/${ID}$`);
const R_JOB_CANCEL = new RegExp(`^/api/sync-jobs/${ID}/cancel$`);
const R_JOB_PROGRESS = new RegExp(`^/api/connector/jobs/${ID}/progress$`);

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
  if (method === "DELETE" && (m = R_CONNECTOR.exec(pathname))) return deleteConnector(request, env, m[1]);
  if (method === "DELETE" && (m = R_DEVICE.exec(pathname))) return deleteDevice(request, env, m[1]);
  if (pathname === "/api/devices" && method === "GET") return listDevices(request, env);
  if (pathname === "/api/devices" && method === "POST") return createDevice(request, env);
  if (pathname === "/api/devices/sync-all" && method === "POST") return syncAll(request, env);
  if (method === "POST" && (m = R_DEVICE_DEACTIVATE.exec(pathname))) return deactivateDevice(request, env, m[1]);
  if (method === "POST" && (m = R_DEVICE_SYNC.exec(pathname))) return queueSync(request, env, m[1]);
  if (pathname === "/api/sync-jobs" && method === "GET") return listSyncJobs(request, env);
  if (method === "POST" && (m = R_JOB_CANCEL.exec(pathname))) return cancelJob(request, env, m[1]);
  if (pathname === "/api/status" && method === "GET") return status(request, env);
  if (pathname === "/api/overview" && method === "GET") return overview(request, env);
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
  if (method === "POST" && (m = R_JOB_PROGRESS.exec(pathname))) return jobProgress(request, env, m[1]);
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

# ---------------------------------------------------------------- worker/src/pages.ts
Write-File "worker/src/pages.ts" @'
import { VERSION } from "./env";
import type { AuthContext } from "./lib/auth";
import { escapeHtml } from "./lib/http";

// ------------------------------------------------------------------ design tokens + components
const STYLE = String.raw`
:root {
  --canvas:#EEF2F0; --surface:#FFFFFF; --surface-2:#F5F8F6; --ink:#17302B; --ink-2:#3A4F4A; --muted:#62746F;
  --line:#D6DFDB; --line-2:#E5ECE9;
  --side:#17302B; --side-ink:#E4EEEA; --side-muted:#93ABA4; --side-hover:rgba(255,255,255,.07);
  --accent:#126B4E; --accent-hover:#0E5A41; --accent-ink:#FFFFFF; --accent-soft:#E0F0E8;
  --amber:#9A5A05; --amber-soft:#FBF0DC; --red:#B42318; --red-soft:#FDECEA;
  --radius:8px; --radius-lg:12px;
  color-scheme: light;
}
@media (prefers-color-scheme: dark) {
  :root {
    --canvas:#0E1614; --surface:#15201D; --surface-2:#1A2724; --ink:#E3ECE8; --ink-2:#C3D1CC; --muted:#8EA29C;
    --line:#293834; --line-2:#21302C;
    --side:#0A110F; --side-ink:#E3ECE8; --side-muted:#80958F; --side-hover:rgba(255,255,255,.06);
    --accent:#3DB389; --accent-hover:#52C49A; --accent-ink:#06201A; --accent-soft:#163A2F;
    --amber:#E3A94F; --amber-soft:#36290F; --red:#F27A6D; --red-soft:#3A1916;
    color-scheme: dark;
  }
}
* { box-sizing:border-box; }
[hidden] { display:none !important; }
html, body { margin:0; }
body {
  background:var(--canvas); color:var(--ink);
  font-family:"IBM Plex Sans", system-ui, -apple-system, "Segoe UI", sans-serif;
  font-size:14px; line-height:1.5; -webkit-font-smoothing:antialiased;
}
h1, h2, h3 { margin:0; font-weight:600; letter-spacing:-0.01em; }
h1 { font-size:26px; line-height:1.2; }
h2 { font-size:16px; }
p { margin:0; }
a { color:var(--accent); }
.num, td.num, .tnum { font-variant-numeric:tabular-nums; }
:focus-visible { outline:2px solid var(--accent); outline-offset:2px; }
@media (prefers-reduced-motion: reduce) { * { transition:none !important; animation:none !important; } }

/* ---------- buttons + inputs */
.btn {
  display:inline-flex; align-items:center; justify-content:center; gap:6px;
  height:36px; padding:0 14px; border-radius:var(--radius); border:1px solid transparent;
  font:inherit; font-weight:500; font-size:14px; cursor:pointer; text-decoration:none; white-space:nowrap;
  transition:background .12s, border-color .12s, color .12s;
}
.btn-primary { background:var(--accent); color:var(--accent-ink); }
.btn-primary:hover { background:var(--accent-hover); }
.btn-ghost { background:var(--surface); color:var(--ink); border-color:var(--line); }
.btn-ghost:hover { border-color:var(--muted); }
.btn-quiet { background:transparent; color:var(--muted); padding:0 8px; }
.btn-quiet:hover { color:var(--ink); }
.btn-danger { background:transparent; color:var(--red); padding:0 8px; }
.btn-danger:hover { background:var(--red-soft); }
.btn-sm { height:30px; padding:0 11px; font-size:13px; }
.btn:disabled, .btn[aria-disabled="true"] { opacity:.45; cursor:default; }
.btn-block { width:100%; height:40px; }

.field { display:flex; flex-direction:column; gap:6px; min-width:0; }
.field label { font-size:13px; font-weight:500; color:var(--ink-2); }
.input, select.input {
  height:38px; padding:0 12px; width:100%; border-radius:var(--radius); border:1px solid var(--line);
  background:var(--surface); color:var(--ink); font:inherit; font-size:14px;
  transition:border-color .12s, box-shadow .12s;
}
.input::placeholder { color:var(--muted); opacity:.8; }
.input:focus { outline:none; border-color:var(--accent); box-shadow:0 0 0 3px var(--accent-soft); }
.input-sm { height:32px; font-size:13px; padding:0 10px; }
.hint { font-size:12.5px; color:var(--muted); }
.error-text { color:var(--red); font-size:13px; min-height:18px; }
.ok-text { color:var(--accent); font-size:13px; min-height:18px; }
.panel-body .error-text:empty, .page > .error-text:empty { display:none; }

/* ---------- app shell */
.shell { display:grid; grid-template-columns:236px minmax(0, 1fr); min-height:100vh; }
.side, .main { min-width:0; }
.side {
  background:var(--side); color:var(--side-ink); padding:20px 14px 16px;
  position:sticky; top:0; height:100vh; display:flex; flex-direction:column; gap:22px;
}
.brand { display:flex; align-items:center; gap:10px; padding:2px 8px; color:var(--side-ink); text-decoration:none; }
.brand svg { flex:none; }
.brand-name { font-weight:600; font-size:15px; line-height:1.2; }
.brand-co { font-size:12.5px; color:var(--side-muted); line-height:1.3; }
.nav { display:flex; flex-direction:column; gap:2px; }
.nav a {
  display:flex; align-items:center; gap:10px; padding:8px 10px; border-radius:var(--radius);
  color:var(--side-muted); text-decoration:none; font-weight:500; position:relative;
}
.nav a:hover { color:var(--side-ink); background:var(--side-hover); }
.nav a[aria-current="page"] { color:var(--side-ink); background:var(--side-hover); }
.nav a[aria-current="page"]::before {
  content:""; position:absolute; left:-14px; top:8px; bottom:8px; width:3px; border-radius:0 3px 3px 0; background:var(--accent);
}
.nav svg { width:18px; height:18px; flex:none; }
.nav .count { margin-left:auto; font-size:12px; color:var(--side-muted); }
.side-foot { margin-top:auto; border-top:1px solid rgba(255,255,255,.08); padding:14px 8px 0; font-size:13px; }
.side-foot .who { color:var(--side-ink); font-weight:500; }
.side-foot .role { color:var(--side-muted); text-transform:capitalize; }
.side-foot .btn { margin-top:10px; color:var(--side-muted); padding:0; height:auto; }
.side-foot .btn:hover { color:var(--side-ink); }
.side-foot .ver { margin-top:12px; font-size:11.5px; color:var(--side-muted); opacity:.7; }

.main { padding:30px 40px 60px; max-width:1180px; width:100%; }
.page[hidden] { display:none; }
.page-head { display:flex; align-items:flex-end; justify-content:space-between; gap:16px; margin-bottom:22px; flex-wrap:wrap; }
.page-head p { color:var(--muted); margin-top:6px; max-width:70ch; }
.page-actions { display:flex; gap:8px; flex-wrap:wrap; align-items:center; }
.stack > * + * { margin-top:18px; }

/* ---------- panels + tables */
.panel { background:var(--surface); border:1px solid var(--line); border-radius:var(--radius-lg); }
.panel-head { display:flex; align-items:flex-start; justify-content:space-between; gap:16px; padding:18px 20px 0; flex-wrap:wrap; }
.panel-head p { color:var(--muted); margin-top:4px; font-size:13.5px; max-width:75ch; }
.panel-body { padding:16px 20px 20px; }
.table-wrap { overflow-x:auto; margin-top:14px; border-top:1px solid var(--line-2); }
table { width:100%; border-collapse:collapse; }
th {
  text-align:left; font-size:12.5px; font-weight:500; color:var(--muted); background:var(--surface-2);
  padding:9px 14px; border-bottom:1px solid var(--line-2); white-space:nowrap;
}
td { padding:11px 14px; border-bottom:1px solid var(--line-2); white-space:nowrap; vertical-align:middle; }
tr:last-child td { border-bottom:0; }
tbody tr:hover td, tr.editing td { background:var(--surface-2); }
td .input-sm { min-width:160px; }
th.num, td.num { text-align:right; }
td.wrap { white-space:normal; min-width:220px; }
td.muted, .muted { color:var(--muted); }
td.actions { text-align:right; }
td.actions .btn + .btn { margin-left:6px; }
td.empty { color:var(--muted); padding:28px 14px; text-align:center; white-space:normal; }
.sub-id { display:block; color:var(--muted); font-size:12.5px; }

.pill { display:inline-flex; align-items:center; gap:6px; font-size:13px; font-weight:500; white-space:nowrap; }
.pill::before { content:""; width:7px; height:7px; border-radius:50%; background:currentColor; }
.pill.ok { color:var(--accent); } .pill.warn { color:var(--amber); } .pill.bad { color:var(--red); } .pill.idle { color:var(--muted); }
.t-warn { color:var(--amber); } .t-bad { color:var(--red); }

/* ---------- notices */
.notices { display:flex; flex-direction:column; gap:8px; margin-bottom:18px; }
.nav .count[data-dot="1"]::after { content:""; display:inline-block; width:7px; height:7px; border-radius:50%; background:var(--amber); margin-left:6px; vertical-align:1px; }
.notice {
  display:flex; gap:12px; align-items:flex-start; padding:11px 14px; border-radius:var(--radius);
  border:1px solid var(--line); border-left-width:3px; background:var(--surface); font-size:13.5px;
}
.notice.error { border-left-color:var(--red); background:var(--red-soft); border-color:transparent; border-left-color:var(--red); }
.notice.warning { border-left-color:var(--amber); background:var(--amber-soft); border-color:transparent; border-left-color:var(--amber); }
.notice.info { border-left-color:var(--accent); }
.notice strong { font-weight:600; }

/* ---------- overview: summary strip */
.summary { display:grid; grid-template-columns:repeat(4, minmax(0, 1fr)); }
.summary > div { padding:16px 20px; border-left:1px solid var(--line-2); min-width:0; }
.summary > div:first-child { border-left:0; }
.summary .k { font-size:12.5px; color:var(--muted); }
.summary .v { font-size:22px; font-weight:600; margin-top:2px; font-variant-numeric:tabular-nums; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.summary .v small { font-size:14px; font-weight:500; color:var(--muted); }
.summary .d { font-size:12.5px; color:var(--muted); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }

/* ---------- overview: day timeline (the signature element) */
.day-nav { display:flex; align-items:center; gap:6px; }
.day-nav .day-label { font-weight:600; min-width:150px; text-align:center; font-variant-numeric:tabular-nums; }
.tl { padding:6px 20px 18px; }
.tl-row { display:grid; grid-template-columns:200px minmax(0, 1fr) 92px; align-items:center; gap:14px; min-height:40px; }
.tl-row + .tl-row { border-top:1px solid var(--line-2); }
.tl-axis { min-height:30px; border-top:0 !important; }
.tl-who { min-width:0; }
.tl-who .n { font-weight:500; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.tl-who .i { font-size:12px; color:var(--muted); }
.tl-track { position:relative; height:26px; }
.tl-grid { position:absolute; top:0; bottom:0; width:1px; background:var(--line-2); }
.tl-hour { position:absolute; top:6px; transform:translateX(-50%); font-size:11.5px; color:var(--muted); font-variant-numeric:tabular-nums; }
.tl-bar { position:absolute; top:9px; height:8px; border-radius:4px; background:var(--accent-soft); border:1px solid var(--accent); }
.tl-tick { position:absolute; top:4px; width:2px; height:18px; margin-left:-1px; border-radius:1px; background:var(--accent); }
.tl-tick.single { background:var(--amber); width:3px; }
.tl-sum { text-align:right; font-variant-numeric:tabular-nums; font-weight:500; }
.tl-sum.t-warn { font-weight:400; font-size:12.5px; }
.tl-now { position:absolute; top:-2px; bottom:-2px; width:0; border-left:1px dashed var(--red); }
.tl-empty { padding:36px 20px; text-align:center; color:var(--muted); }
.absent { padding:14px 20px 18px; border-top:1px solid var(--line-2); display:flex; gap:8px; flex-wrap:wrap; align-items:center; }
.absent .k { color:var(--muted); font-size:13px; margin-right:4px; }
.chip { display:inline-flex; align-items:center; height:26px; padding:0 10px; border-radius:13px; background:var(--surface-2); border:1px solid var(--line-2); font-size:13px; color:var(--ink-2); }

/* ---------- forms in panels */
.form-row { display:grid; gap:12px; align-items:end; }
.form-row.cols-2 { grid-template-columns:minmax(0, 1fr) auto; }
.form-row.cols-dev { grid-template-columns:1.3fr 1.1fr 90px 100px 1.2fr auto; }
.form-row.cols-exp { grid-template-columns:180px 180px auto; justify-content:start; }
.setup {
  margin-top:16px; padding:16px 18px; border-radius:var(--radius); background:var(--accent-soft);
  border:1px solid color-mix(in srgb, var(--accent) 30%, transparent);
}
.setup h3 { font-size:15px; }
.setup ol { margin:8px 0 14px; padding-left:20px; line-height:1.7; }
.setup details { margin-top:12px; font-size:13px; color:var(--ink-2); }
.setup summary { cursor:pointer; }
.setup code { display:block; margin:8px 0; padding:8px 10px; border-radius:6px; background:var(--surface); word-break:break-all; font-size:12.5px; }
.search { max-width:260px; }

/* ---------- live sync progress */
.prog { display:flex; flex-direction:column; gap:5px; min-width:200px; max-width:300px; white-space:normal; }
.prog-text { font-size:13px; color:var(--ink-2); line-height:1.35; }
.prog-bar { height:6px; border-radius:3px; background:var(--line-2); overflow:hidden; position:relative; }
.prog-bar > span { display:block; height:100%; background:var(--accent); border-radius:3px; transition:width .4s ease; }
.prog-bar.busy > span { width:35% !important; position:absolute; animation:prog-slide 1.3s ease-in-out infinite; }
@keyframes prog-slide { from { left:-35%; } to { left:100%; } }
.prog-meta { font-size:12px; color:var(--muted); }
.fail-text { display:block; margin-top:4px; font-size:12.5px; color:var(--red); white-space:normal; min-width:220px; max-width:320px; line-height:1.35; }
tr.syncing td { background:color-mix(in srgb, var(--accent-soft) 45%, transparent); }

/* ---------- dialog */
dialog.dlg {
  border:1px solid var(--line); border-radius:var(--radius-lg); padding:0; width:min(460px, calc(100vw - 32px));
  background:var(--surface); color:var(--ink); box-shadow:0 20px 50px rgba(0,0,0,.25);
}
dialog.dlg::backdrop { background:rgba(10, 20, 18, .45); }
.dlg-body { padding:22px 22px 6px; }
.dlg-body h3 { font-size:17px; }
.dlg-body p { color:var(--ink-2); margin-top:8px; }
.dlg-opts { margin-top:14px; display:flex; flex-direction:column; gap:10px; }
.dlg-opt { display:flex; gap:10px; align-items:flex-start; padding:10px 12px; border:1px solid var(--line); border-radius:var(--radius); cursor:pointer; }
.dlg-opt:has(input:checked) { border-color:var(--accent); background:var(--accent-soft); }
.dlg-opt input[type=radio] { margin-top:3px; accent-color:var(--accent); }
.dlg-opt select { margin-top:8px; }
.dlg-foot { display:flex; justify-content:flex-end; gap:8px; padding:16px 22px 20px; }
.btn-danger-solid { background:var(--red); color:#fff; }
.btn-danger-solid:hover { filter:brightness(1.08); }

/* ---------- toast */
.toast {
  position:fixed; left:50%; bottom:24px; transform:translateX(-50%) translateY(20px); opacity:0;
  background:var(--ink); color:var(--canvas); padding:10px 16px; border-radius:var(--radius); font-size:13.5px;
  transition:opacity .18s, transform .18s; pointer-events:none; max-width:min(560px, calc(100vw - 32px)); z-index:10;
}
.toast.show { opacity:1; transform:translateX(-50%) translateY(0); }

/* ---------- responsive */
@media (max-width: 1000px) {
  .form-row.cols-dev { grid-template-columns:1fr 1fr; }
  .summary { grid-template-columns:repeat(2, minmax(0, 1fr)); }
  .summary > div:nth-child(3) { border-left:0; }
  .summary > div:nth-child(n+3) { border-top:1px solid var(--line-2); }
}
@media (max-width: 860px) {
  .shell { grid-template-columns:minmax(0, 1fr); }
  .side { position:sticky; height:auto; z-index:5; flex-direction:row; flex-wrap:wrap; align-items:center; gap:10px 16px; padding:12px 16px; }
  .nav { flex-direction:row; overflow-x:auto; width:100%; order:3; gap:4px; margin:0 -4px; }
  .nav a { padding:7px 10px; white-space:nowrap; }
  .nav a[aria-current="page"]::before { display:none; }
  .nav .count { display:none; }
  .side-foot { margin:0 0 0 auto; border:0; padding:0; display:flex; align-items:center; gap:12px; }
  .side-foot .who, .side-foot .role, .side-foot .ver { display:none; }
  .side-foot .btn { margin:0; }
  .main { padding:22px 16px 48px; }
  h1 { font-size:22px; }
  .tl-row { grid-template-columns:110px minmax(0, 1fr) 64px; gap:8px; }
  .tl { padding:6px 12px 14px; }
  .form-row.cols-2, .form-row.cols-dev, .form-row.cols-exp { grid-template-columns:1fr; }
}
@media (max-width: 520px) {
  .summary { grid-template-columns:1fr 1fr; }
  .summary > div { padding:12px 14px; }
  .summary .v { font-size:18px; }
}

/* ---------- sign-in pages */
.auth { display:grid; grid-template-columns:minmax(0, 1.05fr) minmax(0, 1fr); min-height:100vh; }
.auth-side { background:var(--side); color:var(--side-ink); padding:44px 52px; display:flex; flex-direction:column; justify-content:space-between; gap:40px; }
.auth-side h1 { font-size:34px; line-height:1.15; max-width:16ch; margin-top:56px; }
.auth-side p { color:var(--side-muted); margin-top:14px; max-width:44ch; font-size:15px; }
.demo { border-top:1px solid rgba(255,255,255,.1); padding-top:20px; max-width:520px; }
.demo-row { display:grid; grid-template-columns:96px 1fr; align-items:center; gap:12px; height:30px; font-size:13px; color:var(--side-muted); }
.demo-track { position:relative; height:8px; border-radius:4px; background:rgba(255,255,255,.06); }
.demo-bar { position:absolute; top:0; bottom:0; border-radius:4px; background:rgba(61,179,137,.35); border:1px solid #3DB389; }
.demo-bar.single { width:4px !important; background:#E3A94F; border-color:#E3A94F; }
.demo-axis { display:flex; justify-content:space-between; margin:8px 0 0 108px; font-size:11.5px; color:var(--side-muted); font-variant-numeric:tabular-nums; }
.auth-form { display:flex; align-items:center; justify-content:center; padding:40px 24px; }
.auth-card { width:100%; max-width:380px; }
.auth-card h2 { font-size:22px; }
.auth-card .lead { color:var(--muted); margin:6px 0 26px; }
.auth-card form { display:flex; flex-direction:column; gap:16px; }
.auth-card .alt { margin-top:22px; color:var(--muted); font-size:13.5px; }
.auth-foot { font-size:12px; color:var(--side-muted); opacity:.8; }
@media (max-width: 860px) {
  .auth { grid-template-columns:1fr; }
  .auth-side { padding:24px 20px; gap:16px; }
  .auth-side h1 { margin-top:18px; font-size:24px; }
  .demo, .auth-foot { display:none; }
}
`;

const FONT = `<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600&display=swap" rel="stylesheet">`;

/** Brand mark: a 24-hour dial with the working hours highlighted. */
const LOGO = `<svg width="30" height="30" viewBox="0 0 32 32" aria-hidden="true">
  <circle cx="16" cy="16" r="13" fill="none" stroke="currentColor" stroke-opacity=".28" stroke-width="2.5"/>
  <path d="M16 3 A13 13 0 0 1 28.4 20" fill="none" stroke="#3DB389" stroke-width="2.5" stroke-linecap="round"/>
  <path d="M16 9 V16 L20.5 18.5" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>
</svg>`;

function layout(title: string, body: string): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title} - HR Attendance</title>
<link rel="icon" href="data:image/svg+xml,${encodeURIComponent(LOGO.replace("currentColor", "#17302B").replace("currentColor", "#17302B"))}">
${FONT}
<style>${STYLE}</style>
</head>
<body>${body}</body>
</html>`;
}

// ------------------------------------------------------------------ sign in / sign up
const AUTH_SCRIPT = String.raw`<script>
document.getElementById("f").addEventListener("submit", async function (e) {
  e.preventDefault();
  var btn = this.querySelector("button[type=submit]");
  var msg = document.getElementById("msg");
  msg.textContent = "";
  btn.disabled = true;
  try {
    var res = await fetch(this.dataset.endpoint, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(Object.fromEntries(new FormData(this)))
    });
    var out = await res.json().catch(function () { return {}; });
    if (res.ok) { location.href = out.redirect || "/app"; return; }
    msg.textContent = out.error || "Something went wrong. Try again.";
  } catch (err) {
    msg.textContent = "Can't reach the server. Check your internet connection and try again.";
  }
  btn.disabled = false;
});
</script>`;

function authSide(): string {
  const rows: Array<[string, number, number]> = [
    ["Hilal Khan", 37, 71], ["Ayesha S.", 34, 76], ["Bilal J.", 40, 88], ["Awais Butt", 46, 0], ["Huda Ijaz", 35, 74],
  ];
  const demo = rows.map(([n, a, b]) =>
    `<div class="demo-row"><span>${n}</span><div class="demo-track"><div class="demo-bar${b ? "" : " single"}" style="left:${a}%;width:${b ? b - a : 0}%"></div></div></div>`).join("");
  return `<aside class="auth-side">
  <div>
    <div class="brand">${LOGO}<div><div class="brand-name">HR Attendance</div></div></div>
    <h1>Your time machine's punches, ready as Excel every two days.</h1>
    <p>The connector reads your ZKTeco machine in the office. Reports, names and missing check-outs are all here, without touching the machine.</p>
  </div>
  <div class="demo" aria-hidden="true">
    ${demo}
    <div class="demo-axis"><span>06:00</span><span>09:00</span><span>12:00</span><span>15:00</span><span>18:00</span><span>21:00</span></div>
  </div>
  <div class="auth-foot">${VERSION}</div>
</aside>`;
}

export function loginPage(): string {
  return layout("Sign in", `
<div class="auth">
  ${authSide()}
  <main class="auth-form"><div class="auth-card">
    <h2>Sign in</h2>
    <p class="lead">Use the email you registered your company with.</p>
    <form id="f" data-endpoint="/api/auth/login">
      <div class="field"><label for="email">Email</label><input class="input" id="email" name="email" type="email" autocomplete="email" required></div>
      <div class="field"><label for="password">Password</label><input class="input" id="password" name="password" type="password" autocomplete="current-password" required></div>
      <div class="error-text" id="msg" role="alert"></div>
      <button class="btn btn-primary btn-block" type="submit">Sign in</button>
    </form>
    <p class="alt">New company? <a href="/signup">Create an account</a></p>
  </div></main>
</div>
${AUTH_SCRIPT}`);
}

export function signupPage(requireCode: boolean): string {
  const codeField = requireCode
    ? `<div class="field"><label for="signup_code">Sign-up code</label><input class="input" id="signup_code" name="signup_code" type="text" autocomplete="off" required><span class="hint">Ask your administrator for this code.</span></div>`
    : "";
  return layout("Create account", `
<div class="auth">
  ${authSide()}
  <main class="auth-form"><div class="auth-card">
    <h2>Create your company account</h2>
    <p class="lead">You'll be the owner of this workspace and can add machines right after.</p>
    <form id="f" data-endpoint="/api/auth/signup">
      <div class="field"><label for="company_name">Company name</label><input class="input" id="company_name" name="company_name" type="text" autocomplete="organization" required></div>
      <div class="field"><label for="full_name">Your full name</label><input class="input" id="full_name" name="full_name" type="text" autocomplete="name" required></div>
      <div class="field"><label for="email">Work email</label><input class="input" id="email" name="email" type="email" autocomplete="email" required></div>
      <div class="field"><label for="password">Password</label><input class="input" id="password" name="password" type="password" autocomplete="new-password" minlength="8" required><span class="hint">At least 8 characters.</span></div>
      ${codeField}
      <div class="error-text" id="msg" role="alert"></div>
      <button class="btn btn-primary btn-block" type="submit">Create account</button>
    </form>
    <p class="alt">Already have an account? <a href="/login">Sign in</a></p>
  </div></main>
</div>
${AUTH_SCRIPT}`);
}

// ------------------------------------------------------------------ dashboard
const ICONS: Record<string, string> = {
  overview: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 7h16M4 12h10M4 17h13"/><circle cx="18" cy="12" r="1.6" fill="currentColor" stroke="none"/></svg>`,
  reports: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M6 3h8l4 4v14H6z"/><path d="M14 3v4h4M9 12h6M9 16h6"/></svg>`,
  employees: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="9" cy="8" r="3.2"/><path d="M3.5 19c.8-3 3-4.6 5.5-4.6s4.7 1.6 5.5 4.6"/><path d="M16 5.2a3 3 0 0 1 0 5.6M18 14.6c1.3.6 2.2 1.9 2.6 4.4"/></svg>`,
  machines: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><rect x="6" y="3" width="12" height="18" rx="2"/><rect x="9" y="6" width="6" height="4" rx="1"/><path d="M12 13.5c-1.5 0-2.5 1.2-2.5 2.6v1.4M14.5 17.5v-1.4c0-.6-.2-1.2-.5-1.6" stroke-linecap="round"/></svg>`,
  history: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 12a8 8 0 1 0 2.4-5.7L4 8.5"/><path d="M4 4v4.5h4.5M12 8v4.5l3 1.8"/></svg>`,
};

const NAV: Array<[string, string]> = [
  ["overview", "Overview"], ["reports", "Reports"], ["employees", "Employees"], ["machines", "Machines"], ["history", "Sync history"],
];

export function appPage(auth: AuthContext): string {
  const e = escapeHtml;
  const canManage = auth.role === "owner" || auth.role === "admin";
  const manageOnly = canManage ? "" : " hidden";
  const nav = NAV.map(([id, label]) =>
    `<a href="#${id}" data-page="${id}">${ICONS[id]}<span>${label}</span><span class="count" id="count_${id}"></span></a>`).join("");

  return layout("Dashboard", `
<div class="shell">
  <aside class="side">
    <a class="brand" href="#overview">${LOGO}<div><div class="brand-name">HR Attendance</div><div class="brand-co">${e(auth.companyName)}</div></div></a>
    <nav class="nav" aria-label="Main">${nav}</nav>
    <div class="side-foot">
      <div class="who">${e(auth.fullName)}</div>
      <div class="role">${e(auth.role)}</div>
      <button class="btn btn-quiet" id="logout" type="button">Sign out</button>
      <div class="ver">${VERSION}</div>
    </div>
  </aside>

  <main class="main" id="main">
    <!-- ============================== Overview -->
    <section class="page" id="page-overview">
      <div class="page-head">
        <div><h1>Overview</h1><p id="ov_sub">Who came in, when, and whether the machine is syncing.</p></div>
        <div class="page-actions"><button class="btn btn-ghost" id="sync_all_ov" type="button"${manageOnly}>Sync all machines now</button></div>
      </div>
      <div class="notices" data-alerts aria-live="polite"></div>
      <div class="stack">
        <div class="panel"><div class="summary" id="summary">
          <div><div class="k">Came in</div><div class="v" id="s_in">&nbsp;</div><div class="d" id="s_in_d">&nbsp;</div></div>
          <div><div class="k">Punches</div><div class="v" id="s_punches">&nbsp;</div><div class="d" id="s_punches_d">&nbsp;</div></div>
          <div><div class="k">Last sync</div><div class="v" id="s_sync">&nbsp;</div><div class="d" id="s_sync_d">&nbsp;</div></div>
          <div><div class="k">Next Excel report</div><div class="v" id="s_next">&nbsp;</div><div class="d" id="s_next_d">&nbsp;</div></div>
        </div></div>

        <div class="panel">
          <div class="panel-head">
            <div><h2>Attendance timeline</h2><p>Bars run from first punch to last punch. An amber mark means only one punch, so the check-out is missing.</p></div>
            <div class="day-nav">
              <button class="btn btn-ghost btn-sm" id="day_prev" type="button" aria-label="Previous day">&#8249;</button>
              <span class="day-label" id="day_label"></span>
              <button class="btn btn-ghost btn-sm" id="day_next" type="button" aria-label="Next day">&#8250;</button>
              <button class="btn btn-quiet btn-sm" id="day_today" type="button">Today</button>
            </div>
          </div>
          <div class="tl" id="timeline"></div>
          <div class="absent" id="absent" hidden></div>
        </div>
      </div>
    </section>

    <!-- ============================== Reports -->
    <section class="page" id="page-reports" hidden>
      <div class="page-head">
        <div><h1>Reports</h1><p id="r_sched">An Excel report of the previous two days is prepared automatically every two days.</p></div>
        <div class="page-actions"><button class="btn btn-ghost" id="sync_all" type="button"${manageOnly}>Sync all machines now</button></div>
      </div>
      <div class="stack">
        <div class="panel">
          <div class="panel-head"><div><h2>Scheduled reports</h2><p>Each file has a daily summary (first in, last out, hours) and every punch. It's built when you download it, so late punches are included.</p></div></div>
          <div class="table-wrap"><table>
            <thead><tr><th>Period</th><th>Status</th><th class="num">Machines synced</th><th class="num">Employees</th><th class="num">Punches</th><th>Ready</th><th>Note</th><th></th></tr></thead>
            <tbody id="r_rows"></tbody>
          </table></div>
        </div>
        <div class="panel">
          <div class="panel-head"><div><h2>Export any dates</h2><p>Up to 62 days in one file.</p></div></div>
          <div class="panel-body">
            <div class="form-row cols-exp">
              <div class="field"><label for="x_from">From</label><input class="input" id="x_from" type="date"></div>
              <div class="field"><label for="x_to">To</label><input class="input" id="x_to" type="date"></div>
              <button class="btn btn-primary" id="x_go" type="button">Download Excel</button>
            </div>
            <div class="error-text" id="x_msg" style="margin-top:8px"></div>
          </div>
        </div>
      </div>
    </section>

    <!-- ============================== Employees -->
    <section class="page" id="page-employees" hidden>
      <div class="page-head">
        <div><h1>Employees</h1><p id="e_sub">Names are read from the machine on every sync.</p></div>
        <div class="page-actions"><input class="input search" id="e_search" type="search" placeholder="Search name, ID or department" aria-label="Search employees"></div>
      </div>
      <div class="panel">
        <div class="table-wrap" style="margin-top:0;border-top:0;border-radius:12px">
          <table>
            <thead><tr><th class="num">User ID</th><th>Name</th><th>Department</th><th>Name from</th><th>Last punch</th><th></th></tr></thead>
            <tbody id="e_rows"></tbody>
          </table>
        </div>
      </div>
      <div class="error-text" id="e_msg" style="margin-top:10px"></div>
    </section>

    <!-- ============================== Machines -->
    <section class="page" id="page-machines" hidden>
      <div class="page-head">
        <div><h1>Machines</h1><p>The connector is a small program on an office PC that reads the attendance machine and sends the punches here. It only reads: nothing on the machine is changed or cleared.</p></div>
      </div>
      <div class="notices" data-alerts aria-live="polite"></div>
      <div class="stack">
        <div class="panel">
          <div class="panel-head"><div><h2>Connectors</h2><p>One per office PC. Download the installer, extract it on a Windows PC on the machine's network and double-click Install.cmd.</p></div></div>
          <div class="panel-body"${manageOnly}>
            <div class="form-row cols-2">
              <div class="field"><label for="c_name">New connector name</label><input class="input" id="c_name" placeholder="e.g. Reception PC"></div>
              <button class="btn btn-primary" id="c_add" type="button">Create connector</button>
            </div>
            <div class="error-text" id="c_msg" style="margin-top:8px"></div>
            <div id="c_token"></div>
          </div>
          <div class="table-wrap"><table>
            <thead><tr><th>Name</th><th>Status</th><th>Version</th><th>Last seen</th><th class="num">Machines</th><th>Token</th><th></th></tr></thead>
            <tbody id="c_rows"></tbody>
          </table></div>
        </div>

        <div class="panel">
          <div class="panel-head"><div><h2>Attendance machines</h2><p>Find the IP and comm key on the machine under Menu, then COMM. The default port is 4370.</p></div></div>
          <div class="panel-body"${manageOnly}>
            <div class="form-row cols-dev">
              <div class="field"><label for="d_name">Machine name</label><input class="input" id="d_name" placeholder="e.g. Main entrance"></div>
              <div class="field"><label for="d_ip">IP address</label><input class="input" id="d_ip" placeholder="192.168.10.21" inputmode="decimal"></div>
              <div class="field"><label for="d_port">Port</label><input class="input" id="d_port" value="4370" inputmode="numeric"></div>
              <div class="field"><label for="d_key">Comm key</label><input class="input" id="d_key" value="0" inputmode="numeric"></div>
              <div class="field"><label for="d_conn">Read by connector</label><select class="input" id="d_conn"></select></div>
              <button class="btn btn-primary" id="d_add" type="button">Add machine</button>
            </div>
            <div class="error-text" id="d_msg" style="margin-top:8px"></div>
          </div>
          <div class="table-wrap"><table>
            <thead><tr><th>Machine</th><th>Last sync</th><th>Clock</th><th class="num">Punches</th><th>Connector</th><th></th></tr></thead>
            <tbody id="d_rows"></tbody>
          </table></div>
        </div>
      </div>
    </section>

    <!-- ============================== Sync history -->
    <section class="page" id="page-history" hidden>
      <div class="page-head">
        <div><h1>Sync history</h1><p>Every time the connector read a machine. Read counts every punch on the machine; New counts the ones imported for the first time.</p></div>
      </div>
      <div class="panel">
        <div class="table-wrap" style="margin-top:0;border-top:0;border-radius:12px"><table>
          <thead><tr><th>Requested</th><th>Machine</th><th>Started by</th><th>Status</th><th class="num">Read</th><th class="num">New</th><th class="num">Skipped</th><th>Finished</th><th>Details</th><th></th></tr></thead>
          <tbody id="j_rows"></tbody>
        </table></div>
      </div>
    </section>
  </main>
</div>
<div class="toast" id="toast" role="status" aria-live="polite"></div>
<dialog class="dlg" id="dlg" aria-labelledby="dlg_title">
  <form method="dialog">
    <div class="dlg-body"><h3 id="dlg_title"></h3><div id="dlg_content"></div><div class="error-text" id="dlg_msg" style="margin-top:10px"></div></div>
    <div class="dlg-foot"><button class="btn btn-ghost" value="cancel" type="submit">Cancel</button><button class="btn btn-danger-solid" id="dlg_ok" value="ok" type="submit"></button></div>
  </form>
</dialog>
<script>var CAN_MANAGE = ${canManage ? "true" : "false"};</script>
${DASH_SCRIPT}`);
}

// Client script. Written with String.raw: no template substitutions or backticks inside.
const DASH_SCRIPT = String.raw`<script>
var DASH = "\u2014";
var MONTHS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
var DAYS = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];

/* ---------- helpers */
async function api(method, path, body) {
  var opts = { method: method, headers: {} };
  if (body !== undefined) { opts.headers["content-type"] = "application/json"; opts.body = JSON.stringify(body); }
  var res = await fetch(path, opts);
  var data = await res.json().catch(function () { return {}; });
  if (res.status === 401) { location.href = "/login"; throw new Error("Signed out"); }
  if (!res.ok) throw new Error(data.error || ("Request failed (" + res.status + ")"));
  return data;
}
function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text !== undefined && text !== null) e.textContent = text; return e; }
function td(text, cls) { return el("td", cls, (text === null || text === undefined || text === "") ? DASH : String(text)); }
function pill(text, kind) { var c = el("td"); c.appendChild(el("span", "pill " + kind, text)); return c; }
function btn(label, kind, onClick) { var b = el("button", "btn btn-sm " + kind, label); b.type = "button"; b.addEventListener("click", onClick); return b; }
function emptyRow(tbody, cols, text) { var tr = el("tr"); var c = el("td", "empty", text); c.colSpan = cols; tr.appendChild(c); tbody.appendChild(tr); }
function setText(id, text) { document.getElementById(id).textContent = text || ""; }
var toastTimer;
function toast(text) { var t = document.getElementById("toast"); t.textContent = text; t.classList.add("show"); clearTimeout(toastTimer); toastTimer = setTimeout(function () { t.classList.remove("show"); }, 3500); }

function pad(n) { return String(n).padStart(2, "0"); }
function isoDay(d) { return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()); }
function parseDay(s) { var p = s.split("-"); return new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2])); }
function addDays(s, n) { var d = parseDay(s); d.setDate(d.getDate() + n); return isoDay(d); }
function fmtDay(s) { var d = parseDay(s); return d.getDate() + " " + MONTHS[d.getMonth()] + " " + d.getFullYear(); }
function fmtDayShort(s) { var d = parseDay(s); return DAYS[d.getDay()] + " " + d.getDate() + " " + MONTHS[d.getMonth()]; }
function period(a, b) { return a === b ? fmtDay(a) : (parseDay(a).getDate() + " " + MONTHS[parseDay(a).getMonth()] + " \u2013 " + fmtDay(b)); }
function shortPeriod(a, b) {
  var x = parseDay(a), y = parseDay(b);
  if (a === b) return y.getDate() + " " + MONTHS[y.getMonth()];
  return x.getMonth() === y.getMonth() ? x.getDate() + "\u2013" + y.getDate() + " " + MONTHS[y.getMonth()]
    : x.getDate() + " " + MONTHS[x.getMonth()] + " \u2013 " + y.getDate() + " " + MONTHS[y.getMonth()];
}
function when(iso) {
  if (!iso) return DASH;
  var d = new Date(iso);
  return d.getDate() + " " + MONTHS[d.getMonth()] + ", " + pad(d.getHours()) + ":" + pad(d.getMinutes());
}
function ago(iso) {
  if (!iso) return "Never";
  var m = Math.round((Date.now() - new Date(iso).getTime()) / 60000);
  if (m < 1) return "Just now";
  if (m < 60) return m + " min ago";
  if (m < 48 * 60) return Math.round(m / 60) + " h ago";
  return Math.round(m / 1440) + " days ago";
}
function punchTime(s) { return s ? s.slice(0, 16).replace(" ", ", ") : DASH; }
function minutes(t) { var p = t.split(":"); return Number(p[0]) * 60 + Number(p[1]); }
function dur(mins) { return Math.floor(mins / 60) + "h " + pad(mins % 60) + "m"; }

/* ---------- confirm dialog: onConfirm may throw to keep the dialog open with the error */
function confirmDialog(title, content, okLabel, onConfirm) {
  var dlg = document.getElementById("dlg");
  setText("dlg_title", title);
  var box = document.getElementById("dlg_content"); box.textContent = "";
  (Array.isArray(content) ? content : [content]).forEach(function (n) { box.appendChild(typeof n === "string" ? el("p", null, n) : n); });
  setText("dlg_msg", "");
  var ok = document.getElementById("dlg_ok"); ok.textContent = okLabel; ok.disabled = false;
  ok.onclick = async function (ev) {
    ev.preventDefault();
    ok.disabled = true;
    try { await onConfirm(); dlg.close(); }
    catch (err) { setText("dlg_msg", err.message); ok.disabled = false; }
  };
  dlg.showModal();
}

/* ---------- navigation */
var PAGES = ["overview", "reports", "employees", "machines", "history"];
function showPage() {
  var id = (location.hash || "#overview").slice(1);
  if (PAGES.indexOf(id) < 0) id = "overview";
  PAGES.forEach(function (p) {
    document.getElementById("page-" + p).hidden = p !== id;
    var a = document.querySelector('.nav a[data-page="' + p + '"]');
    if (p === id) a.setAttribute("aria-current", "page"); else a.removeAttribute("aria-current");
  });
  document.title = document.querySelector('.nav a[data-page="' + id + '"] span').textContent + " - HR Attendance";
  window.scrollTo(0, 0);
}
window.addEventListener("hashchange", showPage);

/* ---------- status notices */
async function loadStatus() {
  var data = await api("GET", "/api/status");
  document.querySelectorAll(".notices[data-alerts]").forEach(function (box) {
    box.textContent = "";
    box.hidden = !data.alerts.length;
    data.alerts.forEach(function (a) { box.appendChild(el("div", "notice " + a.level, a.text)); });
  });
  var urgent = data.alerts.filter(function (a) { return a.level !== "info"; }).length;
  document.getElementById("count_machines").dataset.dot = urgent ? "1" : "";
}

/* ---------- overview */
var ovDate = null;
var ovToday = null;
async function loadOverview() {
  var data = await api("GET", "/api/overview" + (ovDate ? "?date=" + ovDate : ""));
  ovDate = data.date; ovToday = data.today;
  var isToday = data.date === data.today;
  document.getElementById("day_label").textContent = isToday ? "Today, " + fmtDayShort(data.date) : fmtDayShort(data.date) + " " + parseDay(data.date).getFullYear();
  document.getElementById("day_next").disabled = isToday;
  document.getElementById("day_today").hidden = isToday;

  var total = data.present.length + data.absent.length;
  var s_in = document.getElementById("s_in"); s_in.textContent = data.present.length + " ";
  s_in.appendChild(el("small", null, "of " + total));
  var singles = data.present.filter(function (p) { return p.punches.length === 1; }).length;
  setText("s_in_d", singles ? singles + " without check-out" : (data.present.length ? "All with check-out" : (isToday ? "No punches yet today" : "No punches")));
  setText("s_punches", data.punches);
  setText("s_punches_d", isToday ? "So far today" : fmtDay(data.date));
  setText("s_sync", data.machines ? ago(data.last_sync) : "No machine");
  setText("s_sync_d", data.machines ? (data.machines + " machine" + (data.machines > 1 ? "s" : "")) : "Add one under Machines");
  var sc = data.schedule;
  setText("s_next", fmtDayShort(sc.next_due));
  setText("s_next_d", "After " + pad(sc.hour) + ":00, for " + shortPeriod(sc.next_start, sc.next_end));
  renderTimeline(data, isToday);
}

function renderTimeline(data, isToday) {
  var box = document.getElementById("timeline");
  box.textContent = "";
  var absentBox = document.getElementById("absent");
  absentBox.textContent = "";
  absentBox.hidden = !data.absent.length || !data.present.length;

  if (!data.present.length) {
    box.appendChild(el("div", "tl-empty", isToday
      ? "No one has punched in yet today. Punches appear here after the next sync."
      : "No punches on this day."));
    return;
  }

  // Axis: whole hours around the earliest and latest punch, at least 06:00 - 20:00.
  var first = 24 * 60, last = 0;
  data.present.forEach(function (p) { first = Math.min(first, minutes(p.punches[0])); last = Math.max(last, minutes(p.punches[p.punches.length - 1])); });
  var startH = Math.max(0, Math.min(6, Math.floor(first / 60) - 1));
  var endH = Math.min(24, Math.max(20, Math.ceil(last / 60) + 1));
  var span = (endH - startH) * 60;
  function pos(m) { return ((m - startH * 60) / span * 100) + "%"; }
  // Keep hour labels at least ~48px apart, whatever the screen width.
  var trackPx = Math.max(120, box.clientWidth - (window.innerWidth <= 860 ? 200 : 340));
  var step = [1, 2, 3, 4, 6, 12].find(function (h) { return trackPx / (endH - startH) * h >= 48; }) || 12;

  function gridInto(track, withLabels) {
    for (var h = startH; h <= endH; h++) {
      if ((h - startH) % step !== 0) continue;
      var g = el(withLabels ? "span" : "div", withLabels ? "tl-hour" : "tl-grid", withLabels ? pad(h) + ":00" : null);
      g.style.left = pos(h * 60);
      track.appendChild(g);
    }
  }

  var axis = el("div", "tl-row tl-axis");
  axis.appendChild(el("div"));
  var axisTrack = el("div", "tl-track"); gridInto(axisTrack, true); axis.appendChild(axisTrack);
  axis.appendChild(el("div", "tl-sum muted", "Hours"));
  box.appendChild(axis);

  var nowMin = null;
  if (isToday) { var n = new Date(); nowMin = n.getHours() * 60 + n.getMinutes(); }

  data.present.forEach(function (p) {
    var row = el("div", "tl-row");
    var who = el("div", "tl-who");
    who.appendChild(el("div", "n", p.name || ("User " + p.user_id)));
    who.appendChild(el("div", "i", "ID " + p.user_id + (p.department ? " \u00b7 " + p.department : "")));
    row.appendChild(who);

    var track = el("div", "tl-track");
    gridInto(track, false);
    var a = minutes(p.punches[0]), b = minutes(p.punches[p.punches.length - 1]);
    var single = p.punches.length === 1;
    if (!single) {
      var bar = el("div", "tl-bar"); bar.style.left = pos(a); bar.style.width = ((b - a) / span * 100) + "%";
      track.appendChild(bar);
    }
    p.punches.forEach(function (t) {
      var tick = el("div", "tl-tick" + (single ? " single" : ""));
      tick.style.left = pos(minutes(t));
      tick.title = t;
      track.appendChild(tick);
    });
    if (nowMin !== null && nowMin >= startH * 60 && nowMin <= endH * 60) {
      var now = el("div", "tl-now"); now.style.left = pos(nowMin); now.title = "Now"; track.appendChild(now);
    }
    var label = p.punches.join(", ");
    track.setAttribute("role", "img");
    track.setAttribute("aria-label", (p.name || "User " + p.user_id) + ": punches at " + label);
    track.title = label;
    row.appendChild(track);

    row.appendChild(single
      ? el("div", "tl-sum t-warn", "In " + p.punches[0])
      : el("div", "tl-sum", dur(b - a)));
    box.appendChild(row);
  });

  if (!absentBox.hidden) {
    absentBox.appendChild(el("span", "k", "No punch (" + data.absent.length + "):"));
    data.absent.forEach(function (x) { absentBox.appendChild(el("span", "chip", x.name || ("ID " + x.user_id))); });
  }
}

document.getElementById("day_prev").addEventListener("click", function () { ovDate = addDays(ovDate, -1); loadOverview().catch(function (e) { toast(e.message); }); });
document.getElementById("day_next").addEventListener("click", function () { if (ovDate < ovToday) { ovDate = addDays(ovDate, 1); loadOverview().catch(function (e) { toast(e.message); }); } });
document.getElementById("day_today").addEventListener("click", function () { ovDate = null; loadOverview().catch(function (e) { toast(e.message); }); });

/* ---------- reports */
async function loadReports() {
  var data = await api("GET", "/api/reports");
  var s = data.schedule;
  setText("r_sched", "Every " + s.every_days + " days, an Excel report of the previous " + s.every_days + " days is prepared after " +
    pad(s.hour) + ":00 (" + s.timezone + "). Next: " + period(s.next_start, s.next_end) + ", ready on " + fmtDay(s.next_due) + ".");
  var tbody = document.getElementById("r_rows");
  tbody.textContent = "";
  document.getElementById("count_reports").textContent = data.reports.length ? data.reports.length : "";
  if (!data.reports.length) emptyRow(tbody, 8, "No reports yet. The first one appears at the next scheduled time, or use Export any dates below.");
  data.reports.forEach(function (r) {
    var tr = el("tr");
    tr.appendChild(td(period(r.period_start, r.period_end)));
    tr.appendChild(r.status === "ready" ? pill("Ready", "ok") : pill("Collecting", "warn"));
    tr.appendChild(td(r.devices_synced + " of " + r.devices_total, "num"));
    tr.appendChild(td(r.status === "ready" ? r.employee_count : "", "num"));
    tr.appendChild(td(r.status === "ready" ? r.punch_count : "", "num"));
    tr.appendChild(td(r.ready_at ? when(r.ready_at) : ""));
    tr.appendChild(td(r.note, r.note ? "wrap t-warn" : "muted"));
    var actions = el("td", "actions");
    var a = el("a", "btn btn-sm " + (r.status === "ready" ? "btn-primary" : "btn-ghost"), "Download Excel");
    a.href = "/api/reports/" + r.id + "/download";
    actions.appendChild(a);
    tr.appendChild(actions);
    tbody.appendChild(tr);
  });
}

document.getElementById("x_from").value = isoDay(new Date(Date.now() - 2 * 86400000));
document.getElementById("x_to").value = isoDay(new Date(Date.now() - 86400000));
document.getElementById("x_go").addEventListener("click", function () {
  var from = document.getElementById("x_from").value;
  var to = document.getElementById("x_to").value;
  if (!from || !to) { setText("x_msg", "Choose both dates."); return; }
  if (to < from) { setText("x_msg", "The end date must be on or after the start date."); return; }
  setText("x_msg", "");
  location.href = "/api/export.xlsx?from=" + encodeURIComponent(from) + "&to=" + encodeURIComponent(to);
});

/* ---------- employees */
var empEditing = false;
var empData = [];
function cellInput(value, placeholder, maxLength, label) {
  var i = el("input", "input input-sm");
  i.value = value || ""; i.placeholder = placeholder || ""; i.maxLength = maxLength; i.setAttribute("aria-label", label);
  return i;
}
async function loadEmployees() {
  if (empEditing) return; // never wipe what someone is typing
  var data = await api("GET", "/api/employees");
  empData = data.employees;
  document.getElementById("count_employees").textContent = data.total || "";
  setText("e_sub", data.total + " employee" + (data.total === 1 ? "" : "s") +
    (data.unnamed ? ", " + data.unnamed + " without a name" : "") +
    ". Names are read from the machine on every sync." +
    (CAN_MANAGE ? " Type a name to override it; clear it to use the machine's name again." : ""));
  renderEmployees();
}
var empEditingId = null;
function renderEmployees() {
  var q = document.getElementById("e_search").value.trim().toLowerCase();
  var tbody = document.getElementById("e_rows");
  tbody.textContent = "";
  var list = empData.filter(function (e) {
    return !q || (e.user_id + " " + e.name + " " + (e.machine_name || "") + " " + e.department).toLowerCase().indexOf(q) >= 0;
  });
  if (!empData.length) { emptyRow(tbody, 6, "No employees yet. They appear after the first sync."); return; }
  if (!list.length) { emptyRow(tbody, 6, "No employee matches \u201c" + q + "\u201d."); return; }
  list.forEach(function (e) { tbody.appendChild(e.user_id === empEditingId ? editRow(e) : viewRow(e)); });
}
function viewRow(e) {
  var tr = el("tr");
  tr.appendChild(td(e.user_id, "num"));
  var name = el("td");
  if (e.name) name.appendChild(el("span", null, e.name)); else name.appendChild(el("span", "pill warn", "Needs a name"));
  tr.appendChild(name);
  tr.appendChild(td(e.department, e.department ? "" : "muted"));
  tr.appendChild(td(e.name_edited ? "Edited here" : (e.machine_name ? "Machine" : ""), "muted"));
  tr.appendChild(td(punchTime(e.last_punch), "muted"));
  var actions = el("td", "actions");
  if (CAN_MANAGE) actions.appendChild(btn("Edit", "btn-ghost", function () {
    empEditingId = e.user_id; empEditing = true; renderEmployees();
    var f = document.querySelector("#e_rows input"); if (f) f.focus();
  }));
  tr.appendChild(actions);
  return tr;
}
function editRow(e) {
  var tr = el("tr", "editing");
  tr.appendChild(td(e.user_id, "num"));
  var nameIn = cellInput(e.name, e.machine_name || "Enter a name", 80, "Name for user " + e.user_id);
  var deptIn = cellInput(e.department, "Add department", 60, "Department for user " + e.user_id);
  var c1 = el("td"); c1.appendChild(nameIn);
  if (e.machine_name) c1.appendChild(el("span", "sub-id", "On the machine: " + e.machine_name));
  tr.appendChild(c1);
  var c2 = el("td"); c2.appendChild(deptIn); tr.appendChild(c2);
  tr.appendChild(td(e.name_edited ? "Edited here" : (e.machine_name ? "Machine" : ""), "muted"));
  tr.appendChild(td(punchTime(e.last_punch), "muted"));
  function done() { empEditingId = null; empEditing = false; }
  var save = btn("Save", "btn-primary", async function () {
    save.disabled = true;
    var name = nameIn.value.trim();
    // Same as the machine's name (or empty): keep following the machine.
    if (e.machine_name && name === e.machine_name) name = "";
    try {
      await api("PUT", "/api/employees/" + encodeURIComponent(e.user_id), { name: name, department: deptIn.value });
      setText("e_msg", "");
      done();
      toast("Saved " + (name || e.machine_name || "user " + e.user_id));
      await loadEmployees();
    } catch (err) { setText("e_msg", err.message); save.disabled = false; }
  });
  var cancel = btn("Cancel", "btn-quiet", function () { done(); setText("e_msg", ""); renderEmployees(); });
  [nameIn, deptIn].forEach(function (x) {
    x.addEventListener("keydown", function (ev) { if (ev.key === "Enter") save.click(); if (ev.key === "Escape") cancel.click(); });
  });
  var c3 = el("td", "actions"); c3.appendChild(cancel); c3.appendChild(save); tr.appendChild(c3);
  return tr;
}
document.getElementById("e_search").addEventListener("input", function () { if (!empEditing) renderEmployees(); });

/* ---------- machines: connectors */
async function downloadInstaller(connectorId, token) {
  var res = await fetch("/api/connectors/" + connectorId + "/package", {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(token ? { token: token } : {})
  });
  if (res.status === 401) { location.href = "/login"; throw new Error("Signed out"); }
  if (!res.ok) { var d = await res.json().catch(function () { return {}; }); throw new Error(d.error || ("Download failed (" + res.status + ")")); }
  var blob = await res.blob();
  var m = /filename="([^"]+)"/.exec(res.headers.get("content-disposition") || "");
  var a = el("a"); a.href = URL.createObjectURL(blob); a.download = m ? m[1] : "ZKT-Connector.zip";
  document.body.appendChild(a); a.click();
  setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 2000);
}

var connectorsData = [];
var devicesData = [];
async function loadConnectors() {
  var data = await api("GET", "/api/connectors");
  var tbody = document.getElementById("c_rows");
  var select = document.getElementById("d_conn");
  tbody.textContent = ""; select.textContent = "";
  var active = data.connectors.filter(function (c) { return c.is_active; });
  connectorsData = data.connectors;
  if (!active.length) { var o0 = el("option", null, "Create a connector first"); o0.value = ""; select.appendChild(o0); }
  if (!data.connectors.length) emptyRow(tbody, 7, "No connectors yet. Create one above, then download its installer.");
  data.connectors.forEach(function (c) {
    var tr = el("tr");
    tr.appendChild(td(c.name));
    var online = c.last_seen_at && (Date.now() - new Date(c.last_seen_at).getTime()) < 10 * 60000;
    tr.appendChild(!c.is_active ? pill("Revoked", "idle") : !c.last_seen_at ? pill("Not installed", "warn") : online ? pill("Online", "ok") : pill("Offline", "bad"));
    tr.appendChild(td(c.version, "muted"));
    tr.appendChild(td(c.last_seen_at ? ago(c.last_seen_at) : "", "muted"));
    tr.appendChild(td(c.device_count, "num"));
    tr.appendChild(td(c.token_hint ? "\u2026" + c.token_hint : "", "muted"));
    var actions = el("td", "actions");
    var deletable = !c.is_active || (!c.last_seen_at && !c.device_count);
    if (CAN_MANAGE && deletable) {
      actions.appendChild(btn("Delete", "btn-danger", function () {
        confirmDialog("Delete " + c.name + "?",
          [c.is_active ? "This connector was never installed. Deleting it removes it from this list." :
            "This connector is revoked and can no longer sync. Deleting it removes it from this list. Attendance already imported is kept."],
          "Delete connector",
          async function () { await api("DELETE", "/api/connectors/" + c.id); toast("Deleted " + c.name); await refreshMachines(); });
      }));
    }
    if (CAN_MANAGE && c.is_active) {
      actions.appendChild(btn("Download installer", "btn-ghost", async function () {
        if (c.last_seen_at && !confirm("Download a new installer for " + c.name + "?\n\nThis creates a new token. The PC that runs this connector now stops syncing until you run Install.cmd from the new download on it.")) return;
        try { await downloadInstaller(c.id, null); toast("Installer downloaded. Extract it on the office PC and run Install.cmd."); await refreshMachines(); }
        catch (err) { setText("c_msg", err.message); }
      }));
      actions.appendChild(btn("Revoke", "btn-danger", async function () {
        if (!confirm("Revoke " + c.name + "? It stops syncing immediately.")) return;
        try { await api("POST", "/api/connectors/" + c.id + "/revoke", {}); toast("Revoked " + c.name); await refreshMachines(); } catch (err) { setText("c_msg", err.message); }
      }));
    }
    tr.appendChild(actions);
    tbody.appendChild(tr);
  });
  active.forEach(function (c) { var o = el("option", null, c.name); o.value = c.id; select.appendChild(o); });
}

document.getElementById("c_add").addEventListener("click", async function () {
  setText("c_msg", "");
  var box = document.getElementById("c_token"); box.textContent = "";
  try {
    var r = await api("POST", "/api/connectors", { name: document.getElementById("c_name").value });
    var wrap = el("div", "setup");
    wrap.appendChild(el("h3", null, "Install " + r.connector.name + " on the office PC"));
    var steps = el("ol");
    ["Download the installer. It's already set up for your company.",
     "Copy the ZIP to a Windows PC on the same network as the machine.",
     "Right-click the ZIP, choose Extract All, then double-click Install.cmd and click Yes."].forEach(function (t) { steps.appendChild(el("li", null, t)); });
    wrap.appendChild(steps);
    var dl = btn("Download installer", "btn-primary", async function () {
      dl.disabled = true;
      try { await downloadInstaller(r.connector.id, r.token); dl.textContent = "Downloaded"; toast("Installer downloaded"); }
      catch (err) { setText("c_msg", err.message); dl.disabled = false; }
    });
    dl.classList.remove("btn-sm");
    wrap.appendChild(dl);
    var adv = el("details");
    adv.appendChild(el("summary", null, "Show the token for manual setup"));
    adv.appendChild(el("code", null, r.token));
    var copy = btn("Copy token", "btn-ghost", function () { navigator.clipboard.writeText(r.token); copy.textContent = "Copied"; });
    adv.appendChild(copy);
    wrap.appendChild(adv);
    box.appendChild(wrap);
    document.getElementById("c_name").value = "";
    await refreshMachines();
  } catch (err) { setText("c_msg", err.message); }
});

/* ---------- machines: devices */
function clockText(sec) {
  if (sec === null || sec === undefined) return null;
  var a = Math.abs(sec);
  if (a <= 60) return { t: "Correct", k: "ok" };
  var t = a < 5400 ? Math.round(a / 60) + " min" : a < 172800 ? Math.round(a / 3600) + " h" : Math.round(a / 86400) + " days";
  return { t: t + (sec < 0 ? " slow" : " fast"), k: "warn" };
}
var devicesTimer = null;
function syncCell(d, active) {
  var c = el("td");
  var st = d.last_job_status;
  if (!d.is_active) { c.appendChild(el("span", "pill idle", "Inactive")); return c; }
  if (active) {
    var box = el("div", "prog");
    var waitingFor = st === "pending" ? Math.round((Date.now() - new Date(d.job_requested_at).getTime()) / 1000) : 0;
    var text = st === "pending"
      ? (d.connector_seen && Date.now() - new Date(d.connector_seen).getTime() < 120000
          ? "Starting\u2026 the connector picks this up in a few seconds"
          : "Waiting for the connector. It looks offline: check that the office PC is on.")
      : (d.job_msg || "Syncing\u2026");
    box.appendChild(el("div", "prog-text", text));
    var bar = el("div", "prog-bar" + (d.job_pct === null || d.job_pct === undefined || st === "pending" || d.job_stage === "retrying" ? " busy" : ""));
    var fill = el("span"); fill.style.width = (d.job_pct || 0) + "%"; bar.appendChild(fill);
    box.appendChild(bar);
    if (st === "pending" && waitingFor > 20) box.appendChild(el("div", "prog-meta", "Waiting " + waitingFor + " s. It stops by itself after 10 minutes."));
    c.appendChild(box);
    return c;
  }
  if (st === "failed") {
    c.appendChild(el("span", "pill bad", "Failed " + (d.job_finished_at ? ago(d.job_finished_at).toLowerCase() : "")));
    if (d.job_error) { var f = el("span", "fail-text", d.job_error); f.title = d.job_error; c.appendChild(f); }
    return c;
  }
  c.appendChild(el("span", "pill " + (st === "success" ? "ok" : "idle"), d.last_sync_at ? ago(d.last_sync_at) : "Never"));
  if (st === "success" && d.job_new !== null && d.job_new !== undefined) c.appendChild(el("span", "sub-id", d.job_new + " new punches"));
  return c;
}

async function loadDevices() {
  var anyActive = false;
  var data = await api("GET", "/api/devices");
  var tbody = document.getElementById("d_rows");
  tbody.textContent = "";
  devicesData = data.devices;
  document.getElementById("count_machines").textContent = data.devices.filter(function (d) { return d.is_active; }).length || "";
  if (!data.devices.length) emptyRow(tbody, 6, "No machines yet. Add your attendance machine above.");
  data.devices.forEach(function (d) {
    var tr = el("tr");
    var name = el("td"); name.appendChild(document.createTextNode(d.name));
    name.appendChild(el("span", "sub-id", d.ip_address + ":" + d.port + (d.is_active ? "" : " \u00b7 deactivated")));
    if (d.serial_number) name.appendChild(el("span", "sub-id", "Serial " + d.serial_number));
    tr.appendChild(name);
    var st = d.last_job_status;
    var active = d.is_active && (st === "pending" || st === "running");
    if (active) { anyActive = true; tr.className = "syncing"; }
    tr.appendChild(syncCell(d, active));
    var ck = clockText(d.clock_offset_seconds);
    tr.appendChild(ck ? pill(ck.t, ck.k) : td(""));
    tr.appendChild(td(d.log_count, "num"));
    tr.appendChild(td(d.connector_name, "muted"));
    var actions = el("td", "actions");
    if (CAN_MANAGE && active) {
      actions.appendChild(btn("Stop", "btn-danger", async function () {
        try { await api("POST", "/api/sync-jobs/" + d.job_id + "/cancel", {}); toast("Stopped the sync of " + d.name); await refreshMachines(); }
        catch (err) { toast(err.message); await refreshMachines(); }
      }));
    } else if (CAN_MANAGE && d.is_active) {
      actions.appendChild(btn("Sync now", "btn-ghost", async function () {
        try {
          var r = await api("POST", "/api/devices/" + d.id + "/sync", {});
          toast(r.already_queued ? "A sync for " + d.name + " is already running." : "Sync started. Progress is shown here.");
          await refreshMachines();
        } catch (err) { setText("d_msg", err.message); }
      }));
      actions.appendChild(btn("Deactivate", "btn-danger", async function () {
        if (!confirm("Deactivate " + d.name + "? Its attendance data is kept.")) return;
        try { await api("POST", "/api/devices/" + d.id + "/deactivate", {}); toast("Deactivated " + d.name); await refreshMachines(); } catch (err) { setText("d_msg", err.message); }
      }));
    }
    if (CAN_MANAGE && !d.is_active) actions.appendChild(btn("Delete", "btn-danger", function () { deleteMachine(d); }));
    tr.appendChild(actions);
    tbody.appendChild(tr);
  });
  // While a sync runs, refresh every 1.5 s to show live progress; then refresh the rest once.
  clearTimeout(devicesTimer);
  if (anyActive) {
    devicesTimer = setTimeout(function () { quiet(loadDevices()); }, 1500);
    wasActive = true;
  } else if (wasActive) {
    wasActive = false;
    quiet(loadJobs()); quiet(loadStatus()); quiet(loadEmployees()); if (ovDate === ovToday) quiet(loadOverview());
  }
}
var wasActive = false;

function deleteMachine(d) {
  var punches = Number(d.log_count) || 0;
  if (!punches) {
    confirmDialog("Delete " + d.name + "?", ["This machine is deactivated and has no punches. Deleting it removes it from this list."], "Delete machine",
      async function () { await api("DELETE", "/api/devices/" + d.id, {}); toast("Deleted " + d.name); await refreshAll(); });
    return;
  }
  var targets = devicesData.filter(function (x) { return x.id !== d.id && x.is_active; });
  var opts = el("div", "dlg-opts");
  var moveSel = null;
  function option(value, title, hint, checked) {
    var lab = el("label", "dlg-opt");
    var r = el("input"); r.type = "radio"; r.name = "dlg_choice"; r.value = value; r.checked = checked;
    var txt = el("div"); txt.appendChild(el("div", null, title)); if (hint) txt.appendChild(el("div", "hint", hint));
    lab.appendChild(r); lab.appendChild(txt); opts.appendChild(lab);
    return txt;
  }
  if (targets.length) {
    var t = option("move", "Move the punches to another machine", "Keeps them in reports. Use this when the same machine was added again.", true);
    moveSel = el("select", "input input-sm");
    targets.forEach(function (x) { var o = el("option", null, x.name + " (" + x.ip_address + ")"); o.value = x.id; if (x.ip_address === d.ip_address) o.selected = true; moveSel.appendChild(o); });
    t.appendChild(moveSel);
  }
  option("delete", "Delete the punches too", "They disappear from all reports and Excel files. This can't be undone.", !targets.length);
  confirmDialog("Delete " + d.name + "?",
    ["This machine is deactivated but holds " + punches + " punches.", opts],
    "Delete machine",
    async function () {
      var choice = (document.querySelector('input[name="dlg_choice"]:checked') || {}).value;
      var body = choice === "move" ? { move_to: moveSel.value } : { delete_punches: true };
      var r = await api("DELETE", "/api/devices/" + d.id, body);
      var target = choice === "move" ? moveSel.options[moveSel.selectedIndex].textContent.replace(/ \(.*\)$/, "") : "";
      toast(choice !== "move" ? "Deleted " + d.name + " and its " + r.punches + " punches"
        : r.moved === r.punches ? "Deleted " + d.name + ". Moved " + r.moved + " punches to " + target + "."
        : "Deleted " + d.name + ". " + target + " already had " + (r.punches - r.moved) + " of its punches" + (r.moved ? "; moved the other " + r.moved + "." : ", so nothing was lost."));
      await refreshAll();
    });
}
document.getElementById("d_add").addEventListener("click", async function () {
  setText("d_msg", "");
  try {
    await api("POST", "/api/devices", {
      name: document.getElementById("d_name").value,
      ip_address: document.getElementById("d_ip").value,
      port: document.getElementById("d_port").value,
      comm_key: document.getElementById("d_key").value,
      connector_id: document.getElementById("d_conn").value
    });
    toast("Added " + document.getElementById("d_name").value);
    document.getElementById("d_name").value = "";
    document.getElementById("d_ip").value = "";
    await refreshMachines();
  } catch (err) { setText("d_msg", err.message); }
});

/* ---------- sync history */
async function loadJobs() {
  var data = await api("GET", "/api/sync-jobs?limit=30");
  var tbody = document.getElementById("j_rows");
  tbody.textContent = "";
  if (!data.jobs.length) emptyRow(tbody, 10, "No syncs yet. Click Sync now on a machine, or wait for the scheduled sync.");
  var anyActive = false;
  var LABEL = { success: ["Done", "ok"], failed: ["Failed", "bad"], pending: ["Waiting", "warn"], running: ["Syncing", "warn"] };
  data.jobs.forEach(function (j) {
    var tr = el("tr");
    tr.appendChild(td(when(j.requested_at)));
    tr.appendChild(td(j.device_name));
    tr.appendChild(td(j.trigger_type === "scheduled" ? "Schedule" : "Manual", "muted"));
    var l = LABEL[j.status] || [j.status, "idle"];
    tr.appendChild(pill(l[0], l[1]));
    tr.appendChild(td(j.status === "success" ? j.records_fetched + (j.records_skipped || 0) : "", "num"));
    tr.appendChild(td(j.status === "success" ? j.records_inserted : "", "num"));
    tr.appendChild(td(j.records_skipped || "", j.records_skipped ? "num t-warn" : "num muted"));
    tr.appendChild(td(j.finished_at ? when(j.finished_at) : ""));
    var isActive = j.status === "pending" || j.status === "running";
    if (isActive) anyActive = true;
    tr.appendChild(td(isActive ? (j.progress_msg || (j.status === "pending" ? "Waiting for the connector" : "Syncing")) + (j.progress_pct !== null && j.progress_pct !== undefined && j.status === "running" ? " (" + j.progress_pct + "%)" : "") : j.error_message,
      isActive ? "wrap muted" : j.error_message ? "wrap t-bad" : "muted"));
    var act = el("td", "actions");
    if (CAN_MANAGE && isActive) act.appendChild(btn("Stop", "btn-danger", async function () {
      try { await api("POST", "/api/sync-jobs/" + j.id + "/cancel", {}); toast("Sync stopped"); } catch (err) { toast(err.message); }
      quiet(loadJobs()); quiet(loadDevices());
    }));
    tr.appendChild(act);
    tbody.appendChild(tr);
  });
  clearTimeout(jobsTimer);
  if (anyActive) jobsTimer = setTimeout(function () { quiet(loadJobs()); }, 2000);
}
var jobsTimer = null;

/* ---------- sync all */
async function syncAllNow(b) {
  b.disabled = true;
  try {
    var r = await api("POST", "/api/devices/sync-all", {});
    toast(r.devices ? (r.queued ? "Sync started for " + r.queued + " machine" + (r.queued > 1 ? "s" : "") + ". Progress is shown under Machines." : "Already syncing.") : "No machine has an active connector yet.");
    await refreshAll();
  } catch (err) { toast(err.message); }
  b.disabled = false;
}
document.getElementById("sync_all").addEventListener("click", function () { syncAllNow(this); });
document.getElementById("sync_all_ov").addEventListener("click", function () { syncAllNow(this); });

document.getElementById("logout").addEventListener("click", async function () {
  await fetch("/api/auth/logout", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" });
  location.href = "/login";
});

/* ---------- refresh */
function quiet(p) { return p.catch(function (e) { if (e.message !== "Signed out") console.warn(e); }); }
function refreshMachines() { return Promise.all([quiet(loadConnectors()), quiet(loadDevices()), quiet(loadStatus())]); }
function refreshAll() {
  return Promise.all([quiet(loadStatus()), quiet(loadOverview()), quiet(loadReports()), quiet(loadEmployees()),
    quiet(loadConnectors()), quiet(loadDevices()), quiet(loadJobs())]);
}
showPage();
refreshAll();
setInterval(function () {
  if (document.hidden) return;
  quiet(loadStatus()); quiet(loadJobs()); quiet(loadReports()); quiet(loadDevices()); quiet(loadConnectors());
  if (ovDate === ovToday) quiet(loadOverview());
}, 20000);
</script>`;
'@

Write-Host ""
Write-Host "Phase 11 files written. Next steps are listed in the chat." -ForegroundColor Cyan
