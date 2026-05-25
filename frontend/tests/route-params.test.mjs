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

const routeParams = await importTypeScriptModule(new URL("../lib/route-params.ts", import.meta.url));

test("accepts only UUID route path parameters", () => {
  assert.equal(
    routeParams.safeUuidPathParam("00000000-0000-0000-0000-000000000000"),
    "00000000-0000-0000-0000-000000000000",
  );
  assert.equal(
    routeParams.safeUuidPathParam("ABCDEF12-3456-7890-ABCD-EF1234567890"),
    "ABCDEF12-3456-7890-ABCD-EF1234567890",
  );

  for (const value of [
    "",
    "not-a-uuid",
    "../00000000-0000-0000-0000-000000000000",
    "00000000-0000-0000-0000-000000000000?logs=true",
    "00000000-0000-0000-0000-000000000000/logs",
    "00000000-0000-0000-0000-000000000000%2Flogs",
  ]) {
    assert.equal(routeParams.safeUuidPathParam(value), null, value);
  }
});

test("formats a stable invalid route parameter message", () => {
  assert.equal(routeParams.invalidUuidPathParamMessage("taskId"), "taskId must be a UUID");
});
