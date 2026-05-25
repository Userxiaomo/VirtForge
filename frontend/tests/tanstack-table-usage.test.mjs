import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const controlPanelPath = fileURLToPath(new URL("../components/control-panel.tsx", import.meta.url));

test("control panel tables use TanStack Table primitives", async () => {
  const source = await readFile(controlPanelPath, "utf8");

  assert.match(source, /from "@tanstack\/react-table"/);
  assert.match(source, /\buseReactTable\b/);
  assert.match(source, /\bgetCoreRowModel\b/);
  assert.match(source, /\bflexRender\b/);
});
