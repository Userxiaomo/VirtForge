import { cookies } from "next/headers";
import { NextResponse } from "next/server";
import {
  adminCookieOptionsForEnvironment,
  clearedAdminCookieOptionsForEnvironment,
  isBearerCompatibleAdminSecret,
} from "./admin-session";
import { masterFetchFailureResponse } from "./master-fetch-failure";
import { normalizeMasterAdminPath } from "./master-path";
import { withMasterFetchTimeout } from "./master-timeout";
import { normalizeMasterApiBaseUrl } from "./master-url";
import { applyNoStoreHeaders } from "./response-cache";
import { isAllowedPanelMutationRequest } from "./request-security";

export type TaskStatus = "pending" | "assigned" | "running" | "succeeded" | "failed" | "canceled";

export type NodeSummary = {
  id: string;
  name: string;
  status: string;
  scheduling_enabled: boolean;
  agent_version?: string | null;
  last_seen_at?: string | null;
  libvirt_status: string;
  host_checks: HostPreflightCheck[];
  cpu_total: number;
  cpu_used: number;
  memory_total: number;
  memory_used: number;
  disk_total: number;
  disk_used: number;
  committed_cpu: number;
  committed_memory_mb: number;
  committed_disk_gb: number;
  vm_count: number;
  created_at: string;
};

export type HostPreflightCheck = {
  name: string;
  status: string;
  message: string;
};

export type AuditLogDto = {
  id: number;
  request_id?: string | null;
  actor_id: string;
  actor_role: string;
  node_id?: string | null;
  task_id?: string | null;
  action: string;
  result: string;
  detail: unknown;
  created_at: string;
};

export type UpdateNodeSchedulingRequest = {
  enabled: boolean;
};

export type VmStatus = "provisioning" | "running" | "stopped" | "deleting" | "deleted" | "error";

export type CreateVmRequest = {
  node_id: string;
  vm_id?: string | null;
  ip_pool_id?: string | null;
  plan_id?: string | null;
  assigned_ip?: string | null;
  assigned_ip_prefix?: number | null;
  assigned_gateway_ip?: string | null;
  name: string;
  image: string;
  ssh_public_key?: string | null;
  cpu_cores: number;
  memory_mb: number;
  disk_gb: number;
};

export type VmActionTaskRequest = {
  node_id: string;
  vm_id: string;
};

export type ReinstallVmTaskRequest = VmActionTaskRequest & {
  image?: string | null;
};

export type TaskDto = {
  id: string;
  node_id: string;
  kind:
    | ({ type: "create_vm" } & Partial<CreateVmRequest>)
    | ({ type: "start_vm" } & VmActionTaskRequest)
    | ({ type: "stop_vm" } & VmActionTaskRequest)
    | ({ type: "reboot_vm" } & VmActionTaskRequest)
    | ({ type: "reinstall_vm"; name: string; image: string; ssh_public_key?: string | null; disk_gb: number } & VmActionTaskRequest)
    | ({ type: "delete_vm" } & VmActionTaskRequest);
  status: TaskStatus;
  error_message?: string | null;
  created_at: string;
  updated_at: string;
};

export type TaskLogDto = {
  id: number;
  task_id: string;
  node_id: string;
  message: string;
  created_at: string;
};

export type VmDto = {
  id: string;
  node_id: string;
  ip_pool_id?: string | null;
  plan_id?: string | null;
  assigned_ip?: string | null;
  name: string;
  image: string;
  ssh_public_key?: string | null;
  cpu_cores: number;
  memory_mb: number;
  disk_gb: number;
  status: VmStatus;
  last_task_id?: string | null;
  last_task_status?: TaskStatus | null;
  created_at: string;
  updated_at: string;
  deleted_at?: string | null;
};

export type IpPoolDto = {
  id: string;
  name: string;
  cidr: string;
  gateway_ip: string;
  allocated_count: number;
  created_at: string;
  updated_at: string;
};

export type CreateIpPoolRequest = {
  name: string;
  cidr: string;
  gateway_ip: string;
};

