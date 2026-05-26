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

const i18n = await importTypeScriptModule(new URL("../lib/i18n.ts", import.meta.url));
const controlPanelPath = fileURLToPath(new URL("../components/control-panel.tsx", import.meta.url));

test("defaults the panel language to Simplified Chinese", () => {
  assert.equal(i18n.defaultLanguage, "zh-CN");
  assert.equal(i18n.translations["zh-CN"].login.title, "管理员登录");
  assert.equal(i18n.translations["zh-CN"].nav.dashboard, "仪表盘");
  assert.equal(i18n.translations["en-US"].login.title, "Admin Login");
});

test("reads only supported stored languages", () => {
  assert.equal(i18n.readStoredLanguage({ getItem: () => "en-US" }), "en-US");
  assert.equal(i18n.readStoredLanguage({ getItem: () => "zh-CN" }), "zh-CN");
  assert.equal(i18n.readStoredLanguage({ getItem: () => "fr-FR" }), "zh-CN");
  assert.equal(i18n.readStoredLanguage({ getItem: () => null }), "zh-CN");
});

test("control panel exposes a persistent language selector", async () => {
  const source = await readFile(controlPanelPath, "utf8");

  assert.match(source, /const \[language, setLanguage\] = useState<Language>\(\(\) => readStoredLanguage\(\)\);/);
  assert.match(source, /writeStoredLanguage\(nextLanguage\);/);
  assert.match(source, /<select[\s\S]*value=\{language\}/);
  assert.match(source, /supportedLanguages\.map\(\(option\) =>/);
  assert.match(source, /const text = translations\[language\];/);
});
