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
import {
  type I18nText,
  type Language,
  readStoredLanguage,
  supportedLanguages,
  translations,
  writeStoredLanguage,
} from "../lib/i18n";
import { isCreateVmNodeSelectable, nodeCreateVmAdmissionLabel } from "../lib/node-readiness";
import { panelMutationHeaderName, panelMutationHeaderValue } from "../lib/request-security";
import { canCancelTaskStatus, shouldAutoRefreshTaskStatus } from "../lib/task-actions";
import { availableVmActions, type VmAction } from "../lib/vm-actions";

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

const navItems: View[] = [
  "dashboard",
  "nodes",
  "plans",
  "images",
  "ipPools",
  "install",
  "tasks",
  "audit",
  "createVm",
  "vms",
];

const vmActionIcons = {
  "start-vm": Play,
  "stop-vm": Power,
  "reboot-vm": RefreshCcw,
  "reinstall-vm": RefreshCcw,
  "delete-vm": Trash2,
} satisfies Record<VmAction, LucideIcon>;

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
  const [language, setLanguage] = useState<Language>(() => readStoredLanguage());
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
  const text = translations[language];

  function handleLanguageChange(nextLanguage: Language) {
    setLanguage(nextLanguage);
    writeStoredLanguage(nextLanguage);
    document.documentElement.lang = nextLanguage;
  }

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
      setMessage(error instanceof Error ? error.message : text.login.failed);
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
    const label = nextEnabled ? text.nodes.enableScheduling : text.nodes.disableScheduling;
    const confirmed = await confirmPanelAction({
      confirmLabel: label,
      danger: true,
      message: nextEnabled
        ? text.confirm.enableScheduling(node.name)
        : text.confirm.disableScheduling(node.name),
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
      confirmLabel: nextEnabled ? text.common.enable : text.common.disable,
      danger: !nextEnabled,
      message: text.confirm.imageAvailability(image.name, nextEnabled),
      title: nextEnabled ? text.images.titleEnabled : text.images.titleDisabled,
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
      confirmLabel: nextEnabled ? text.common.enable : text.common.disable,
      danger: !nextEnabled,
      message: text.confirm.planAvailability(plan.name, nextEnabled),
      title: nextEnabled ? text.plans.titleEnabled : text.plans.titleDisabled,
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
      confirmLabel: text.common.generate,
      danger: true,
      message: text.confirm.generateInstall(selectedNode?.name ?? selectedNodeId),
      title: text.app.generateAgentCommand,
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
      confirmLabel: text.nav.createVm,
      message: text.confirm.createVm(
        vm.name,
        selectedNode?.name ?? vm.node_id,
        vm.cpu_cores,
        vm.memory_mb,
        vm.disk_gb,
      ),
      title: text.nav.createVm,
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
    const label = text.vmActions[action];
    const confirmed = await confirmPanelAction({
      confirmLabel: label,
      danger: action !== "start-vm",
      message: vmActionConfirmationText(action, vm, text),
      title: text.confirm.vmActionTitle(label),
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
      confirmLabel: text.tasks.cancel,
      danger: true,
      message: text.confirm.cancelTask(task.kind.type),
      title: text.tasks.cancel,
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
      confirmLabel: text.tasks.retry,
      message: text.confirm.retryTask(task.kind.type),
      title: text.tasks.retry,
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
    document.documentElement.lang = language;
  }, [language]);

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
            <span>{text.app.brand}</span>
          </div>
          <h1>{text.login.title}</h1>
          <label>
            {text.login.username}
            <input
              autoComplete="username"
              onChange={(event) => setUsername(event.target.value)}
              type="text"
              value={username}
            />
          </label>
          <label>
            {text.login.password}
            <input
              autoComplete="current-password"
              onChange={(event) => setPassword(event.target.value)}
              type="password"
              value={password}
            />
          </label>
          <button className="primary" disabled={loading} type="submit">
            <ShieldCheck aria-hidden="true" />
            {text.login.submit}
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
          <span>{text.app.brand}</span>
        </div>
        <nav aria-label={text.dashboard.overview}>
          {navItems.map((item) => (
            <button
              className={item === view ? "active" : ""}
              key={item}
              onClick={() => setView(item)}
              type="button"
            >
              {titleFor(item, text)}
            </button>
          ))}
        </nav>
        <label className="language-picker">
          <span>{text.language.label}</span>
          <select
            aria-label={text.language.ariaLabel}
            onChange={(event) => handleLanguageChange(event.target.value as Language)}
            value={language}
          >
            {supportedLanguages.map((option) => (
              <option key={option.code} value={option.code}>
                {option.label}
              </option>
            ))}
          </select>
        </label>
        <button className="ghost logout" onClick={logout} type="button">
          <LogOut aria-hidden="true" />
          {text.app.signOut}
        </button>
      </aside>

      <section className="content">
        <header className="topbar">
          <div>
            <p className="eyebrow">{text.app.eyebrow}</p>
            <h1>{titleFor(view, text)}</h1>
          </div>
          <button className="primary" onClick={() => setView("install")} type="button">
            <ClipboardPlus aria-hidden="true" />
            {text.app.generateAgentCommand}
          </button>
        </header>

        {actionMessage ? <p className="error" role="alert">{actionMessage}</p> : null}

        {view === "dashboard" ? (
          <Dashboard
            nodes={nodes}
            pendingTasks={pendingTasks}
            runningVms={runningVms.length}
            text={text}
            tasks={tasks}
            vms={vms}
          />
        ) : null}
        {view === "nodes" ? (
          <Nodes nodes={nodes} onCreate={createNode} onToggleScheduling={toggleNodeScheduling} text={text} />
        ) : null}
        {view === "plans" ? (
          <Plans plans={plans} onCreate={createPlan} onToggleEnabled={togglePlanEnabled} text={text} />
        ) : null}
        {view === "images" ? (
          <Images images={images} onCreate={createImage} onToggleEnabled={toggleImageEnabled} text={text} />
        ) : null}
        {view === "ipPools" ? <IpPools ipPools={ipPools} onCreate={createIpPool} text={text} /> : null}
        {view === "install" ? (
          <InstallAgent
            install={install}
            nodes={nodes}
            onGenerate={generateInstall}
            selectedNodeId={selectedNodeId}
            setSelectedNodeId={selectInstallNode}
            text={text}
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
            text={text}
          />
        ) : null}
        {view === "audit" ? <AuditLogs auditLogs={auditLogs} text={text} /> : null}
        {view === "createVm" ? (
          <CreateVm images={images} ipPools={ipPools} nodes={nodes} onCreate={createVm} plans={plans} text={text} />
        ) : null}
        {view === "vms" ? <Vms onAction={createVmAction} text={text} vms={vms} /> : null}
      </section>
      {confirmation ? (
        <ConfirmationDialog
          onCancel={() => resolveConfirmation(false)}
          onProceed={() => resolveConfirmation(true)}
          request={confirmation}
          text={text}
        />
      ) : null}
    </main>
  );
}

