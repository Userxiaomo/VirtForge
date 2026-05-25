"use client";

import {
  Activity,
  Ban,
  Boxes,
  Clipboard,
  ClipboardPlus,
  ImageIcon,
  ListChecks,
  LogOut,
  Play,
  Power,
  RefreshCcw,
  Server,
  ShieldCheck,
  Trash2,
  type LucideIcon,
} from "lucide-react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { createColumnHelper, flexRender, getCoreRowModel, useReactTable } from "@tanstack/react-table";
import { type FormEvent, type KeyboardEvent, useCallback, useEffect, useMemo, useRef, useState } from "react";
import type {
  AuditLogDto,
  BootstrapTokenResponse,
  CreateImageRequest,
  CreateIpPoolRequest,
  CreatePlanRequest,
  CreateVmRequest,
  ImageDto,
  IpPoolDto,
  NodeSummary,
  PlanDto,
  TaskDto,
  TaskLogDto,
  UpdateImageEnabledRequest,
  UpdateNodeSchedulingRequest,
  UpdatePlanEnabledRequest,
  VmDto,
} from "../lib/api";
import { formatAuditDetail } from "../lib/audit-detail";
import { formatHostChecks } from "../lib/host-checks";
import { isCreateVmNodeSelectable, nodeCreateVmAdmissionLabel } from "../lib/node-readiness";
import { panelMutationHeaderName, panelMutationHeaderValue } from "../lib/request-security";
import { canCancelTaskStatus, shouldAutoRefreshTaskStatus } from "../lib/task-actions";
import { availableVmActions, type VmAction, vmActionConfirmationMessage } from "../lib/vm-actions";

type View =
  | "dashboard"
  | "nodes"
  | "plans"
  | "images"
  | "ipPools"
  | "install"
  | "tasks"
  | "audit"
  | "createVm"
  | "vms";

const navItems: Array<{ id: View; label: string }> = [
  { id: "dashboard", label: "Dashboard" },
  { id: "nodes", label: "Nodes" },
  { id: "plans", label: "Plans" },
  { id: "images", label: "Images" },
  { id: "ipPools", label: "IP Pools" },
  { id: "install", label: "Install Agent" },
  { id: "tasks", label: "Tasks" },
  { id: "audit", label: "Audit" },
  { id: "createVm", label: "Create VM" },
  { id: "vms", label: "VMs" },
];

const vmActionConfig = {
  "start-vm": { label: "Start", icon: Play },
  "stop-vm": { label: "Stop", icon: Power },
  "reboot-vm": { label: "Reboot", icon: RefreshCcw },
  "reinstall-vm": { label: "Reinstall", icon: RefreshCcw },
  "delete-vm": { label: "Delete", icon: Trash2 },
} satisfies Record<VmAction, { label: string; icon: LucideIcon }>;

type PanelApi = <T>(path: string, init?: RequestInit) => Promise<T>;

type PanelData = {
  nodes: NodeSummary[];
  plans: PlanDto[];
  images: ImageDto[];
  ipPools: IpPoolDto[];
  tasks: TaskDto[];
  auditLogs: AuditLogDto[];
  vms: VmDto[];
};

type ConfirmationOptions = {
  title: string;
  message: string;
  confirmLabel: string;
  danger?: boolean;
};

type ConfirmationRequest = ConfirmationOptions & {
  resolve: (confirmed: boolean) => void;
  triggerElement: HTMLElement | null;
};

const emptyPanelData: PanelData = {
  auditLogs: [],
  images: [],
  ipPools: [],
  nodes: [],
  plans: [],
  tasks: [],
  vms: [],
};

const panelDataQueryKey = ["control-panel"] as const;
const taskLogsBaseQueryKey = ["task-logs"] as const;
const taskLogsQueryKey = (taskId: string) => [...taskLogsBaseQueryKey, taskId] as const;
const activeTaskRefreshIntervalMs = 3_000;
const activeTaskLogRefreshIntervalMs = 2_000;

const nodeColumnHelper = createColumnHelper<NodeSummary>();
const nodeColumns = [
  nodeColumnHelper.accessor("name", {
    cell: (info) => info.getValue(),
  }),
  nodeColumnHelper.accessor("status", {
    cell: (info) => info.getValue(),
  }),
  nodeColumnHelper.accessor((node) => (node.scheduling_enabled ? "scheduling" : "maintenance"), {
    id: "scheduling",
    cell: (info) => info.getValue(),
  }),
  nodeColumnHelper.display({
    id: "capacity",
    cell: ({ row }) => formatNodeCapacitySummary(row.original),
  }),
  nodeColumnHelper.accessor("libvirt_status", {
    cell: (info) => info.getValue(),
  }),
];

const taskColumnHelper = createColumnHelper<TaskDto>();
const taskColumns = [
  taskColumnHelper.accessor((task) => task.kind.type, {
    id: "kind",
    cell: (info) => info.getValue(),
  }),
  taskColumnHelper.accessor("status", {
    cell: (info) => info.getValue(),
  }),
  taskColumnHelper.display({
    id: "detail",
    cell: ({ row }) => row.original.error_message ?? new Date(row.original.created_at).toLocaleString(),
  }),
];

