import type { TaskStatus } from "./api";

export function canCancelTaskStatus(status: TaskStatus): boolean {
  return status === "pending" || status === "assigned";
}

export function shouldAutoRefreshTaskStatus(status: TaskStatus): boolean {
  return status === "pending" || status === "assigned" || status === "running";
}
