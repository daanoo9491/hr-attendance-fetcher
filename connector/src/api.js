// HTTP client for the Attendance Fetcher Worker (connector side).
// Every request has a time limit, so a bad network can never freeze the connector.
export const CONNECTOR_VERSION = "0.9.0";

const DEFAULT_TIMEOUT_MS = 30000;
export const CLAIM_WAIT_SECONDS = 20;

export class ApiClient {
  constructor(baseUrl, token) {
    this.baseUrl = baseUrl.replace(/\/+$/, "");
    this.token = token;
  }

  async request(method, path, body, timeoutMs = DEFAULT_TIMEOUT_MS) {
    let res;
    try {
      res = await fetch(this.baseUrl + path, {
        method,
        headers: {
          authorization: `Bearer ${this.token}`,
          "content-type": "application/json",
          "x-connector-version": CONNECTOR_VERSION,
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch (err) {
      const timedOut = err && (err.name === "TimeoutError" || err.name === "AbortError");
      const e = new Error(timedOut
        ? `${method} ${path}: no answer from the server within ${Math.round(timeoutMs / 1000)} s`
        : `${method} ${path}: cannot reach the server (${err.cause?.code ?? err.message})`);
      e.network = true;
      throw e;
    }

    const text = await res.text();
    let data;
    try {
      data = text ? JSON.parse(text) : {};
    } catch {
      data = { error: text.slice(0, 200) };
    }

    if (!res.ok) {
      const err = new Error(`${method} ${path} -> ${res.status}: ${data.error ?? "request failed"}`);
      err.status = res.status;
      throw err;
    }
    return data;
  }

  getConfig() {
    return this.request("GET", "/api/connector/config");
  }

  /** Waits up to `waitSeconds` on the server for a job (long poll). */
  claimJob(waitSeconds = CLAIM_WAIT_SECONDS) {
    return this.request("POST", `/api/connector/jobs/claim?wait=${waitSeconds}`, {}, (waitSeconds + 20) * 1000);
  }

  /** Reports what the connector is doing. Resolves to { stop: true } when the job was cancelled. */
  reportProgress(jobId, stage, pct, message) {
    return this.request("POST", `/api/connector/jobs/${encodeURIComponent(jobId)}/progress`, { stage, pct, message }, 15000);
  }

  /** records: [{ user_id, timestamp: "YYYY-MM-DD HH:MM:SS", state, verify_mode }] (max 1000 per call) */
  uploadLogs(jobId, records) {
    return this.request("POST", `/api/connector/jobs/${encodeURIComponent(jobId)}/logs`, { records });
  }

  /** users: [{ user_id, name }] from the machine's user list */
  uploadUsers(jobId, users) {
    return this.request("POST", `/api/connector/jobs/${encodeURIComponent(jobId)}/users`, { users });
  }

  /** payload: { status: "success" | "failed", error_message?, device_serial? } */
  completeJob(jobId, payload) {
    return this.request("POST", `/api/connector/jobs/${encodeURIComponent(jobId)}/complete`, payload);
  }
}

export function clientFromEnv() {
  const base = process.env.API_BASE_URL;
  const token = process.env.CONNECTOR_TOKEN;
  if (!base) throw new Error("API_BASE_URL is not set in .env");
  if (!token || !token.startsWith("zkc_")) {
    throw new Error("CONNECTOR_TOKEN is not set in .env (create a connector in the dashboard and paste its token)");
  }
  return new ApiClient(base, token);
}