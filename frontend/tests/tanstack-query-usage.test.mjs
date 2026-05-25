import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const providersPath = fileURLToPath(new URL("../components/app-providers.tsx", import.meta.url));
const layoutPath = fileURLToPath(new URL("../app/layout.tsx", import.meta.url));
const controlPanelPath = fileURLToPath(new URL("../components/control-panel.tsx", import.meta.url));

test("frontend panel data is managed through TanStack Query", async () => {
  const [providers, layout, controlPanel] = await Promise.all([
    readOptionalSource(providersPath),
    readFile(layoutPath, "utf8"),
    readFile(controlPanelPath, "utf8"),
  ]);

  assert.match(providers, /from "@tanstack\/react-query"/);
  assert.match(providers, /\bQueryClientProvider\b/);
  assert.match(layout, /\bAppProviders\b/);
  assert.match(controlPanel, /from "@tanstack\/react-query"/);
  assert.match(controlPanel, /\buseQuery\b/);
  assert.match(controlPanel, /\buseMutation\b/);
  assert.match(controlPanel, /\binvalidateQueries\b/);
  assert.match(controlPanel, /\brefetchInterval\b/);
  assert.match(controlPanel, /\bshouldAutoRefreshTaskStatus\b/);
});

async function readOptionalSource(path) {
  try {
    return await readFile(path, "utf8");
  } catch (error) {
    if (error && error.code === "ENOENT") {
      return "";
    }
    throw error;
  }
}
