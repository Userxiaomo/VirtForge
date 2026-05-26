import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const controlPanelPath = fileURLToPath(new URL("../components/control-panel.tsx", import.meta.url));

test("selected failed task error message is visible with task logs", async () => {
  const source = await readFile(controlPanelPath, "utf8");

  assert.match(source, /const taskErrorMessage = selectedTask\?\.error_message \?\? "";/);
  assert.match(
    source,
    /taskErrorMessage \? <p className="error" role="alert">\{text\.tasks\.failed\(taskErrorMessage\)\}<\/p> : null/,
  );
});
