import "dotenv/config";
import { CONNECTOR_VERSION, clientFromEnv } from "./api.js";

async function main() {
  console.log(`ZKT Connector ${CONNECTOR_VERSION}`);
  console.log(`API : ${process.env.API_BASE_URL ?? "(not set)"}`);

  if (!process.env.API_BASE_URL) {
    console.log("API_BASE_URL not set - copy .env.example to .env first.");
    return;
  }

  try {
    const res = await fetch(`${process.env.API_BASE_URL.replace(/\/+$/, "")}/api/health`);
    const health = await res.json();
    console.log(`Worker: ${health.status} (${health.version})`);

    const config = await clientFromEnv().getConfig();
    console.log(`Connector: ${config.connector.name}`);
    if (!config.devices.length) console.log("Devices: none assigned yet");
    for (const d of config.devices) {
      console.log(`Device: ${d.name}  ${d.ip_address}:${d.port}  comm key ${d.comm_key}`);
    }
  } catch (err) {
    console.error("Error:", err.message);
    process.exitCode = 1;
  }
}

main();