export function ControlPanel() {
  const queryClient = useQueryClient();
  const [view, setView] = useState<View>("dashboard");
  const [username, setUsername] = useState("admin");
  const [password, setPassword] = useState("");
  const [authenticated, setAuthenticated] = useState(false);
  const [selectedTaskId, setSelectedTaskId] = useState("");
  const [selectedNodeId, setSelectedNodeId] = useState("");
  const [install, setInstall] = useState<BootstrapTokenResponse | null>(null);
  const [message, setMessage] = useState("");
  const [actionMessage, setActionMessage] = useState("");
  const [confirmation, setConfirmation] = useState<ConfirmationRequest | null>(null);
  const [loading, setLoading] = useState(false);

  const api = useCallback(async <T,>(path: string, init?: RequestInit): Promise<T> => {
    const method = init?.method?.toUpperCase() ?? "GET";
    const headers = new Headers(init?.headers);
    if (init?.body && !headers.has("Content-Type")) {
      headers.set("Content-Type", "application/json");
    }
    if (method !== "GET" && method !== "HEAD") {
      headers.set(panelMutationHeaderName, panelMutationHeaderValue);
    }

    const response = await fetch(path, {
      ...init,
      headers,
    });
    if (!response.ok) {
      const body = (await response.json().catch(() => ({ error: response.statusText }))) as {
        error?: string;
      };
      throw new Error(body.error ?? response.statusText);
    }
    return (await response.json()) as T;
  }, []);

  const panelQuery = useQuery({
    queryKey: panelDataQueryKey,
    queryFn: () => loadPanelData(api),
    refetchInterval: (query) =>
      query.state.data?.tasks.some((task) => shouldAutoRefreshTaskStatus(task.status))
        ? activeTaskRefreshIntervalMs
        : false,
  });
  const panelData = panelQuery.data ?? emptyPanelData;
  const { auditLogs, images, ipPools, nodes, plans, tasks, vms } = panelData;
  const selectedTask = tasks.find((task) => task.id === selectedTaskId);

  const taskLogsQuery = useQuery({
    enabled: authenticated && selectedTaskId.length > 0,
    queryKey: taskLogsQueryKey(selectedTaskId),
    queryFn: () => api<TaskLogDto[]>(`/api/tasks/${selectedTaskId}/logs`),
    refetchInterval: selectedTask && shouldAutoRefreshTaskStatus(selectedTask.status)
      ? activeTaskLogRefreshIntervalMs
      : false,
  });
  const taskLogs = selectedTaskId ? taskLogsQuery.data ?? [] : [];
  const taskLogMessage = selectedTaskId && taskLogsQuery.error ? errorMessage(taskLogsQuery.error) : "";

  const invalidatePanelData = useCallback(
    async () => {
      await queryClient.invalidateQueries({ queryKey: panelDataQueryKey });
    },
    [queryClient],
  );

  const panelMutation = useMutation<void, Error, () => Promise<void>>({
    mutationFn: (operation) => operation(),
    onSuccess: invalidatePanelData,
  });

  const runPanelMutation = (operation: () => Promise<void>) => panelMutation.mutateAsync(operation);

  async function runPanelAction(operation: () => Promise<void>) {
    setActionMessage("");
    try {
      await operation();
    } catch (error) {
      setActionMessage(errorMessage(error));
    }
  }

  function confirmPanelAction(options: ConfirmationOptions): Promise<boolean> {
    return new Promise((resolve) => {
      setConfirmation({
        ...options,
        resolve,
        triggerElement: document.activeElement instanceof HTMLElement ? document.activeElement : null,
      });
    });
  }

  function resolveConfirmation(confirmed: boolean) {
    if (!confirmation) {
      return;
    }
    const current = confirmation;
    setConfirmation(null);
    current.resolve(confirmed);
    current.triggerElement?.focus();
  }

  const runningVms = useMemo(() => vms.filter((vm) => vm.status === "running"), [vms]);
  const pendingTasks = useMemo(
    () => tasks.filter((task) => shouldAutoRefreshTaskStatus(task.status)).length,
    [tasks],
  );

  const loadTaskLogs = useCallback(
    async (taskId: string) => {
      setSelectedTaskId(taskId);
      await queryClient.invalidateQueries({ queryKey: taskLogsQueryKey(taskId) });
    },
    [queryClient],
  );

  function selectInstallNode(nodeId: string) {
    setInstall(null);
    setSelectedNodeId(nodeId);
  }

  async function focusQueuedTask(task: TaskDto) {
    await invalidatePanelData();
    await loadTaskLogs(task.id);
    setView("tasks");
  }

  async function login(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setLoading(true);
    setMessage("");
    try {
      await api<{ ok: boolean }>("/api/session", {
        method: "POST",
        body: JSON.stringify({ username, password }),
      });
      setPassword("");
      setAuthenticated(true);
      await invalidatePanelData();
    } catch (error) {
      setMessage(error instanceof Error ? error.message : "login failed");
    } finally {
      setLoading(false);
    }
  }

  async function logout() {
    await runPanelAction(async () => {
      await api<{ ok: boolean }>("/api/session", { method: "DELETE" });
      setAuthenticated(false);
      setSelectedTaskId("");
      setInstall(null);
      queryClient.removeQueries({ queryKey: panelDataQueryKey });
      queryClient.removeQueries({ queryKey: taskLogsBaseQueryKey });
    });
  }

  async function createNode(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formElement = event.currentTarget;
    const form = new FormData(formElement);
    const name = String(form.get("name") ?? "").trim();
    if (!name) return;

    await runPanelAction(async () => {
      await runPanelMutation(async () => {
        await api<NodeSummary>("/api/nodes", {
          method: "POST",
          body: JSON.stringify({ name }),
        });
      });
      formElement.reset();
    });
  }

  async function toggleNodeScheduling(node: NodeSummary) {
    const nextEnabled = !node.scheduling_enabled;
    const label = nextEnabled ? "Enable Scheduling" : "Disable Scheduling";
    const confirmed = await confirmPanelAction({
      confirmLabel: label,
      danger: true,
      message: nextEnabled
        ? `${node.name} will accept newly assigned VM tasks after this change.`
        : `${node.name} will stop receiving new VM tasks. Already assigned work is unchanged.`,
      title: label,
    });
    if (!confirmed) {
      return;
    }

    const request: UpdateNodeSchedulingRequest = { enabled: nextEnabled };
    await runPanelAction(async () => {
      await runPanelMutation(async () => {
        await api<NodeSummary>(`/api/nodes/${node.id}/scheduling`, {
          method: "POST",
          body: JSON.stringify(request),
        });
      });
    });
  }

  async function createIpPool(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formElement = event.currentTarget;
    const form = new FormData(formElement);
    const request: CreateIpPoolRequest = {
      name: String(form.get("name") ?? "").trim(),
      cidr: String(form.get("cidr") ?? "").trim(),
      gateway_ip: String(form.get("gateway_ip") ?? "").trim(),
    };
    if (!request.name || !request.cidr || !request.gateway_ip) return;

    await runPanelAction(async () => {
      await runPanelMutation(async () => {
        await api<IpPoolDto>("/api/ip-pools", {
          method: "POST",
          body: JSON.stringify(request),
        });
      });
      formElement.reset();
    });
  }

  async function createImage(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formElement = event.currentTarget;
    const form = new FormData(formElement);
    const request: CreateImageRequest = {
      name: String(form.get("name") ?? "").trim(),
      file_name: String(form.get("file_name") ?? "").trim(),
      enabled: form.get("enabled") === "on",
    };
    if (!request.name || !request.file_name) return;

    await runPanelAction(async () => {
      await runPanelMutation(async () => {
        await api<ImageDto>("/api/images", {
          method: "POST",
          body: JSON.stringify(request),
        });
      });
      formElement.reset();
    });
  }

  async function toggleImageEnabled(image: ImageDto) {
    const nextEnabled = !image.enabled;
    const confirmed = await confirmPanelAction({
      confirmLabel: nextEnabled ? "Enable" : "Disable",
      danger: !nextEnabled,
      message: `${image.name} will ${nextEnabled ? "be available for new VM tasks" : "stop being available for future create or reinstall tasks"}.`,
      title: `${nextEnabled ? "Enable" : "Disable"} Image`,
    });
    if (!confirmed) {
      return;
    }

    const request: UpdateImageEnabledRequest = { enabled: nextEnabled };
    await runPanelAction(async () => {
      await runPanelMutation(async () => {
        await api<ImageDto>(`/api/images/${image.id}/enabled`, {
          method: "POST",
          body: JSON.stringify(request),
        });
      });
    });
  }

  async function createPlan(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formElement = event.currentTarget;
    const form = new FormData(formElement);
    const request: CreatePlanRequest = {
      name: String(form.get("name") ?? "").trim(),
      slug: String(form.get("slug") ?? "").trim(),
      cpu_cores: Number(form.get("cpu_cores")),
      memory_mb: Number(form.get("memory_mb")),
      disk_gb: Number(form.get("disk_gb")),
      enabled: form.get("enabled") === "on",
    };
    if (!request.name || !request.slug) return;

    await runPanelAction(async () => {
      await runPanelMutation(async () => {
        await api<PlanDto>("/api/plans", {
          method: "POST",
          body: JSON.stringify(request),
        });
      });
      formElement.reset();
    });
  }

  async function togglePlanEnabled(plan: PlanDto) {
    const nextEnabled = !plan.enabled;
    const confirmed = await confirmPanelAction({
      confirmLabel: nextEnabled ? "Enable" : "Disable",
      danger: !nextEnabled,
      message: `${plan.name} will ${nextEnabled ? "be available for new VM tasks" : "stop being available for future VM tasks"}.`,
      title: `${nextEnabled ? "Enable" : "Disable"} Plan`,
    });
    if (!confirmed) {
      return;
    }

    const request: UpdatePlanEnabledRequest = { enabled: nextEnabled };
    await runPanelAction(async () => {
      await runPanelMutation(async () => {
        await api<PlanDto>(`/api/plans/${plan.id}/enabled`, {
          method: "POST",
          body: JSON.stringify(request),
        });
      });
    });
  }

  async function generateInstall(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!selectedNodeId) return;
    const selectedNode = nodes.find((node) => node.id === selectedNodeId);
    const confirmed = await confirmPanelAction({
      confirmLabel: "Generate",
      danger: true,
      message: `Generate a one-time bootstrap token for ${selectedNode?.name ?? selectedNodeId}? It will be shown in the install command and expires in 1 hour.`,
      title: "Generate Install Command",
    });
    if (!confirmed) {
      return;
    }

    const expires = new Date(Date.now() + 60 * 60 * 1000).toISOString();
    await runPanelAction(async () => {
      const response = await api<BootstrapTokenResponse>(
        `/api/nodes/${selectedNodeId}/bootstrap-tokens`,
        {
          method: "POST",
          body: JSON.stringify({ expires_at: expires }),
        },
      );
      setInstall(response);
    });
  }

  async function createVm(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const formElement = event.currentTarget;
    const form = new FormData(formElement);
    const vm: CreateVmRequest = {
      node_id: String(form.get("node_id")),
      ip_pool_id: optionalFormValue(form, "ip_pool_id"),
      plan_id: optionalFormValue(form, "plan_id"),
      name: String(form.get("name")),
      image: String(form.get("image")),
      ssh_public_key: optionalFormValue(form, "ssh_public_key"),
      cpu_cores: Number(form.get("cpu_cores")),
      memory_mb: Number(form.get("memory_mb")),
      disk_gb: Number(form.get("disk_gb")),
    };
    const selectedNode = nodes.find((node) => node.id === vm.node_id);
    const confirmed = await confirmPanelAction({
      confirmLabel: "Create VM",
      message: `Queue create_vm for ${vm.name} on ${selectedNode?.name ?? vm.node_id} with ${vm.cpu_cores} CPU, ${vm.memory_mb} MB memory, and ${vm.disk_gb} GB disk.`,
      title: "Create VM",
    });
    if (!confirmed) {
      return;
    }

    await runPanelAction(async () => {
      const task = await api<TaskDto>("/api/tasks/create-vm", {
        method: "POST",
        body: JSON.stringify({ vm }),
      });
      await focusQueuedTask(task);
      formElement.reset();
    });
  }

  async function createVmAction(action: VmAction, vm: VmDto) {
    const { label } = vmActionConfig[action];
    const confirmed = await confirmPanelAction({
      confirmLabel: label,
      danger: action !== "start-vm",
      message: vmActionConfirmationMessage(action, vm),
      title: `${label} VM`,
    });
    if (!confirmed) {
      return;
    }

    await runPanelAction(async () => {
      const task = await api<TaskDto>(`/api/tasks/${action}`, {
        method: "POST",
        body: JSON.stringify({ node_id: vm.node_id, vm_id: vm.id }),
      });
      await focusQueuedTask(task);
    });
  }

  async function cancelTask(task: TaskDto) {
    const confirmed = await confirmPanelAction({
      confirmLabel: "Cancel Task",
      danger: true,
      message: `Cancel ${task.kind.type} task? This only applies before host work starts.`,
      title: "Cancel Task",
    });
    if (!confirmed) {
      return;
    }

    await runPanelAction(async () => {
      await runPanelMutation(async () => {
        await api<TaskDto>(`/api/tasks/${task.id}/cancel`, {
          method: "POST",
        });
      });
      await loadTaskLogs(task.id);
    });
  }

  async function retryTask(task: TaskDto) {
    const confirmed = await confirmPanelAction({
      confirmLabel: "Retry Task",
      message: `Retry ${task.kind.type} task? This queues a new task from the terminal task payload.`,
      title: "Retry Task",
    });
    if (!confirmed) {
      return;
    }

    await runPanelAction(async () => {
      const retried = await api<TaskDto>(`/api/tasks/${task.id}/retry`, {
        method: "POST",
      });
      await focusQueuedTask(retried);
    });
  }

  useEffect(() => {
    if (panelQuery.isSuccess) {
      setAuthenticated(true);
    }
  }, [panelQuery.isSuccess]);

  useEffect(() => {
    if (panelQuery.isError && isUnauthorizedError(panelQuery.error)) {
      setAuthenticated(false);
    }
  }, [panelQuery.error, panelQuery.isError]);

  useEffect(() => {
    if (!selectedNodeId && nodes[0]) {
      setSelectedNodeId(nodes[0].id);
      return;
    }
    if (selectedNodeId && nodes.length > 0 && !nodes.some((node) => node.id === selectedNodeId)) {
      setSelectedNodeId(nodes[0].id);
    }
  }, [nodes, selectedNodeId]);

  if (!authenticated) {
    return (
      <main className="login-shell">
        <form className="login-panel" onSubmit={login}>
          <div className="brand dark">
            <ShieldCheck aria-hidden="true" />
            <span>VPS Master</span>
          </div>
          <h1>Admin Login</h1>
          <label>
            Username
            <input
              autoComplete="username"
              onChange={(event) => setUsername(event.target.value)}
              type="text"
              value={username}
            />
          </label>
          <label>
            Password
            <input
              autoComplete="current-password"
              onChange={(event) => setPassword(event.target.value)}
              type="password"
              value={password}
            />
          </label>
          <button className="primary" disabled={loading} type="submit">
            <ShieldCheck aria-hidden="true" />
            Sign in
          </button>
          {message ? <p className="error">{message}</p> : null}
        </form>
      </main>
    );
  }

  return (
    <main className="shell">
      <aside className="sidebar">
        <div className="brand">
          <Activity aria-hidden="true" />
          <span>VPS Master</span>
        </div>
        <nav aria-label="Primary">
          {navItems.map((item) => (
            <button
              className={item.id === view ? "active" : ""}
              key={item.id}
              onClick={() => setView(item.id)}
              type="button"
            >
              {item.label}
            </button>
          ))}
        </nav>
        <button className="ghost logout" onClick={logout} type="button">
          <LogOut aria-hidden="true" />
          Sign out
        </button>
      </aside>

      <section className="content">
        <header className="topbar">
          <div>
            <p className="eyebrow">MVP Operations</p>
            <h1>{titleFor(view)}</h1>
          </div>
          <button className="primary" onClick={() => setView("install")} type="button">
            <ClipboardPlus aria-hidden="true" />
            Generate Agent Command
          </button>
        </header>

        {actionMessage ? <p className="error" role="alert">{actionMessage}</p> : null}

        {view === "dashboard" ? (
          <Dashboard
            nodes={nodes}
            pendingTasks={pendingTasks}
            runningVms={runningVms.length}
            tasks={tasks}
            vms={vms}
          />
        ) : null}
        {view === "nodes" ? (
          <Nodes nodes={nodes} onCreate={createNode} onToggleScheduling={toggleNodeScheduling} />
        ) : null}
        {view === "plans" ? <Plans plans={plans} onCreate={createPlan} onToggleEnabled={togglePlanEnabled} /> : null}
        {view === "images" ? (
          <Images images={images} onCreate={createImage} onToggleEnabled={toggleImageEnabled} />
        ) : null}
        {view === "ipPools" ? <IpPools ipPools={ipPools} onCreate={createIpPool} /> : null}
        {view === "install" ? (
          <InstallAgent
            install={install}
            nodes={nodes}
            onGenerate={generateInstall}
            selectedNodeId={selectedNodeId}
            setSelectedNodeId={selectInstallNode}
          />
        ) : null}
        {view === "tasks" ? (
          <Tasks
            logs={taskLogs}
            message={taskLogMessage}
            onCancelTask={cancelTask}
            onRetryTask={retryTask}
            onSelectTask={loadTaskLogs}
            selectedTaskId={selectedTaskId}
            tasks={tasks}
          />
        ) : null}
        {view === "audit" ? <AuditLogs auditLogs={auditLogs} /> : null}
        {view === "createVm" ? (
          <CreateVm images={images} ipPools={ipPools} nodes={nodes} onCreate={createVm} plans={plans} />
        ) : null}
        {view === "vms" ? <Vms onAction={createVmAction} vms={vms} /> : null}
      </section>
      {confirmation ? (
        <ConfirmationDialog
          onCancel={() => resolveConfirmation(false)}
          onProceed={() => resolveConfirmation(true)}
          request={confirmation}
        />
      ) : null}
    </main>
  );
}

