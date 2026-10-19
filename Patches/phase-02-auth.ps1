# =====================================================================
# HR Auto Attendance Fetcher - PHASE 2 : Login + multi-tenant access
# Run from the ROOT of the repo (hr-attendance-fetcher):
#   powershell -ExecutionPolicy Bypass -File .\phase-02-auth.ps1
# =====================================================================
$ErrorActionPreference = "Stop"

function Write-File([string]$Path, [string]$Content) {
    $full = Join-Path (Get-Location) $Path
    $dir  = Split-Path $full -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($full, $Content.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  wrote $Path" -ForegroundColor Green
}

if (-not (Test-Path "worker/migrations/0001_init.sql")) {
    throw "Run this from the repo root, after Phase 1 (worker/migrations/0001_init.sql not found)."
}

Write-Host "Phase 2: writing auth + tenant code..." -ForegroundColor Cyan

# ---------------------------------------------------------------- package.json (workers-types v5 for current wrangler)
Write-File "worker/package.json" @'
{
  "name": "hr-attendance-worker",
  "version": "0.2.0",
  "private": true,
  "scripts": {
    "dev": "wrangler dev",
    "deploy": "wrangler deploy",
    "typecheck": "tsc --noEmit"
  },
  "devDependencies": {
    "@cloudflare/workers-types": "^5.20261001.1",
    "typescript": "^5.6.0",
    "wrangler": "^4.0.0"
  }
}
'@

# ---------------------------------------------------------------- env
Write-File "worker/src/env.ts" @'
export interface Env {
  DB: D1Database;
  /** Optional. When set, sign-up requires this code (set with: wrangler secret put SIGNUP_CODE). */
  SIGNUP_CODE?: string;
}

export const VERSION = "0.2.0-phase2";
'@

# ---------------------------------------------------------------- http helpers
Write-File "worker/src/lib/http.ts" @'
export class HttpError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

export function json(data: unknown, status = 200, headers: HeadersInit = {}): Response {
  const h = new Headers(headers);
  h.set("content-type", "application/json; charset=utf-8");
  h.set("cache-control", "no-store");
  return new Response(JSON.stringify(data, null, 2), { status, headers: h });
}

export function html(body: string, status = 200): Response {
  return new Response(body, {
    status,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "x-frame-options": "DENY",
      "referrer-policy": "same-origin",
    },
  });
}

export function redirect(location: string, headers: HeadersInit = {}): Response {
  const h = new Headers(headers);
  h.set("location", location);
  return new Response(null, { status: 302, headers: h });
}

/** Only accepts application/json bodies (also blocks cross-site HTML form posts). */
export async function readJson<T>(request: Request): Promise<T> {
  const ct = request.headers.get("content-type") ?? "";
  if (!ct.includes("application/json")) {
    throw new HttpError(415, "Content-Type must be application/json");
  }
  try {
    return (await request.json()) as T;
  } catch {
    throw new HttpError(400, "Invalid JSON body");
  }
}

export function getCookie(request: Request, name: string): string | null {
  const header = request.headers.get("cookie");
  if (!header) return null;
  for (const part of header.split(";")) {
    const [key, ...rest] = part.trim().split("=");
    if (key === name) return decodeURIComponent(rest.join("="));
  }
  return null;
}

export function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}
'@

# ---------------------------------------------------------------- crypto
Write-File "worker/src/lib/crypto.ts" @'
// PBKDF2-SHA256 password hashing with Web Crypto (100k = Workers maximum).
const ITERATIONS = 100_000;
const encoder = new TextEncoder();

function toB64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

function fromB64(b64: string): Uint8Array {
  const s = atob(b64);
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

async function pbkdf2(password: string, salt: Uint8Array, iterations: number): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey("raw", encoder.encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt, iterations }, key, 256);
  return new Uint8Array(bits);
}

export function timingSafeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a[i] ^ b[i];
  return diff === 0;
}

export async function hashPassword(password: string): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const hash = await pbkdf2(password, salt, ITERATIONS);
  return `pbkdf2$${ITERATIONS}$${toB64(salt)}$${toB64(hash)}`;
}

