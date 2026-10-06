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
.dash { max-width:1100px; margin:24px auto; padding:0 16px; }
.dash .card { margin-bottom:20px; padding:20px; }
.dash h2 { font-size:16px; margin:0 0 4px; }
.dash p.sub { margin-bottom:14px; }
.row { display:flex; flex-wrap:wrap; gap:10px; align-items:flex-end; }
.row .f { display:flex; flex-direction:column; flex:1 1 140px; }
.row .f label { margin:0 0 4px; }
.row input, .row select { padding:8px 10px; border:1px solid var(--border); border-radius:8px; background:var(--bg); color:var(--text); font-size:14px; width:100%; }
.row button, .sm { width:auto; margin:0; padding:9px 14px; font-size:14px; }
.sm { padding:5px 10px; font-size:13px; margin-left:4px; background:transparent; color:var(--text); border:1px solid var(--border); }
.sm.primary { background:var(--accent); color:#fff; border-color:var(--accent); }
.tbl { overflow-x:auto; margin-top:14px; }
table { width:100%; border-collapse:collapse; font-size:13px; }
th, td { text-align:left; padding:8px 6px; border-bottom:1px solid var(--border); white-space:nowrap; }
th { color:var(--muted); font-weight:500; }
td.err { white-space:normal; color:var(--error); max-width:280px; }
td.warn { color:#b26b00; }
.badge { display:inline-block; padding:2px 8px; border-radius:999px; font-size:12px; border:1px solid var(--border); }
.b-success, .b-active, .b-ready { color:#1a7f37; border-color:#1a7f37; }
.b-collecting { color:#b26b00; border-color:#b26b00; }
a.dl { display:inline-block; text-decoration:none; border-radius:8px; }
.b-failed, .b-revoked, .b-inactive { color:var(--error); border-color:var(--error); }
.b-running, .b-pending { color:#b26b00; border-color:#b26b00; }
.token { margin-top:14px; padding:12px; border:1px dashed var(--accent); border-radius:8px; font-size:13px; }
.token code { display:block; margin:8px 0; padding:8px; background:var(--bg); border-radius:6px; word-break:break-all; font-size:13px; }
.empty { color:var(--muted); font-size:13px; padding:10px 0; }
.dash .msg { margin-top:8px; min-height:0; }
.sm.primary:disabled { opacity:.3; }
input.cell { padding:6px 8px; border:1px solid var(--border); border-radius:6px; background:var(--bg); color:var(--text); font-size:13px; width:100%; min-width:140px; }
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
  const canManage = auth.role === "owner" || auth.role === "admin";
  const hide = canManage ? "" : ` style="display:none"`;
  return layout("Dashboard", `
<div class="dash">
  <div class="top">
    <div>
      <h1>${e(auth.companyName)}</h1>
      <p class="sub" style="margin:0">${e(auth.fullName)} &middot; ${e(auth.role)}</p>
    </div>
    <button id="logout" type="button">Sign out</button>
  </div>

  <div class="card">
    <h2>Attendance reports</h2>
    <p class="sub" id="r_sched">Every 2 days an Excel report of the previous 2 days is prepared automatically.</p>
    <div class="tbl"><table>
      <thead><tr><th>Period</th><th>Status</th><th>Machines synced</th><th>Employees</th><th>Punches</th><th>Ready at</th><th>Note</th><th></th></tr></thead>
      <tbody id="r_rows"></tbody>
    </table></div>
    <div class="row" style="margin-top:16px">
      <div class="f" style="flex:0 1 170px"><label for="x_from">Custom export from</label><input id="x_from" type="date"></div>
      <div class="f" style="flex:0 1 170px"><label for="x_to">to</label><input id="x_to" type="date"></div>
      <button id="x_go" type="button">Download Excel</button>
    </div>
    <div class="msg" id="x_msg"></div>
  </div>

  <div class="card">
    <h2>Employees</h2>
    <p class="sub" id="e_sub">Names are read from the machine's user list on every sync. Type a name here to override it, or leave it blank to use the machine's name.</p>
    <div class="tbl"><table>
      <thead><tr><th>User ID</th><th>Name</th><th>Department</th><th>Name source</th><th>Last punch</th><th></th></tr></thead>
      <tbody id="e_rows"></tbody>
    </table></div>
    <div class="msg" id="e_msg"></div>
  </div>

  <div class="card">
    <h2>1. Connectors</h2>
    <p class="sub">A connector is the ZKT Connector app on an office PC that can reach the machine. Its token goes into connector/.env.</p>
    <div class="row"${hide}>
      <div class="f"><label for="c_name">Connector name</label><input id="c_name" placeholder="Office PC - Lahore"></div>
      <button id="c_add" type="button">Create connector</button>
    </div>
    <div class="msg" id="c_msg"></div>
    <div id="c_token"></div>
    <div class="tbl"><table>
      <thead><tr><th>Name</th><th>Token</th><th>Status</th><th>Version</th><th>Last seen</th><th>Devices</th><th></th></tr></thead>
      <tbody id="c_rows"></tbody>
    </table></div>
  </div>

  <div class="card">
    <h2>2. Devices</h2>
    <p class="sub">Attendance machines on your LAN, each assigned to the connector that reads it.</p>
    <div class="row"${hide}>
      <div class="f"><label for="d_name">Device name</label><input id="d_name" placeholder="Main entrance K50"></div>
      <div class="f"><label for="d_ip">IP address</label><input id="d_ip" placeholder="192.168.10.21"></div>
      <div class="f" style="flex:0 1 90px"><label for="d_port">Port</label><input id="d_port" value="4370"></div>
      <div class="f" style="flex:0 1 90px"><label for="d_key">Comm key</label><input id="d_key" value="0"></div>
      <div class="f"><label for="d_conn">Connector</label><select id="d_conn"></select></div>
      <button id="d_add" type="button">Add device</button>
    </div>
    <div class="msg" id="d_msg"></div>
    <div class="tbl"><table>
      <thead><tr><th>Name</th><th>Address</th><th>Connector</th><th>Serial</th><th>Clock</th><th>Last sync</th><th>Logs</th><th>Last job</th><th></th></tr></thead>
      <tbody id="d_rows"></tbody>
    </table></div>
  </div>

  <div class="card">
    <h2>3. Sync jobs</h2>
    <p class="sub">Each import run. The connector picks up pending jobs and uploads the machine's attendance logs.</p>
    <div class="tbl"><table>
      <thead><tr><th>Requested</th><th>Device</th><th>Trigger</th><th>Status</th><th>Read</th><th>New</th><th>Skipped</th><th>Finished</th><th>Error</th></tr></thead>
      <tbody id="j_rows"></tbody>
    </table></div>
  </div>

  <div class="foot">${VERSION}</div>
</div>
<script>
var CAN_MANAGE = ${canManage ? "true" : "false"};

async function api(method, path, body) {
  var opts = { method: method, headers: {} };
  if (body !== undefined) { opts.headers["content-type"] = "application/json"; opts.body = JSON.stringify(body); }
  var res = await fetch(path, opts);
  var data = await res.json().catch(function () { return {}; });
  if (res.status === 401) { location.href = "/login"; throw new Error("Signed out"); }
  if (!res.ok) throw new Error(data.error || ("Request failed (" + res.status + ")"));
  return data;
}

function when(v) { return v ? new Date(v).toLocaleString() : "\\u2014"; }
function td(text, cls) { var c = document.createElement("td"); c.textContent = (text === null || text === undefined || text === "") ? "\\u2014" : String(text); if (cls) c.className = cls; return c; }
function badge(text) { var c = document.createElement("td"); if (!text) { c.textContent = "\\u2014"; return c; } var s = document.createElement("span"); s.className = "badge b-" + text; s.textContent = text; c.appendChild(s); return c; }
function btn(label, primary, onClick) { var b = document.createElement("button"); b.type = "button"; b.className = primary ? "sm primary" : "sm"; b.textContent = label; b.addEventListener("click", onClick); return b; }
function clockCell(sec) {
  var c = document.createElement("td");
  if (sec === null || sec === undefined) { c.textContent = "\\u2014"; return c; }
  var a = Math.abs(sec);
  var txt = a < 60 ? a + " s" : a < 3600 ? Math.round(a / 60) + " min" : a < 86400 ? (a / 3600).toFixed(1) + " h" : Math.round(a / 86400) + " days";
  c.textContent = a <= 60 ? "OK" : (sec < 0 ? txt + " slow" : txt + " fast");
  if (a > 60) { c.className = "warn"; c.title = "The machine clock is off. Correct the time on the machine so punches are recorded at the right time."; }
  return c;
}
function emptyRow(tbody, cols, text) { var tr = document.createElement("tr"); var c = document.createElement("td"); c.colSpan = cols; c.className = "empty"; c.textContent = text; tr.appendChild(c); tbody.appendChild(tr); }
function showMsg(id, text) { document.getElementById(id).textContent = text || ""; }

function fmtDate(d) { var p = d.split("-"); var m = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"][Number(p[1]) - 1]; return p[2] + " " + m + " " + p[0]; }
function period(a, b) { return a === b ? fmtDate(a) : fmtDate(a) + " \\u2013 " + fmtDate(b); }
function isoLocal(offsetDays) { var d = new Date(); d.setDate(d.getDate() + offsetDays); var p = function (n) { return String(n).padStart(2, "0"); }; return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate()); }

async function loadReports() {
  var data = await api("GET", "/api/reports");
  var s = data.schedule;
  document.getElementById("r_sched").textContent =
    "Every " + s.every_days + " days an Excel report of the previous " + s.every_days + " days is prepared automatically. Next: " +
    period(s.next_start, s.next_end) + ", ready on " + fmtDate(s.next_due) + " after " + String(s.hour).padStart(2, "0") + ":00 (" + s.timezone + ").";
  var tbody = document.getElementById("r_rows");
  tbody.textContent = "";
  if (!data.reports.length) emptyRow(tbody, 8, "No reports yet. The first one is created at the next scheduled time.");
  data.reports.forEach(function (r) {
    var tr = document.createElement("tr");
    tr.appendChild(td(period(r.period_start, r.period_end)));
    tr.appendChild(badge(r.status === "ready" ? "ready" : "collecting"));
    tr.appendChild(td(r.devices_synced + " / " + r.devices_total));
    tr.appendChild(td(r.status === "ready" ? r.employee_count : ""));
    tr.appendChild(td(r.status === "ready" ? r.punch_count : ""));
    tr.appendChild(td(when(r.ready_at)));
    tr.appendChild(td(r.note, r.note ? "warn" : ""));
    var actions = document.createElement("td");
    var a = document.createElement("a");
    a.href = "/api/reports/" + r.id + "/download";
    a.className = "sm primary dl";
    a.textContent = "Download Excel";
    actions.appendChild(a);
    tr.appendChild(actions);
    tbody.appendChild(tr);
  });
}

var empEditing = false;

function input(value, placeholder, maxLength) {
  var i = document.createElement("input");
  i.value = value || "";
  i.placeholder = placeholder || "";
  i.maxLength = maxLength;
  i.className = "cell";
  return i;
}

async function loadEmployees() {
  if (empEditing) return; // don't wipe what someone is typing
  var data = await api("GET", "/api/employees");
  document.getElementById("e_sub").textContent =
    data.total + " employee(s), " + data.unnamed + " without a name. Names are read from the machine's user list on every sync. " +
    (CAN_MANAGE ? "Type a name to override it, or leave it blank to use the machine's name." : "");
  var tbody = document.getElementById("e_rows");
  tbody.textContent = "";
  if (!data.employees.length) emptyRow(tbody, 6, "No employees yet. They appear after the first sync.");
  data.employees.forEach(function (e) {
    var tr = document.createElement("tr");
    tr.appendChild(td(e.user_id));
    var source = e.name_edited ? "Edited" : (e.machine_name ? "Machine" : "");
    if (!CAN_MANAGE) {
      tr.appendChild(td(e.name, e.name ? "" : "warn"));
      tr.appendChild(td(e.department));
      tr.appendChild(td(source));
      tr.appendChild(td(e.last_punch));
      tr.appendChild(document.createElement("td"));
      tbody.appendChild(tr);
      return;
    }
    var nameIn = input(e.name_edited ? e.name : "", e.machine_name || "Enter name", 80);
    var deptIn = input(e.department, "Department", 60);
    var c1 = document.createElement("td"); c1.appendChild(nameIn); tr.appendChild(c1);
    var c2 = document.createElement("td"); c2.appendChild(deptIn); tr.appendChild(c2);
    tr.appendChild(td(source, source ? "" : "warn"));
    tr.appendChild(td(e.last_punch));
    var save = btn("Save", true, async function () {
      save.disabled = true;
      try {
        await api("PUT", "/api/employees/" + encodeURIComponent(e.user_id), { name: nameIn.value, department: deptIn.value });
        showMsg("e_msg", "");
        empEditing = false;
        await loadEmployees();
      } catch (err) { showMsg("e_msg", err.message); save.disabled = false; }
    });
    save.disabled = true;
    var orig = nameIn.value + "|" + deptIn.value;
    [nameIn, deptIn].forEach(function (el) {
      el.addEventListener("input", function () { save.disabled = (nameIn.value + "|" + deptIn.value) === orig; empEditing = !save.disabled; });
      el.addEventListener("keydown", function (ev) { if (ev.key === "Enter" && !save.disabled) save.click(); });
    });
    var c3 = document.createElement("td"); c3.appendChild(save); tr.appendChild(c3);
    tbody.appendChild(tr);
  });
}

async function loadConnectors() {
  var data = await api("GET", "/api/connectors");
  var tbody = document.getElementById("c_rows");
  var select = document.getElementById("d_conn");
  tbody.textContent = ""; select.textContent = "";
  var none = document.createElement("option"); none.value = ""; none.textContent = "(none yet)"; select.appendChild(none);
  if (!data.connectors.length) emptyRow(tbody, 7, "No connectors yet. Create one first.");
  data.connectors.forEach(function (c) {
    var tr = document.createElement("tr");
    tr.appendChild(td(c.name));
    tr.appendChild(td(c.token_hint ? "zkc_\\u2026" + c.token_hint : ""));
    tr.appendChild(badge(c.is_active ? "active" : "revoked"));
    tr.appendChild(td(c.version));
    tr.appendChild(td(when(c.last_seen_at)));
    tr.appendChild(td(c.device_count));
    var actions = document.createElement("td");
    if (CAN_MANAGE && c.is_active) {
      actions.appendChild(btn("Revoke", false, async function () {
        if (!confirm("Revoke connector '" + c.name + "'? It will stop working immediately.")) return;
        try { await api("POST", "/api/connectors/" + c.id + "/revoke", {}); await refresh(); } catch (err) { alert(err.message); }
      }));
    }
    tr.appendChild(actions);
    tbody.appendChild(tr);
    if (c.is_active) { var o = document.createElement("option"); o.value = c.id; o.textContent = c.name; select.appendChild(o); }
  });
  if (select.options.length > 1) select.selectedIndex = 1;
}

async function loadDevices() {
  var data = await api("GET", "/api/devices");
  var tbody = document.getElementById("d_rows");
  tbody.textContent = "";
  if (!data.devices.length) emptyRow(tbody, 9, "No devices yet.");
  data.devices.forEach(function (d) {
    var tr = document.createElement("tr");
    tr.appendChild(td(d.name + (d.is_active ? "" : " (inactive)")));
    tr.appendChild(td(d.ip_address + ":" + d.port));
    tr.appendChild(td(d.connector_name));
    tr.appendChild(td(d.serial_number));
    tr.appendChild(clockCell(d.clock_offset_seconds));
    tr.appendChild(td(when(d.last_sync_at)));
    tr.appendChild(td(d.log_count));
    tr.appendChild(badge(d.last_job_status));
    var actions = document.createElement("td");
    if (CAN_MANAGE && d.is_active) {
      actions.appendChild(btn("Sync now", true, async function () {
        try {
          var r = await api("POST", "/api/devices/" + d.id + "/sync", {});
          showMsg("d_msg", r.already_queued ? "A sync for this device is already " + r.job.status + "." : "");
          await refresh();
        } catch (err) { alert(err.message); }
      }));
      actions.appendChild(btn("Deactivate", false, async function () {
        if (!confirm("Deactivate device '" + d.name + "'? Its attendance data is kept.")) return;
        try { await api("POST", "/api/devices/" + d.id + "/deactivate", {}); await refresh(); } catch (err) { alert(err.message); }
      }));
    }
    tr.appendChild(actions);
    tbody.appendChild(tr);
  });
}

async function loadJobs() {
  var data = await api("GET", "/api/sync-jobs?limit=20");
  var tbody = document.getElementById("j_rows");
  tbody.textContent = "";
  if (!data.jobs.length) emptyRow(tbody, 9, "No sync jobs yet.");
  data.jobs.forEach(function (j) {
    var tr = document.createElement("tr");
    tr.appendChild(td(when(j.requested_at)));
    tr.appendChild(td(j.device_name));
    tr.appendChild(td(j.trigger_type));
    tr.appendChild(badge(j.status));
    tr.appendChild(td(j.records_fetched + (j.records_skipped || 0)));
    tr.appendChild(td(j.records_inserted));
    tr.appendChild(td(j.records_skipped, j.records_skipped ? "warn" : ""));
    tr.appendChild(td(when(j.finished_at)));
    tr.appendChild(td(j.error_message, j.error_message ? "err" : ""));
    tbody.appendChild(tr);
  });
}

async function refresh() {
  try { await Promise.all([loadReports(), loadEmployees(), loadConnectors(), loadDevices(), loadJobs()]); }
  catch (err) { showMsg("d_msg", err.message); }
}

document.getElementById("c_add").addEventListener("click", async function () {
  showMsg("c_msg", "");
  var box = document.getElementById("c_token"); box.textContent = "";
  try {
    var r = await api("POST", "/api/connectors", { name: document.getElementById("c_name").value });
    var wrap = document.createElement("div"); wrap.className = "token";
    var title = document.createElement("strong"); title.textContent = "Connector token for '" + r.connector.name + "'";
    var code = document.createElement("code"); code.textContent = r.token;
    var note = document.createElement("div"); note.textContent = r.note;
    var copy = btn("Copy token", true, function () { navigator.clipboard.writeText(r.token); copy.textContent = "Copied"; });
    wrap.appendChild(title); wrap.appendChild(code); wrap.appendChild(note); wrap.appendChild(copy);
    box.appendChild(wrap);
    document.getElementById("c_name").value = "";
    await refresh();
  } catch (err) { showMsg("c_msg", err.message); }
});

document.getElementById("d_add").addEventListener("click", async function () {
  showMsg("d_msg", "");
  try {
    await api("POST", "/api/devices", {
      name: document.getElementById("d_name").value,
      ip_address: document.getElementById("d_ip").value,
      port: document.getElementById("d_port").value,
      comm_key: document.getElementById("d_key").value,
      connector_id: document.getElementById("d_conn").value
    });
    document.getElementById("d_name").value = "";
    document.getElementById("d_ip").value = "";
    await refresh();
  } catch (err) { showMsg("d_msg", err.message); }
});

document.getElementById("x_from").value = isoLocal(-2);
document.getElementById("x_to").value = isoLocal(-1);
document.getElementById("x_go").addEventListener("click", function () {
  var from = document.getElementById("x_from").value;
  var to = document.getElementById("x_to").value;
  if (!from || !to) { showMsg("x_msg", "Choose both dates."); return; }
  if (to < from) { showMsg("x_msg", "'to' must be on or after 'from'."); return; }
  showMsg("x_msg", "");
  location.href = "/api/export.xlsx?from=" + encodeURIComponent(from) + "&to=" + encodeURIComponent(to);
});

document.getElementById("logout").addEventListener("click", async function () {
  await fetch("/api/auth/logout", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" });
  location.href = "/login";
});

refresh();
setInterval(function () { loadJobs(); loadReports(); }, 15000);
</script>`);
}