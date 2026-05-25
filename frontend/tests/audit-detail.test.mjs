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

const auditDetail = await importTypeScriptModule(new URL("../lib/audit-detail.ts", import.meta.url));

test("formats task audit detail for operator scanning", () => {
  assert.equal(
    auditDetail.formatAuditDetail({
      task_kind: "create_vm",
      vm_id: "vm-123",
      status: "succeeded",
      has_error: false,
    }),
    "kind=create_vm, vm=vm-123, status=succeeded, error=no",
  );
});

test("formats retry source task detail", () => {
  assert.equal(
    auditDetail.formatAuditDetail({
      task_kind: "create_vm",
      vm_id: "vm-123",
      source_task_id: "task-456",
    }),
    "kind=create_vm, vm=vm-123, source=task-456",
  );
});

test("handles empty or unsupported detail values", () => {
  assert.equal(auditDetail.formatAuditDetail(null), "no detail");
  assert.equal(auditDetail.formatAuditDetail(["not", "an", "object"]), "no detail");
});
