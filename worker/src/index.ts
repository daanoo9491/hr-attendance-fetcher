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