function ConfirmationDialog({
  onCancel,
  onProceed,
  request,
}: {
  onCancel: () => void;
  onProceed: () => void;
  request: ConfirmationRequest;
}) {
  const cancelButtonRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    cancelButtonRef.current?.focus();
  }, []);

  function handleDialogKeyDown(event: KeyboardEvent<HTMLElement>) {
    if (event.key === "Escape") {
      event.preventDefault();
      onCancel();
    }
  }

  return (
    <div className="modal-backdrop">
      <section
        aria-describedby="confirmation-message"
        aria-labelledby="confirmation-title"
        aria-modal="true"
        className="confirmation-dialog"
        onKeyDown={handleDialogKeyDown}
        role="dialog"
      >
        <h2 id="confirmation-title">{request.title}</h2>
        <p id="confirmation-message">{request.message}</p>
        <div className="dialog-actions">
          <button className="ghost" onClick={onCancel} ref={cancelButtonRef} type="button">
            Cancel
          </button>
          <button
            className={request.danger ? "primary danger-button" : "primary"}
            onClick={onProceed}
            type="button"
          >
            {request.confirmLabel}
          </button>
        </div>
      </section>
    </div>
  );
}

function Dashboard({
  nodes,
  pendingTasks,
  runningVms,
  tasks,
  vms,
}: {
  nodes: NodeSummary[];
  pendingTasks: number;
  runningVms: number;
  tasks: TaskDto[];
  vms: VmDto[];
}) {
  const stats = [
    { label: "Nodes", value: nodes.length, icon: Server },
    { label: "VMs", value: vms.length, icon: Boxes },
    { label: "Running VMs", value: runningVms, icon: Activity },
    { label: "Pending Tasks", value: pendingTasks, icon: ListChecks },
  ];

  return (
    <>
      <section className="stats" aria-label="Overview">
        {stats.map((stat) => {
          const Icon = stat.icon;
          return (
            <article key={stat.label} className="card">
              <Icon aria-hidden="true" />
              <span>{stat.label}</span>
              <strong>{stat.value}</strong>
            </article>
          );
        })}
      </section>
      <section className="workbench">
        <Panel title="Recent Tasks">
          <TaskTable tasks={tasks.slice(0, 5)} />
        </Panel>
        <Panel title="Node Health">
          <NodeTable nodes={nodes.slice(0, 5)} />
        </Panel>
      </section>
    </>
  );
}

