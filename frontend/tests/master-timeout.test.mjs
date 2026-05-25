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

const masterTimeout = await importTypeScriptModule(
  new URL("../lib/master-timeout.ts", import.meta.url),
);

test("parses a bounded frontend-to-master fetch timeout", () => {
  assert.equal(masterTimeout.masterFetchTimeoutMs(undefined), 30_000);
  assert.equal(masterTimeout.masterFetchTimeoutMs("1000"), 1_000);
  assert.equal(masterTimeout.masterFetchTimeoutMs("300000"), 300_000);

  for (const value of ["", "0", "999", "300001", "1.5", "ten", " 1000"]) {
    assert.throws(
      () => masterTimeout.masterFetchTimeoutMs(value),
      /MASTER_FETCH_TIMEOUT_MS/,
      value,
    );
  }
});

test("adds a master fetch abort signal without replacing caller supplied signals", () => {
  const request = masterTimeout.withMasterFetchTimeout(
    {
      method: "POST",
      headers: new Headers({ "X-Test": "1" }),
    },
    1_000,
  );

  assert.equal(request.method, "POST");
  assert.equal(new Headers(request.headers).get("X-Test"), "1");
  assert.ok(request.signal instanceof AbortSignal);

  const controller = new AbortController();
  const preserved = masterTimeout.withMasterFetchTimeout(
    { signal: controller.signal },
    1_000,
  );

  assert.equal(preserved.signal, controller.signal);
});

test("forces frontend-to-master fetches to handle redirects manually", () => {
  const request = masterTimeout.withMasterFetchTimeout({
    redirect: "follow",
  });

  assert.equal(request.redirect, "manual");
});