export async function verifyPassword(password: string, stored: string): Promise<boolean> {
  const parts = stored.split("$");
  if (parts.length !== 4 || parts[0] !== "pbkdf2") return false;
  const iterations = Number(parts[1]);
  if (!Number.isInteger(iterations) || iterations < 1) return false;
  const actual = await pbkdf2(password, fromB64(parts[2]), iterations);
  return timingSafeEqual(actual, fromB64(parts[3]));
}

/** URL-safe random token. */
export function randomToken(bytes = 32): string {
  const b = crypto.getRandomValues(new Uint8Array(bytes));
  return toB64(b).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(input));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
'@

# ---------------------------------------------------------------- auth / tenant context
Write-File "worker/src/lib/auth.ts" @'
import type { Env } from "../env";
import { HttpError, getCookie } from "./http";
import { randomToken, sha256Hex } from "./crypto";

export const SESSION_COOKIE = "hr_session";
const SESSION_SECONDS = 7 * 24 * 60 * 60; // 7 days

export type Role = "owner" | "admin" | "viewer";

/** Everything a request needs to stay inside its own company (tenant). */
export interface AuthContext {
  userId: string;
  email: string;
  fullName: string;
  role: Role;
  companyId: string;
  companyName: string;
  companySlug: string;
  companyTimezone: string;
}

function sessionCookie(value: string, maxAge: number): string {
  return `${SESSION_COOKIE}=${value}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${maxAge}`;
}

export function clearSessionCookie(): string {
  return sessionCookie("", 0);
}

/** Creates a session and returns the Set-Cookie header value. Only the token's hash is stored. */
export async function createSession(env: Env, userId: string): Promise<string> {
  const token = randomToken();
  const id = await sha256Hex(token);
  const now = new Date();
  const expires = new Date(now.getTime() + SESSION_SECONDS * 1000);

  await env.DB.batch([
    env.DB.prepare("DELETE FROM sessions WHERE expires_at < ?").bind(now.toISOString()),
    env.DB.prepare("INSERT INTO sessions (id, user_id, expires_at) VALUES (?, ?, ?)").bind(id, userId, expires.toISOString()),
    env.DB.prepare("UPDATE users SET last_login_at = ? WHERE id = ?").bind(now.toISOString(), userId),
  ]);

  return sessionCookie(token, SESSION_SECONDS);
}

export async function destroySession(env: Env, request: Request): Promise<void> {
  const token = getCookie(request, SESSION_COOKIE);
  if (!token) return;
  await env.DB.prepare("DELETE FROM sessions WHERE id = ?").bind(await sha256Hex(token)).run();
}

export async function getAuth(request: Request, env: Env): Promise<AuthContext | null> {
  const token = getCookie(request, SESSION_COOKIE);
  if (!token) return null;

  const row = await env.DB.prepare(
    `SELECT u.id AS user_id, u.email, u.full_name, u.role,
            c.id AS company_id, c.name AS company_name, c.slug AS company_slug, c.timezone AS company_timezone
       FROM sessions s
       JOIN users u     ON u.id = s.user_id
       JOIN companies c ON c.id = u.company_id
      WHERE s.id = ? AND s.expires_at > ? AND u.is_active = 1 AND c.status = 'active'`,
  )
    .bind(await sha256Hex(token), new Date().toISOString())
    .first<{
      user_id: string; email: string; full_name: string; role: Role;
      company_id: string; company_name: string; company_slug: string; company_timezone: string;
    }>();

  if (!row) return null;
  return {
    userId: row.user_id,
    email: row.email,
    fullName: row.full_name,
    role: row.role,
    companyId: row.company_id,
    companyName: row.company_name,
    companySlug: row.company_slug,
    companyTimezone: row.company_timezone,
  };
}

export async function requireAuth(request: Request, env: Env): Promise<AuthContext> {
  const auth = await getAuth(request, env);
  if (!auth) throw new HttpError(401, "Not signed in");
  return auth;
}

export function requireRole(auth: AuthContext, roles: Role[]): void {
  if (!roles.includes(auth.role)) throw new HttpError(403, "You do not have permission for this action");
}
'@

