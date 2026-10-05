// Phase 5: process one sync job end to end.
// read machine (read-only, with retries) -> filter -> upload in batches -> complete job
import { readDevice } from "./zk/client.js";
import { log } from "./log.js";

const BATCH_SIZE = 1000;
const FUTURE_TOLERANCE_MS = 24 * 60 * 60 * 1000; // punches > 1 day after the machine's own clock are skipped

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function retryDelaysMs() {
  const base = Number(process.env.RETRY_DELAY_SECONDS);
  const s = Number.isFinite(base) && base >= 0 ? base : 10;
  return [s * 1000, s * 3000]; // wait 10 s, then 30 s (3 attempts in total)
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

async function withRetry(label, fn) {
  const delays = retryDelaysMs();
  for (let attempt = 1; ; attempt++) {
    try {
      return await fn();
    } catch (err) {
      if (attempt > delays.length || !isRetryable(err)) throw err;
      const wait = delays[attempt - 1];
      log.warn(`${label} failed (attempt ${attempt}/${delays.length + 1}): ${err.message}. Retrying in ${Math.round(wait / 1000)} s`);
      await sleep(wait);
    }
  }
}

async function safeFail(api, jobId, message) {
  try {
    await api.completeJob(jobId, { status: "failed", error_message: message.slice(0, 480) });
  } catch (err) {
    log.error(`Could not report failure for job ${jobId}: ${err.message}`);
  }
}

/** Returns a summary object; never throws for device/upload problems (they are reported on the job). */
export async function processJob(api, job, { timeoutMs = 10000 } = {}) {
  const d = job.device;
  const started = Date.now();
  log.info(`Job ${job.id.slice(0, 8)} (${job.trigger_type}): reading "${d.name}" at ${d.ip_address}:${d.port}`);

  // 1) Read the machine (read-only)
  let result;
  try {
    result = await withRetry("Reading machine", () =>
      readDevice({ ip: d.ip_address, port: d.port, commKey: d.comm_key, timeoutMs }));
  } catch (err) {
    const msg = `Could not read machine ${d.ip_address}:${d.port}: ${err.message}`;
    log.error(msg);
    await safeFail(api, job.id, msg);
    return { ok: false, error: msg };
  }

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
    for (let i = 0; i < keep.length; i += BATCH_SIZE) {
      const batch = keep.slice(i, i + BATCH_SIZE);
      const res = await withRetry("Upload", () => api.uploadLogs(job.id, batch));
      inserted += res.inserted;
      duplicates += res.duplicates;
      rejected += res.rejected;
    }
  } catch (err) {
    const msg = `Upload failed: ${err.message}`;
    log.error(msg);
    if (err.status !== 409) await safeFail(api, job.id, msg); // 409 = job already closed by the server
    return { ok: false, error: msg };
  }

  // 3) Complete
  try {
    await withRetry("Completing job", () => api.completeJob(job.id, {
      status: "success",
      device_serial: result.serialNumber ?? undefined,
      records_skipped: skipped.length + rejected,
      clock_offset_seconds: offset ?? undefined,
    }));
  } catch (err) {
    log.error(`Could not complete job: ${err.message}`);
    return { ok: false, error: err.message };
  }

  const secs = ((Date.now() - started) / 1000).toFixed(1);
  log.info(`Job ${job.id.slice(0, 8)} done in ${secs} s: ${inserted} new, ${duplicates} already imported, ${skipped.length + rejected} skipped`);
  return { ok: true, read: result.records.length, inserted, duplicates, skipped: skipped.length + rejected };
}