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

const hostChecks = await importTypeScriptModule(new URL("../lib/host-checks.ts", import.meta.url));

test("formats host preflight failures with diagnostic messages", () => {
  assert.equal(
    hostChecks.formatHostChecks([
      { name: "kvm", status: "available", message: "/dev/kvm ready" },
      { name: "libvirt", status: "unavailable", message: "virsh qemu:///system failed" },
    ]),
    "kvm: available; libvirt: unavailable - virsh qemu:///system failed",
  );
});

test("omits empty host check messages and reports missing checks", () => {
  assert.equal(
    hostChecks.formatHostChecks([{ name: "cloud-init", status: "not_checked", message: "" }]),
    "cloud-init: not checked",
  );
  assert.equal(hostChecks.formatHostChecks([]), "not reported");
});
