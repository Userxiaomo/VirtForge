import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const controlPanelPath = fileURLToPath(new URL("../components/control-panel.tsx", import.meta.url));

test("authenticated panel actions surface request errors in a visible alert", async () => {
  const source = await readFile(controlPanelPath, "utf8");

  assert.match(source, /const \[actionMessage, setActionMessage\] = useState\(""\);/);
  assert.match(source, /async function runPanelAction\(operation: \(\) => Promise<void>\)/);
  assert.match(
    source,
    /setActionMessage\(""\);[\s\S]*try \{[\s\S]*await operation\(\);[\s\S]*\} catch \(error\) \{[\s\S]*setActionMessage\(errorMessage\(error\)\);/,
  );
  assert.match(source, /<p className="error" role="alert">\{actionMessage\}<\/p>/);

  for (const functionName of [
    "logout",
    "createNode",
    "toggleNodeScheduling",
    "createIpPool",
    "createImage",
    "toggleImageEnabled",
    "createPlan",
    "togglePlanEnabled",
    "generateInstall",
    "createVm",
    "createVmAction",
    "cancelTask",
    "retryTask",
  ]) {
    const functionSource = extractFunction(source, `async function ${functionName}`);
    assert.match(
      functionSource,
      /await runPanelAction\(async \(\) => \{/,
      `${functionName} should report failures through runPanelAction`,
    );
  }
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
