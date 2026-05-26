import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const controlPanelPath = fileURLToPath(new URL("../components/control-panel.tsx", import.meta.url));

test("changing the selected install node clears the one-time install command", async () => {
  const source = await readFile(controlPanelPath, "utf8");
  const functionSource = extractFunction(source, "function selectInstallNode");

  assert.match(functionSource, /setInstall\(null\);/);
  assert.match(functionSource, /setSelectedNodeId\(nodeId\);/);
  assert.match(source, /setSelectedNodeId=\{selectInstallNode\}/);
});

test("install node picker has an explicit placeholder before selecting a node", async () => {
  const source = await readFile(controlPanelPath, "utf8");

  assert.match(source, /<option value="">\{text\.install\.selectNode\}<\/option>/);
  assert.match(source, /disabled=\{!selectedNodeId\}/);
});

test("install node picker has an accessible name", async () => {
  const source = await readFile(controlPanelPath, "utf8");

  assert.match(source, /aria-label=\{text\.install\.targetAriaLabel\}/);
});

function extractFunction(source, declaration) {
  const declarationIndex = source.indexOf(declaration);
  assert.notEqual(declarationIndex, -1, `${declaration} not found`);
  const bodyStart = source.indexOf("{", declarationIndex);
  assert.notEqual(bodyStart, -1, `${declaration} body not found`);

  let depth = 0;
  for (let index = bodyStart; index < source.length; index += 1) {
    const char = source[index];
    if (char === "{") {
      depth += 1;
      continue;
    }
    if (char === "}") {
      depth -= 1;
      if (depth === 0) {
        return source.slice(declarationIndex, index + 1);
      }
    }
  }

  assert.fail(`${declaration} body did not close`);
}