function ConfirmationDialog({
  onCancel,
  onProceed,
  request,
  text,
}: {
  onCancel: () => void;
  onProceed: () => void;
  request: ConfirmationRequest;
  text: I18nText;
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
            {text.common.cancel}
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
  text,
  tasks,
  vms,
}: {
  nodes: NodeSummary[];
  pendingTasks: number;
  runningVms: number;
  text: I18nText;
  tasks: TaskDto[];
  vms: VmDto[];
}) {
  const stats = [
    { label: text.nav.nodes, value: nodes.length, icon: Server },
    { label: text.nav.vms, value: vms.length, icon: Boxes },
    { label: text.dashboard.runningVms, value: runningVms, icon: Activity },
    { label: text.dashboard.pendingTasks, value: pendingTasks, icon: ListChecks },
  ];

  return (
    <>
      <section className="stats" aria-label={text.dashboard.overview}>
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
        <Panel title={text.dashboard.recentTasks}>
          <TaskTable tasks={tasks.slice(0, 5)} text={text} />
        </Panel>
        <Panel title={text.dashboard.nodeHealth}>
          <NodeTable nodes={nodes.slice(0, 5)} text={text} />
        </Panel>
      </section>
    </>
  );
}

function Nodes({
  nodes,
  onCreate,
  onToggleScheduling,
  text,
}: {
  nodes: NodeSummary[];
  onCreate: (event: FormEvent<HTMLFormElement>) => void;
  onToggleScheduling: (node: NodeSummary) => void;
  text: I18nText;
}) {
  const [selectedNodeId, setSelectedNodeId] = useState("");
  const selectedNode = nodes.find((node) => node.id === selectedNodeId) ?? nodes[0];

  return (
    <section className="stack">
      <form className="inline-form" onSubmit={onCreate}>
        <input name="name" placeholder="node-01" />
        <button className="primary" type="submit">
          <Server aria-hidden="true" />
          {text.nodes.add}
        </button>
      </form>
      <Panel title={text.nav.nodes}>
        <NodeTable nodes={nodes} onSelect={setSelectedNodeId} selectedNodeId={selectedNode?.id} text={text} />
      </Panel>
      <Panel title={text.nodes.detail}>
        {selectedNode ? (
          <>
            <div className="toolbar">
              <button className="ghost" onClick={() => onToggleScheduling(selectedNode)} type="button">
                <Power aria-hidden="true" />
                {selectedNode.scheduling_enabled ? text.nodes.disableScheduling : text.nodes.enableScheduling}
              </button>
            </div>
            <dl className="detail-grid">
              <div>
                <dt>{text.common.name}</dt>
                <dd>{selectedNode.name}</dd>
              </div>
              <div>
                <dt>{text.common.status}</dt>
                <dd>{selectedNode.status}</dd>
              </div>
              <div>
                <dt>{text.nodes.scheduling}</dt>
                <dd>{selectedNode.scheduling_enabled ? text.common.enabled : text.common.disabled}</dd>
              </div>
              <div>
                <dt>{text.nodes.agent}</dt>
                <dd>{selectedNode.agent_version ?? text.common.notRegistered}</dd>
              </div>
              <div>
                <dt>{text.nodes.libvirt}</dt>
                <dd>{selectedNode.libvirt_status}</dd>
              </div>
              <div>
                <dt>{text.nodes.lastSeen}</dt>
                <dd>
                  {selectedNode.last_seen_at
                    ? new Date(selectedNode.last_seen_at).toLocaleString()
                    : text.common.never}
                </dd>
              </div>
              <div>
                <dt>{text.nodes.cpu}</dt>
                <dd>
                  {selectedNode.cpu_total > 0
                    ? text.nodes.coresCommitted(selectedNode.committed_cpu, selectedNode.cpu_total)
                    : text.common.notReported}
                </dd>
              </div>
              <div>
                <dt>{text.nodes.memory}</dt>
                <dd>
                  {formatCapacity(selectedNode.memory_used, selectedNode.memory_total, text)}
                  {selectedNode.memory_total > 0
                    ? `, ${text.nodes.mbCommitted(selectedNode.committed_memory_mb)}`
                    : ""}
                </dd>
              </div>
              <div>
                <dt>{text.nodes.dataDisk}</dt>
                <dd>
                  {formatCapacity(selectedNode.disk_used, selectedNode.disk_total, text)}
                  {selectedNode.disk_total > 0
                    ? `, ${text.nodes.gbCommitted(selectedNode.committed_disk_gb)}`
                    : ""}
                </dd>
              </div>
              <div>
                <dt>{text.nodes.managedVms}</dt>
                <dd>{selectedNode.vm_count}</dd>
              </div>
              <div className="wide">
                <dt>{text.nodes.hostChecks}</dt>
                <dd>{formatHostChecks(selectedNode.host_checks)}</dd>
              </div>
              <div className="wide">
                <dt>{text.nodes.nodeId}</dt>
                <dd>{selectedNode.id}</dd>
              </div>
            </dl>
          </>
        ) : (
          <div className="empty">{text.nodes.select}</div>
        )}
      </Panel>
    </section>
  );
}

