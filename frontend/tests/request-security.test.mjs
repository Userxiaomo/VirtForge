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

const security = await importTypeScriptModule(new URL("../lib/request-security.ts", import.meta.url));

function mutationRequest(headers) {
  return new Request("https://panel.example.com/api/tasks/create-vm", { headers });
}

test("allows a marked same-origin panel mutation", () => {
  const request = mutationRequest({
    "Origin": "https://panel.example.com",
    "Sec-Fetch-Site": "same-origin",
    [security.panelMutationHeaderName]: security.panelMutationHeaderValue,
  });

  assert.equal(security.isAllowedPanelMutationRequest(request), true);
});

test("allows a marked HTTPS mutation behind an HTTP reverse proxy hop", () => {
  const request = new Request("http://panel.example.com/api/session", {
    headers: {
      "Origin": "https://panel.example.com",
      "Sec-Fetch-Site": "same-origin",
      "X-Forwarded-Host": "panel.example.com",
      "X-Forwarded-Proto": "https",
      [security.panelMutationHeaderName]: security.panelMutationHeaderValue,
    },
  });

  assert.equal(security.isAllowedPanelMutationRequest(request), true);
});

test("rejects a panel mutation without the panel marker header", () => {
  const request = mutationRequest({
    "Origin": "https://panel.example.com",
    "Sec-Fetch-Site": "same-origin",
  });

  assert.equal(security.isAllowedPanelMutationRequest(request), false);
});

test("rejects a cross-site origin even when the marker header is present", () => {
  const request = mutationRequest({
    "Origin": "https://evil.example",
    "Sec-Fetch-Site": "cross-site",
    [security.panelMutationHeaderName]: security.panelMutationHeaderValue,
  });

  assert.equal(security.isAllowedPanelMutationRequest(request), false);
});

test("rejects same-site browser mutations without same-origin metadata", () => {
  const request = mutationRequest({
    "Sec-Fetch-Site": "same-site",
    [security.panelMutationHeaderName]: security.panelMutationHeaderValue,
  });

  assert.equal(security.isAllowedPanelMutationRequest(request), false);
});

test("allows non-browser callers only when no cross-site metadata is present", () => {
  const request = mutationRequest({
    [security.panelMutationHeaderName]: security.panelMutationHeaderValue,
  });

  assert.equal(security.isAllowedPanelMutationRequest(request), true);
});
