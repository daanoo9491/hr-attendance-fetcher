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