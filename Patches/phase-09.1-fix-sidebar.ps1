# =====================================================================
# HR Auto Attendance Fetcher - PHASE 9.1 : fix notices appearing in the
# sidebar after the dashboard refreshes. Run from the ROOT of the repo:
#   powershell -ExecutionPolicy Bypass -File .\phase-09.1-fix-sidebar.ps1
# =====================================================================
$ErrorActionPreference = "Stop"

function Write-File([string]$Path, [string]$Content) {
    $full = Join-Path (Get-Location) $Path
    $dir  = Split-Path $full -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($full, $Content.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "  wrote $Path" -ForegroundColor Green
}

if (-not (Test-Path "worker/src/routes/overview.ts")) {
    throw "Run this from the repo root, after Phase 9 (worker/src/routes/overview.ts not found)."
}

Write-Host "Phase 9.1: fixing the sidebar..." -ForegroundColor Cyan

# ---------------------------------------------------------------- worker/package.json
Write-File "worker/package.json" @'
{
  "name": "hr-attendance-worker",
  "version": "0.9.1",
  "private": true,
  "scripts": {
    "bundle-connector": "node scripts/bundle-connector.mjs",
    "dev": "npm run bundle-connector && wrangler dev",
    "deploy": "npm run bundle-connector && wrangler deploy",
    "typecheck": "npm run bundle-connector && tsc --noEmit"
  },
  "devDependencies": {
    "@cloudflare/workers-types": "^5.20261001.1",
    "typescript": "^5.6.0",
    "wrangler": "^4.0.0"
  }
}
'@

# ---------------------------------------------------------------- worker/src/env.ts
Write-File "worker/src/env.ts" @'
export interface Env {
  DB: D1Database;
  /** Optional. When set, sign-up requires this code (set with: wrangler secret put SIGNUP_CODE). */
  SIGNUP_CODE?: string;
}

export const VERSION = "0.9.1-phase9";

/** Number of files in worker/migrations. The health check reports "degraded" until all are applied. */
export const EXPECTED_MIGRATIONS = 5;
'@

# ---------------------------------------------------------------- worker/src/pages.ts
Write-File "worker/src/pages.ts" @'
import { VERSION } from "./env";
import type { AuthContext } from "./lib/auth";
import { escapeHtml } from "./lib/http";

// ------------------------------------------------------------------ design tokens + components
const STYLE = String.raw`
:root {
  --canvas:#EEF2F0; --surface:#FFFFFF; --surface-2:#F5F8F6; --ink:#17302B; --ink-2:#3A4F4A; --muted:#62746F;
  --line:#D6DFDB; --line-2:#E5ECE9;
  --side:#17302B; --side-ink:#E4EEEA; --side-muted:#93ABA4; --side-hover:rgba(255,255,255,.07);
  --accent:#126B4E; --accent-hover:#0E5A41; --accent-ink:#FFFFFF; --accent-soft:#E0F0E8;
  --amber:#9A5A05; --amber-soft:#FBF0DC; --red:#B42318; --red-soft:#FDECEA;
  --radius:8px; --radius-lg:12px;
  color-scheme: light;
}
@media (prefers-color-scheme: dark) {
  :root {
    --canvas:#0E1614; --surface:#15201D; --surface-2:#1A2724; --ink:#E3ECE8; --ink-2:#C3D1CC; --muted:#8EA29C;
    --line:#293834; --line-2:#21302C;
    --side:#0A110F; --side-ink:#E3ECE8; --side-muted:#80958F; --side-hover:rgba(255,255,255,.06);
    --accent:#3DB389; --accent-hover:#52C49A; --accent-ink:#06201A; --accent-soft:#163A2F;
    --amber:#E3A94F; --amber-soft:#36290F; --red:#F27A6D; --red-soft:#3A1916;
    color-scheme: dark;
  }
}
* { box-sizing:border-box; }
[hidden] { display:none !important; }
html, body { margin:0; }
body {
  background:var(--canvas); color:var(--ink);
  font-family:"IBM Plex Sans", system-ui, -apple-system, "Segoe UI", sans-serif;
  font-size:14px; line-height:1.5; -webkit-font-smoothing:antialiased;
}
h1, h2, h3 { margin:0; font-weight:600; letter-spacing:-0.01em; }
h1 { font-size:26px; line-height:1.2; }
h2 { font-size:16px; }
p { margin:0; }
a { color:var(--accent); }
.num, td.num, .tnum { font-variant-numeric:tabular-nums; }
:focus-visible { outline:2px solid var(--accent); outline-offset:2px; }
@media (prefers-reduced-motion: reduce) { * { transition:none !important; animation:none !important; } }

/* ---------- buttons + inputs */
.btn {
  display:inline-flex; align-items:center; justify-content:center; gap:6px;
  height:36px; padding:0 14px; border-radius:var(--radius); border:1px solid transparent;
  font:inherit; font-weight:500; font-size:14px; cursor:pointer; text-decoration:none; white-space:nowrap;
  transition:background .12s, border-color .12s, color .12s;
}
.btn-primary { background:var(--accent); color:var(--accent-ink); }
.btn-primary:hover { background:var(--accent-hover); }
.btn-ghost { background:var(--surface); color:var(--ink); border-color:var(--line); }
.btn-ghost:hover { border-color:var(--muted); }
.btn-quiet { background:transparent; color:var(--muted); padding:0 8px; }
.btn-quiet:hover { color:var(--ink); }
.btn-danger { background:transparent; color:var(--red); padding:0 8px; }
.btn-danger:hover { background:var(--red-soft); }
.btn-sm { height:30px; padding:0 11px; font-size:13px; }
.btn:disabled, .btn[aria-disabled="true"] { opacity:.45; cursor:default; }
.btn-block { width:100%; height:40px; }

.field { display:flex; flex-direction:column; gap:6px; min-width:0; }
.field label { font-size:13px; font-weight:500; color:var(--ink-2); }
.input, select.input {
  height:38px; padding:0 12px; width:100%; border-radius:var(--radius); border:1px solid var(--line);
  background:var(--surface); color:var(--ink); font:inherit; font-size:14px;
  transition:border-color .12s, box-shadow .12s;
}
.input::placeholder { color:var(--muted); opacity:.8; }
.input:focus { outline:none; border-color:var(--accent); box-shadow:0 0 0 3px var(--accent-soft); }
.input-sm { height:32px; font-size:13px; padding:0 10px; }
.hint { font-size:12.5px; color:var(--muted); }
.error-text { color:var(--red); font-size:13px; min-height:18px; }
.ok-text { color:var(--accent); font-size:13px; min-height:18px; }
.panel-body .error-text:empty, .page > .error-text:empty { display:none; }

/* ---------- app shell */
.shell { display:grid; grid-template-columns:236px minmax(0, 1fr); min-height:100vh; }
.side, .main { min-width:0; }
.side {
  background:var(--side); color:var(--side-ink); padding:20px 14px 16px;
  position:sticky; top:0; height:100vh; display:flex; flex-direction:column; gap:22px;
}
.brand { display:flex; align-items:center; gap:10px; padding:2px 8px; color:var(--side-ink); text-decoration:none; }
.brand svg { flex:none; }
.brand-name { font-weight:600; font-size:15px; line-height:1.2; }
.brand-co { font-size:12.5px; color:var(--side-muted); line-height:1.3; }
.nav { display:flex; flex-direction:column; gap:2px; }
.nav a {
  display:flex; align-items:center; gap:10px; padding:8px 10px; border-radius:var(--radius);
  color:var(--side-muted); text-decoration:none; font-weight:500; position:relative;
}
.nav a:hover { color:var(--side-ink); background:var(--side-hover); }
.nav a[aria-current="page"] { color:var(--side-ink); background:var(--side-hover); }
.nav a[aria-current="page"]::before {
  content:""; position:absolute; left:-14px; top:8px; bottom:8px; width:3px; border-radius:0 3px 3px 0; background:var(--accent);
}
.nav svg { width:18px; height:18px; flex:none; }
.nav .count { margin-left:auto; font-size:12px; color:var(--side-muted); }
.side-foot { margin-top:auto; border-top:1px solid rgba(255,255,255,.08); padding:14px 8px 0; font-size:13px; }
.side-foot .who { color:var(--side-ink); font-weight:500; }
.side-foot .role { color:var(--side-muted); text-transform:capitalize; }
.side-foot .btn { margin-top:10px; color:var(--side-muted); padding:0; height:auto; }
.side-foot .btn:hover { color:var(--side-ink); }
.side-foot .ver { margin-top:12px; font-size:11.5px; color:var(--side-muted); opacity:.7; }

.main { padding:30px 40px 60px; max-width:1180px; width:100%; }
.page[hidden] { display:none; }
.page-head { display:flex; align-items:flex-end; justify-content:space-between; gap:16px; margin-bottom:22px; flex-wrap:wrap; }
.page-head p { color:var(--muted); margin-top:6px; max-width:70ch; }
.page-actions { display:flex; gap:8px; flex-wrap:wrap; align-items:center; }
.stack > * + * { margin-top:18px; }

/* ---------- panels + tables */
.panel { background:var(--surface); border:1px solid var(--line); border-radius:var(--radius-lg); }
.panel-head { display:flex; align-items:flex-start; justify-content:space-between; gap:16px; padding:18px 20px 0; flex-wrap:wrap; }
.panel-head p { color:var(--muted); margin-top:4px; font-size:13.5px; max-width:75ch; }
.panel-body { padding:16px 20px 20px; }
.table-wrap { overflow-x:auto; margin-top:14px; border-top:1px solid var(--line-2); }
table { width:100%; border-collapse:collapse; }
th {
  text-align:left; font-size:12.5px; font-weight:500; color:var(--muted); background:var(--surface-2);
  padding:9px 14px; border-bottom:1px solid var(--line-2); white-space:nowrap;
}
td { padding:11px 14px; border-bottom:1px solid var(--line-2); white-space:nowrap; vertical-align:middle; }
tr:last-child td { border-bottom:0; }
tbody tr:hover td, tr.editing td { background:var(--surface-2); }
td .input-sm { min-width:160px; }
th.num, td.num { text-align:right; }
td.wrap { white-space:normal; min-width:220px; }
td.muted, .muted { color:var(--muted); }
td.actions { text-align:right; }
td.actions .btn + .btn { margin-left:6px; }
td.empty { color:var(--muted); padding:28px 14px; text-align:center; white-space:normal; }
.sub-id { display:block; color:var(--muted); font-size:12.5px; }

.pill { display:inline-flex; align-items:center; gap:6px; font-size:13px; font-weight:500; white-space:nowrap; }
.pill::before { content:""; width:7px; height:7px; border-radius:50%; background:currentColor; }
.pill.ok { color:var(--accent); } .pill.warn { color:var(--amber); } .pill.bad { color:var(--red); } .pill.idle { color:var(--muted); }
.t-warn { color:var(--amber); } .t-bad { color:var(--red); }

/* ---------- notices */
.notices { display:flex; flex-direction:column; gap:8px; margin-bottom:18px; }
.nav .count[data-dot="1"]::after { content:""; display:inline-block; width:7px; height:7px; border-radius:50%; background:var(--amber); margin-left:6px; vertical-align:1px; }
.notice {
  display:flex; gap:12px; align-items:flex-start; padding:11px 14px; border-radius:var(--radius);
  border:1px solid var(--line); border-left-width:3px; background:var(--surface); font-size:13.5px;
}
.notice.error { border-left-color:var(--red); background:var(--red-soft); border-color:transparent; border-left-color:var(--red); }
.notice.warning { border-left-color:var(--amber); background:var(--amber-soft); border-color:transparent; border-left-color:var(--amber); }
.notice.info { border-left-color:var(--accent); }
.notice strong { font-weight:600; }

/* ---------- overview: summary strip */
.summary { display:grid; grid-template-columns:repeat(4, minmax(0, 1fr)); }
.summary > div { padding:16px 20px; border-left:1px solid var(--line-2); min-width:0; }
.summary > div:first-child { border-left:0; }
.summary .k { font-size:12.5px; color:var(--muted); }
.summary .v { font-size:22px; font-weight:600; margin-top:2px; font-variant-numeric:tabular-nums; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.summary .v small { font-size:14px; font-weight:500; color:var(--muted); }
.summary .d { font-size:12.5px; color:var(--muted); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }

/* ---------- overview: day timeline (the signature element) */
.day-nav { display:flex; align-items:center; gap:6px; }
.day-nav .day-label { font-weight:600; min-width:150px; text-align:center; font-variant-numeric:tabular-nums; }
.tl { padding:6px 20px 18px; }
.tl-row { display:grid; grid-template-columns:200px minmax(0, 1fr) 92px; align-items:center; gap:14px; min-height:40px; }
.tl-row + .tl-row { border-top:1px solid var(--line-2); }
.tl-axis { min-height:30px; border-top:0 !important; }
.tl-who { min-width:0; }
.tl-who .n { font-weight:500; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.tl-who .i { font-size:12px; color:var(--muted); }
.tl-track { position:relative; height:26px; }
.tl-grid { position:absolute; top:0; bottom:0; width:1px; background:var(--line-2); }
.tl-hour { position:absolute; top:6px; transform:translateX(-50%); font-size:11.5px; color:var(--muted); font-variant-numeric:tabular-nums; }
.tl-bar { position:absolute; top:9px; height:8px; border-radius:4px; background:var(--accent-soft); border:1px solid var(--accent); }
.tl-tick { position:absolute; top:4px; width:2px; height:18px; margin-left:-1px; border-radius:1px; background:var(--accent); }
.tl-tick.single { background:var(--amber); width:3px; }
.tl-sum { text-align:right; font-variant-numeric:tabular-nums; font-weight:500; }
.tl-sum.t-warn { font-weight:400; font-size:12.5px; }
.tl-now { position:absolute; top:-2px; bottom:-2px; width:0; border-left:1px dashed var(--red); }
.tl-empty { padding:36px 20px; text-align:center; color:var(--muted); }
.absent { padding:14px 20px 18px; border-top:1px solid var(--line-2); display:flex; gap:8px; flex-wrap:wrap; align-items:center; }
.absent .k { color:var(--muted); font-size:13px; margin-right:4px; }
.chip { display:inline-flex; align-items:center; height:26px; padding:0 10px; border-radius:13px; background:var(--surface-2); border:1px solid var(--line-2); font-size:13px; color:var(--ink-2); }

/* ---------- forms in panels */
.form-row { display:grid; gap:12px; align-items:end; }
.form-row.cols-2 { grid-template-columns:minmax(0, 1fr) auto; }
.form-row.cols-dev { grid-template-columns:1.3fr 1.1fr 90px 100px 1.2fr auto; }
.form-row.cols-exp { grid-template-columns:180px 180px auto; justify-content:start; }
.setup {
  margin-top:16px; padding:16px 18px; border-radius:var(--radius); background:var(--accent-soft);
  border:1px solid color-mix(in srgb, var(--accent) 30%, transparent);
}
.setup h3 { font-size:15px; }
.setup ol { margin:8px 0 14px; padding-left:20px; line-height:1.7; }
.setup details { margin-top:12px; font-size:13px; color:var(--ink-2); }
.setup summary { cursor:pointer; }
.setup code { display:block; margin:8px 0; padding:8px 10px; border-radius:6px; background:var(--surface); word-break:break-all; font-size:12.5px; }
.search { max-width:260px; }

/* ---------- toast */
.toast {
  position:fixed; left:50%; bottom:24px; transform:translateX(-50%) translateY(20px); opacity:0;
  background:var(--ink); color:var(--canvas); padding:10px 16px; border-radius:var(--radius); font-size:13.5px;
  transition:opacity .18s, transform .18s; pointer-events:none; max-width:min(560px, calc(100vw - 32px)); z-index:10;
}
.toast.show { opacity:1; transform:translateX(-50%) translateY(0); }

/* ---------- responsive */
@media (max-width: 1000px) {
  .form-row.cols-dev { grid-template-columns:1fr 1fr; }
  .summary { grid-template-columns:repeat(2, minmax(0, 1fr)); }
  .summary > div:nth-child(3) { border-left:0; }
  .summary > div:nth-child(n+3) { border-top:1px solid var(--line-2); }
}
@media (max-width: 860px) {
  .shell { grid-template-columns:minmax(0, 1fr); }
  .side { position:sticky; height:auto; z-index:5; flex-direction:row; flex-wrap:wrap; align-items:center; gap:10px 16px; padding:12px 16px; }
  .nav { flex-direction:row; overflow-x:auto; width:100%; order:3; gap:4px; margin:0 -4px; }
  .nav a { padding:7px 10px; white-space:nowrap; }
  .nav a[aria-current="page"]::before { display:none; }
  .nav .count { display:none; }
  .side-foot { margin:0 0 0 auto; border:0; padding:0; display:flex; align-items:center; gap:12px; }
  .side-foot .who, .side-foot .role, .side-foot .ver { display:none; }
  .side-foot .btn { margin:0; }
  .main { padding:22px 16px 48px; }
  h1 { font-size:22px; }
  .tl-row { grid-template-columns:110px minmax(0, 1fr) 64px; gap:8px; }
  .tl { padding:6px 12px 14px; }
  .form-row.cols-2, .form-row.cols-dev, .form-row.cols-exp { grid-template-columns:1fr; }
}
@media (max-width: 520px) {
  .summary { grid-template-columns:1fr 1fr; }
  .summary > div { padding:12px 14px; }
  .summary .v { font-size:18px; }
}

/* ---------- sign-in pages */
.auth { display:grid; grid-template-columns:minmax(0, 1.05fr) minmax(0, 1fr); min-height:100vh; }
.auth-side { background:var(--side); color:var(--side-ink); padding:44px 52px; display:flex; flex-direction:column; justify-content:space-between; gap:40px; }
.auth-side h1 { font-size:34px; line-height:1.15; max-width:16ch; margin-top:56px; }
.auth-side p { color:var(--side-muted); margin-top:14px; max-width:44ch; font-size:15px; }
.demo { border-top:1px solid rgba(255,255,255,.1); padding-top:20px; max-width:520px; }
.demo-row { display:grid; grid-template-columns:96px 1fr; align-items:center; gap:12px; height:30px; font-size:13px; color:var(--side-muted); }
.demo-track { position:relative; height:8px; border-radius:4px; background:rgba(255,255,255,.06); }
.demo-bar { position:absolute; top:0; bottom:0; border-radius:4px; background:rgba(61,179,137,.35); border:1px solid #3DB389; }
.demo-bar.single { width:4px !important; background:#E3A94F; border-color:#E3A94F; }
.demo-axis { display:flex; justify-content:space-between; margin:8px 0 0 108px; font-size:11.5px; color:var(--side-muted); font-variant-numeric:tabular-nums; }
.auth-form { display:flex; align-items:center; justify-content:center; padding:40px 24px; }
.auth-card { width:100%; max-width:380px; }
.auth-card h2 { font-size:22px; }
.auth-card .lead { color:var(--muted); margin:6px 0 26px; }
.auth-card form { display:flex; flex-direction:column; gap:16px; }
.auth-card .alt { margin-top:22px; color:var(--muted); font-size:13.5px; }
.auth-foot { font-size:12px; color:var(--side-muted); opacity:.8; }
@media (max-width: 860px) {
  .auth { grid-template-columns:1fr; }
  .auth-side { padding:24px 20px; gap:16px; }
  .auth-side h1 { margin-top:18px; font-size:24px; }
  .demo, .auth-foot { display:none; }
}
`;

const FONT = `<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@400;500;600&display=swap" rel="stylesheet">`;

/** Brand mark: a 24-hour dial with the working hours highlighted. */
const LOGO = `<svg width="30" height="30" viewBox="0 0 32 32" aria-hidden="true">
  <circle cx="16" cy="16" r="13" fill="none" stroke="currentColor" stroke-opacity=".28" stroke-width="2.5"/>
  <path d="M16 3 A13 13 0 0 1 28.4 20" fill="none" stroke="#3DB389" stroke-width="2.5" stroke-linecap="round"/>
  <path d="M16 9 V16 L20.5 18.5" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>
</svg>`;

function layout(title: string, body: string): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title} - HR Attendance</title>
<link rel="icon" href="data:image/svg+xml,${encodeURIComponent(LOGO.replace("currentColor", "#17302B").replace("currentColor", "#17302B"))}">
${FONT}
<style>${STYLE}</style>
</head>
<body>${body}</body>
</html>`;
}

// ------------------------------------------------------------------ sign in / sign up
const AUTH_SCRIPT = String.raw`<script>
document.getElementById("f").addEventListener("submit", async function (e) {
  e.preventDefault();
  var btn = this.querySelector("button[type=submit]");
  var msg = document.getElementById("msg");
  msg.textContent = "";
  btn.disabled = true;
  try {
    var res = await fetch(this.dataset.endpoint, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(Object.fromEntries(new FormData(this)))
    });
    var out = await res.json().catch(function () { return {}; });
    if (res.ok) { location.href = out.redirect || "/app"; return; }
    msg.textContent = out.error || "Something went wrong. Try again.";
  } catch (err) {
    msg.textContent = "Can't reach the server. Check your internet connection and try again.";
  }
  btn.disabled = false;
});
</script>`;

function authSide(): string {
  const rows: Array<[string, number, number]> = [
    ["Hilal Khan", 37, 71], ["Ayesha S.", 34, 76], ["Bilal J.", 40, 88], ["Awais Butt", 46, 0], ["Huda Ijaz", 35, 74],
  ];
  const demo = rows.map(([n, a, b]) =>
    `<div class="demo-row"><span>${n}</span><div class="demo-track"><div class="demo-bar${b ? "" : " single"}" style="left:${a}%;width:${b ? b - a : 0}%"></div></div></div>`).join("");
  return `<aside class="auth-side">
  <div>
    <div class="brand">${LOGO}<div><div class="brand-name">HR Attendance</div></div></div>
    <h1>Your time machine's punches, ready as Excel every two days.</h1>
    <p>The connector reads your ZKTeco machine in the office. Reports, names and missing check-outs are all here, without touching the machine.</p>
  </div>
  <div class="demo" aria-hidden="true">
    ${demo}
    <div class="demo-axis"><span>06:00</span><span>09:00</span><span>12:00</span><span>15:00</span><span>18:00</span><span>21:00</span></div>
  </div>
  <div class="auth-foot">${VERSION}</div>
