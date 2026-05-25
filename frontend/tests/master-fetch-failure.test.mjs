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

const masterFetchFailure = await importTypeScriptModule(
  new URL("../lib/master-fetch-failure.ts", import.meta.url),
);

test("maps master fetch timeout failures to a sanitized gateway timeout", () => {
  const failure = masterFetchFailure.masterFetchFailureResponse(
    new DOMException("secret-token-value", "TimeoutError"),
  );

  assert.equal(failure.status, 504);
  assert.deepEqual(failure.body, { error: "master request timed out" });
  assert.doesNotMatch(JSON.stringify(failure), /secret-token-value/);
});

test("maps generic master fetch failures to a sanitized bad gateway response", () => {
  const failure = masterFetchFailure.masterFetchFailureResponse(
    new Error("password=secret-token-value"),
  );

  assert.equal(failure.status, 502);
  assert.deepEqual(failure.body, { error: "master unavailable" });
  assert.doesNotMatch(JSON.stringify(failure), /secret-token-value|password/);
});
