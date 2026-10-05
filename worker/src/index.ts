export interface Env {
  DB: D1Database;
}

const VERSION = "0.1.0-phase1";

const REQUIRED_TABLES = [
  "companies",
  "users",
  "sessions",
  "connectors",
  "devices",
  "employees",
  "sync_jobs",
  "attendance_logs",
];

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

async function checkSchema(db: D1Database) {
  const { results } = await db
    .prepare("SELECT name FROM sqlite_master WHERE type = 'table'")
    .all<{ name: string }>();
  const existing = new Set((results ?? []).map((r) => r.name));
  const missing = REQUIRED_TABLES.filter((t) => !existing.has(t));
  return { ok: missing.length === 0, tables: REQUIRED_TABLES.length - missing.length, missing };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/api/health") {
      try {
        const ping = await env.DB.prepare("SELECT 1 AS ok").first<{ ok: number }>();
        const schema = await checkSchema(env.DB);
        const healthy = ping?.ok === 1 && schema.ok;
        return json(
          {
            status: healthy ? "ok" : "degraded",
            version: VERSION,
            d1: ping?.ok === 1 ? "connected" : "unknown",
            schema: schema.ok ? "ready" : "missing tables",
            tables: `${schema.tables}/${REQUIRED_TABLES.length}`,
            missing: schema.missing,
          },
          healthy ? 200 : 503,
        );
      } catch (err) {
        return json({ status: "error", version: VERSION, d1: "failed", error: String(err) }, 500);
      }
    }

    if (url.pathname === "/") {
      return new Response(`HR Auto Attendance Fetcher - ${VERSION}`, {
        headers: { "content-type": "text/plain; charset=utf-8" },
      });
    }

    return json({ error: "Not found" }, 404);
  },
};