function Nodes({
  nodes,
  onCreate,
  onToggleScheduling,
}: {
  nodes: NodeSummary[];
  onCreate: (event: FormEvent<HTMLFormElement>) => void;
  onToggleScheduling: (node: NodeSummary) => void;
}) {
  const [selectedNodeId, setSelectedNodeId] = useState("");
  const selectedNode = nodes.find((node) => node.id === selectedNodeId) ?? nodes[0];

  return (
    <section className="stack">
      <form className="inline-form" onSubmit={onCreate}>
        <input name="name" placeholder="node-01" />
        <button className="primary" type="submit">
          <Server aria-hidden="true" />
          Add Node
        </button>
      </form>
      <Panel title="Nodes">
        <NodeTable nodes={nodes} onSelect={setSelectedNodeId} selectedNodeId={selectedNode?.id} />
      </Panel>
      <Panel title="Node Detail">
        {selectedNode ? (
          <>
            <div className="toolbar">
              <button className="ghost" onClick={() => onToggleScheduling(selectedNode)} type="button">
                <Power aria-hidden="true" />
                {selectedNode.scheduling_enabled ? "Disable Scheduling" : "Enable Scheduling"}
              </button>
            </div>
            <dl className="detail-grid">
              <div>
                <dt>Name</dt>
                <dd>{selectedNode.name}</dd>
              </div>
              <div>
                <dt>Status</dt>
                <dd>{selectedNode.status}</dd>
              </div>
              <div>
                <dt>Scheduling</dt>
                <dd>{selectedNode.scheduling_enabled ? "enabled" : "disabled"}</dd>
              </div>
              <div>
                <dt>Agent</dt>
                <dd>{selectedNode.agent_version ?? "not registered"}</dd>
              </div>
              <div>
                <dt>Libvirt</dt>
                <dd>{selectedNode.libvirt_status}</dd>
              </div>
              <div>
                <dt>Last Seen</dt>
                <dd>
                  {selectedNode.last_seen_at
                    ? new Date(selectedNode.last_seen_at).toLocaleString()
                    : "never"}
                </dd>
              </div>
              <div>
                <dt>CPU</dt>
                <dd>
                  {selectedNode.cpu_total > 0
                    ? `${selectedNode.committed_cpu} / ${selectedNode.cpu_total} cores committed`
                    : "not reported"}
                </dd>
              </div>
              <div>
                <dt>Memory</dt>
                <dd>
                  {formatCapacity(selectedNode.memory_used, selectedNode.memory_total)}
                  {selectedNode.memory_total > 0
                    ? `, ${selectedNode.committed_memory_mb} MB committed`
                    : ""}
                </dd>
              </div>
              <div>
                <dt>Data Disk</dt>
                <dd>
                  {formatCapacity(selectedNode.disk_used, selectedNode.disk_total)}
                  {selectedNode.disk_total > 0
                    ? `, ${selectedNode.committed_disk_gb} GB committed`
                    : ""}
                </dd>
              </div>
              <div>
                <dt>Managed VMs</dt>
                <dd>{selectedNode.vm_count}</dd>
              </div>
              <div className="wide">
                <dt>Host Checks</dt>
                <dd>{formatHostChecks(selectedNode.host_checks)}</dd>
              </div>
              <div className="wide">
                <dt>Node ID</dt>
                <dd>{selectedNode.id}</dd>
              </div>
            </dl>
          </>
        ) : (
          <div className="empty">Select a node.</div>
        )}
      </Panel>
    </section>
  );
}

