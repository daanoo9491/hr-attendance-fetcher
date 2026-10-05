import "dotenv/config";

const VERSION = "0.0.1-phase0";

async function main() {
  console.log(`ZKT Connector ${VERSION}`);
  console.log(`Device : ${process.env.DEVICE_IP ?? "(not set)"}:${process.env.DEVICE_PORT ?? "4370"}`);
  console.log(`API    : ${process.env.API_BASE_URL ?? "(not set)"}`);

  if (!process.env.API_BASE_URL) {
    console.log("API_BASE_URL not set - copy .env.example to .env first.");
    return;
  }

  try {
    const res = await fetch(`${process.env.API_BASE_URL}/api/health`);
    console.log("Worker health:", await res.json());
  } catch (err) {
    console.error("Could not reach Worker:", err.message);
    process.exitCode = 1;
  }
}

main();