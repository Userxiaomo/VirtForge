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

const masterPath = await importTypeScriptModule(
  new URL("../lib/master-path.ts", import.meta.url),
);

test("accepts only master admin API paths for authenticated forwarding", () => {
  assert.equal(masterPath.normalizeMasterAdminPath("/api/admin/nodes"), "/api/admin/nodes");
  assert.equal(
    masterPath.normalizeMasterAdminPath("/api/admin/tasks/00000000-0000-0000-0000-000000000000/logs"),
    "/api/admin/tasks/00000000-0000-0000-0000-000000000000/logs",
  );

  for (const value of [
    "",
    "api/admin/nodes",
    "//evil.example/api/admin/nodes",
    "https://panel.example.com/api/admin/nodes",
    "/api/agent/register",
    "/api/admin/../agent/register",
    "/api/admin/%2e%2e/agent/register",
    "/api/admin/nodes?token=secret",
    "/api/admin/nodes#token",
    "/api/admin/nodes bad",
    "/api/admin/nodes`",
  ]) {
    assert.throws(
      () => masterPath.normalizeMasterAdminPath(value),
      /master admin API path/,
      value,
    );
  }
});