</aside>`;
}

export function loginPage(): string {
  return layout("Sign in", `
<div class="auth">
  ${authSide()}
  <main class="auth-form"><div class="auth-card">
    <h2>Sign in</h2>
    <p class="lead">Use the email you registered your company with.</p>
    <form id="f" data-endpoint="/api/auth/login">
      <div class="field"><label for="email">Email</label><input class="input" id="email" name="email" type="email" autocomplete="email" required></div>
      <div class="field"><label for="password">Password</label><input class="input" id="password" name="password" type="password" autocomplete="current-password" required></div>
      <div class="error-text" id="msg" role="alert"></div>
      <button class="btn btn-primary btn-block" type="submit">Sign in</button>
    </form>
    <p class="alt">New company? <a href="/signup">Create an account</a></p>
  </div></main>
</div>
${AUTH_SCRIPT}`);
}

export function signupPage(requireCode: boolean): string {
  const codeField = requireCode
    ? `<div class="field"><label for="signup_code">Sign-up code</label><input class="input" id="signup_code" name="signup_code" type="text" autocomplete="off" required><span class="hint">Ask your administrator for this code.</span></div>`
    : "";
  return layout("Create account", `
<div class="auth">
  ${authSide()}
  <main class="auth-form"><div class="auth-card">
    <h2>Create your company account</h2>
    <p class="lead">You'll be the owner of this workspace and can add machines right after.</p>
    <form id="f" data-endpoint="/api/auth/signup">
      <div class="field"><label for="company_name">Company name</label><input class="input" id="company_name" name="company_name" type="text" autocomplete="organization" required></div>
      <div class="field"><label for="full_name">Your full name</label><input class="input" id="full_name" name="full_name" type="text" autocomplete="name" required></div>
      <div class="field"><label for="email">Work email</label><input class="input" id="email" name="email" type="email" autocomplete="email" required></div>
      <div class="field"><label for="password">Password</label><input class="input" id="password" name="password" type="password" autocomplete="new-password" minlength="8" required><span class="hint">At least 8 characters.</span></div>
      ${codeField}
      <div class="error-text" id="msg" role="alert"></div>
      <button class="btn btn-primary btn-block" type="submit">Create account</button>
    </form>
    <p class="alt">Already have an account? <a href="/login">Sign in</a></p>
  </div></main>
