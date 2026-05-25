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

const readiness = await importTypeScriptModule(
  new URL("../lib/node-readiness.ts", import.meta.url),
);

function node(overrides = {}) {
  return {
    id: "00000000-0000-0000-0000-000000000000",
    name: "node-01",
    status: "online",
    scheduling_enabled: true,
    agent_version: "0.1.0",
    last_seen_at: "2026-05-23T00:00:00Z",
    libvirt_status: "available",
    host_checks: [],
    cpu_total: 4,
    cpu_used: 1,
    memory_total: 8 * 1024 * 1024 * 1024,
    memory_used: 2 * 1024 * 1024 * 1024,
    disk_total: 100 * 1024 * 1024 * 1024,
    disk_used: 10 * 1024 * 1024 * 1024,
    committed_cpu: 1,
    committed_memory_mb: 512,
    committed_disk_gb: 10,
    vm_count: 1,
    created_at: "2026-05-23T00:00:00Z",
    ...overrides,
  };
}

test("offers only online freshly heartbeating non-failed nodes for create VM", () => {
  const now = new Date("2026-05-23T00:30:00Z");
  assert.equal(readiness.isCreateVmNodeSelectable(node(), now), true);
  assert.equal(
    readiness.isCreateVmNodeSelectable(node({ libvirt_status: "not_checked" }), now),
    true,
  );

  for (const overrides of [
    { status: "offline" },
    { scheduling_enabled: false },
    { agent_version: null },
    { last_seen_at: null },
    { last_seen_at: "2026-05-22T22:29:59Z" },
    { libvirt_status: "unavailable" },
  ]) {
    assert.equal(
      readiness.isCreateVmNodeSelectable(node(overrides), now),
      false,
      JSON.stringify(overrides),
    );
  }
});

test("labels why a node is not ready for create VM", () => {
  const now = new Date("2026-05-23T00:30:00Z");
  assert.equal(readiness.nodeCreateVmAdmissionLabel(node(), now), "ready");
  assert.equal(readiness.nodeCreateVmAdmissionLabel(node({ status: "offline" }), now), "offline");
  assert.equal(
    readiness.nodeCreateVmAdmissionLabel(node({ scheduling_enabled: false }), now),
    "maintenance",
  );
  assert.equal(
    readiness.nodeCreateVmAdmissionLabel(node({ agent_version: null }), now),
    "not registered",
  );
  assert.equal(
    readiness.nodeCreateVmAdmissionLabel(node({ last_seen_at: null }), now),
    "no heartbeat",
  );
  assert.equal(
    readiness.nodeCreateVmAdmissionLabel(node({ last_seen_at: "2026-05-22T22:29:59Z" }), now),
    "stale heartbeat",
  );
  assert.equal(
    readiness.nodeCreateVmAdmissionLabel(node({ libvirt_status: "unavailable" }), now),
    "libvirt unavailable",
  );
  assert.equal(
    readiness.nodeCreateVmAdmissionLabel(node({ libvirt_status: "not_checked" }), now),
    "libvirt not checked",
  );
});
