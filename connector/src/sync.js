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