export interface Env {
  DB: D1Database;
  /** Optional. When set, sign-up requires this code (set with: wrangler secret put SIGNUP_CODE). */
  SIGNUP_CODE?: string;
}

export const VERSION = "0.8.0-phase8";

/** Number of files in worker/migrations. The health check reports "degraded" until all are applied. */
export const EXPECTED_MIGRATIONS = 5;