function IpPools({
  ipPools,
  onCreate,
  text,
}: {
  ipPools: IpPoolDto[];
  onCreate: (event: FormEvent<HTMLFormElement>) => void;
  text: I18nText;
}) {
  return (
    <section className="stack">
      <form className="form-grid" onSubmit={onCreate}>
        <label>
          {text.common.name}
          <input name="name" pattern="[A-Za-z0-9_.-]{1,80}" required />
        </label>
        <label>
          {text.ipPools.cidr}
          <input defaultValue="192.0.2.0/29" name="cidr" required />
        </label>
        <label>
          {text.ipPools.gateway}
          <input defaultValue="192.0.2.1" name="gateway_ip" required />
        </label>
        <button className="primary" type="submit">
          <Boxes aria-hidden="true" />
          {text.ipPools.add}
        </button>
      </form>
      <Panel title={text.nav.ipPools}>
        {ipPools.length === 0 ? (
          <div className="empty">{text.ipPools.empty}</div>
        ) : (
          <div className="table">
            {ipPools.map((pool) => (
              <div className="row ip-row" key={pool.id}>
                <span>{pool.name}</span>
                <span>{pool.cidr}</span>
                <span>{pool.gateway_ip}</span>
                <span>{text.ipPools.allocated(pool.allocated_count)}</span>
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
  text,
}: {
  images: ImageDto[];
  onCreate: (event: FormEvent<HTMLFormElement>) => void;
  onToggleEnabled: (image: ImageDto) => void;
  text: I18nText;
}) {
  return (
    <section className="stack">
      <form className="form-grid" onSubmit={onCreate}>
        <label>
          {text.common.name}
          <input name="name" pattern="[A-Za-z0-9 _-]{1,80}" required />
        </label>
        <label>
          {text.images.fileName}
          <input defaultValue="debian-12.qcow2" name="file_name" pattern="[A-Za-z0-9_.-]{1,80}" required />
        </label>
        <label className="checkbox-line">
          <input defaultChecked name="enabled" type="checkbox" />
          {text.common.enabled}
        </label>
        <button className="primary" type="submit">
          <ImageIcon aria-hidden="true" />
          {text.images.add}
        </button>
      </form>
      <Panel title={text.nav.images}>
        {images.length === 0 ? (
          <div className="empty">{text.images.empty}</div>
        ) : (
          <div className="table">
            {images.map((image) => (
              <div className="row image-row" key={image.id}>
                <span>{image.name}</span>
                <span>{image.file_name}</span>
                <span>{image.enabled ? text.common.enabled : text.common.disabled}</span>
                <button className="ghost" onClick={() => onToggleEnabled(image)} type="button">
                  {image.enabled ? <Ban aria-hidden="true" /> : <Power aria-hidden="true" />}
                  {image.enabled ? text.common.disable : text.common.enable}
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
  text,
}: {
  onCreate: (event: FormEvent<HTMLFormElement>) => void;
  onToggleEnabled: (plan: PlanDto) => void;
  plans: PlanDto[];
  text: I18nText;
}) {
  return (
    <section className="stack">
      <form className="form-grid" onSubmit={onCreate}>
        <label>
          {text.common.name}
          <input name="name" pattern="[A-Za-z0-9 _-]{1,80}" required />
        </label>
        <label>
          {text.plans.slug}
          <input defaultValue="small-1" name="slug" pattern="[A-Za-z0-9_-]{1,80}" required />
        </label>
        <label>
          {text.nodes.cpu}
          <input defaultValue={1} min={1} name="cpu_cores" type="number" />
        </label>
        <label>
          {text.plans.memoryMb}
          <input defaultValue={512} min={128} name="memory_mb" type="number" />
        </label>
        <label>
          {text.plans.diskGb}
          <input defaultValue={10} min={1} name="disk_gb" type="number" />
        </label>
        <label className="checkbox-line">
          <input defaultChecked name="enabled" type="checkbox" />
          {text.common.enabled}
        </label>
        <button className="primary" type="submit">
          <Boxes aria-hidden="true" />
          {text.plans.add}
        </button>
      </form>
      <Panel title={text.nav.plans}>
        {plans.length === 0 ? (
          <div className="empty">{text.plans.empty}</div>
        ) : (
          <div className="table">
            {plans.map((plan) => (
              <div className="row plan-row" key={plan.id}>
                <span>{plan.name}</span>
                <span>{plan.slug}</span>
                <span>{text.plans.sizing(plan.cpu_cores, plan.memory_mb, plan.disk_gb)}</span>
                <span>{plan.enabled ? text.common.enabled : text.common.disabled}</span>
                <button className="ghost" onClick={() => onToggleEnabled(plan)} type="button">
                  {plan.enabled ? <Ban aria-hidden="true" /> : <Power aria-hidden="true" />}
                  {plan.enabled ? text.common.disable : text.common.enable}
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
  text,
}: {
  install: BootstrapTokenResponse | null;
  nodes: NodeSummary[];
  onGenerate: (event: FormEvent<HTMLFormElement>) => void;
  selectedNodeId: string;
  setSelectedNodeId: (nodeId: string) => void;
  text: I18nText;
}) {
  return (
    <section className="stack">
      <form className="inline-form" onSubmit={onGenerate}>
        <select
          aria-label={text.install.targetAriaLabel}
          onChange={(event) => setSelectedNodeId(event.target.value)}
          value={selectedNodeId}
        >
          <option value="">{text.install.selectNode}</option>
          {nodes.map((node) => (
            <option key={node.id} value={node.id}>
              {node.name}
            </option>
          ))}
        </select>
        <button className="primary" disabled={!selectedNodeId} type="submit">
          <ClipboardPlus aria-hidden="true" />
          {text.common.generate}
        </button>
      </form>
      <Panel title={text.install.commandTitle}>
        {install ? (
          <div className="command-box">
            <code>{install.install_command}</code>
            <button
              className="ghost"
              onClick={() => void navigator.clipboard.writeText(install.install_command)}
              type="button"
            >
              <Clipboard aria-hidden="true" />
              {text.common.copy}
            </button>
          </div>
        ) : (
          <div className="empty">{text.install.noCommand}</div>
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
  text,
}: {
  logs: TaskLogDto[];
  message: string;
  onCancelTask: (task: TaskDto) => void;
  onRetryTask: (task: TaskDto) => void;
  onSelectTask: (taskId: string) => void;
  selectedTaskId: string;
  tasks: TaskDto[];
  text: I18nText;
}) {
  const selectedTask = tasks.find((task) => task.id === selectedTaskId);
  const taskErrorMessage = selectedTask?.error_message ?? "";
  const canCancel = selectedTask && canCancelTaskStatus(selectedTask.status);
  const canRetry = selectedTask && ["failed", "canceled"].includes(selectedTask.status);

  return (
    <section className="stack">
      <Panel title={text.tasks.title}>
        <TaskTable onSelect={onSelectTask} selectedTaskId={selectedTaskId} tasks={tasks} text={text} />
      </Panel>
      <Panel title={text.tasks.logs}>
        {canCancel ? (
          <div className="toolbar">
            <button className="ghost danger" onClick={() => onCancelTask(selectedTask)} type="button">
              <Ban aria-hidden="true" />
              {text.tasks.cancel}
            </button>
          </div>
        ) : null}
        {canRetry ? (
          <div className="toolbar">
            <button className="ghost" onClick={() => onRetryTask(selectedTask)} type="button">
              <RefreshCcw aria-hidden="true" />
              {text.tasks.retry}
            </button>
          </div>
        ) : null}
        {!selectedTaskId ? <div className="empty">{text.tasks.select}</div> : null}
        {selectedTaskId && message ? <p className="error">{message}</p> : null}
        {taskErrorMessage ? <p className="error" role="alert">{text.tasks.failed(taskErrorMessage)}</p> : null}
        {selectedTaskId && !message && !taskErrorMessage && logs.length === 0 ? (
          <div className="empty">{text.tasks.noLogs}</div>
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

function AuditLogs({ auditLogs, text }: { auditLogs: AuditLogDto[]; text: I18nText }) {
  return (
    <Panel title={text.audit.title}>
      {auditLogs.length === 0 ? (
        <div className="empty">{text.audit.empty}</div>
      ) : (
        <div className="table">
          {auditLogs.map((entry) => (
            <div className="row audit-row" key={entry.id}>
              <span>{new Date(entry.created_at).toLocaleString()}</span>
              <span>{entry.request_id ?? text.audit.noRequest}</span>
              <span>{entry.actor_role}</span>
              <span>{entry.action}</span>
              <span>{entry.result}</span>
              <span>{entry.node_id ?? text.audit.noNode}</span>
              <span>{entry.task_id ?? text.audit.noTask}</span>
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
  text,
}: {
  images: ImageDto[];
  ipPools: IpPoolDto[];
  nodes: NodeSummary[];
  onCreate: (event: FormEvent<HTMLFormElement>) => void;
  plans: PlanDto[];
  text: I18nText;
}) {
  const enabledImages = images.filter((image) => image.enabled);
  const enabledPlans = plans.filter((plan) => plan.enabled);
  const selectableNodes = nodes.filter((node) => isCreateVmNodeSelectable(node));

  return (
    <Panel title={text.nav.createVm}>
      <form className="form-grid" onSubmit={onCreate}>
        <label>
          {text.createVm.node}
          <select name="node_id" required>
            {selectableNodes.map((node) => (
              <option key={node.id} value={node.id}>
                {node.name} ({formatNodeCapacitySummary(node, text)}, {nodeCreateVmAdmissionLabel(node)})
              </option>
            ))}
          </select>
        </label>
        {nodes.length > 0 && selectableNodes.length === 0 ? (
          <div className="wide-field muted">
            {text.createVm.noReadyNodes}
          </div>
        ) : null}
        {nodes.some((node) => !isCreateVmNodeSelectable(node)) ? (
          <div className="wide-field muted">
            {text.createVm.unreadyNodes}{" "}
            {nodes
              .filter((node) => !isCreateVmNodeSelectable(node))
              .map((node) => `${node.name} (${nodeCreateVmAdmissionLabel(node)})`)
              .join(", ")}
          </div>
        ) : null}
        <label>
          {text.createVm.ipPool}
          <select name="ip_pool_id">
            <option value="">{text.createVm.noReservation}</option>
            {ipPools.map((pool) => (
              <option key={pool.id} value={pool.id}>
                {pool.name} ({pool.allocated_count})
              </option>
            ))}
          </select>
        </label>
        <label>
          {text.createVm.plan}
          <select name="plan_id">
            <option value="">{text.createVm.customSizing}</option>
            {enabledPlans.map((plan) => (
              <option key={plan.id} value={plan.id}>
                {plan.name} ({plan.cpu_cores} CPU / {plan.memory_mb} MB / {plan.disk_gb} GB)
              </option>
            ))}
          </select>
        </label>
        <label>
          {text.common.name}
          <input name="name" pattern="[A-Za-z0-9_-]{1,64}" required />
        </label>
        <label>
          {text.createVm.image}
          <select name="image" required>
            {enabledImages.map((image) => (
              <option key={image.id} value={image.file_name}>
                {image.name} ({image.file_name})
              </option>
            ))}
          </select>
        </label>
        <label className="wide-field">
          {text.createVm.sshPublicKey}
          <textarea name="ssh_public_key" placeholder="ssh-ed25519 AAAA..." rows={3} />
        </label>
        <label>
          {text.nodes.cpu}
          <input defaultValue={1} min={1} name="cpu_cores" type="number" />
        </label>
        <label>
          {text.plans.memoryMb}
          <input defaultValue={512} min={128} name="memory_mb" type="number" />
        </label>
        <label>
          {text.plans.diskGb}
          <input defaultValue={10} min={1} name="disk_gb" type="number" />
        </label>
        <button className="primary" disabled={selectableNodes.length === 0 || enabledImages.length === 0} type="submit">
          <Play aria-hidden="true" />
          {text.createVm.createTask}
        </button>
      </form>
    </Panel>
  );
}

function Vms({
  onAction,
  text,
  vms,
}: {
  onAction: (action: VmAction, vm: VmDto) => void;
  text: I18nText;
  vms: VmDto[];
}) {
  return (
    <Panel title={text.nav.vms}>
      {vms.length === 0 ? (
        <div className="empty">{text.vms.empty}</div>
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
                <span>{vm.assigned_ip ?? text.vms.noIp}</span>
                <span>{vm.ssh_public_key ? text.vms.sshKey : text.vms.noSshKey}</span>
                <div className="actions">
                  {actions.map((action) => {
                    const Icon = vmActionIcons[action];
                    const label = text.vmActions[action];
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
                    <span className="muted">{hasActiveTask ? text.vms.taskActive : text.vms.noActions}</span>
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
  text,
}: {
  nodes: NodeSummary[];
  onSelect?: (nodeId: string) => void;
  selectedNodeId?: string;
  text: I18nText;
}) {
  const table = useReactTable({
    columns: nodeColumns,
    data: nodes,
    getCoreRowModel: getCoreRowModel(),
    getRowId: (node) => node.id,
  });

  if (nodes.length === 0) return <div className="empty">{text.nodes.empty}</div>;
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
  text,
}: {
  onSelect?: (taskId: string) => void;
  selectedTaskId?: string;
  tasks: TaskDto[];
  text: I18nText;
}) {
  const table = useReactTable({
    columns: taskColumns,
    data: tasks,
    getCoreRowModel: getCoreRowModel(),
    getRowId: (task) => task.id,
  });

  if (tasks.length === 0) return <div className="empty">{text.tasks.empty}</div>;
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

function titleFor(view: View, text: I18nText) {
  return text.nav[view];
}

function vmActionConfirmationText(action: VmAction, vm: VmDto, text: I18nText) {
  switch (action) {
    case "start-vm":
      return text.confirm.vmActionMessage["start-vm"](vm.name);
    case "stop-vm":
      return text.confirm.vmActionMessage["stop-vm"](vm.name);
    case "reboot-vm":
      return text.confirm.vmActionMessage["reboot-vm"](vm.name);
    case "reinstall-vm":
      return text.confirm.vmActionMessage["reinstall-vm"](vm.name, vm.id);
    case "delete-vm":
      return text.confirm.vmActionMessage["delete-vm"](vm.name, vm.id);
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

function formatCapacity(used: number, total: number, text: I18nText) {
  if (total <= 0) return text.common.notReported;
  return `${formatBytes(used)} / ${formatBytes(total)}`;
}

function formatNodeCapacitySummary(node: NodeSummary, text?: I18nText) {
  const cpuUnknown = text?.nodes.cpuUnknown ?? "CPU unknown";
  const memoryUnknown = text?.nodes.memoryUnknown ?? "memory unknown";
  const diskUnknown = text?.nodes.diskUnknown ?? "disk unknown";
  const cpu = node.cpu_total > 0 ? `${node.committed_cpu}/${node.cpu_total} CPU` : cpuUnknown;
  const memoryTotalMb = Math.floor(node.memory_total / 1024 / 1024);
  const memory =
    memoryTotalMb > 0 ? `${node.committed_memory_mb}/${memoryTotalMb} MB` : memoryUnknown;
  const diskTotalGb = Math.floor(node.disk_total / 1024 / 1024 / 1024);
  const disk = diskTotalGb > 0 ? `${node.committed_disk_gb}/${diskTotalGb} GB` : diskUnknown;
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