</div>
${AUTH_SCRIPT}`);
}

// ------------------------------------------------------------------ dashboard
const ICONS: Record<string, string> = {
  overview: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M4 7h16M4 12h10M4 17h13"/><circle cx="18" cy="12" r="1.6" fill="currentColor" stroke="none"/></svg>`,
  reports: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><path d="M6 3h8l4 4v14H6z"/><path d="M14 3v4h4M9 12h6M9 16h6"/></svg>`,
  employees: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="9" cy="8" r="3.2"/><path d="M3.5 19c.8-3 3-4.6 5.5-4.6s4.7 1.6 5.5 4.6"/><path d="M16 5.2a3 3 0 0 1 0 5.6M18 14.6c1.3.6 2.2 1.9 2.6 4.4"/></svg>`,
  machines: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"><rect x="6" y="3" width="12" height="18" rx="2"/><rect x="9" y="6" width="6" height="4" rx="1"/><path d="M12 13.5c-1.5 0-2.5 1.2-2.5 2.6v1.4M14.5 17.5v-1.4c0-.6-.2-1.2-.5-1.6" stroke-linecap="round"/></svg>`,
  history: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 12a8 8 0 1 0 2.4-5.7L4 8.5"/><path d="M4 4v4.5h4.5M12 8v4.5l3 1.8"/></svg>`,
};

