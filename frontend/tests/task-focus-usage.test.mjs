import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const controlPanelPath = fileURLToPath(new URL("../components/control-panel.tsx", import.meta.url));

test("queued VM task responses are selected for log viewing", async () => {
  const source = await readFile(controlPanelPath, "utf8");

  assert.match(source, /async function focusQueuedTask\(task: TaskDto\)/);
  assert.match(source, /const task = await api<TaskDto>\("\/api\/tasks\/create-vm"/);
  assert.match(source, /const task = await api<TaskDto>\(`\/api\/tasks\/\$\{action\}`/);
  assert.match(source, /const retried = await api<TaskDto>\(`\/api\/tasks\/\$\{task\.id\}\/retry`/);
  assert.equal((source.match(/await focusQueuedTask\(/g) ?? []).length, 3);
});
