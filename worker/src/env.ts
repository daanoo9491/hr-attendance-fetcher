export interface Env {
  DB: D1Database;
  /** Optional. When set, sign-up requires this code (set with: wrangler secret put SIGNUP_CODE). */
  SIGNUP_CODE?: string;
}

export const VERSION = "0.5.0-phase5";

/** Number of files in worker/migrations. The health check reports "degraded" until all are applied. */
export const EXPECTED_MIGRATIONS = 3;