export type ImageDto = {
  id: string;
  name: string;
  file_name: string;
  enabled: boolean;
  created_at: string;
  updated_at: string;
};

export type CreateImageRequest = {
  name: string;
  file_name: string;
  enabled: boolean;
};

export type UpdateImageEnabledRequest = {
  enabled: boolean;
};

export type CreatePlanRequest = {
  name: string;
  slug: string;
  cpu_cores: number;
  memory_mb: number;
  disk_gb: number;
  enabled: boolean;
};

export type UpdatePlanEnabledRequest = {
  enabled: boolean;
};

export type PlanDto = {
  id: string;
  name: string;
  slug: string;
  cpu_cores: number;
  memory_mb: number;
  disk_gb: number;
  enabled: boolean;
  created_at: string;
  updated_at: string;
};

export type BootstrapTokenResponse = {
  node_id: string;
  expires_at: string;
  bootstrap_token: string;
  install_command: string;
};

const adminCookieName = "vps_admin_token";

export function masterBaseUrl() {
  return normalizeMasterApiBaseUrl(process.env.MASTER_API_BASE_URL);
}

export async function adminTokenFromCookie() {
  const cookieStore = await cookies();
  return cookieStore.get(adminCookieName)?.value;
}

export function setAdminCookie(response: NextResponse, token: string) {
  response.cookies.set(
    adminCookieName,
    token,
    adminCookieOptionsForEnvironment(process.env.NODE_ENV),
  );
}

export function clearAdminCookie(response: NextResponse) {
  response.cookies.set(
    adminCookieName,
    "",
    clearedAdminCookieOptionsForEnvironment(process.env.NODE_ENV),
  );
}

function noStoreJsonResponse(body: unknown, init?: ResponseInit) {
  const response = NextResponse.json(body, init);
  applyNoStoreHeaders(response.headers);
  return response;
}

export async function masterFetch(path: string, init: RequestInit = {}) {
  let masterPath: string;
  try {
    masterPath = normalizeMasterAdminPath(path);
  } catch {
    return noStoreJsonResponse({ error: "invalid master admin API path" }, { status: 500 });
  }

  const token = await adminTokenFromCookie();
  if (!token || !isBearerCompatibleAdminSecret(token)) {
    return noStoreJsonResponse({ error: "unauthorized" }, { status: 401 });
  }

  const headers = new Headers(init.headers);
  headers.set("Authorization", `Bearer ${token}`);
  if (init.body && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }

  let response: Response;
  try {
    response = await fetch(
      `${masterBaseUrl()}${masterPath}`,
      withMasterFetchTimeout({
        ...init,
        headers,
        cache: "no-store",
      }),
    );
  } catch (error) {
    const failure = masterFetchFailureResponse(error);
    return noStoreJsonResponse(failure.body, { status: failure.status });
  }
  const text = await response.text();
  const responseHeaders = new Headers({
    "Content-Type": response.headers.get("Content-Type") ?? "application/json",
  });
  applyNoStoreHeaders(responseHeaders);
  const requestId = response.headers.get("X-Request-Id");
  if (requestId) {
    responseHeaders.set("X-Request-Id", requestId);
  }

  return new NextResponse(text, {
    status: response.status,
    headers: responseHeaders,
  });
}

export function requirePanelMutationRequest(request: Pick<Request, "headers" | "url">) {
  if (isAllowedPanelMutationRequest(request)) {
    return null;
  }

  return noStoreJsonResponse({ error: "invalid same-origin mutation request" }, { status: 403 });
}

export async function masterMutationFetch(
  request: Request,
  path: string,
  init: RequestInit = {},
) {
  const forbidden = requirePanelMutationRequest(request);
  if (forbidden) {
    return forbidden;
  }

  const method = init.method ?? request.method;
  const forwarded: RequestInit = { ...init, method };
  if (forwarded.body === undefined && method !== "GET" && method !== "HEAD") {
    const body = await request.text();
    if (body) {
      forwarded.body = body;
    }
  }

  return masterFetch(path, forwarded);
}
