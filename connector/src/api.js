// HTTP client for the Attendance Fetcher Worker (connector side).
export const CONNECTOR_VERSION = "0.4.0";

export class ApiClient {
  constructor(baseUrl, token) {
    this.baseUrl = baseUrl.replace(/\/+$/, "");
    this.token = token;
  }

  async request(method, path, body) {
    const res = await fetch(this.baseUrl + path, {
      method,
      headers: {
        authorization: `Bearer ${this.token}`,
        "content-type": "application/json",
        "x-connector-version": CONNECTOR_VERSION,
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });

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

  claimJob() {
    return this.request("POST", "/api/connector/jobs/claim", {});
  }

  /** records: [{ user_id, timestamp: "YYYY-MM-DD HH:MM:SS", state, verify_mode }] (max 1000 per call) */
  uploadLogs(jobId, records) {
    return this.request("POST", `/api/connector/jobs/${encodeURIComponent(jobId)}/logs`, { records });
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