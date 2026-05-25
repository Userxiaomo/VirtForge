const defaultMasterApiBaseUrl = "http://127.0.0.1:8080";

export function normalizeMasterApiBaseUrl(value?: string) {
  const configured = value ?? defaultMasterApiBaseUrl;

  if (!configured.trim()) {
    throw new Error("MASTER_API_BASE_URL must not be empty");
  }
  if (containsUnsafeBaseUrlCharacters(configured)) {
    throw new Error("MASTER_API_BASE_URL contains unsupported characters");
  }

  let parsed: URL;
  try {
    parsed = new URL(configured);
  } catch {
    throw new Error("MASTER_API_BASE_URL must be a valid URL");
  }

  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new Error("MASTER_API_BASE_URL must use http:// or https://");
  }
  if (!parsed.hostname) {
    throw new Error("MASTER_API_BASE_URL must include a host");
  }
  if (parsed.username || parsed.password) {
    throw new Error("MASTER_API_BASE_URL must not include username or password");
  }
  validateMasterApiBaseUrlPort(parsed);
  if (parsed.pathname !== "/") {
    throw new Error("MASTER_API_BASE_URL must not include a path");
  }
  if (parsed.search || parsed.hash) {
    throw new Error("MASTER_API_BASE_URL must not include query strings or fragments");
  }
  if (parsed.protocol === "http:" && !isAllowedHttpMasterHost(parsed.hostname)) {
    throw new Error(
      "MASTER_API_BASE_URL http:// is allowed only for loopback, private IP, or single-label internal hosts",
    );
  }

  return parsed.origin;
}

function containsUnsafeBaseUrlCharacters(value: string) {
  return /[\u0000-\u001F\u007F\s'"\\`]/.test(value);
}

function validateMasterApiBaseUrlPort(parsed: URL) {
  if (!parsed.port) {
    return;
  }

  const port = Number(parsed.port);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error("MASTER_API_BASE_URL port must be between 1 and 65535");
  }
}

function isAllowedHttpMasterHost(hostname: string) {
  const host = hostname.toLowerCase().replace(/^\[(.*)\]$/, "$1");
  if (host === "localhost" || host === "::1") {
    return true;
  }
  if (!host.includes(".")) {
    return true;
  }

  const octets = host.split(".");
  if (octets.length !== 4) {
    return false;
  }

  const parts = octets.map((part) => Number(part));
  if (parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) {
    return false;
  }

  const [first, second] = parts;
  return (
    first === 10 ||
    first === 127 ||
    (first === 172 && second >= 16 && second <= 31) ||
    (first === 192 && second === 168)
  );
}
