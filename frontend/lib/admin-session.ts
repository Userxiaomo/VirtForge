export const adminSessionMaxAgeSeconds = 8 * 60 * 60;

export type AdminCookieOptions = {
  httpOnly: true;
  sameSite: "strict";
  secure: boolean;
  path: "/";
  maxAge: number;
};

export type AdminLoginParseResult =
  | {
      ok: true;
      username: string;
      password: string;
    }
  | {
      ok: false;
      error: string;
    };

export function adminCookieOptions(secure: boolean): AdminCookieOptions {
  return {
    httpOnly: true,
    sameSite: "strict",
    secure,
    path: "/",
    maxAge: adminSessionMaxAgeSeconds,
  };
}

export function adminCookieOptionsForEnvironment(environment: string | undefined) {
  return adminCookieOptions(environment !== "development");
}

export function clearedAdminCookieOptionsForEnvironment(environment: string | undefined) {
  return {
    ...adminCookieOptionsForEnvironment(environment),
    maxAge: 0,
  };
}

export function parseAdminLoginBody(body: unknown): AdminLoginParseResult {
  if (!isRecord(body)) {
    return missingCredentials();
  }

  const username = typeof body.username === "string" ? body.username.trim() : "";
  const password = typeof body.password === "string" ? body.password : "";
  if (!username || !password) {
    return missingCredentials();
  }
  if (!isValidAdminUsername(username)) {
    return {
      ok: false,
      error: "username contains unsupported characters",
    };
  }
  if (!isBearerCompatibleAdminSecret(password)) {
    return {
      ok: false,
      error: "password contains unsupported characters",
    };
  }

  return {
    ok: true,
    username,
    password,
  };
}

export function isBearerCompatibleAdminSecret(value: string) {
  return (
    value.length >= 1 &&
    value.length <= 256 &&
    [...value].every(
      (char) =>
        isAsciiGraphic(char) &&
        !/\s/.test(char) &&
        char !== '"' &&
        char !== "'" &&
        char !== "\\" &&
        char !== "`",
    )
  );
}

export function isValidAdminUsername(value: string) {
  return (
    value.length >= 1 &&
    value.length <= 64 &&
    [...value].every(
      (char) =>
        (char >= "A" && char <= "Z") ||
        (char >= "a" && char <= "z") ||
        (char >= "0" && char <= "9") ||
        char === "." ||
        char === "_" ||
        char === "-",
    )
  );
}

function missingCredentials(): AdminLoginParseResult {
  return {
    ok: false,
    error: "username and password are required",
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isAsciiGraphic(value: string) {
  const codePoint = value.codePointAt(0);
  return codePoint !== undefined && codePoint >= 0x21 && codePoint <= 0x7e;
}