# ---------------------------------------------------------------- auth routes
Write-File "worker/src/routes/auth.ts" @'
import type { Env } from "../env";
import { HttpError, json, readJson } from "../lib/http";
import { hashPassword, verifyPassword } from "../lib/crypto";
import { clearSessionCookie, createSession, destroySession, requireAuth } from "../lib/auth";

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function cleanText(value: unknown, field: string, max = 120): string {
  const v = typeof value === "string" ? value.trim() : "";
  if (v.length < 2) throw new HttpError(400, `${field} is required`);
  if (v.length > max) throw new HttpError(400, `${field} is too long`);
  return v;
}

function cleanEmail(value: unknown): string {
  const v = typeof value === "string" ? value.trim().toLowerCase() : "";
  if (!EMAIL_RE.test(v) || v.length > 200) throw new HttpError(400, "A valid email is required");
  return v;
}

function cleanPassword(value: unknown): string {
  const v = typeof value === "string" ? value : "";
  if (v.length < 8) throw new HttpError(400, "Password must be at least 8 characters");
  if (v.length > 200) throw new HttpError(400, "Password is too long");
  return v;
}

async function uniqueSlug(env: Env, name: string): Promise<string> {
  const base = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 40) || "company";
  let slug = base;
  for (let i = 0; i < 5; i++) {
    const taken = await env.DB.prepare("SELECT 1 FROM companies WHERE slug = ?").bind(slug).first();
    if (!taken) return slug;
    slug = `${base}-${crypto.randomUUID().slice(0, 4)}`;
  }
  return `${base}-${crypto.randomUUID().slice(0, 8)}`;
}

/** POST /api/auth/signup - creates a new company (tenant) and its owner. */
export async function signup(request: Request, env: Env): Promise<Response> {
  const body = await readJson<Record<string, unknown>>(request);

  if (env.SIGNUP_CODE && body.signup_code !== env.SIGNUP_CODE) {
    throw new HttpError(403, "Invalid sign-up code");
  }

  const companyName = cleanText(body.company_name, "Company name");
  const fullName = cleanText(body.full_name, "Full name");
  const email = cleanEmail(body.email);
  const password = cleanPassword(body.password);

  const exists = await env.DB.prepare("SELECT 1 FROM users WHERE email = ?").bind(email).first();
  if (exists) throw new HttpError(409, "An account with this email already exists");

  const companyId = crypto.randomUUID();
  const userId = crypto.randomUUID();
  const slug = await uniqueSlug(env, companyName);
  const passwordHash = await hashPassword(password);

  await env.DB.batch([
    env.DB.prepare("INSERT INTO companies (id, name, slug) VALUES (?, ?, ?)").bind(companyId, companyName, slug),
    env.DB.prepare(
      "INSERT INTO users (id, company_id, email, full_name, password_hash, role) VALUES (?, ?, ?, ?, ?, 'owner')",
    ).bind(userId, companyId, email, fullName, passwordHash),
  ]);

  const cookie = await createSession(env, userId);
  return json({ ok: true, redirect: "/app" }, 201, { "set-cookie": cookie });
}

/** POST /api/auth/login */
export async function login(request: Request, env: Env): Promise<Response> {
  const body = await readJson<Record<string, unknown>>(request);
  const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  const password = typeof body.password === "string" ? body.password : "";
  if (!email || !password) throw new HttpError(400, "Email and password are required");

  const user = await env.DB.prepare(
    `SELECT u.id, u.password_hash, u.is_active, c.status AS company_status
       FROM users u JOIN companies c ON c.id = u.company_id
      WHERE u.email = ?`,
  )
    .bind(email)
    .first<{ id: string; password_hash: string; is_active: number; company_status: string }>();

  if (!user) {
    await hashPassword(password); // keep timing similar so emails can't be probed
    throw new HttpError(401, "Invalid email or password");
  }
  if (!(await verifyPassword(password, user.password_hash))) {
    throw new HttpError(401, "Invalid email or password");
  }
  if (user.is_active !== 1) throw new HttpError(403, "This account is disabled");
  if (user.company_status !== "active") throw new HttpError(403, "This company account is suspended");

  const cookie = await createSession(env, user.id);
  return json({ ok: true, redirect: "/app" }, 200, { "set-cookie": cookie });
}

/** POST /api/auth/logout */
export async function logout(request: Request, env: Env): Promise<Response> {
  await destroySession(env, request);
  return json({ ok: true, redirect: "/login" }, 200, { "set-cookie": clearSessionCookie() });
}