function IpPools({
  ipPools,
  onCreate,
}: {
  ipPools: IpPoolDto[];
  onCreate: (event: FormEvent<HTMLFormElement>) => void;
}) {
  return (
    <section className="stack">
      <form className="form-grid" onSubmit={onCreate}>
        <label>
          Name
          <input name="name" pattern="[A-Za-z0-9_.-]{1,80}" required />
        </label>
        <label>
          CIDR
          <input defaultValue="192.0.2.0/29" name="cidr" required />
        </label>
        <label>
          Gateway
          <input defaultValue="192.0.2.1" name="gateway_ip" required />
        </label>
        <button className="primary" type="submit">
          <Boxes aria-hidden="true" />
          Add Pool
        </button>
      </form>
      <Panel title="IP Pools">
        {ipPools.length === 0 ? (
          <div className="empty">No IP pools yet.</div>
        ) : (
          <div className="table">
            {ipPools.map((pool) => (
              <div className="row ip-row" key={pool.id}>
                <span>{pool.name}</span>
                <span>{pool.cidr}</span>
                <span>{pool.gateway_ip}</span>
                <span>{pool.allocated_count} allocated</span>
              </div>
            ))}
          </div>
        )}
      </Panel>
    </section>
  );
}

function Images({
  images,
  onCreate,
  onToggleEnabled,
}: {
  images: ImageDto[];
  onCreate: (event: FormEvent<HTMLFormElement>) => void;
  onToggleEnabled: (image: ImageDto) => void;
}) {
  return (
    <section className="stack">
      <form className="form-grid" onSubmit={onCreate}>
        <label>
          Name
          <input name="name" pattern="[A-Za-z0-9 _-]{1,80}" required />
        </label>
        <label>
          File Name
          <input defaultValue="debian-12.qcow2" name="file_name" pattern="[A-Za-z0-9_.-]{1,80}" required />
        </label>
        <label className="checkbox-line">
          <input defaultChecked name="enabled" type="checkbox" />
          Enabled
        </label>
        <button className="primary" type="submit">
          <ImageIcon aria-hidden="true" />
          Add Image
        </button>
      </form>
      <Panel title="Images">
        {images.length === 0 ? (
          <div className="empty">No images registered.</div>
        ) : (
          <div className="table">
            {images.map((image) => (
              <div className="row image-row" key={image.id}>
                <span>{image.name}</span>
                <span>{image.file_name}</span>
                <span>{image.enabled ? "enabled" : "disabled"}</span>
                <button className="ghost" onClick={() => onToggleEnabled(image)} type="button">
                  {image.enabled ? <Ban aria-hidden="true" /> : <Power aria-hidden="true" />}
                  {image.enabled ? "Disable" : "Enable"}
                </button>
              </div>
            ))}
          </div>
        )}
      </Panel>
    </section>
  );
}

