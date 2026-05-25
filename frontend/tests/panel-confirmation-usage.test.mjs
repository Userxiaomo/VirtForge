import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const controlPanelPath = fileURLToPath(new URL("../components/control-panel.tsx", import.meta.url));

test("dangerous panel actions use the in-panel confirmation dialog", async () => {
  const source = await readFile(controlPanelPath, "utf8");

  assert.doesNotMatch(source, /\bconfirm\(/);
  assert.match(source, /const \[confirmation, setConfirmation\] = useState<ConfirmationRequest \| null>\(null\);/);
  assert.match(source, /function confirmPanelAction\(options: ConfirmationOptions\): Promise<boolean>/);
  assert.match(source, /<ConfirmationDialog[\s\S]*request=\{confirmation\}/);
  assert.match(source, /role="dialog"/);
  assert.match(source, /aria-modal="true"/);
  assert.match(source, /triggerElement: document\.activeElement instanceof HTMLElement \? document\.activeElement : null/);
  assert.match(source, /current\.triggerElement\?\.focus\(\);/);
  assert.match(source, /const cancelButtonRef = useRef<HTMLButtonElement>\(null\);/);
  assert.match(source, /cancelButtonRef\.current\?\.focus\(\);/);
  assert.match(source, /function handleDialogKeyDown\(event: KeyboardEvent<HTMLElement>\)/);
  assert.match(source, /if \(event\.key === "Escape"\)/);
  assert.match(source, /onKeyDown=\{handleDialogKeyDown\}/);
  assert.match(source, /ref=\{cancelButtonRef\}/);

  for (const functionName of [
    "toggleNodeScheduling",
    "toggleImageEnabled",
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
      /await confirmPanelAction\(\{/,
      `${functionName} should wait for the panel confirmation dialog`,
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
