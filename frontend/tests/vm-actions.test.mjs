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

const vmActions = await importTypeScriptModule(new URL("../lib/vm-actions.ts", import.meta.url));
const controlPanelPath = fileURLToPath(new URL("../components/control-panel.tsx", import.meta.url));

const vm = {
  id: "vm-123",
  name: "customer-prod-01",
  status: "running",
};

test("builds explicit confirmation text for destructive VM actions", () => {
  assert.equal(
    vmActions.vmActionConfirmationMessage("delete-vm", vm),
    "Delete VM customer-prod-01? This schedules libvirt domain and managed disk removal for vm-123.",
  );
  assert.equal(
    vmActions.vmActionConfirmationMessage("reinstall-vm", vm),
    "Reinstall VM customer-prod-01? This replaces the guest disk and can destroy data inside vm-123.",
  );
});

test("builds interruption warnings for power VM actions", () => {
  assert.equal(
    vmActions.vmActionConfirmationMessage("stop-vm", vm),
    "Stop VM customer-prod-01? This can interrupt running workloads.",
  );
  assert.equal(
    vmActions.vmActionConfirmationMessage("reboot-vm", vm),
    "Reboot VM customer-prod-01? This can interrupt running workloads.",
  );
  assert.equal(vmActions.vmActionConfirmationMessage("start-vm", vm), "Start VM customer-prod-01?");
});

test("shows VM actions that match the VM lifecycle state", () => {
  assert.deepEqual(vmActions.availableVmActions({ status: "running" }), [
    "stop-vm",
    "reboot-vm",
    "reinstall-vm",
    "delete-vm",
  ]);
  assert.deepEqual(vmActions.availableVmActions({ status: "stopped" }), [
    "start-vm",
    "reinstall-vm",
    "delete-vm",
  ]);
  assert.deepEqual(vmActions.availableVmActions({ status: "error" }), [
    "start-vm",
    "reinstall-vm",
    "delete-vm",
  ]);
  assert.deepEqual(vmActions.availableVmActions({ status: "provisioning" }), []);
  assert.deepEqual(vmActions.availableVmActions({ status: "deleting" }), []);
  assert.deepEqual(vmActions.availableVmActions({ status: "deleted" }), []);
});

test("hides VM actions while the VM has an active reserved task", () => {
  for (const status of ["running", "stopped", "error"]) {
    assert.deepEqual(vmActions.availableVmActions({ status, hasActiveTask: true }), [], status);
  }

  assert.deepEqual(vmActions.availableVmActions({ status: "stopped", hasActiveTask: false }), [
    "start-vm",
    "reinstall-vm",
    "delete-vm",
  ]);
});

test("VM panel passes active task reservation state into action availability", async () => {
  const source = await readFile(controlPanelPath, "utf8");
  const apiSource = await readFile(fileURLToPath(new URL("../lib/api.ts", import.meta.url)), "utf8");

  assert.match(apiSource, /last_task_status\?: TaskStatus \| null;/);
  assert.match(source, /<Vms onAction=\{createVmAction\} vms=\{vms\} \/>/);
  assert.doesNotMatch(source, /activeTaskIds\.has\(vm\.last_task_id\)/);
  assert.match(source, /shouldAutoRefreshTaskStatus\(vm\.last_task_status\)/);
  assert.match(source, /availableVmActions\(\{ status: vm\.status, hasActiveTask \}\)/);
});
