// Run: npm test   (uses the mock device, no hardware needed)
import test from "node:test";
import assert from "node:assert/strict";
import { startMockDevice, sampleRecords, sampleUsers } from "./mock-device.js";
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
    if (typeof c === "string") {
      assert.ok(c === "buffer:13" || c === "buffer:9", `unexpected dataset requested: ${c}`);
    } else {
      assert.ok(READ_ONLY_COMMANDS.has(c), `non read-only command sent to device: ${c}`);
    }
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

test("user list: names read (72-byte), no passwords or card numbers", () =>
  withMock({ records: sampleRecords(100) }, async (mock) => {
    const r = await readDevice({ ip: "127.0.0.1", port: mock.port, timeoutMs: 3000 });
    assert.equal(r.users.length, 25);
    const expected = sampleUsers(mock.records)[0];
    assert.deepEqual(r.users[0], { user_id: expected.user_id, name: expected.name });
    for (const u of r.users) assert.deepEqual(Object.keys(u).sort(), ["name", "user_id"]);
    assertReadOnly(mock.received);
  }));

test("user list: 28-byte format and blank / non-English names", () => {
  const records = sampleRecords(20);
  const users = sampleUsers(records);
  users[0].name = "";
  users[1].name = "\u0639\u0644\u06cc"; // Urdu "Ali"
  return withMock({ records, users, userRecordSize: 28 }, async (mock) => {
    const r = await readDevice({ ip: "127.0.0.1", port: mock.port, timeoutMs: 3000 });
    assert.equal(r.users[0].name, "");
    assert.equal(r.users[1].name, "\u0639\u0644\u06cc");
  });
});

test("machine refuses user list: attendance still returned", () =>
  withMock({ records: sampleRecords(30), refuseUsers: true }, async (mock) => {
    const r = await readDevice({ ip: "127.0.0.1", port: mock.port, timeoutMs: 3000 });
    assert.equal(r.records.length, 30);
    assert.equal(r.users.length, 0);
    assert.match(r.usersError, /buffered reads/);
  }));

test("8-byte records are mapped from internal number to user ID", () => {
  const records = sampleRecords(40);
  const users = sampleUsers(records).map((u) => ({ ...u, user_id: String(1000 + u.uid) }));
  // In the 8-byte format the machine stores its internal number (uid), not the user ID.
  const byId = new Map(sampleUsers(records).map((u) => [u.user_id, u.uid]));
  const stored = records.map((r) => ({ ...r, user_id: String(byId.get(r.user_id)) }));
  return withMock({ records: stored, recordSize: 8, users }, async (mock) => {
    const r = await readDevice({ ip: "127.0.0.1", port: mock.port, timeoutMs: 3000 });
    assert.ok(r.records.every((x) => Number(x.user_id) > 1000));
  });
});

test("other datasets (e.g. fingerprints) are blocked", () =>
  withMock({ records: sampleRecords(5) }, async (mock) => {
    const c = new ZkClient({ ip: "127.0.0.1", port: mock.port, timeoutMs: 3000 });
    await c.connect();
    await assert.rejects(c.readWithBuffer(1503), /read-only allowlist/);
    await c.disconnect();
  }));