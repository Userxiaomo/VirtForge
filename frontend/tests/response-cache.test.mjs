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

const responseCache = await importTypeScriptModule(
  new URL("../lib/response-cache.ts", import.meta.url),
);
const sessionRoutePath = fileURLToPath(new URL("../app/api/session/route.ts", import.meta.url));
const apiPath = fileURLToPath(new URL("../lib/api.ts", import.meta.url));

test("marks browser responses carrying one-time secrets as non-cacheable", () => {
  const headers = new Headers({ "Content-Type": "application/json" });

  responseCache.applyNoStoreHeaders(headers);

  assert.equal(headers.get("Content-Type"), "application/json");
  assert.equal(headers.get("Cache-Control"), "no-store, max-age=0");
  assert.equal(headers.get("Pragma"), "no-cache");
  assert.equal(headers.get("Expires"), "0");
});

test("marks admin session responses as non-cacheable", async () => {
  const source = await readFile(sessionRoutePath, "utf8");

  assert.match(source, /from "\.\.\/\.\.\/\.\.\/lib\/response-cache"/);
  assert.match(source, /applyNoStoreHeaders\(response\.headers\);/);
  assert.match(source, /function sessionJsonResponse\(/);
});

test("marks BFF proxy error responses as non-cacheable", async () => {
  const source = await readFile(apiPath, "utf8");

  assert.match(source, /function noStoreJsonResponse\(/);
  for (const errorPath of [
    /return noStoreJsonResponse\(\{ error: "invalid master admin API path" \}, \{ status: 500 \}\);/,
    /return noStoreJsonResponse\(\{ error: "unauthorized" \}, \{ status: 401 \}\);/,
    /return noStoreJsonResponse\(failure\.body, \{ status: failure\.status \}\);/,
    /return noStoreJsonResponse\(\{ error: "invalid same-origin mutation request" \}, \{ status: 403 \}\);/,
  ]) {
    assert.match(source, errorPath);
  }
  assert.doesNotMatch(source, /return NextResponse\.json\(\{ error:/);
});
