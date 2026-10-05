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