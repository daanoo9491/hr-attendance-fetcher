export interface Env {
  DB: D1Database;
}

const VERSION = "0.0.1-phase0";

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/api/health") {
      try {
        const row = await env.DB.prepare("SELECT 1 AS ok").first<{ ok: number }>();
        return json({ status: "ok", version: VERSION, d1: row?.ok === 1 ? "connected" : "unknown" });
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