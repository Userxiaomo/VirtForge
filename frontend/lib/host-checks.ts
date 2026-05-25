import type { HostPreflightCheck } from "./api";

export function formatHostChecks(checks: HostPreflightCheck[]) {
  if (checks.length === 0) {
    return "not reported";
  }

  return checks.map(formatHostCheck).join("; ");
}

function formatHostCheck(check: HostPreflightCheck) {
  const status = check.status === "not_checked" ? "not checked" : check.status;
  const message = check.message.trim();
  const shouldShowMessage = message.length > 0 && check.status !== "available";
  return shouldShowMessage ? `${check.name}: ${status} - ${message}` : `${check.name}: ${status}`;
}
