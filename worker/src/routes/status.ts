// Dashboard status: problems that need attention, worst first.
import type { Env } from "../env";
import { json } from "../lib/http";
import { requireAuth } from "../lib/auth";
import { CONNECTOR_VERSION } from "../generated/connector-files";
import { expireStaleJobs } from "../lib/jobs";

const OFFLINE_MINUTES = 3;
const CLOCK_WARN_SECONDS = 120;

type Level = "error" | "warning" | "info";
interface Alert { level: Level; text: string }

function versionLess(a: string, b: string): boolean {
  const pa = a.split(".").map((n) => parseInt(n, 10) || 0);
  const pb = b.split(".").map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < 3; i++) if ((pa[i] ?? 0) !== (pb[i] ?? 0)) return (pa[i] ?? 0) < (pb[i] ?? 0);
  return false;
}

function ago(iso: string, now: number): string {
  const min = Math.round((now - Date.parse(iso)) / 60000);
  if (min < 60) return `${min} min ago`;
  if (min < 48 * 60) return `${Math.round(min / 60)} h ago`;
  return `${Math.round(min / 1440)} days ago`;
}

/** GET /api/status */
export async function status(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  await expireStaleJobs(env, { companyId: auth.companyId });
  const now = Date.now();
  const alerts: Alert[] = [];

  const { results: connectors } = await env.DB.prepare(
    `SELECT c.id, c.name, c.version, c.last_seen_at,
            (SELECT COUNT(*) FROM devices d WHERE d.connector_id = c.id AND d.is_active = 1) AS devices
       FROM connectors c WHERE c.company_id = ? AND c.is_active = 1`,
  ).bind(auth.companyId).all<{ id: string; name: string; version: string | null; last_seen_at: string | null; devices: number }>();

  const { results: devices } = await env.DB.prepare(
    `SELECT d.id, d.name, d.connector_id, d.clock_offset_seconds,
            (SELECT j.status FROM sync_jobs j WHERE j.device_id = d.id ORDER BY j.requested_at DESC LIMIT 1) AS last_status,
            (SELECT j.error_message FROM sync_jobs j WHERE j.device_id = d.id ORDER BY j.requested_at DESC LIMIT 1) AS last_error
       FROM devices d WHERE d.company_id = ? AND d.is_active = 1`,
  ).bind(auth.companyId).all<{
    id: string; name: string; connector_id: string | null; clock_offset_seconds: number | null;
    last_status: string | null; last_error: string | null;
  }>();

  const cs = connectors ?? [];
  const ds = devices ?? [];

  if (!cs.length) {
    alerts.push({ level: "info", text: "Get started: under Machines, create a connector, download its installer and run it on a PC on the machine's network." });
  }
  for (const c of cs) {
    if (!c.last_seen_at) {
      alerts.push({ level: "warning", text: `Connector "${c.name}" has not connected yet. Download the installer and run Install.cmd on the office PC.` });
    } else if (now - Date.parse(c.last_seen_at) > OFFLINE_MINUTES * 60000) {
      alerts.push({ level: "error", text: `Connector "${c.name}" is offline (last seen ${ago(c.last_seen_at, now)}). Check that the office PC is on and connected to the internet.` });
    } else if (c.version && versionLess(c.version, CONNECTOR_VERSION)) {
      alerts.push({ level: "info", text: `Connector "${c.name}" runs version ${c.version}; ${CONNECTOR_VERSION} is available. Click Download installer and run Install.cmd to update.` });
    }
    if (c.devices === 0) {
      alerts.push({ level: "info", text: `Connector "${c.name}" has no machine assigned yet. Add one under Machines.` });
    }
  }
  for (const d of ds) {
    if (!d.connector_id || !cs.some((c) => c.id === d.connector_id)) {
      alerts.push({ level: "warning", text: `Machine "${d.name}" has no active connector, so it cannot sync.` });
    }
    if (d.last_status === "failed") {
      alerts.push({ level: "error", text: `Last sync of "${d.name}" failed: ${d.last_error ?? "unknown error"}` });
    }
    if (d.clock_offset_seconds !== null && Math.abs(d.clock_offset_seconds) > CLOCK_WARN_SECONDS) {
      const sec = Math.abs(d.clock_offset_seconds);
      const amount = sec < 5400 ? `${Math.round(sec / 60)} min` : sec < 172800 ? `${Math.round(sec / 3600)} h` : `${Math.round(sec / 86400)} days`;
      alerts.push({ level: "warning", text: `The clock on "${d.name}" is ${amount} ${d.clock_offset_seconds < 0 ? "slow" : "fast"}. Set the correct time on the machine (Menu > System > Date/Time).` });
    }
  }

  const order: Record<Level, number> = { error: 0, warning: 1, info: 2 };
  alerts.sort((a, b) => order[a.level] - order[b.level]);
  return json({ alerts, latest_connector_version: CONNECTOR_VERSION });
}