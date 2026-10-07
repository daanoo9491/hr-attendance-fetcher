// "Download installer": a ZIP with the ZKT Connector, already configured for this
// company and connector (server address + token in .env). Owner/admin only.
import type { Env } from "../env";
import { HttpError, readJson } from "../lib/http";
import { requireAuth, requireRole } from "../lib/auth";
import { randomToken, sha256Hex } from "../lib/crypto";
import { zipStore, type ZipEntry } from "../lib/zip";
import { CONNECTOR_FILES, CONNECTOR_VERSION } from "../generated/connector-files";

const FOLDER = "ZKT-Connector";
const TOKEN_RE = /^zkc_[A-Za-z0-9_-]{20,}$/;

function ascii(s: string): string {
  return s.replace(/[^\x20-\x7e]/g, "").replace(/[\r\n]/g, " ").trim();
}

function envFile(apiBase: string, token: string, companyName: string, connectorName: string): string {
  const lines = [
    "# ZKT Connector settings",
    `# Company   : ${ascii(companyName) || "-"}`,
    `# Connector : ${ascii(connectorName) || "-"}`,
    `# Created   : ${new Date().toISOString().slice(0, 16).replace("T", " ")} UTC`,
    "# Keep this file private: the token allows uploading attendance for your company.",
    "",
    `API_BASE_URL=${apiBase}`,
    `CONNECTOR_TOKEN=${token}`,
    "",
    "# How long to wait for the machine (ms), and the first retry delay when",
    "# the machine or server fails (s). Syncs start within a few seconds.",
    "DEVICE_TIMEOUT_MS=10000",
    "RETRY_DELAY_SECONDS=5",
    "",
  ];
  return lines.join("\r\n");
}

/**
 * POST /api/connectors/:id/package   { token?: "zkc_..." }
 * With the token just shown after "Create connector": that token is packed as-is.
 * Without a token: a NEW token is issued (the old one stops working) and packed.
 */
export async function downloadConnector(request: Request, env: Env, id: string): Promise<Response> {
  const auth = await requireAuth(request, env);
  requireRole(auth, ["owner", "admin"]);
  const body = await readJson<{ token?: unknown }>(request);

  const connector = await env.DB.prepare(
    "SELECT id, name, token_hash FROM connectors WHERE id = ? AND company_id = ? AND is_active = 1",
  ).bind(id, auth.companyId).first<{ id: string; name: string; token_hash: string }>();
  if (!connector) throw new HttpError(404, "Connector not found or revoked");

  let token: string;
  let rotated = false;
  if (typeof body.token === "string" && body.token) {
    if (!TOKEN_RE.test(body.token) || (await sha256Hex(body.token)) !== connector.token_hash) {
      throw new HttpError(403, "That token does not belong to this connector");
    }
    token = body.token;
  } else {
    token = `zkc_${randomToken(32)}`;
    await env.DB.prepare("UPDATE connectors SET token_hash = ?, token_hint = ? WHERE id = ? AND company_id = ?")
      .bind(await sha256Hex(token), token.slice(-4), connector.id, auth.companyId).run();
    rotated = true;
  }

  const apiBase = new URL(request.url).origin;
  const entries: ZipEntry[] = Object.entries(CONNECTOR_FILES).map(([name, data]) => ({ name: `${FOLDER}/${name}`, data }));
  entries.push({ name: `${FOLDER}/.env`, data: envFile(apiBase, token, auth.companyName, connector.name) });
  entries.sort((a, b) => a.name.localeCompare(b.name));

  const slug = ascii(connector.name).replace(/[^A-Za-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40) || "connector";
  const filename = `ZKT-Connector-${CONNECTOR_VERSION}-${slug}.zip`;

  return new Response(zipStore(entries), {
    headers: {
      "content-type": "application/zip",
      "content-disposition": `attachment; filename="${filename}"`,
      "cache-control": "no-store",
      "x-connector-version": CONNECTOR_VERSION,
      "x-token-rotated": rotated ? "1" : "0",
    },
  });
}