function Plans({
  onCreate,
  onToggleEnabled,
  plans,
}: {
  onCreate: (event: FormEvent<HTMLFormElement>) => void;
  onToggleEnabled: (plan: PlanDto) => void;
  plans: PlanDto[];
}) {
  return (
    <section className="stack">
      <form className="form-grid" onSubmit={onCreate}>
        <label>
          Name
          <input name="name" pattern="[A-Za-z0-9 _-]{1,80}" required />
        </label>
        <label>
          Slug
          <input defaultValue="small-1" name="slug" pattern="[A-Za-z0-9_-]{1,80}" required />
        </label>
        <label>
          CPU
          <input defaultValue={1} min={1} name="cpu_cores" type="number" />
        </label>
        <label>
          Memory MB
          <input defaultValue={512} min={128} name="memory_mb" type="number" />
        </label>
        <label>
          Disk GB
          <input defaultValue={10} min={1} name="disk_gb" type="number" />
        </label>
        <label className="checkbox-line">
          <input defaultChecked name="enabled" type="checkbox" />
          Enabled
        </label>
        <button className="primary" type="submit">
          <Boxes aria-hidden="true" />
          Add Plan
        </button>
      </form>
      <Panel title="Plans">
        {plans.length === 0 ? (
          <div className="empty">No plans configured.</div>
        ) : (
          <div className="table">
            {plans.map((plan) => (
              <div className="row plan-row" key={plan.id}>
                <span>{plan.name}</span>
                <span>{plan.slug}</span>
                <span>
                  {plan.cpu_cores} CPU / {plan.memory_mb} MB / {plan.disk_gb} GB
                </span>
                <span>{plan.enabled ? "enabled" : "disabled"}</span>
                <button className="ghost" onClick={() => onToggleEnabled(plan)} type="button">
                  {plan.enabled ? <Ban aria-hidden="true" /> : <Power aria-hidden="true" />}
                  {plan.enabled ? "Disable" : "Enable"}
                </button>
              </div>
            ))}
          </div>
        )}
      </Panel>
    </section>
  );
}

function InstallAgent({
  install,
  nodes,
  onGenerate,
  selectedNodeId,
  setSelectedNodeId,
}: {
  install: BootstrapTokenResponse | null;
  nodes: NodeSummary[];
  onGenerate: (event: FormEvent<HTMLFormElement>) => void;
  selectedNodeId: string;
  setSelectedNodeId: (nodeId: string) => void;
}) {
  return (
    <section className="stack">
      <form className="inline-form" onSubmit={onGenerate}>
        <select
          aria-label="Agent install target node"
          onChange={(event) => setSelectedNodeId(event.target.value)}
          value={selectedNodeId}
        >
          <option value="">Select node</option>
          {nodes.map((node) => (
            <option key={node.id} value={node.id}>
              {node.name}
            </option>
          ))}
        </select>
        <button className="primary" disabled={!selectedNodeId} type="submit">
          <ClipboardPlus aria-hidden="true" />
          Generate
        </button>
      </form>
      <Panel title="Install Command">
        {install ? (
          <div className="command-box">
            <code>{install.install_command}</code>
            <button
              className="ghost"
              onClick={() => void navigator.clipboard.writeText(install.install_command)}
              type="button"
            >
              <Clipboard aria-hidden="true" />
              Copy
            </button>
          </div>
        ) : (
          <div className="empty">No command generated.</div>
        )}
      </Panel>
    </section>
  );
}