const NAV: Array<[string, string]> = [
  ["overview", "Overview"], ["reports", "Reports"], ["employees", "Employees"], ["machines", "Machines"], ["history", "Sync history"],
];

export function appPage(auth: AuthContext): string {
  const e = escapeHtml;
  const canManage = auth.role === "owner" || auth.role === "admin";
  const manageOnly = canManage ? "" : " hidden";
  const nav = NAV.map(([id, label]) =>
    `<a href="#${id}" data-page="${id}">${ICONS[id]}<span>${label}</span><span class="count" id="count_${id}"></span></a>`).join("");

  return layout("Dashboard", `
<div class="shell">
  <aside class="side">
    <a class="brand" href="#overview">${LOGO}<div><div class="brand-name">HR Attendance</div><div class="brand-co">${e(auth.companyName)}</div></div></a>
    <nav class="nav" aria-label="Main">${nav}</nav>
    <div class="side-foot">
      <div class="who">${e(auth.fullName)}</div>
      <div class="role">${e(auth.role)}</div>
      <button class="btn btn-quiet" id="logout" type="button">Sign out</button>
      <div class="ver">${VERSION}</div>
    </div>
  </aside>

  <main class="main" id="main">
    <!-- ============================== Overview -->
    <section class="page" id="page-overview">
      <div class="page-head">
        <div><h1>Overview</h1><p id="ov_sub">Who came in, when, and whether the machine is syncing.</p></div>
        <div class="page-actions"><button class="btn btn-ghost" id="sync_all_ov" type="button"${manageOnly}>Sync all machines now</button></div>
      </div>
      <div class="notices" data-alerts aria-live="polite"></div>
      <div class="stack">
        <div class="panel"><div class="summary" id="summary">
          <div><div class="k">Came in</div><div class="v" id="s_in">&nbsp;</div><div class="d" id="s_in_d">&nbsp;</div></div>
          <div><div class="k">Punches</div><div class="v" id="s_punches">&nbsp;</div><div class="d" id="s_punches_d">&nbsp;</div></div>
          <div><div class="k">Last sync</div><div class="v" id="s_sync">&nbsp;</div><div class="d" id="s_sync_d">&nbsp;</div></div>
          <div><div class="k">Next Excel report</div><div class="v" id="s_next">&nbsp;</div><div class="d" id="s_next_d">&nbsp;</div></div>
        </div></div>

        <div class="panel">
          <div class="panel-head">
            <div><h2>Attendance timeline</h2><p>Bars run from first punch to last punch. An amber mark means only one punch, so the check-out is missing.</p></div>
            <div class="day-nav">
              <button class="btn btn-ghost btn-sm" id="day_prev" type="button" aria-label="Previous day">&#8249;</button>
              <span class="day-label" id="day_label"></span>
              <button class="btn btn-ghost btn-sm" id="day_next" type="button" aria-label="Next day">&#8250;</button>
              <button class="btn btn-quiet btn-sm" id="day_today" type="button">Today</button>
            </div>
          </div>
          <div class="tl" id="timeline"></div>
          <div class="absent" id="absent" hidden></div>
        </div>
      </div>
    </section>

    <!-- ============================== Reports -->
    <section class="page" id="page-reports" hidden>
      <div class="page-head">
        <div><h1>Reports</h1><p id="r_sched">An Excel report of the previous two days is prepared automatically every two days.</p></div>
        <div class="page-actions"><button class="btn btn-ghost" id="sync_all" type="button"${manageOnly}>Sync all machines now</button></div>
      </div>
      <div class="stack">
        <div class="panel">
          <div class="panel-head"><div><h2>Scheduled reports</h2><p>Each file has a daily summary (first in, last out, hours) and every punch. It's built when you download it, so late punches are included.</p></div></div>
          <div class="table-wrap"><table>
            <thead><tr><th>Period</th><th>Status</th><th class="num">Machines synced</th><th class="num">Employees</th><th class="num">Punches</th><th>Ready</th><th>Note</th><th></th></tr></thead>
            <tbody id="r_rows"></tbody>
          </table></div>
        </div>
        <div class="panel">
          <div class="panel-head"><div><h2>Export any dates</h2><p>Up to 62 days in one file.</p></div></div>
          <div class="panel-body">
            <div class="form-row cols-exp">
              <div class="field"><label for="x_from">From</label><input class="input" id="x_from" type="date"></div>
              <div class="field"><label for="x_to">To</label><input class="input" id="x_to" type="date"></div>
              <button class="btn btn-primary" id="x_go" type="button">Download Excel</button>
            </div>
            <div class="error-text" id="x_msg" style="margin-top:8px"></div>
          </div>
        </div>
      </div>
    </section>

    <!-- ============================== Employees -->
    <section class="page" id="page-employees" hidden>
      <div class="page-head">
        <div><h1>Employees</h1><p id="e_sub">Names are read from the machine on every sync.</p></div>
        <div class="page-actions"><input class="input search" id="e_search" type="search" placeholder="Search name, ID or department" aria-label="Search employees"></div>
      </div>
      <div class="panel">
        <div class="table-wrap" style="margin-top:0;border-top:0;border-radius:12px">
          <table>
            <thead><tr><th class="num">User ID</th><th>Name</th><th>Department</th><th>Name from</th><th>Last punch</th><th></th></tr></thead>
            <tbody id="e_rows"></tbody>
          </table>
        </div>
      </div>
      <div class="error-text" id="e_msg" style="margin-top:10px"></div>
    </section>

    <!-- ============================== Machines -->
    <section class="page" id="page-machines" hidden>
      <div class="page-head">
        <div><h1>Machines</h1><p>The connector is a small program on an office PC that reads the attendance machine and sends the punches here. It only reads: nothing on the machine is changed or cleared.</p></div>
      </div>
      <div class="notices" data-alerts aria-live="polite"></div>
      <div class="stack">
        <div class="panel">
          <div class="panel-head"><div><h2>Connectors</h2><p>One per office PC. Download the installer, extract it on a Windows PC on the machine's network and double-click Install.cmd.</p></div></div>
          <div class="panel-body"${manageOnly}>
            <div class="form-row cols-2">
              <div class="field"><label for="c_name">New connector name</label><input class="input" id="c_name" placeholder="e.g. Reception PC"></div>
              <button class="btn btn-primary" id="c_add" type="button">Create connector</button>
            </div>
            <div class="error-text" id="c_msg" style="margin-top:8px"></div>
            <div id="c_token"></div>
          </div>
          <div class="table-wrap"><table>
            <thead><tr><th>Name</th><th>Status</th><th>Version</th><th>Last seen</th><th class="num">Machines</th><th>Token</th><th></th></tr></thead>
            <tbody id="c_rows"></tbody>
          </table></div>
        </div>

        <div class="panel">
          <div class="panel-head"><div><h2>Attendance machines</h2><p>Find the IP and comm key on the machine under Menu, then COMM. The default port is 4370.</p></div></div>
          <div class="panel-body"${manageOnly}>
            <div class="form-row cols-dev">
              <div class="field"><label for="d_name">Machine name</label><input class="input" id="d_name" placeholder="e.g. Main entrance"></div>
              <div class="field"><label for="d_ip">IP address</label><input class="input" id="d_ip" placeholder="192.168.10.21" inputmode="decimal"></div>
              <div class="field"><label for="d_port">Port</label><input class="input" id="d_port" value="4370" inputmode="numeric"></div>
              <div class="field"><label for="d_key">Comm key</label><input class="input" id="d_key" value="0" inputmode="numeric"></div>
              <div class="field"><label for="d_conn">Read by connector</label><select class="input" id="d_conn"></select></div>
              <button class="btn btn-primary" id="d_add" type="button">Add machine</button>
            </div>
            <div class="error-text" id="d_msg" style="margin-top:8px"></div>
          </div>
          <div class="table-wrap"><table>
            <thead><tr><th>Machine</th><th>Last sync</th><th>Clock</th><th class="num">Punches stored</th><th>Connector</th><th>Serial</th><th></th></tr></thead>
            <tbody id="d_rows"></tbody>
          </table></div>
        </div>
      </div>
    </section>

    <!-- ============================== Sync history -->
    <section class="page" id="page-history" hidden>
      <div class="page-head">
        <div><h1>Sync history</h1><p>Every time the connector read a machine. Read counts every punch on the machine; New counts the ones imported for the first time.</p></div>
      </div>
      <div class="panel">
        <div class="table-wrap" style="margin-top:0;border-top:0;border-radius:12px"><table>
          <thead><tr><th>Requested</th><th>Machine</th><th>Started by</th><th>Status</th><th class="num">Read</th><th class="num">New</th><th class="num">Skipped</th><th>Finished</th><th>Problem</th></tr></thead>
          <tbody id="j_rows"></tbody>
        </table></div>
      </div>
    </section>
  </main>
</div>
<div class="toast" id="toast" role="status" aria-live="polite"></div>
<script>var CAN_MANAGE = ${canManage ? "true" : "false"};</script>
${DASH_SCRIPT}`);
}

