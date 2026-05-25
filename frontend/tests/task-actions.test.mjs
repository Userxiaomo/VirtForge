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

const taskActions = await importTypeScriptModule(new URL("../lib/task-actions.ts", import.meta.url));

test("allows canceling only tasks that have not started running", () => {
  assert.equal(taskActions.canCancelTaskStatus("pending"), true);
  assert.equal(taskActions.canCancelTaskStatus("assigned"), true);

  for (const status of ["running", "succeeded", "failed", "canceled"]) {
    assert.equal(taskActions.canCancelTaskStatus(status), false, status);
  }
});

test("auto-refreshes only active task statuses", () => {
  for (const status of ["pending", "assigned", "running"]) {
    assert.equal(taskActions.shouldAutoRefreshTaskStatus(status), true, status);
  }

  for (const status of ["succeeded", "failed", "canceled"]) {
    assert.equal(taskActions.shouldAutoRefreshTaskStatus(status), false, status);
  }
});
