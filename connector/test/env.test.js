// Run: npm test
import test from "node:test";
import assert from "node:assert/strict";
import { parseEnv } from "../src/env.js";

test(".env parsing: comments, quotes, CRLF, BOM", () => {
  const text = "\uFEFF# comment\r\nAPI_BASE_URL=https://x.workers.dev\r\nCONNECTOR_TOKEN = zkc_abc  # note\r\nQUOTED=\"a # b\"\r\n\r\nbad line\r\n=x\r\n";
  assert.deepEqual(parseEnv(text), {
    API_BASE_URL: "https://x.workers.dev",
    CONNECTOR_TOKEN: "zkc_abc",
    QUOTED: "a # b",
  });
});