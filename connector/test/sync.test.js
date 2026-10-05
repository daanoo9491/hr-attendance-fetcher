// Run: npm test
import test from "node:test";
import assert from "node:assert/strict";
import { filterRecords, clockOffsetSeconds } from "../src/sync.js";

const rec = (timestamp, user_id = "1") => ({ user_id, timestamp, state: 0, verify_mode: 1 });

test("future-dated punches (machine clock was wrong) are skipped", () => {
  const records = [
    rec("2027-07-28 13:10:47", "6"),
    rec("2015-05-13 12:15:30", "1"),
    rec("2026-10-05 19:00:16", "10"),
    rec("2026-10-06 20:31:32", "3"), // exactly 1 day after machine clock: kept
    rec("2026-10-06 20:31:33", "4"), // 1 s later: skipped
  ];
  const { keep, skipped } = filterRecords(records, "2026-10-05 20:31:32");
  assert.deepEqual(keep.map((r) => r.timestamp), ["2015-05-13 12:15:30", "2026-10-05 19:00:16", "2026-10-06 20:31:32"]);
  assert.deepEqual(skipped.map((r) => r.user_id), ["6", "4"]);
});

test("clock offset is machine minus PC time", () => {
  const now = new Date("2026-10-05T20:35:28").getTime();
  assert.equal(clockOffsetSeconds("2026-10-05 20:31:32", now), -236);
  assert.equal(clockOffsetSeconds(null, now), null);
});