function Tasks({
  logs,
  message,
  onCancelTask,
  onRetryTask,
  onSelectTask,
  selectedTaskId,
  tasks,
}: {
  logs: TaskLogDto[];
  message: string;
  onCancelTask: (task: TaskDto) => void;
  onRetryTask: (task: TaskDto) => void;
  onSelectTask: (taskId: string) => void;
  selectedTaskId: string;
  tasks: TaskDto[];
}) {
  const selectedTask = tasks.find((task) => task.id === selectedTaskId);
  const taskErrorMessage = selectedTask?.error_message ?? "";
  const canCancel = selectedTask && canCancelTaskStatus(selectedTask.status);
  const canRetry = selectedTask && ["failed", "canceled"].includes(selectedTask.status);

  return (
    <section className="stack">
      <Panel title="Tasks">
        <TaskTable onSelect={onSelectTask} selectedTaskId={selectedTaskId} tasks={tasks} />
      </Panel>
      <Panel title="Task Logs">
        {canCancel ? (
          <div className="toolbar">
            <button className="ghost danger" onClick={() => onCancelTask(selectedTask)} type="button">
              <Ban aria-hidden="true" />
              Cancel Task
            </button>
          </div>
        ) : null}
        {canRetry ? (
          <div className="toolbar">
            <button className="ghost" onClick={() => onRetryTask(selectedTask)} type="button">
              <RefreshCcw aria-hidden="true" />
              Retry Task
            </button>
          </div>
        ) : null}
        {!selectedTaskId ? <div className="empty">Select a task.</div> : null}
        {selectedTaskId && message ? <p className="error">{message}</p> : null}
        {taskErrorMessage ? <p className="error" role="alert">Task failed: {taskErrorMessage}</p> : null}
        {selectedTaskId && !message && !taskErrorMessage && logs.length === 0 ? (
          <div className="empty">No logs for this task.</div>
        ) : null}
        {logs.length > 0 ? (
          <div className="log-list">
            {logs.map((log) => (
              <div className="log-line" key={log.id}>
                <time>{new Date(log.created_at).toLocaleString()}</time>
                <span className="log-message">{log.message}</span>
              </div>
            ))}
          </div>
        ) : null}
      </Panel>
    </section>
  );
}

function AuditLogs({ auditLogs }: { auditLogs: AuditLogDto[] }) {
  return (
    <Panel title="Audit Logs">
      {auditLogs.length === 0 ? (
        <div className="empty">No audit entries yet.</div>
      ) : (
        <div className="table">
          {auditLogs.map((entry) => (
            <div className="row audit-row" key={entry.id}>
              <span>{new Date(entry.created_at).toLocaleString()}</span>
              <span>{entry.request_id ?? "no request"}</span>
              <span>{entry.actor_role}</span>
              <span>{entry.action}</span>
              <span>{entry.result}</span>
              <span>{entry.node_id ?? "no node"}</span>
              <span>{entry.task_id ?? "no task"}</span>
              <span>{formatAuditDetail(entry.detail)}</span>
            </div>
          ))}
        </div>
      )}
    </Panel>
  );
}

function CreateVm({
  images,
  ipPools,
  nodes,
  onCreate,
  plans,
}: {
  images: ImageDto[];
  ipPools: IpPoolDto[];
  nodes: NodeSummary[];
  onCreate: (event: FormEvent<HTMLFormElement>) => void;
  plans: PlanDto[];
}) {
  const enabledImages = images.filter((image) => image.enabled);
  const enabledPlans = plans.filter((plan) => plan.enabled);
  const selectableNodes = nodes.filter((node) => isCreateVmNodeSelectable(node));

  return (
    <Panel title="Create VM">
      <form className="form-grid" onSubmit={onCreate}>
        <label>
          Node
          <select name="node_id" required>
            {selectableNodes.map((node) => (
              <option key={node.id} value={node.id}>
                {node.name} ({formatNodeCapacitySummary(node)}, {nodeCreateVmAdmissionLabel(node)})
              </option>
            ))}
          </select>
        </label>
        {nodes.length > 0 && selectableNodes.length === 0 ? (
          <div className="wide-field muted">
            No node is online, heartbeating, schedulable, and available for create tasks.
          </div>
        ) : null}
        {nodes.some((node) => !isCreateVmNodeSelectable(node)) ? (
          <div className="wide-field muted">
            Unready nodes:{" "}
            {nodes
              .filter((node) => !isCreateVmNodeSelectable(node))
              .map((node) => `${node.name} (${nodeCreateVmAdmissionLabel(node)})`)
              .join(", ")}
          </div>
        ) : null}
        <label>
          IP Pool
          <select name="ip_pool_id">
            <option value="">No reservation</option>
            {ipPools.map((pool) => (
              <option key={pool.id} value={pool.id}>
                {pool.name} ({pool.allocated_count})
              </option>
            ))}
          </select>
        </label>
        <label>
          Plan
          <select name="plan_id">
            <option value="">Custom sizing</option>
            {enabledPlans.map((plan) => (
              <option key={plan.id} value={plan.id}>
                {plan.name} ({plan.cpu_cores} CPU / {plan.memory_mb} MB / {plan.disk_gb} GB)
              </option>
            ))}
          </select>
        </label>
        <label>
          Name
          <input name="name" pattern="[A-Za-z0-9_-]{1,64}" required />
        </label>
        <label>
          Image
          <select name="image" required>
            {enabledImages.map((image) => (
              <option key={image.id} value={image.file_name}>
                {image.name} ({image.file_name})
              </option>
            ))}
          </select>
        </label>
        <label className="wide-field">
          SSH Public Key
          <textarea name="ssh_public_key" placeholder="ssh-ed25519 AAAA..." rows={3} />
        </label>
        <label>
          CPU
          <input defaultValue={1} min={1} name="cpu_cores" type="number" />
        </label>
        <label>
          Memory MB
          <input defaultValue={512} min={128} name="memory_mb" type="number" />
        </label>
        <label>
          Disk GB
          <input defaultValue={10} min={1} name="disk_gb" type="number" />
        </label>
        <button className="primary" disabled={selectableNodes.length === 0 || enabledImages.length === 0} type="submit">
          <Play aria-hidden="true" />
          Create Task
        </button>
      </form>
    </Panel>
  );
}

