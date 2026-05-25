export function normalizeMasterAdminPath(value: string) {
  if (!value || containsUnsafeMasterPathCharacters(value)) {
    throw new Error("invalid master admin API path");
  }
  if (value.startsWith("//") || !value.startsWith("/api/admin/")) {
    throw new Error("invalid master admin API path");
  }
  if (value.includes("?") || value.includes("#")) {
    throw new Error("invalid master admin API path");
  }

  validatePathSegments(value);
  return value;
}

function containsUnsafeMasterPathCharacters(value: string) {
  return /[\u0000-\u001F\u007F\s'"\\`]/.test(value);
}

function validatePathSegments(value: string) {
  for (const segment of value.split("/")) {
    const normalized = segment.toLowerCase().replaceAll("%2e", ".");
    if (normalized === "." || normalized === "..") {
      throw new Error("invalid master admin API path");
    }
    if (normalized.includes("%2f") || normalized.includes("%5c")) {
      throw new Error("invalid master admin API path");
    }
  }
}
