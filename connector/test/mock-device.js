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