/** GET /api/auth/me */
export async function me(request: Request, env: Env): Promise<Response> {
  const auth = await requireAuth(request, env);
  return json({
    user: { id: auth.userId, email: auth.email, full_name: auth.fullName, role: auth.role },
    company: { id: auth.companyId, name: auth.companyName, slug: auth.companySlug, timezone: auth.companyTimezone },
  });
}
'@

# ---------------------------------------------------------------- health route (moved from index.ts)
Write-File "worker/src/routes/health.ts" @'
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
'@

# ---------------------------------------------------------------- pages
Write-File "worker/src/pages.ts" @'
import { VERSION } from "./env";
import type { AuthContext } from "./lib/auth";
import { escapeHtml } from "./lib/http";

const STYLE = `
:root { --bg:#f5f6f8; --card:#ffffff; --text:#1c2330; --muted:#667085; --border:#d9dde3; --accent:#1f6feb; --error:#c62828; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#0f1318; --card:#171c23; --text:#e6e9ee; --muted:#98a2b3; --border:#2a313b; --accent:#4c8dff; --error:#ff6b6b; }
}
* { box-sizing:border-box; }
body { margin:0; font-family:system-ui,-apple-system,"Segoe UI",sans-serif; background:var(--bg); color:var(--text); }
.wrap { max-width:420px; margin:8vh auto; padding:0 16px; }
.wide { max-width:860px; }
.card { background:var(--card); border:1px solid var(--border); border-radius:12px; padding:28px; }
h1 { font-size:20px; margin:0 0 4px; }
p.sub { color:var(--muted); margin:0 0 20px; font-size:14px; }
label { display:block; font-size:13px; margin:14px 0 6px; color:var(--muted); }
input { width:100%; padding:10px 12px; border:1px solid var(--border); border-radius:8px; background:var(--bg); color:var(--text); font-size:15px; }
button { margin-top:20px; width:100%; padding:11px; border:0; border-radius:8px; background:var(--accent); color:#fff; font-size:15px; cursor:pointer; }
button:disabled { opacity:.6; cursor:default; }
.msg { color:var(--error); font-size:14px; min-height:20px; margin-top:12px; }
.alt { text-align:center; font-size:14px; margin-top:16px; color:var(--muted); }
a { color:var(--accent); }
.top { display:flex; justify-content:space-between; align-items:center; margin-bottom:20px; }
.top button { width:auto; margin:0; padding:8px 14px; background:transparent; color:var(--text); border:1px solid var(--border); }
dl { display:grid; grid-template-columns:140px 1fr; gap:10px 16px; margin:0; font-size:15px; }
dt { color:var(--muted); }
dd { margin:0; word-break:break-word; }
.foot { color:var(--muted); font-size:12px; text-align:center; margin-top:16px; }
`;

function layout(title: string, body: string): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
<style>${STYLE}</style>
</head>
<body>${body}</body>
</html>`;
}

/** Shared client script: posts the form as JSON and follows the redirect. */
function formScript(endpoint: string): string {
  return `<script>
document.getElementById("f").addEventListener("submit", async function (e) {
  e.preventDefault();
  var btn = this.querySelector("button");
  var msg = document.getElementById("msg");
  msg.textContent = "";
  btn.disabled = true;
  try {
    var data = Object.fromEntries(new FormData(this));
    var res = await fetch("${endpoint}", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(data)
    });
    var out = await res.json().catch(function () { return {}; });
    if (res.ok) { location.href = out.redirect || "/app"; return; }
    msg.textContent = out.error || "Something went wrong";
  } catch (err) {
    msg.textContent = "Network error, please try again";
  }
  btn.disabled = false;
});
</script>`;
}

export function loginPage(): string {
  return layout("Sign in", `
<div class="wrap"><div class="card">
  <h1>HR Attendance</h1>
  <p class="sub">Sign in to your company account</p>
  <form id="f">
    <label for="email">Email</label>
    <input id="email" name="email" type="email" autocomplete="email" required>
    <label for="password">Password</label>
    <input id="password" name="password" type="password" autocomplete="current-password" required>
    <button type="submit">Sign in</button>
    <div class="msg" id="msg"></div>
  </form>
  <div class="alt">New company? <a href="/signup">Create an account</a></div>
