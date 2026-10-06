// Loads settings from the .env file next to the connector (no dependencies).
// The file is found relative to this code, not the current folder, so it works
// the same when started by Windows at boot, by a shortcut, or from a terminal.
// Values already set in the environment win over the file.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const CONNECTOR_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
export const ENV_FILE = path.join(CONNECTOR_DIR, ".env");

export function parseEnv(text) {
  const out = {};
  for (const raw of text.replace(/^\uFEFF/, "").split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq <= 0) continue;
    const key = line.slice(0, eq).trim();
    let value = line.slice(eq + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    } else {
      const hash = value.indexOf(" #");
      if (hash >= 0) value = value.slice(0, hash).trim();
    }
    if (/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) out[key] = value;
  }
  return out;
}

if (fs.existsSync(ENV_FILE)) {
  const values = parseEnv(fs.readFileSync(ENV_FILE, "utf8"));
  for (const [k, v] of Object.entries(values)) {
    if (process.env[k] === undefined) process.env[k] = v;
  }
}