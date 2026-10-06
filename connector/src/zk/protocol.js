// ZKTeco "ZK6" TCP protocol helpers (port 4370).
// Packet layout, checksum, comm-key scrambling and time decoding follow the
// public pyzk / zkemsdk implementations.

export const CMD = Object.freeze({
  USERTEMP_RRQ: 9,       // read user list (with FCT_USER)
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

/** Datasets the connector may read through PREPARE_BUFFER: attendance log and user list only. */
export const FCT_USER = 5;
export const READ_ONLY_DATASETS = new Map([
  [CMD.ATTLOG_RRQ, 0],
  [CMD.USERTEMP_RRQ, FCT_USER],
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

/**
 * Parses the user list. Only the user ID and name are kept; passwords and
 * card numbers stored on the machine are never read out of the buffer.
 * Record layout: 72 bytes (TFT devices such as K40/K50) or 28 bytes (old models).
 */
export function parseUsers(buffer, userCount) {
  if (buffer.length < 4 || userCount <= 0) return { recordSize: 0, users: [] };
  const total = buffer.readUInt32LE(0);
  const body = buffer.subarray(4, 4 + total);
  const recordSize = total / userCount === 28 ? 28 : 72;
  const text = (b) => b.toString("utf8").split("\0")[0].replace(/\uFFFD/g, "").trim();

  const users = [];
  for (let off = 0; off + recordSize <= body.length; off += recordSize) {
    const r = body.subarray(off, off + recordSize);
    if (recordSize === 72) {
      users.push({ uid: r.readUInt16LE(0), user_id: text(r.subarray(48, 72)) || String(r.readUInt16LE(0)), name: text(r.subarray(11, 35)) });
    } else {
      users.push({ uid: r.readUInt16LE(0), user_id: String(r.readUInt32LE(24)), name: text(r.subarray(8, 16)) });
    }
  }
  return { recordSize, users };
}