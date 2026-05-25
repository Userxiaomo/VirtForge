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

const session = await importTypeScriptModule(new URL("../lib/admin-session.ts", import.meta.url));

test("accepts username and password login payloads", () => {
  const result = session.parseAdminLoginBody({
    username: " admin ",
    password: "secret-password",
  });

  assert.deepEqual(result, {
    ok: true,
    username: "admin",
    password: "secret-password",
  });
});

test("rejects legacy token-only browser login payloads", () => {
  const result = session.parseAdminLoginBody({ token: "raw-admin-token" });

  assert.deepEqual(result, {
    ok: false,
    error: "username and password are required",
  });
});

test("rejects bearer-incompatible browser login passwords before master verification", () => {
  for (const password of [
    "bad password",
    "bad\"password",
    "bad'password",
    "bad\\password",
    "bad`password",
    "a".repeat(257),
  ]) {
    assert.deepEqual(
      session.parseAdminLoginBody({ username: "admin", password }),
      {
        ok: false,
        error: "password contains unsupported characters",
      },
      password,
    );
  }
});

test("rejects unsupported browser login usernames before master verification", () => {
  for (const username of [
    "admin ops",
    "admin/ops",
    "admin\"ops",
    "admin'ops",
    "admin\\ops",
    "admin`ops",
    "管理员",
    "a".repeat(65),
  ]) {
    assert.deepEqual(
      session.parseAdminLoginBody({ username, password: "secret-password" }),
      {
        ok: false,
        error: "username contains unsupported characters",
      },
      username,
    );
  }
});

test("uses a finite HttpOnly admin cookie lifetime", () => {
  assert.equal(session.adminSessionMaxAgeSeconds, 8 * 60 * 60);
  assert.deepEqual(session.adminCookieOptions(false), {
    httpOnly: true,
    sameSite: "strict",
    secure: false,
    path: "/",
    maxAge: 8 * 60 * 60,
  });
});

test("uses Secure admin cookies outside explicit development mode", () => {
  assert.equal(session.adminCookieOptionsForEnvironment("development").secure, false);
  assert.equal(session.adminCookieOptionsForEnvironment("production").secure, true);
  assert.equal(session.adminCookieOptionsForEnvironment("staging").secure, true);
  assert.equal(session.adminCookieOptionsForEnvironment(undefined).secure, true);
});

test("validates admin cookie secrets before bearer forwarding", () => {
  assert.equal(session.isBearerCompatibleAdminSecret("adm_SAFE-token.1:/+="), true);

  for (const value of [
    "",
    "bad token",
    "bad\"token",
    "bad'token",
    "bad\\token",
    "bad`token",
    "a".repeat(257),
  ]) {
    assert.equal(session.isBearerCompatibleAdminSecret(value), false, value);
  }
});
