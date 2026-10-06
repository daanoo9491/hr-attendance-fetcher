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

  if (result.users.length) {
    const named = result.users.filter((u) => u.name);
    console.log(`Names        : ${named.length} of ${result.users.length} users have a name on the machine`);
    for (const u of result.users.slice(0, 10)) console.log(`  user ${u.user_id.padEnd(8)} ${u.name || "(no name on machine)"}`);
    if (result.users.length > 10) console.log(`  ... and ${result.users.length - 10} more`);
  } else if (result.usersError) {
    console.log(`Names        : could not read user list (${result.usersError})`);
  }

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
  console.log("\nNothing was uploaded (this command only reads). Use \"npm start\" or Sync now to import.");
}

main().catch((err) => {
  console.error(`\nFAILED: ${err.message}`);
  if (/Cannot (connect|reach)|did not respond/.test(err.message)) {
    console.error("Checks: 1) ping the machine's IP from this PC  2) this PC is on the same network (e.g. 192.168.10.x)");
    console.error("        3) port 4370 is not blocked  4) close ZKTime/ZKBio or other software connected to the machine, then retry");
  }
  process.exitCode = 1;
});