# =====================================================================
# HR Auto Attendance Fetcher - PHASE 4 : ZKT Connector reads the machine
# (read-only ZKTeco TCP client). Run from the ROOT of the repo:
#   powershell -ExecutionPolicy Bypass -File .\phase-04-read-device.ps1
# =====================================================================
$ErrorActionPreference = "Stop"

function Write-File([string]$Path, [string]$Content) {
    $full = Join-Path (Get-Location) $Path
    $dir  = Split-Path $full -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($full, $Content.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  wrote $Path" -ForegroundColor Green
}

if (-not (Test-Path "connector/src/api.js")) {
    throw "Run this from the repo root, after Phase 3 (connector/src/api.js not found)."
}

Write-Host "Phase 4: writing ZKTeco read-only client..." -ForegroundColor Cyan

# ---------------------------------------------------------------- .gitignore
Write-File ".gitignore" @'
node_modules/
.wrangler/
.dev.vars
.env
dist/
*.log
output/
'@

# ---------------------------------------------------------------- connector/package.json
Write-File "connector/package.json" @'
{
  "name": "zkt-connector",
  "version": "0.4.0",
  "private": true,
  "type": "module",
  "scripts": {
    "start": "node src/index.js",
    "api-test": "node src/api-test.js",
    "read-device": "node src/read-device.js",
    "mock-device": "node test/mock-device.js",
    "test": "node --test test/zk.test.js"
  },
  "dependencies": {
    "dotenv": "^16.4.5"
  }
}
'@

# ---------------------------------------------------------------- connector/.env.example
Write-File "connector/.env.example" @'
# --- Attendance Fetcher SaaS (Cloudflare Worker) ---
API_BASE_URL=https://hr-attendance-fetcher.bilaljahangir1995.workers.dev
# Create a connector in the dashboard (/app) and paste its token here
CONNECTOR_TOKEN=zkc_paste_your_token_here

# How long to wait for the machine before giving up (ms)
DEVICE_TIMEOUT_MS=10000

# --- Optional fallback when no CONNECTOR_TOKEN is set. Normally the
# --- device IP / port / comm key come from the dashboard.
# DEVICE_IP=192.168.10.21
# DEVICE_PORT=4370
# DEVICE_COMM_KEY=0
'@

# ---------------------------------------------------------------- connector/src/api.js
Write-File "connector/src/api.js" @'
// HTTP client for the Attendance Fetcher Worker (connector side).
export const CONNECTOR_VERSION = "0.4.0";

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

# ---------------------------------------------------------------- connector/src/zk/protocol.js
Write-File "connector/src/zk/protocol.js" @'
// ZKTeco "ZK6" TCP protocol helpers (port 4370).
// Packet layout, checksum, comm-key scrambling and time decoding follow the
// public pyzk / zkemsdk implementations.

export const CMD = Object.freeze({
  OPTIONS_RRQ: 11,       // read a device option, e.g. ~SerialNumber
  ATTLOG_RRQ: 13,        // read all attendance records
  GET_FREE_SIZES: 50,    // read record counts / capacity
  GET_TIME: 201,         // read device clock
  CONNECT: 1000,
  EXIT: 1001,
  AUTH: 1102,            // send comm key
  PREPARE_DATA: 1500,    // device -> "large data follows"
  DATA: 1501,            // device -> data packet
  FREE_DATA: 1502,       // release the device's read buffer
  PREPARE_BUFFER: 1503,  // ask device to buffer a dataset
  READ_BUFFER: 1504,     // read a chunk of that buffer
  ACK_OK: 2000,
  ACK_ERROR: 2001,
  ACK_DATA: 2002,
  ACK_UNAUTH: 2005,
});

/**
 * The ONLY commands the connector is allowed to send. None of them change
 * anything on the machine: no clearing logs, no users, no time, no restart.
 */
export const READ_ONLY_COMMANDS = new Set([
  CMD.CONNECT, CMD.EXIT, CMD.AUTH,
  CMD.GET_FREE_SIZES, CMD.OPTIONS_RRQ, CMD.GET_TIME,
  CMD.PREPARE_BUFFER, CMD.READ_BUFFER, CMD.FREE_DATA,
]);

export const USHRT_MAX = 65535;
const TCP_MAGIC_1 = 0x5050;
const TCP_MAGIC_2 = 0x7d82;

export function checksum(buf) {
  let sum = 0;
  let i = 0;
  for (; i + 1 < buf.length; i += 2) {
    sum += buf[i] | (buf[i + 1] << 8);
    if (sum > USHRT_MAX) sum -= USHRT_MAX;
  }
  if (i < buf.length) sum += buf[buf.length - 1];
  while (sum > USHRT_MAX) sum -= USHRT_MAX;
  sum = ~sum;
  while (sum < 0) sum += USHRT_MAX;
  return sum & 0xffff;
}

/** Builds one TCP frame. Returns the bytes and the reply id that was used. */
export function buildFrame(command, sessionId, replyId, data = Buffer.alloc(0)) {
  const body = Buffer.alloc(8 + data.length);
  body.writeUInt16LE(command, 0);
  body.writeUInt16LE(0, 2);
  body.writeUInt16LE(sessionId, 4);
  body.writeUInt16LE(replyId, 6);
  data.copy(body, 8);

  const cs = checksum(body);
  let nextReply = replyId + 1;
  if (nextReply >= USHRT_MAX) nextReply -= USHRT_MAX;
  body.writeUInt16LE(cs, 2);
  body.writeUInt16LE(nextReply, 6);

  const top = Buffer.alloc(8);
  top.writeUInt16LE(TCP_MAGIC_1, 0);
  top.writeUInt16LE(TCP_MAGIC_2, 2);
  top.writeUInt32LE(body.length, 4);
  return Buffer.concat([top, body]);
}

/**
 * Splits a byte stream into frames. Returns { frames, rest }.
 * Throws if the stream is not ZKTeco TCP.
 */
export function parseFrames(buffer) {
  const frames = [];
  let buf = buffer;
  while (buf.length >= 8) {
    if (buf.readUInt16LE(0) !== TCP_MAGIC_1 || buf.readUInt16LE(2) !== TCP_MAGIC_2) {
      throw new Error("Invalid packet from device (not a ZKTeco TCP response)");
    }
    const len = buf.readUInt32LE(4);
    if (len < 8 || len > 64 * 1024 * 1024) throw new Error(`Invalid packet length from device: ${len}`);
    if (buf.length < 8 + len) break;
    const p = buf.subarray(8, 8 + len);
    frames.push({
      command: p.readUInt16LE(0),
      sessionId: p.readUInt16LE(4),
      replyId: p.readUInt16LE(6),
      data: Buffer.from(p.subarray(8)),
    });
    buf = buf.subarray(8 + len);
  }
  return { frames, rest: buf };
}

/** Scrambles the numeric comm key with the session id (zkemsdk MakeKey). */
export function makeCommKey(key, sessionId, ticks = 50) {
  const k0 = Number(key) >>> 0;
  let k = 0;
  for (let i = 0; i < 32; i++) {
    k = ((k2(k) | ((k0 >>> i) & 1)) >>> 0);
  }
  k = (k + Number(sessionId)) % 0x100000000;

  const b = Buffer.alloc(4);
  b.writeUInt32LE(k >>> 0, 0);
  const x = [b[0] ^ 0x5a, b[1] ^ 0x4b, b[2] ^ 0x53, b[3] ^ 0x4f]; // 'Z','K','S','O'
  const swapped = [x[2], x[3], x[0], x[1]];                          // swap the two 16-bit halves
  const B = ticks & 0xff;
  return Buffer.from([swapped[0] ^ B, swapped[1] ^ B, B, swapped[3] ^ B]);

  function k2(v) { return (v << 1) >>> 0; }
}

/** Device timestamps are packed local times (zkemsdk DecodeTime). */
export function decodeTime(t) {
  let v = t >>> 0;
  const second = v % 60; v = Math.floor(v / 60);
  const minute = v % 60; v = Math.floor(v / 60);
  const hour = v % 24; v = Math.floor(v / 24);
  const day = (v % 31) + 1; v = Math.floor(v / 31);
  const month = (v % 12) + 1; v = Math.floor(v / 12);
  const year = v + 2000;
  const p = (n) => String(n).padStart(2, "0");
  return `${year}-${p(month)}-${p(day)} ${p(hour)}:${p(minute)}:${p(second)}`;
}

/** Inverse of decodeTime (used by the mock device in tests). */
export function encodeTime(ts) {
  const m = /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$/.exec(ts);
  if (!m) throw new Error(`Bad timestamp ${ts}`);
  const [y, mo, d, h, mi, s] = m.slice(1).map(Number);
  return ((((y - 2000) * 12 * 31 + (mo - 1) * 31 + (d - 1)) * 24 + h) * 60 + mi) * 60 + s;
}

/**
 * Parses the attendance buffer. Record layout depends on firmware:
 *  40 bytes (TFT devices such as K40/K50), 16 bytes, or 8 bytes (old models).
 */
export function parseAttendance(buffer, recordCount) {
  if (buffer.length < 4 || recordCount <= 0) return { recordSize: 0, records: [] };
  const total = buffer.readUInt32LE(0);
  const body = buffer.subarray(4, 4 + total);
  const ratio = total / recordCount;
  const recordSize = ratio === 8 ? 8 : ratio === 16 ? 16 : 40;

  const records = [];
  for (let off = 0; off + recordSize <= body.length; off += recordSize) {
    const r = body.subarray(off, off + recordSize);
    if (recordSize === 40) {
      const uid = r.readUInt16LE(0);
      const userId = r.subarray(2, 26).toString("latin1").split("\0")[0].trim();
      records.push({
        user_id: userId || String(uid),
        timestamp: decodeTime(r.readUInt32LE(27)),
        state: r.readUInt8(31),
        verify_mode: r.readUInt8(26),
      });
    } else if (recordSize === 16) {
      records.push({
        user_id: String(r.readUInt32LE(0)),
        timestamp: decodeTime(r.readUInt32LE(4)),
        state: r.readUInt8(9),
        verify_mode: r.readUInt8(8),
      });
    } else {
      records.push({
        user_id: String(r.readUInt16LE(0)), // 8-byte format only stores the internal uid
        timestamp: decodeTime(r.readUInt32LE(3)),
        state: r.readUInt8(7),
        verify_mode: r.readUInt8(2),
      });
    }
  }
  return { recordSize, records };
}
'@

# ---------------------------------------------------------------- connector/src/zk/client.js
Write-File "connector/src/zk/client.js" @'
// Read-only ZKTeco TCP client. Every outgoing command is checked against
// READ_ONLY_COMMANDS, so this client cannot clear logs or change the machine.
import net from "node:net";
import {
  CMD, READ_ONLY_COMMANDS, USHRT_MAX,
  buildFrame, makeCommKey, parseFrames, parseAttendance, decodeTime,
} from "./protocol.js";

const MAX_CHUNK = 0xffc0; // max bytes per READ_BUFFER request over TCP

class FrameReader {
  constructor(socket) {
    this.buf = Buffer.alloc(0);
    this.frames = [];
    this.waiters = [];
    this.error = null;
    socket.on("data", (chunk) => {
      this.buf = Buffer.concat([this.buf, chunk]);
      try {
        const { frames, rest } = parseFrames(this.buf);
        this.buf = rest;
        for (const f of frames) {
          const w = this.waiters.shift();
          if (w) w.resolve(f);
          else this.frames.push(f);
        }
      } catch (err) {
        this.fail(err);
        socket.destroy();
      }
    });
    socket.on("error", (err) => this.fail(err));
    socket.on("close", () => this.fail(new Error("Connection closed by device")));
  }

  fail(err) {
    if (this.error) return;
    this.error = err;
    for (const w of this.waiters.splice(0)) w.reject(err);
  }

  next(timeoutMs) {
    if (this.frames.length) return Promise.resolve(this.frames.shift());
    if (this.error) return Promise.reject(this.error);
    return new Promise((resolve, reject) => {
      const w = {
        resolve: (f) => { clearTimeout(timer); resolve(f); },
        reject: (e) => { clearTimeout(timer); reject(e); },
      };
      const timer = setTimeout(() => {
        const i = this.waiters.indexOf(w);
        if (i >= 0) this.waiters.splice(i, 1);
        reject(new Error(`Device did not respond within ${timeoutMs} ms`));
      }, timeoutMs);
      this.waiters.push(w);
    });
  }
}

export class ZkClient {
  constructor({ ip, port = 4370, commKey = 0, timeoutMs = 10000 }) {
    this.ip = ip;
    this.port = Number(port);
    this.commKey = Number(commKey) || 0;
    this.timeoutMs = Number(timeoutMs) || 10000;
    this.socket = null;
    this.reader = null;
    this.sessionId = 0;
    this.replyId = USHRT_MAX - 1;
  }

  async connect() {
    this.socket = await new Promise((resolve, reject) => {
      const s = net.createConnection({ host: this.ip, port: this.port });
      const timer = setTimeout(() => {
        s.destroy();
        reject(new Error(`Cannot reach ${this.ip}:${this.port} (timeout after ${this.timeoutMs} ms). Check the IP, cable/Wi-Fi and that this PC is on the same network.`));
      }, this.timeoutMs);
      s.once("connect", () => { clearTimeout(timer); resolve(s); });
      s.once("error", (err) => {
        clearTimeout(timer);
        reject(new Error(`Cannot connect to ${this.ip}:${this.port}: ${err.code ?? err.message}`));
      });
    });
    this.socket.setNoDelay(true);
    this.reader = new FrameReader(this.socket);

    const res = await this.command(CMD.CONNECT);
    this.sessionId = res.sessionId;
    if (res.command === CMD.ACK_UNAUTH) {
      const auth = await this.command(CMD.AUTH, makeCommKey(this.commKey, this.sessionId));
      if (auth.command !== CMD.ACK_OK) {
        throw new Error("Device rejected the comm key. Check Menu > COMM > Comm Key on the machine and the device settings in the dashboard.");
      }
    } else if (res.command !== CMD.ACK_OK) {
      throw new Error(`Device refused the connection (response ${res.command})`);
    }
  }

  async command(cmd, data = Buffer.alloc(0)) {
    if (!READ_ONLY_COMMANDS.has(cmd)) {
      throw new Error(`Blocked: command ${cmd} is not on the read-only allowlist`);
    }
    if (!this.socket || !this.reader) throw new Error("Not connected");
    this.socket.write(buildFrame(cmd, this.sessionId, this.replyId, data));
    const res = await this.reader.next(this.timeoutMs);
    this.replyId = res.replyId;
    return res;
  }

  async getSizes() {
    const res = await this.command(CMD.GET_FREE_SIZES);
    if (res.command !== CMD.ACK_OK || res.data.length < 80) {
      throw new Error(`Could not read record counts (response ${res.command})`);
    }
    const f = (i) => res.data.readInt32LE(i * 4);
    return { users: f(4), fingerprints: f(6), records: f(8), recordsCapacity: f(16) };
  }

  async getSerialNumber() {
    const res = await this.command(CMD.OPTIONS_RRQ, Buffer.from("~SerialNumber\0", "latin1"));
    if (res.command !== CMD.ACK_OK) return null;
    const text = res.data.toString("latin1").split("\0")[0];
    const eq = text.indexOf("=");
    return eq >= 0 ? text.slice(eq + 1).trim() || null : null;
  }

  async getTime() {
    const res = await this.command(CMD.GET_TIME);
    if (res.command !== CMD.ACK_OK || res.data.length < 4) return null;
    return decodeTime(res.data.readUInt32LE(0));
  }

  async readChunk(start, size) {
    const req = Buffer.alloc(8);
    req.writeInt32LE(start, 0);
    req.writeInt32LE(size, 4);
    const res = await this.command(CMD.READ_BUFFER, req);

    if (res.command === CMD.DATA) return res.data;
    if (res.command === CMD.PREPARE_DATA) {
      const expected = res.data.readUInt32LE(0);
      const parts = [];
      let got = 0;
      while (got < expected) {
        const f = await this.reader.next(this.timeoutMs);
        if (f.command !== CMD.DATA) throw new Error(`Unexpected packet ${f.command} while reading data`);
        parts.push(f.data);
        got += f.data.length;
      }
      const ack = await this.reader.next(this.timeoutMs);
      if (ack.command !== CMD.ACK_OK) throw new Error(`Device did not confirm chunk (response ${ack.command})`);
      return Buffer.concat(parts).subarray(0, expected);
    }
    throw new Error(`Device refused chunk read (response ${res.command})`);
  }

  async readWithBuffer(dataCommand, onProgress) {
    const req = Buffer.alloc(11);
    req.writeInt8(1, 0);
    req.writeInt16LE(dataCommand, 1);
    req.writeInt32LE(0, 3);
    req.writeInt32LE(0, 7);
    const res = await this.command(CMD.PREPARE_BUFFER, req);

    if (res.command === CMD.DATA) return res.data; // small dataset sent directly
    if (res.command !== CMD.ACK_OK || res.data.length < 5) {
      throw new Error(`Device does not support buffered reads (response ${res.command})`);
    }

    const size = res.data.readUInt32LE(1);
    const parts = [];
    let start = 0;
    while (start < size) {
      const len = Math.min(MAX_CHUNK, size - start);
      parts.push(await this.readChunk(start, len));
      start += len;
      if (onProgress) onProgress(start, size);
    }
    await this.command(CMD.FREE_DATA);
    return Buffer.concat(parts);
  }

  /** Reads every attendance record stored on the machine. Nothing is deleted. */
  async getAttendance(onProgress) {
    const sizes = await this.getSizes();
    if (sizes.records <= 0) return { sizes, recordSize: 0, records: [] };
    const buffer = await this.readWithBuffer(CMD.ATTLOG_RRQ, onProgress);
    const { recordSize, records } = parseAttendance(buffer, sizes.records);
    return { sizes, recordSize, records };
  }

  async disconnect() {
    if (!this.socket) return;
    try {
      if (!this.reader.error) {
        this.socket.write(buildFrame(CMD.EXIT, this.sessionId, this.replyId));
        await Promise.race([this.reader.next(2000), new Promise((r) => setTimeout(r, 2000))]).catch(() => {});
      }
    } finally {
      this.socket.destroy();
      this.socket = null;
    }
  }
}

/** Connect, read everything we need, always disconnect. */
export async function readDevice(options, onProgress) {
  const client = new ZkClient(options);
  try {
    await client.connect();
    const serialNumber = await client.getSerialNumber();
    const deviceTime = await client.getTime();
    const { sizes, recordSize, records } = await client.getAttendance(onProgress);
    return { serialNumber, deviceTime, sizes, recordSize, records };
  } finally {
    await client.disconnect();
  }
}
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
import "dotenv/config";
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
  console.log("\nNothing was uploaded. Uploading to the dashboard comes in Phase 5.");
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
 * options: { records, recordSize=40, commKey=0, directLimit=1024, dataFrameSize=Infinity, serial }
 * Returns { server, port, received } - received lists every command code the client sent.
 */
export function startMockDevice(options = {}) {
  const records = options.records ?? sampleRecords(500);
  const recordSize = options.recordSize ?? 40;
  const commKey = options.commKey ?? 0;
  const directLimit = options.directLimit ?? 1024;
  const dataFrameSize = options.dataFrameSize ?? Infinity; // real devices send each chunk as one DATA packet
  const serial = options.serial ?? "MOCK0000K50";
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
          d.writeInt32LE(25, 4 * 4);
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
        } else if (f.command === CMD.PREPARE_BUFFER && f.data.readInt16LE(1) !== CMD.ATTLOG_RRQ) {
          received.push(`buffer:${f.data.readInt16LE(1)}`);
          out.push(reply(CMD.ACK_ERROR, f.replyId)); // only the attendance log is served
        } else if (f.command === CMD.PREPARE_BUFFER) {
          buffered = encodeRecords(records, recordSize);
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
        // Coalesce into one write, like real devices often do.
        sock.write(Buffer.concat(out));
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

# ---------------------------------------------------------------- connector/test/zk.test.js
Write-File "connector/test/zk.test.js" @'
// Run: npm test   (uses the mock device, no hardware needed)
import test from "node:test";
import assert from "node:assert/strict";
import { startMockDevice, sampleRecords } from "./mock-device.js";
import { ZkClient, readDevice } from "../src/zk/client.js";
import { READ_ONLY_COMMANDS, decodeTime, encodeTime } from "../src/zk/protocol.js";

async function withMock(options, fn) {
  const mock = await startMockDevice(options);
  try {
    return await fn(mock);
  } finally {
    mock.server.close();
  }
}

function assertReadOnly(received) {
  for (const c of received) {
    assert.ok(READ_ONLY_COMMANDS.has(c), `non read-only command sent to device: ${c}`);
  }
}

test("time encode/decode round-trip", () => {
  for (const ts of ["2000-01-01 00:00:00", "2026-10-05 20:11:59", "2030-12-31 23:59:59"]) {
    assert.equal(decodeTime(encodeTime(ts)), ts);
  }
});

test("small log is sent directly (40-byte records)", () =>
  withMock({ records: sampleRecords(20) }, async (mock) => {
    const r = await readDevice({ ip: "127.0.0.1", port: mock.port, timeoutMs: 3000 });
    assert.equal(r.serialNumber, "MOCK0000K50");
    assert.equal(r.deviceTime, "2026-10-05 20:30:00");
    assert.equal(r.recordSize, 40);
    assert.deepEqual(r.records, mock.records);
    assertReadOnly(mock.received);
  }));

test("large log is read in chunks (60,000 punches)", () =>
  withMock({ records: sampleRecords(60000) }, async (mock) => {
    let progressCalls = 0;
    const r = await readDevice({ ip: "127.0.0.1", port: mock.port, timeoutMs: 5000 }, () => progressCalls++);
    assert.equal(r.records.length, 60000);
    assert.deepEqual(r.records.at(-1), mock.records.at(-1));
    assert.ok(progressCalls >= 2);
    assertReadOnly(mock.received);
  }));

test("chunk split over several DATA packets", () =>
  withMock({ records: sampleRecords(3000), dataFrameSize: 1000 }, async (mock) => {
    const r = await readDevice({ ip: "127.0.0.1", port: mock.port, timeoutMs: 3000 });
    assert.deepEqual(r.records, mock.records);
  }));

test("16-byte and 8-byte record formats", async () => {
  for (const recordSize of [16, 8]) {
    await withMock({ records: sampleRecords(300), recordSize }, async (mock) => {
      const r = await readDevice({ ip: "127.0.0.1", port: mock.port, timeoutMs: 3000 });
      assert.equal(r.recordSize, recordSize);
      assert.deepEqual(r.records, mock.records);
    });
  }
});

test("comm key: correct key works, wrong key is rejected", () =>
  withMock({ records: sampleRecords(50), commKey: 123456 }, async (mock) => {
    const ok = await readDevice({ ip: "127.0.0.1", port: mock.port, commKey: 123456, timeoutMs: 3000 });
    assert.equal(ok.records.length, 50);
    await assert.rejects(
      readDevice({ ip: "127.0.0.1", port: mock.port, commKey: 1, timeoutMs: 3000 }),
      /comm key/,
    );
  }));

test("empty log returns no records", () =>
  withMock({ records: [] }, async (mock) => {
    const r = await readDevice({ ip: "127.0.0.1", port: mock.port, timeoutMs: 3000 });
    assert.equal(r.records.length, 0);
  }));

test("write commands are blocked before reaching the device", () =>
  withMock({ records: sampleRecords(5) }, async (mock) => {
    const c = new ZkClient({ ip: "127.0.0.1", port: mock.port, timeoutMs: 3000 });
    await c.connect();
    await assert.rejects(c.command(15), /read-only allowlist/);   // 15 = CMD_CLEAR_ATTLOG
    await assert.rejects(c.command(1004), /read-only allowlist/); // 1004 = CMD_RESTART
    await c.disconnect();
    assert.ok(!mock.received.includes(15) && !mock.received.includes(1004));
  }));

test("unreachable device fails with a clear message", async () => {
  await assert.rejects(
    readDevice({ ip: "127.0.0.1", port: 1, timeoutMs: 1500 }),
    /Cannot (connect|reach)/,
  );
});
'@

Write-Host ""
Write-Host "Phase 4 files written. Next steps are listed in the chat." -ForegroundColor Cyan