</div><div class="foot">${VERSION}</div></div>
${formScript("/api/auth/login")}`);
}

export function signupPage(requireCode: boolean): string {
  const codeField = requireCode
    ? `<label for="signup_code">Sign-up code</label>
    <input id="signup_code" name="signup_code" type="text" autocomplete="off" required>`
    : "";
  return layout("Create account", `
<div class="wrap"><div class="card">
  <h1>Create your company account</h1>
  <p class="sub">You will be the owner of this company workspace</p>
  <form id="f">
    <label for="company_name">Company name</label>
    <input id="company_name" name="company_name" type="text" required>
    <label for="full_name">Your full name</label>
    <input id="full_name" name="full_name" type="text" autocomplete="name" required>
    <label for="email">Email</label>
    <input id="email" name="email" type="email" autocomplete="email" required>
    <label for="password">Password (min 8 characters)</label>
    <input id="password" name="password" type="password" autocomplete="new-password" minlength="8" required>
    ${codeField}
    <button type="submit">Create account</button>
    <div class="msg" id="msg"></div>
  </form>
  <div class="alt">Already have an account? <a href="/login">Sign in</a></div>
</div><div class="foot">${VERSION}</div></div>
${formScript("/api/auth/signup")}`);
}

export function appPage(auth: AuthContext): string {
  const e = escapeHtml;
  return layout("Dashboard", `
<div class="wrap wide">
  <div class="top">
    <h1>${e(auth.companyName)}</h1>
    <button id="logout" type="button">Sign out</button>
  </div>
  <div class="card">
    <dl>
      <dt>Signed in as</dt><dd>${e(auth.fullName)} (${e(auth.email)})</dd>
      <dt>Role</dt><dd>${e(auth.role)}</dd>
      <dt>Company ID</dt><dd>${e(auth.companyId)}</dd>
      <dt>Workspace</dt><dd>${e(auth.companySlug)}</dd>
      <dt>Timezone</dt><dd>${e(auth.companyTimezone)}</dd>
    </dl>
  </div>
  <div class="foot">${VERSION} - devices, connectors and attendance arrive in the next phases</div>
</div>
<script>
document.getElementById("logout").addEventListener("click", async function () {
  await fetch("/api/auth/logout", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" });
  location.href = "/login";
});
</script>`);
}
'@

# ---------------------------------------------------------------- router
Write-File "worker/src/index.ts" @'
import type { Env } from "./env";
import { HttpError, html, json, redirect } from "./lib/http";
import { getAuth } from "./lib/auth";
import { health } from "./routes/health";
import { login, logout, me, signup } from "./routes/auth";
import { appPage, loginPage, signupPage } from "./pages";

export type { Env };

async function route(request: Request, env: Env): Promise<Response> {
  const { pathname } = new URL(request.url);
  const method = request.method;

  // ---- API
  if (pathname === "/api/health" && method === "GET") return health(env);
  if (pathname === "/api/auth/signup" && method === "POST") return signup(request, env);
  if (pathname === "/api/auth/login" && method === "POST") return login(request, env);
  if (pathname === "/api/auth/logout" && method === "POST") return logout(request, env);
  if (pathname === "/api/auth/me" && method === "GET") return me(request, env);
  if (pathname.startsWith("/api/")) return json({ error: "Not found" }, 404);

  // ---- Pages
  if (method === "GET") {
    if (pathname === "/") {
      return redirect((await getAuth(request, env)) ? "/app" : "/login");
    }
    if (pathname === "/login") {
      return (await getAuth(request, env)) ? redirect("/app") : html(loginPage());
    }
    if (pathname === "/signup") {
      return (await getAuth(request, env)) ? redirect("/app") : html(signupPage(Boolean(env.SIGNUP_CODE)));
    }
    if (pathname === "/app") {
      const auth = await getAuth(request, env);
      return auth ? html(appPage(auth)) : redirect("/login");
    }
  }

  return json({ error: "Not found" }, 404);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    try {
      return await route(request, env);
    } catch (err) {
      if (err instanceof HttpError) return json({ error: err.message }, err.status);
      console.error(err);
      return json({ error: "Internal server error" }, 500);
    }
  },
};
'@

Write-Host ""
Write-Host "Phase 2 files written. Next steps are listed in the chat." -ForegroundColor Cyan
