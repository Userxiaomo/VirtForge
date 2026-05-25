type AuditDetailObject = Record<string, unknown>;

export function formatAuditDetail(detail: unknown): string {
  if (!isPlainObject(detail)) {
    return "no detail";
  }

  const parts = [
    stringPart("kind", detail.task_kind),
    stringPart("vm", detail.vm_id),
    stringPart("status", detail.status),
    booleanPart("error", detail.has_error),
    stringPart("source", detail.source_task_id),
    numberPart("message_bytes", detail.message_bytes),
  ].filter((part): part is string => Boolean(part));

  if (parts.length > 0) {
    return parts.join(", ");
  }

  const fallbackParts = Object.entries(detail)
    .filter(([, value]) => typeof value === "string" || typeof value === "number" || typeof value === "boolean")
    .slice(0, 4)
    .map(([key, value]) => `${key}=${String(value)}`);

  return fallbackParts.length > 0 ? fallbackParts.join(", ") : "detail available";
}

function isPlainObject(value: unknown): value is AuditDetailObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stringPart(label: string, value: unknown): string | null {
  if (typeof value !== "string" || value.length === 0) {
    return null;
  }
  return `${label}=${value}`;
}

function numberPart(label: string, value: unknown): string | null {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return null;
  }
  return `${label}=${value}`;
}

function booleanPart(label: string, value: unknown): string | null {
  if (typeof value !== "boolean") {
    return null;
  }
  return `${label}=${value ? "yes" : "no"}`;
}
