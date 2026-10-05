import { VERSION, type Env } from "../env";
import { json } from "../lib/http";

const REQUIRED_TABLES = [
  "companies", "users", "sessions", "connectors",
  "devices", "employees", "sync_jobs", "attendance_logs",
];

export async function health(env: Env): Promise<Response> {
  try {
    const ping = await env.DB.prepare("SELECT 1 AS ok").first<{ ok: number }>();
    const { results } = await env.DB
      .prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
      .all<{ name: string }>();
    const existing = new Set((results ?? []).map((r) => r.name));
    const missing = REQUIRED_TABLES.filter((t) => !existing.has(t));
    const healthy = ping?.ok === 1 && missing.length === 0;

    return json(
      {
        status: healthy ? "ok" : "degraded",
        version: VERSION,
        d1: ping?.ok === 1 ? "connected" : "unknown",
        schema: missing.length === 0 ? "ready" : "missing tables",
        tables: `${REQUIRED_TABLES.length - missing.length}/${REQUIRED_TABLES.length}`,
        missing,
      },
      healthy ? 200 : 503,
    );
  } catch (err) {
    return json({ status: "error", version: VERSION, d1: "failed", error: String(err) }, 500);
  }
}