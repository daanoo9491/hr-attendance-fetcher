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