// Client script. Written with String.raw: no template substitutions or backticks inside.
const DASH_SCRIPT = String.raw`<script>
var DASH = "\u2014";
var MONTHS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
var DAYS = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];

/* ---------- helpers */
async function api(method, path, body) {
  var opts = { method: method, headers: {} };
  if (body !== undefined) { opts.headers["content-type"] = "application/json"; opts.body = JSON.stringify(body); }
  var res = await fetch(path, opts);
  var data = await res.json().catch(function () { return {}; });
  if (res.status === 401) { location.href = "/login"; throw new Error("Signed out"); }
  if (!res.ok) throw new Error(data.error || ("Request failed (" + res.status + ")"));
  return data;
}
function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text !== undefined && text !== null) e.textContent = text; return e; }
function td(text, cls) { return el("td", cls, (text === null || text === undefined || text === "") ? DASH : String(text)); }
function pill(text, kind) { var c = el("td"); c.appendChild(el("span", "pill " + kind, text)); return c; }
function btn(label, kind, onClick) { var b = el("button", "btn btn-sm " + kind, label); b.type = "button"; b.addEventListener("click", onClick); return b; }
function emptyRow(tbody, cols, text) { var tr = el("tr"); var c = el("td", "empty", text); c.colSpan = cols; tr.appendChild(c); tbody.appendChild(tr); }
function setText(id, text) { document.getElementById(id).textContent = text || ""; }
var toastTimer;
function toast(text) { var t = document.getElementById("toast"); t.textContent = text; t.classList.add("show"); clearTimeout(toastTimer); toastTimer = setTimeout(function () { t.classList.remove("show"); }, 3500); }

function pad(n) { return String(n).padStart(2, "0"); }
function isoDay(d) { return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()); }
function parseDay(s) { var p = s.split("-"); return new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2])); }
function addDays(s, n) { var d = parseDay(s); d.setDate(d.getDate() + n); return isoDay(d); }
function fmtDay(s) { var d = parseDay(s); return d.getDate() + " " + MONTHS[d.getMonth()] + " " + d.getFullYear(); }
function fmtDayShort(s) { var d = parseDay(s); return DAYS[d.getDay()] + " " + d.getDate() + " " + MONTHS[d.getMonth()]; }
function period(a, b) { return a === b ? fmtDay(a) : (parseDay(a).getDate() + " " + MONTHS[parseDay(a).getMonth()] + " \u2013 " + fmtDay(b)); }
function shortPeriod(a, b) {
  var x = parseDay(a), y = parseDay(b);
  if (a === b) return y.getDate() + " " + MONTHS[y.getMonth()];
  return x.getMonth() === y.getMonth() ? x.getDate() + "\u2013" + y.getDate() + " " + MONTHS[y.getMonth()]
    : x.getDate() + " " + MONTHS[x.getMonth()] + " \u2013 " + y.getDate() + " " + MONTHS[y.getMonth()];
}
function when(iso) {
  if (!iso) return DASH;
  var d = new Date(iso);
  return d.getDate() + " " + MONTHS[d.getMonth()] + ", " + pad(d.getHours()) + ":" + pad(d.getMinutes());
}
function ago(iso) {
  if (!iso) return "Never";
  var m = Math.round((Date.now() - new Date(iso).getTime()) / 60000);
  if (m < 1) return "Just now";
  if (m < 60) return m + " min ago";
  if (m < 48 * 60) return Math.round(m / 60) + " h ago";
  return Math.round(m / 1440) + " days ago";
}
function punchTime(s) { return s ? s.slice(0, 16).replace(" ", ", ") : DASH; }
function minutes(t) { var p = t.split(":"); return Number(p[0]) * 60 + Number(p[1]); }
function dur(mins) { return Math.floor(mins / 60) + "h " + pad(mins % 60) + "m"; }

/* ---------- navigation */
var PAGES = ["overview", "reports", "employees", "machines", "history"];
function showPage() {
  var id = (location.hash || "#overview").slice(1);
  if (PAGES.indexOf(id) < 0) id = "overview";
  PAGES.forEach(function (p) {
    document.getElementById("page-" + p).hidden = p !== id;
    var a = document.querySelector('.nav a[data-page="' + p + '"]');
    if (p === id) a.setAttribute("aria-current", "page"); else a.removeAttribute("aria-current");
  });
  document.title = document.querySelector('.nav a[data-page="' + id + '"] span').textContent + " - HR Attendance";
  window.scrollTo(0, 0);
}
window.addEventListener("hashchange", showPage);

/* ---------- status notices */
async function loadStatus() {
  var data = await api("GET", "/api/status");
  document.querySelectorAll(".notices[data-alerts]").forEach(function (box) {
    box.textContent = "";
    box.hidden = !data.alerts.length;
    data.alerts.forEach(function (a) { box.appendChild(el("div", "notice " + a.level, a.text)); });
  });
  var urgent = data.alerts.filter(function (a) { return a.level !== "info"; }).length;
  document.getElementById("count_machines").dataset.dot = urgent ? "1" : "";
}

/* ---------- overview */
var ovDate = null;
var ovToday = null;
async function loadOverview() {
  var data = await api("GET", "/api/overview" + (ovDate ? "?date=" + ovDate : ""));
  ovDate = data.date; ovToday = data.today;
  var isToday = data.date === data.today;
  document.getElementById("day_label").textContent = isToday ? "Today, " + fmtDayShort(data.date) : fmtDayShort(data.date) + " " + parseDay(data.date).getFullYear();
  document.getElementById("day_next").disabled = isToday;
  document.getElementById("day_today").hidden = isToday;

  var total = data.present.length + data.absent.length;
  var s_in = document.getElementById("s_in"); s_in.textContent = data.present.length + " ";
  s_in.appendChild(el("small", null, "of " + total));
  var singles = data.present.filter(function (p) { return p.punches.length === 1; }).length;
  setText("s_in_d", singles ? singles + " without check-out" : (data.present.length ? "All with check-out" : (isToday ? "No punches yet today" : "No punches")));
  setText("s_punches", data.punches);
  setText("s_punches_d", isToday ? "So far today" : fmtDay(data.date));
  setText("s_sync", data.machines ? ago(data.last_sync) : "No machine");
  setText("s_sync_d", data.machines ? (data.machines + " machine" + (data.machines > 1 ? "s" : "")) : "Add one under Machines");
  var sc = data.schedule;
  setText("s_next", fmtDayShort(sc.next_due));
  setText("s_next_d", "After " + pad(sc.hour) + ":00, for " + shortPeriod(sc.next_start, sc.next_end));
  renderTimeline(data, isToday);
}

function renderTimeline(data, isToday) {
  var box = document.getElementById("timeline");
  box.textContent = "";
  var absentBox = document.getElementById("absent");
  absentBox.textContent = "";
  absentBox.hidden = !data.absent.length || !data.present.length;

  if (!data.present.length) {
    box.appendChild(el("div", "tl-empty", isToday
      ? "No one has punched in yet today. Punches appear here after the next sync."
      : "No punches on this day."));
    return;
  }

  // Axis: whole hours around the earliest and latest punch, at least 06:00 - 20:00.
  var first = 24 * 60, last = 0;
  data.present.forEach(function (p) { first = Math.min(first, minutes(p.punches[0])); last = Math.max(last, minutes(p.punches[p.punches.length - 1])); });
  var startH = Math.max(0, Math.min(6, Math.floor(first / 60) - 1));
  var endH = Math.min(24, Math.max(20, Math.ceil(last / 60) + 1));
  var span = (endH - startH) * 60;
  function pos(m) { return ((m - startH * 60) / span * 100) + "%"; }
  // Keep hour labels at least ~48px apart, whatever the screen width.
  var trackPx = Math.max(120, box.clientWidth - (window.innerWidth <= 860 ? 200 : 340));
  var step = [1, 2, 3, 4, 6, 12].find(function (h) { return trackPx / (endH - startH) * h >= 48; }) || 12;

  function gridInto(track, withLabels) {
    for (var h = startH; h <= endH; h++) {
      if ((h - startH) % step !== 0) continue;
      var g = el(withLabels ? "span" : "div", withLabels ? "tl-hour" : "tl-grid", withLabels ? pad(h) + ":00" : null);
      g.style.left = pos(h * 60);
      track.appendChild(g);
    }
  }

  var axis = el("div", "tl-row tl-axis");
  axis.appendChild(el("div"));
  var axisTrack = el("div", "tl-track"); gridInto(axisTrack, true); axis.appendChild(axisTrack);
  axis.appendChild(el("div", "tl-sum muted", "Hours"));
  box.appendChild(axis);

  var nowMin = null;
  if (isToday) { var n = new Date(); nowMin = n.getHours() * 60 + n.getMinutes(); }

  data.present.forEach(function (p) {
    var row = el("div", "tl-row");
    var who = el("div", "tl-who");
    who.appendChild(el("div", "n", p.name || ("User " + p.user_id)));
    who.appendChild(el("div", "i", "ID " + p.user_id + (p.department ? " \u00b7 " + p.department : "")));
    row.appendChild(who);

    var track = el("div", "tl-track");
    gridInto(track, false);
    var a = minutes(p.punches[0]), b = minutes(p.punches[p.punches.length - 1]);
    var single = p.punches.length === 1;
    if (!single) {
      var bar = el("div", "tl-bar"); bar.style.left = pos(a); bar.style.width = ((b - a) / span * 100) + "%";
      track.appendChild(bar);
    }
    p.punches.forEach(function (t) {
      var tick = el("div", "tl-tick" + (single ? " single" : ""));
      tick.style.left = pos(minutes(t));
      tick.title = t;
      track.appendChild(tick);
    });
    if (nowMin !== null && nowMin >= startH * 60 && nowMin <= endH * 60) {
      var now = el("div", "tl-now"); now.style.left = pos(nowMin); now.title = "Now"; track.appendChild(now);
    }
    var label = p.punches.join(", ");
    track.setAttribute("role", "img");
    track.setAttribute("aria-label", (p.name || "User " + p.user_id) + ": punches at " + label);
    track.title = label;
    row.appendChild(track);

    row.appendChild(single
      ? el("div", "tl-sum t-warn", "In " + p.punches[0])
      : el("div", "tl-sum", dur(b - a)));
    box.appendChild(row);
  });

  if (!absentBox.hidden) {
    absentBox.appendChild(el("span", "k", "No punch (" + data.absent.length + "):"));
    data.absent.forEach(function (x) { absentBox.appendChild(el("span", "chip", x.name || ("ID " + x.user_id))); });
  }
}

document.getElementById("day_prev").addEventListener("click", function () { ovDate = addDays(ovDate, -1); loadOverview().catch(function (e) { toast(e.message); }); });
document.getElementById("day_next").addEventListener("click", function () { if (ovDate < ovToday) { ovDate = addDays(ovDate, 1); loadOverview().catch(function (e) { toast(e.message); }); } });
document.getElementById("day_today").addEventListener("click", function () { ovDate = null; loadOverview().catch(function (e) { toast(e.message); }); });

/* ---------- reports */
async function loadReports() {
  var data = await api("GET", "/api/reports");
  var s = data.schedule;
  setText("r_sched", "Every " + s.every_days + " days, an Excel report of the previous " + s.every_days + " days is prepared after " +
    pad(s.hour) + ":00 (" + s.timezone + "). Next: " + period(s.next_start, s.next_end) + ", ready on " + fmtDay(s.next_due) + ".");
  var tbody = document.getElementById("r_rows");
  tbody.textContent = "";
  document.getElementById("count_reports").textContent = data.reports.length ? data.reports.length : "";
  if (!data.reports.length) emptyRow(tbody, 8, "No reports yet. The first one appears at the next scheduled time, or use Export any dates below.");
  data.reports.forEach(function (r) {
    var tr = el("tr");
    tr.appendChild(td(period(r.period_start, r.period_end)));
    tr.appendChild(r.status === "ready" ? pill("Ready", "ok") : pill("Collecting", "warn"));
    tr.appendChild(td(r.devices_synced + " of " + r.devices_total, "num"));
    tr.appendChild(td(r.status === "ready" ? r.employee_count : "", "num"));
    tr.appendChild(td(r.status === "ready" ? r.punch_count : "", "num"));
    tr.appendChild(td(r.ready_at ? when(r.ready_at) : ""));
    tr.appendChild(td(r.note, r.note ? "wrap t-warn" : "muted"));
    var actions = el("td", "actions");
    var a = el("a", "btn btn-sm " + (r.status === "ready" ? "btn-primary" : "btn-ghost"), "Download Excel");
    a.href = "/api/reports/" + r.id + "/download";
    actions.appendChild(a);
    tr.appendChild(actions);
    tbody.appendChild(tr);
  });
}

document.getElementById("x_from").value = isoDay(new Date(Date.now() - 2 * 86400000));
document.getElementById("x_to").value = isoDay(new Date(Date.now() - 86400000));
document.getElementById("x_go").addEventListener("click", function () {
  var from = document.getElementById("x_from").value;
  var to = document.getElementById("x_to").value;
  if (!from || !to) { setText("x_msg", "Choose both dates."); return; }
  if (to < from) { setText("x_msg", "The end date must be on or after the start date."); return; }
  setText("x_msg", "");
  location.href = "/api/export.xlsx?from=" + encodeURIComponent(from) + "&to=" + encodeURIComponent(to);
});

/* ---------- employees */
var empEditing = false;
var empData = [];
function cellInput(value, placeholder, maxLength, label) {
  var i = el("input", "input input-sm");
  i.value = value || ""; i.placeholder = placeholder || ""; i.maxLength = maxLength; i.setAttribute("aria-label", label);
  return i;
}
async function loadEmployees() {
  if (empEditing) return; // never wipe what someone is typing
  var data = await api("GET", "/api/employees");
  empData = data.employees;
  document.getElementById("count_employees").textContent = data.total || "";
  setText("e_sub", data.total + " employee" + (data.total === 1 ? "" : "s") +
    (data.unnamed ? ", " + data.unnamed + " without a name" : "") +
    ". Names are read from the machine on every sync." +
    (CAN_MANAGE ? " Type a name to override it; clear it to use the machine's name again." : ""));
  renderEmployees();
}
var empEditingId = null;
function renderEmployees() {
  var q = document.getElementById("e_search").value.trim().toLowerCase();
  var tbody = document.getElementById("e_rows");
  tbody.textContent = "";
  var list = empData.filter(function (e) {
    return !q || (e.user_id + " " + e.name + " " + (e.machine_name || "") + " " + e.department).toLowerCase().indexOf(q) >= 0;
  });
  if (!empData.length) { emptyRow(tbody, 6, "No employees yet. They appear after the first sync."); return; }
  if (!list.length) { emptyRow(tbody, 6, "No employee matches \u201c" + q + "\u201d."); return; }
  list.forEach(function (e) { tbody.appendChild(e.user_id === empEditingId ? editRow(e) : viewRow(e)); });
}
function viewRow(e) {
  var tr = el("tr");
  tr.appendChild(td(e.user_id, "num"));
  var name = el("td");
  if (e.name) name.appendChild(el("span", null, e.name)); else name.appendChild(el("span", "pill warn", "Needs a name"));
  tr.appendChild(name);
  tr.appendChild(td(e.department, e.department ? "" : "muted"));
  tr.appendChild(td(e.name_edited ? "Edited here" : (e.machine_name ? "Machine" : ""), "muted"));
  tr.appendChild(td(punchTime(e.last_punch), "muted"));
  var actions = el("td", "actions");
  if (CAN_MANAGE) actions.appendChild(btn("Edit", "btn-ghost", function () {
    empEditingId = e.user_id; empEditing = true; renderEmployees();
    var f = document.querySelector("#e_rows input"); if (f) f.focus();
  }));
  tr.appendChild(actions);
  return tr;
}
function editRow(e) {
  var tr = el("tr", "editing");
  tr.appendChild(td(e.user_id, "num"));
  var nameIn = cellInput(e.name, e.machine_name || "Enter a name", 80, "Name for user " + e.user_id);
  var deptIn = cellInput(e.department, "Add department", 60, "Department for user " + e.user_id);
  var c1 = el("td"); c1.appendChild(nameIn);
  if (e.machine_name) c1.appendChild(el("span", "sub-id", "On the machine: " + e.machine_name));
  tr.appendChild(c1);
  var c2 = el("td"); c2.appendChild(deptIn); tr.appendChild(c2);
  tr.appendChild(td(e.name_edited ? "Edited here" : (e.machine_name ? "Machine" : ""), "muted"));
  tr.appendChild(td(punchTime(e.last_punch), "muted"));
  function done() { empEditingId = null; empEditing = false; }
  var save = btn("Save", "btn-primary", async function () {
    save.disabled = true;
    var name = nameIn.value.trim();
    // Same as the machine's name (or empty): keep following the machine.
    if (e.machine_name && name === e.machine_name) name = "";
    try {
      await api("PUT", "/api/employees/" + encodeURIComponent(e.user_id), { name: name, department: deptIn.value });
      setText("e_msg", "");
      done();
      toast("Saved " + (name || e.machine_name || "user " + e.user_id));
      await loadEmployees();
    } catch (err) { setText("e_msg", err.message); save.disabled = false; }
  });
  var cancel = btn("Cancel", "btn-quiet", function () { done(); setText("e_msg", ""); renderEmployees(); });
  [nameIn, deptIn].forEach(function (x) {
    x.addEventListener("keydown", function (ev) { if (ev.key === "Enter") save.click(); if (ev.key === "Escape") cancel.click(); });
  });
  var c3 = el("td", "actions"); c3.appendChild(cancel); c3.appendChild(save); tr.appendChild(c3);
  return tr;
}
document.getElementById("e_search").addEventListener("input", function () { if (!empEditing) renderEmployees(); });

/* ---------- machines: connectors */
async function downloadInstaller(connectorId, token) {
  var res = await fetch("/api/connectors/" + connectorId + "/package", {
    method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(token ? { token: token } : {})
  });
  if (res.status === 401) { location.href = "/login"; throw new Error("Signed out"); }
  if (!res.ok) { var d = await res.json().catch(function () { return {}; }); throw new Error(d.error || ("Download failed (" + res.status + ")")); }
  var blob = await res.blob();
  var m = /filename="([^"]+)"/.exec(res.headers.get("content-disposition") || "");
  var a = el("a"); a.href = URL.createObjectURL(blob); a.download = m ? m[1] : "ZKT-Connector.zip";
  document.body.appendChild(a); a.click();
  setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 2000);
}

async function loadConnectors() {
  var data = await api("GET", "/api/connectors");
  var tbody = document.getElementById("c_rows");
  var select = document.getElementById("d_conn");
  tbody.textContent = ""; select.textContent = "";
  var active = data.connectors.filter(function (c) { return c.is_active; });
  if (!active.length) { var o0 = el("option", null, "Create a connector first"); o0.value = ""; select.appendChild(o0); }
  if (!data.connectors.length) emptyRow(tbody, 7, "No connectors yet. Create one above, then download its installer.");
  data.connectors.forEach(function (c) {
    var tr = el("tr");
    tr.appendChild(td(c.name));
    var online = c.last_seen_at && (Date.now() - new Date(c.last_seen_at).getTime()) < 10 * 60000;
    tr.appendChild(!c.is_active ? pill("Revoked", "idle") : !c.last_seen_at ? pill("Not installed", "warn") : online ? pill("Online", "ok") : pill("Offline", "bad"));
    tr.appendChild(td(c.version, "muted"));
    tr.appendChild(td(c.last_seen_at ? ago(c.last_seen_at) : "", "muted"));
    tr.appendChild(td(c.device_count, "num"));
    tr.appendChild(td(c.token_hint ? "\u2026" + c.token_hint : "", "muted"));
    var actions = el("td", "actions");
    if (CAN_MANAGE && c.is_active) {
      actions.appendChild(btn("Download installer", "btn-ghost", async function () {
        if (c.last_seen_at && !confirm("Download a new installer for " + c.name + "?\n\nThis creates a new token. The PC that runs this connector now stops syncing until you run Install.cmd from the new download on it.")) return;
        try { await downloadInstaller(c.id, null); toast("Installer downloaded. Extract it on the office PC and run Install.cmd."); await refreshMachines(); }
        catch (err) { setText("c_msg", err.message); }
      }));
      actions.appendChild(btn("Revoke", "btn-danger", async function () {
        if (!confirm("Revoke " + c.name + "? It stops syncing immediately.")) return;
        try { await api("POST", "/api/connectors/" + c.id + "/revoke", {}); toast("Revoked " + c.name); await refreshMachines(); } catch (err) { setText("c_msg", err.message); }
      }));
    }
    tr.appendChild(actions);
    tbody.appendChild(tr);
  });
  active.forEach(function (c) { var o = el("option", null, c.name); o.value = c.id; select.appendChild(o); });
}

document.getElementById("c_add").addEventListener("click", async function () {
  setText("c_msg", "");
  var box = document.getElementById("c_token"); box.textContent = "";
  try {
    var r = await api("POST", "/api/connectors", { name: document.getElementById("c_name").value });
    var wrap = el("div", "setup");
    wrap.appendChild(el("h3", null, "Install " + r.connector.name + " on the office PC"));
    var steps = el("ol");
    ["Download the installer. It's already set up for your company.",
     "Copy the ZIP to a Windows PC on the same network as the machine.",
     "Right-click the ZIP, choose Extract All, then double-click Install.cmd and click Yes."].forEach(function (t) { steps.appendChild(el("li", null, t)); });
    wrap.appendChild(steps);
    var dl = btn("Download installer", "btn-primary", async function () {
      dl.disabled = true;
      try { await downloadInstaller(r.connector.id, r.token); dl.textContent = "Downloaded"; toast("Installer downloaded"); }
      catch (err) { setText("c_msg", err.message); dl.disabled = false; }
    });
    dl.classList.remove("btn-sm");
    wrap.appendChild(dl);
    var adv = el("details");
    adv.appendChild(el("summary", null, "Show the token for manual setup"));
    adv.appendChild(el("code", null, r.token));
    var copy = btn("Copy token", "btn-ghost", function () { navigator.clipboard.writeText(r.token); copy.textContent = "Copied"; });
    adv.appendChild(copy);
    wrap.appendChild(adv);
    box.appendChild(wrap);
    document.getElementById("c_name").value = "";
    await refreshMachines();
  } catch (err) { setText("c_msg", err.message); }
});

/* ---------- machines: devices */
function clockText(sec) {
  if (sec === null || sec === undefined) return null;
  var a = Math.abs(sec);
  if (a <= 60) return { t: "Correct", k: "ok" };
  var t = a < 5400 ? Math.round(a / 60) + " min" : a < 172800 ? Math.round(a / 3600) + " h" : Math.round(a / 86400) + " days";
  return { t: t + (sec < 0 ? " slow" : " fast"), k: "warn" };
}
async function loadDevices() {
  var data = await api("GET", "/api/devices");
  var tbody = document.getElementById("d_rows");
  tbody.textContent = "";
  document.getElementById("count_machines").textContent = data.devices.filter(function (d) { return d.is_active; }).length || "";
  if (!data.devices.length) emptyRow(tbody, 7, "No machines yet. Add your attendance machine above.");
  data.devices.forEach(function (d) {
    var tr = el("tr");
    var name = el("td"); name.appendChild(document.createTextNode(d.name));
    name.appendChild(el("span", "sub-id", d.ip_address + ":" + d.port + (d.is_active ? "" : " \u00b7 deactivated")));
    tr.appendChild(name);
    var st = d.last_job_status;
    var syncCell = el("td");
    syncCell.appendChild(el("span", "pill " + (!d.is_active ? "idle" : st === "success" ? "ok" : st === "failed" ? "bad" : st ? "warn" : "idle"),
      !d.is_active ? "Inactive" : st === "failed" ? "Failed" : st === "pending" ? "Waiting" : st === "running" ? "Syncing" : d.last_sync_at ? ago(d.last_sync_at) : "Never"));
    tr.appendChild(syncCell);
    var ck = clockText(d.clock_offset_seconds);
    tr.appendChild(ck ? pill(ck.t, ck.k) : td(""));
    tr.appendChild(td(d.log_count, "num"));
    tr.appendChild(td(d.connector_name, "muted"));
    tr.appendChild(td(d.serial_number, "muted"));
    var actions = el("td", "actions");
    if (CAN_MANAGE && d.is_active) {
      actions.appendChild(btn("Sync now", "btn-ghost", async function () {
        try {
          var r = await api("POST", "/api/devices/" + d.id + "/sync", {});
          toast(r.already_queued ? "A sync for " + d.name + " is already " + r.job.status + "." : "Sync queued. The connector picks it up within a minute.");
          await refreshMachines();
        } catch (err) { setText("d_msg", err.message); }
      }));
      actions.appendChild(btn("Deactivate", "btn-danger", async function () {
        if (!confirm("Deactivate " + d.name + "? Its attendance data is kept.")) return;
        try { await api("POST", "/api/devices/" + d.id + "/deactivate", {}); toast("Deactivated " + d.name); await refreshMachines(); } catch (err) { setText("d_msg", err.message); }
      }));
    }
    tr.appendChild(actions);
    tbody.appendChild(tr);
  });
}
document.getElementById("d_add").addEventListener("click", async function () {
  setText("d_msg", "");
  try {
    await api("POST", "/api/devices", {
      name: document.getElementById("d_name").value,
      ip_address: document.getElementById("d_ip").value,
      port: document.getElementById("d_port").value,
      comm_key: document.getElementById("d_key").value,
      connector_id: document.getElementById("d_conn").value
    });
    toast("Added " + document.getElementById("d_name").value);
    document.getElementById("d_name").value = "";
    document.getElementById("d_ip").value = "";
    await refreshMachines();
  } catch (err) { setText("d_msg", err.message); }
});

/* ---------- sync history */
async function loadJobs() {
  var data = await api("GET", "/api/sync-jobs?limit=30");
  var tbody = document.getElementById("j_rows");
  tbody.textContent = "";
  if (!data.jobs.length) emptyRow(tbody, 9, "No syncs yet. Click Sync now on a machine, or wait for the scheduled sync.");
  var LABEL = { success: ["Done", "ok"], failed: ["Failed", "bad"], pending: ["Waiting", "warn"], running: ["Syncing", "warn"] };
  data.jobs.forEach(function (j) {
    var tr = el("tr");
    tr.appendChild(td(when(j.requested_at)));
    tr.appendChild(td(j.device_name));
    tr.appendChild(td(j.trigger_type === "scheduled" ? "Schedule" : "Manual", "muted"));
    var l = LABEL[j.status] || [j.status, "idle"];
    tr.appendChild(pill(l[0], l[1]));
    tr.appendChild(td(j.status === "success" ? j.records_fetched + (j.records_skipped || 0) : "", "num"));
    tr.appendChild(td(j.status === "success" ? j.records_inserted : "", "num"));
    tr.appendChild(td(j.records_skipped || "", j.records_skipped ? "num t-warn" : "num muted"));
    tr.appendChild(td(j.finished_at ? when(j.finished_at) : ""));
    tr.appendChild(td(j.error_message, j.error_message ? "wrap t-bad" : "muted"));
    tbody.appendChild(tr);
  });
}

/* ---------- sync all */
async function syncAllNow(b) {
  b.disabled = true;
  try {
    var r = await api("POST", "/api/devices/sync-all", {});
    toast(r.devices ? (r.queued ? r.queued + " machine" + (r.queued > 1 ? "s" : "") + " queued. The connector picks them up within a minute." : "Already syncing.") : "No machine has an active connector yet.");
    await refreshAll();
  } catch (err) { toast(err.message); }
  b.disabled = false;
}
document.getElementById("sync_all").addEventListener("click", function () { syncAllNow(this); });
document.getElementById("sync_all_ov").addEventListener("click", function () { syncAllNow(this); });

document.getElementById("logout").addEventListener("click", async function () {
  await fetch("/api/auth/logout", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" });
  location.href = "/login";
});

/* ---------- refresh */
function quiet(p) { return p.catch(function (e) { if (e.message !== "Signed out") console.warn(e); }); }
function refreshMachines() { return Promise.all([quiet(loadConnectors()), quiet(loadDevices()), quiet(loadStatus())]); }
function refreshAll() {
  return Promise.all([quiet(loadStatus()), quiet(loadOverview()), quiet(loadReports()), quiet(loadEmployees()),
    quiet(loadConnectors()), quiet(loadDevices()), quiet(loadJobs())]);
}
showPage();
refreshAll();
setInterval(function () {
  if (document.hidden) return;
  quiet(loadStatus()); quiet(loadJobs()); quiet(loadReports()); quiet(loadDevices()); quiet(loadConnectors());
  if (ovDate === ovToday) quiet(loadOverview());
}, 20000);
</script>`;
'@

Write-Host ""
Write-Host "Phase 9.1 files written. Deploy with: cd worker; npm run deploy" -ForegroundColor Cyan
