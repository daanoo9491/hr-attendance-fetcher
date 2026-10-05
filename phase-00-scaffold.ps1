# =====================================================================
# HR Auto Attendance Fetcher - PHASE 0 : Project scaffold
# Run from the ROOT of your cloned repo (hr-attendance-fetcher):
#   powershell -ExecutionPolicy Bypass -File .\phase-00-scaffold.ps1
# =====================================================================
$ErrorActionPreference = "Stop"

# Writes UTF-8 WITHOUT BOM (BOM breaks wrangler.toml / package.json)
function Write-File([string]$Path, [string]$Content) {
    $full = Join-Path (Get-Location) $Path
    $dir  = Split-Path $full -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($full, $Content.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  wrote $Path" -ForegroundColor Green
}

Write-Host "Phase 0: creating scaffold..." -ForegroundColor Cyan

# ---------------------------------------------------------------- root
Write-File ".gitignore" @'
node_modules/
.wrangler/
.dev.vars
.env
dist/
*.log
'@

Write-File "README.md" @'
# HR Auto Attendance Fetcher

Two independent apps in one repo:

| Folder        | What it is                                   | Runs where                              |
|---------------|----------------------------------------------|-----------------------------------------|
| `worker/`     | Attendance Fetcher SaaS (API + dashboard)    | Cloudflare Workers + D1                 |
| `connector/`  | ZKT Connector - reads K50 attendance logs    | A Windows PC on the same LAN as the K50 |

Flow: Worker cron (every 2 days) creates a sync job -> Connector polls the
Worker API -> reads ONLY attendance logs from the ZKTeco K50 -> uploads them
to the Worker -> stored in D1.

The connector only makes OUTBOUND HTTPS calls, so no port forwarding is
needed and the K50 is never exposed to the internet.
'@

# ---------------------------------------------------------------- worker
Write-File "worker/package.json" @'
{
  "name": "hr-attendance-worker",
  "version": "0.0.1",
  "private": true,
  "scripts": {
    "dev": "wrangler dev",
    "deploy": "wrangler deploy",
    "typecheck": "tsc --noEmit"
  },
  "devDependencies": {
    "@cloudflare/workers-types": "^4.20250101.0",
    "typescript": "^5.6.0",
    "wrangler": "^4.0.0"
  }
}
'@

Write-File "worker/wrangler.toml" @'
name = "hr-attendance-fetcher"
main = "src/index.ts"
compatibility_date = "2026-09-01"

[[d1_databases]]
binding = "DB"
database_name = "hr-attendance"
database_id = "PASTE_D1_DATABASE_ID_HERE"
migrations_dir = "migrations"
'@

Write-File "worker/tsconfig.json" @'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ES2022",
    "moduleResolution": "Bundler",
    "lib": ["ES2022"],
    "types": ["@cloudflare/workers-types"],
    "strict": true,
    "noEmit": true,
    "skipLibCheck": true
  },
  "include": ["src"]
}
'@

Write-File "worker/src/index.ts" @'
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
'@

Write-File "worker/migrations/.gitkeep" ""

# ---------------------------------------------------------------- connector
Write-File "connector/package.json" @'
{
  "name": "zkt-connector",
  "version": "0.0.1",
  "private": true,
  "type": "module",
  "scripts": {
    "start": "node src/index.js"
  },
  "dependencies": {
    "dotenv": "^16.4.5"
  }
}
'@

Write-File "connector/.env.example" @'
# --- ZKTeco K50 on your LAN ---
DEVICE_IP=192.168.1.201
DEVICE_PORT=4370
DEVICE_TIMEOUT_MS=10000

# --- Attendance Fetcher SaaS (Cloudflare Worker) ---
API_BASE_URL=https://hr-attendance-fetcher.YOUR-SUBDOMAIN.workers.dev
CONNECTOR_TOKEN=will-be-issued-in-phase-3
'@

Write-File "connector/src/index.js" @'
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
'@

Write-Host ""
Write-Host "Phase 0 files written." -ForegroundColor Cyan
Write-Host "Next steps are listed in the chat." -ForegroundColor Yellow