function Vms({
  onAction,
  vms,
}: {
  onAction: (action: VmAction, vm: VmDto) => void;
  vms: VmDto[];
}) {
  return (
    <Panel title="VMs">
      {vms.length === 0 ? (
        <div className="empty">No VM records yet.</div>
      ) : (
        <div className="table">
          {vms.map((vm) => {
            const hasActiveTask = vm.last_task_status
              ? shouldAutoRefreshTaskStatus(vm.last_task_status)
              : false;
            const actions = availableVmActions({ status: vm.status, hasActiveTask });

            return (
              <div className="row vm-row" key={vm.id}>
                <span>{vm.name}</span>
                <span>{vm.status}</span>
                <span>{vm.assigned_ip ?? "no ip"}</span>
                <span>{vm.ssh_public_key ? "ssh key" : "no ssh key"}</span>
                <div className="actions">
                  {actions.map((action) => {
                    const { icon: Icon, label } = vmActionConfig[action];
                    return (
                      <button
                        className="icon-button"
                        key={label}
                        onClick={() => onAction(action, vm)}
                        title={label}
                        type="button"
                      >
                        <Icon aria-hidden="true" />
                      </button>
                    );
                  })}
                  {actions.length === 0 ? (
                    <span className="muted">{hasActiveTask ? "Task active" : "No actions"}</span>
                  ) : null}
                </div>
              </div>
            );
          })}
        </div>
      )}
    </Panel>
  );
}

function Panel({ children, title }: { children: React.ReactNode; title: string }) {
  return (
    <section className="panel">
      <h2>{title}</h2>
      {children}
    </section>
  );
}

function NodeTable({
  nodes,
  onSelect,
  selectedNodeId,
}: {
  nodes: NodeSummary[];
  onSelect?: (nodeId: string) => void;
  selectedNodeId?: string;
}) {
  const table = useReactTable({
    columns: nodeColumns,
    data: nodes,
    getCoreRowModel: getCoreRowModel(),
    getRowId: (node) => node.id,
  });

  if (nodes.length === 0) return <div className="empty">No registered nodes.</div>;
  return (
    <div className="table">
      {table.getRowModel().rows.map((row) => (
        <button
          className={row.original.id === selectedNodeId ? "row selectable selected" : "row selectable"}
          key={row.id}
          onClick={() => onSelect?.(row.original.id)}
          type="button"
        >
          {row.getVisibleCells().map((cell) => (
            <span key={cell.id}>{flexRender(cell.column.columnDef.cell, cell.getContext())}</span>
          ))}
        </button>
      ))}
    </div>
  );
}

function TaskTable({
  onSelect,
  selectedTaskId,
  tasks,
}: {
  onSelect?: (taskId: string) => void;
  selectedTaskId?: string;
  tasks: TaskDto[];
}) {
  const table = useReactTable({
    columns: taskColumns,
    data: tasks,
    getCoreRowModel: getCoreRowModel(),
    getRowId: (task) => task.id,
  });

  if (tasks.length === 0) return <div className="empty">No tasks yet.</div>;
  return (
    <div className="table">
      {table.getRowModel().rows.map((row) => (
        <button
          className={row.original.id === selectedTaskId ? "row selectable selected" : "row selectable"}
          key={row.id}
          onClick={() => onSelect?.(row.original.id)}
          type="button"
        >
          {row.getVisibleCells().map((cell) => (
            <span key={cell.id}>{flexRender(cell.column.columnDef.cell, cell.getContext())}</span>
          ))}
        </button>
      ))}
    </div>
  );
}

function titleFor(view: View) {
  switch (view) {
    case "dashboard":
      return "Dashboard";
    case "nodes":
      return "Nodes";
    case "plans":
      return "Plans";
    case "images":
      return "Images";
    case "ipPools":
      return "IP Pools";
    case "install":
      return "Install Agent";
    case "tasks":
      return "Tasks";
    case "audit":
      return "Audit";
    case "createVm":
      return "Create VM";
    case "vms":
      return "VMs";
  }
}

function optionalFormValue(form: FormData, name: string) {
  const value = String(form.get(name) ?? "").trim();
  return value.length > 0 ? value : undefined;
}

async function loadPanelData(api: PanelApi): Promise<PanelData> {
  const [nodes, plans, images, ipPools, tasks, auditLogs, vms] = await Promise.all([
    api<NodeSummary[]>("/api/nodes"),
    api<PlanDto[]>("/api/plans"),
    api<ImageDto[]>("/api/images"),
    api<IpPoolDto[]>("/api/ip-pools"),
    api<TaskDto[]>("/api/tasks"),
    api<AuditLogDto[]>("/api/audit-logs"),
    api<VmDto[]>("/api/vms"),
  ]);

  return { auditLogs, images, ipPools, nodes, plans, tasks, vms };
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : "request failed";
}

function isUnauthorizedError(error: unknown) {
  return errorMessage(error) === "unauthorized";
}

function formatCapacity(used: number, total: number) {
  if (total <= 0) return "not reported";
  return `${formatBytes(used)} / ${formatBytes(total)}`;
}

function formatNodeCapacitySummary(node: NodeSummary) {
  const cpu = node.cpu_total > 0 ? `${node.committed_cpu}/${node.cpu_total} CPU` : "CPU unknown";
  const memoryTotalMb = Math.floor(node.memory_total / 1024 / 1024);
  const memory =
    memoryTotalMb > 0 ? `${node.committed_memory_mb}/${memoryTotalMb} MB` : "memory unknown";
  const diskTotalGb = Math.floor(node.disk_total / 1024 / 1024 / 1024);
  const disk = diskTotalGb > 0 ? `${node.committed_disk_gb}/${diskTotalGb} GB` : "disk unknown";
  return `${cpu}, ${memory}, ${disk}`;
}

function formatBytes(value: number) {
  if (value <= 0) return "0 B";
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let size = value;
  let unitIndex = 0;
  while (size >= 1024 && unitIndex < units.length - 1) {
    size /= 1024;
    unitIndex += 1;
  }
  return `${size.toFixed(unitIndex === 0 ? 0 : 1)} ${units[unitIndex]}`;
}
