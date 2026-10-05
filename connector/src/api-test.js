// Phase 3 end-to-end test of the connector API, WITHOUT the machine.
// Uploads two fake punches for user "TEST" dated 2000-01-01, then uploads
// them again to prove duplicates are skipped. Run: npm run api-test
import "dotenv/config";
import { clientFromEnv, CONNECTOR_VERSION } from "./api.js";

const TEST_RECORDS = [
  { user_id: "TEST", timestamp: "2000-01-01 09:00:00", state: 0, verify_mode: 1 },
  { user_id: "TEST", timestamp: "2000-01-01 18:00:00", state: 1, verify_mode: 1 },
];

async function main() {
  console.log(`ZKT Connector ${CONNECTOR_VERSION} - API test`);
  const api = clientFromEnv();

  const config = await api.getConfig();
  console.log(`\n[1] Token OK. Connector: ${config.connector.name}`);
  if (!config.devices.length) {
    console.log("    No devices assigned to this connector. Add one in the dashboard first.");
    return;
  }
  for (const d of config.devices) {
    console.log(`    Device: ${d.name}  ${d.ip_address}:${d.port}  comm key ${d.comm_key}`);
  }

  const claim = await api.claimJob();
  if (!claim.job) {
    console.log("\n[2] No pending job. Click 'Sync now' on the device in the dashboard, then run this again.");
    return;
  }
  const job = claim.job;
  console.log(`\n[2] Claimed job ${job.id} for device "${job.device.name}" (${job.trigger_type})`);

  const first = await api.uploadLogs(job.id, TEST_RECORDS);
  console.log(`\n[3] First upload : inserted ${first.inserted}, duplicates ${first.duplicates}, rejected ${first.rejected}`);

  const second = await api.uploadLogs(job.id, TEST_RECORDS);
  console.log(`[4] Second upload: inserted ${second.inserted}, duplicates ${second.duplicates}  (expected 0 inserted)`);

  const done = await api.completeJob(job.id, { status: "success" });
  console.log(`\n[5] Job ${done.job.status}: fetched ${done.job.records_fetched}, new ${done.job.records_inserted}`);
  console.log("\nAPI test passed.");
}

main().catch((err) => {
  console.error("\nAPI test FAILED:", err.message);
  process.exitCode = 1;
});