// Read-only ZKTeco TCP client. Every outgoing command is checked against
// READ_ONLY_COMMANDS, so this client cannot clear logs or change the machine.
import net from "node:net";
import {
  CMD, READ_ONLY_COMMANDS, READ_ONLY_DATASETS, USHRT_MAX,
  buildFrame, makeCommKey, parseFrames, parseAttendance, parseUsers, decodeTime,
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
    if (!READ_ONLY_DATASETS.has(dataCommand)) {
      throw new Error(`Blocked: dataset ${dataCommand} is not on the read-only allowlist`);
    }
    const req = Buffer.alloc(11);
    req.writeInt8(1, 0);
    req.writeInt16LE(dataCommand, 1);
    req.writeInt32LE(READ_ONLY_DATASETS.get(dataCommand), 3);
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
  async getAttendance(onProgress, sizes) {
    const s = sizes ?? (await this.getSizes());
    if (s.records <= 0) return { sizes: s, recordSize: 0, records: [] };
    const buffer = await this.readWithBuffer(CMD.ATTLOG_RRQ, onProgress);
    const { recordSize, records } = parseAttendance(buffer, s.records);
    return { sizes: s, recordSize, records };
  }

  /** Reads the user list (user ID + name only). */
  async getUsers(sizes) {
    const s = sizes ?? (await this.getSizes());
    if (s.users <= 0) return [];
    const buffer = await this.readWithBuffer(CMD.USERTEMP_RRQ);
    return parseUsers(buffer, s.users).users;
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

/**
 * Connect, read everything we need, always disconnect.
 * The user list is optional: if the machine refuses it, attendance is still returned
 * (usersError explains why the names are missing).
 */
export async function readDevice(options, onProgress) {
  const client = new ZkClient(options);
  try {
    await client.connect();
    const serialNumber = await client.getSerialNumber();
    const deviceTime = await client.getTime();
    const sizes = await client.getSizes();

    let users = [];
    let usersError = null;
    try {
      users = await client.getUsers(sizes);
    } catch (err) {
      usersError = err.message;
    }

    const { recordSize, records } = await client.getAttendance(onProgress, sizes);

    // Old 8-byte records only store the machine's internal number: map it to the user ID.
    if (recordSize === 8 && users.length) {
      const byUid = new Map(users.map((u) => [String(u.uid), u.user_id]));
      for (const r of records) r.user_id = byUid.get(r.user_id) ?? r.user_id;
    }

    return {
      serialNumber, deviceTime, sizes, recordSize, records,
      users: users.map((u) => ({ user_id: u.user_id, name: u.name })),
      usersError,
    };
  } finally {
    await client.disconnect();
  }
}