import type { NodeSummary } from "./api";

const createVmNodeHeartbeatStaleAfterMs = 2 * 60 * 60 * 1000;

export function isCreateVmNodeSelectable(node: NodeSummary, now = new Date()) {
  return (
    node.status === "online" &&
    node.scheduling_enabled &&
    Boolean(node.agent_version) &&
    Boolean(node.last_seen_at) &&
    !isHeartbeatStale(node.last_seen_at, now) &&
    node.libvirt_status !== "unavailable"
  );
}

export function nodeCreateVmAdmissionLabel(node: NodeSummary, now = new Date()) {
  if (!node.scheduling_enabled) return "maintenance";
  if (node.status !== "online") return "offline";
  if (!node.agent_version) return "not registered";
  if (!node.last_seen_at) return "no heartbeat";
  if (isHeartbeatStale(node.last_seen_at, now)) return "stale heartbeat";
  if (node.libvirt_status === "unavailable") return "libvirt unavailable";
  if (node.libvirt_status === "not_checked") return "libvirt not checked";
  return "ready";
}

function isHeartbeatStale(lastSeenAt: string | null | undefined, now: Date) {
  if (!lastSeenAt) return true;
  const lastSeenMs = Date.parse(lastSeenAt);
  if (!Number.isFinite(lastSeenMs)) return true;
  return now.getTime() - lastSeenMs > createVmNodeHeartbeatStaleAfterMs;
}
