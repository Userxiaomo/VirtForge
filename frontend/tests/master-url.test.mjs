import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { fileURLToPath } from "node:url";
import ts from "typescript";

async function importTypeScriptModule(moduleUrl) {
  const source = await readFile(moduleUrl, "utf8");
  const transpiled = ts.transpileModule(source, {
    compilerOptions: {
      module: ts.ModuleKind.ES2022,
      target: ts.ScriptTarget.ES2022,
    },
    fileName: fileURLToPath(moduleUrl),
  });
  const encoded = Buffer.from(transpiled.outputText, "utf8").toString("base64");
  return import(`data:text/javascript;base64,${encoded}`);
}

const masterUrl = await importTypeScriptModule(new URL("../lib/master-url.ts", import.meta.url));

test("normalizes the frontend master API base URL to an origin", () => {
  assert.equal(masterUrl.normalizeMasterApiBaseUrl(undefined), "http://127.0.0.1:8080");
  assert.equal(masterUrl.normalizeMasterApiBaseUrl("http://master:8080"), "http://master:8080");
  assert.equal(masterUrl.normalizeMasterApiBaseUrl("http://vps-master:8080"), "http://vps-master:8080");
  assert.equal(masterUrl.normalizeMasterApiBaseUrl("http://10.1.2.3:8080"), "http://10.1.2.3:8080");
  assert.equal(masterUrl.normalizeMasterApiBaseUrl("http://172.20.0.10:8080"), "http://172.20.0.10:8080");
  assert.equal(masterUrl.normalizeMasterApiBaseUrl("http://192.168.1.10:8080"), "http://192.168.1.10:8080");
  assert.equal(masterUrl.normalizeMasterApiBaseUrl("http://localhost:8080"), "http://localhost:8080");
  assert.equal(masterUrl.normalizeMasterApiBaseUrl("http://[::1]:8080"), "http://[::1]:8080");
  assert.equal(masterUrl.normalizeMasterApiBaseUrl("https://panel.example.com/"), "https://panel.example.com");
});

test("rejects unsafe frontend master API base URLs before forwarding admin secrets", () => {
  for (const value of [
    "",
    "   ",
    "ftp://master.example.com",
    "http://panel.example.com",
    "http://203.0.113.10:8080",
    "http://master:0",
    "https://panel.example.com:0",
    "https://",
    "https://:8443",
    "https://user:password@panel.example.com",
    "https://panel.example.com/api",
    "https://panel.example.com?token=secret",
    "https://panel.example.com#fragment",
    "https://panel.example.com bad",
    "https://panel.example.com\\",
    "https://panel.example.com`",
    "https://panel.example.com\"",
    "https://panel.example.com'",
    "http://[::1",
  ]) {
    assert.throws(
      () => masterUrl.normalizeMasterApiBaseUrl(value),
      /MASTER_API_BASE_URL/,
      value,
    );
  }
});
