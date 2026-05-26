export const supportedLanguages = [
  { code: "zh-CN", label: "简体中文" },
  { code: "en-US", label: "English" },
] as const;

export type Language = (typeof supportedLanguages)[number]["code"];

export const defaultLanguage: Language = "zh-CN";
export const languageStorageKey = "vps-panel-language";

const zhCN = {
  language: {
    label: "语言",
    ariaLabel: "选择界面语言",
  },
  app: {
    brand: "VPS Master",
    eyebrow: "MVP 运维",
    generateAgentCommand: "生成 Agent 命令",
    signOut: "退出登录",
  },
  nav: {
    dashboard: "仪表盘",
    nodes: "节点",
    plans: "套餐",
    images: "镜像",
    ipPools: "IP 池",
    install: "安装 Agent",
    tasks: "任务",
    audit: "审计",
    createVm: "创建 VM",
    vms: "VM",
  },
  login: {
    title: "管理员登录",
    username: "用户名",
    password: "密码",
    submit: "登录",
    failed: "登录失败",
  },
  common: {
    cancel: "取消",
    copy: "复制",
    enabled: "已启用",
    disabled: "已禁用",
    enable: "启用",
    disable: "禁用",
    generate: "生成",
    name: "名称",
    status: "状态",
    never: "从未",
    notReported: "未上报",
    notRegistered: "未注册",
    requestFailed: "请求失败",
  },
  dashboard: {
    overview: "概览",
    runningVms: "运行中 VM",
    pendingTasks: "待处理任务",
    recentTasks: "最近任务",
    nodeHealth: "节点健康",
  },
  nodes: {
    add: "添加节点",
    detail: "节点详情",
    scheduling: "调度",
    agent: "Agent",
    libvirt: "Libvirt",
    lastSeen: "最后在线",
    cpu: "CPU",
    memory: "内存",
    dataDisk: "数据盘",
    managedVms: "托管 VM",
    hostChecks: "主机检查",
    nodeId: "节点 ID",
    empty: "暂无注册节点。",
    select: "选择一个节点。",
    enableScheduling: "启用调度",
    disableScheduling: "停用调度",
    schedulingEnabledValue: "调度中",
    schedulingMaintenanceValue: "维护中",
    coresCommitted: (committed: number, total: number) => `${committed} / ${total} 核已分配`,
    mbCommitted: (value: number) => `${value} MB 已分配`,
    gbCommitted: (value: number) => `${value} GB 已分配`,
    cpuUnknown: "CPU 未知",
    memoryUnknown: "内存未知",
    diskUnknown: "磁盘未知",
  },
  ipPools: {
    cidr: "CIDR",
    gateway: "网关",
    add: "添加 IP 池",
    empty: "暂无 IP 池。",
    allocated: (count: number) => `${count} 个已分配`,
  },
  images: {
    fileName: "文件名",
    add: "添加镜像",
    empty: "暂无镜像。",
    titleEnabled: "启用镜像",
    titleDisabled: "停用镜像",
  },
  plans: {
    slug: "标识",
    memoryMb: "内存 MB",
    diskGb: "磁盘 GB",
    add: "添加套餐",
    empty: "暂无套餐。",
    titleEnabled: "启用套餐",
    titleDisabled: "停用套餐",
    sizing: (cpu: number, memory: number, disk: number) => `${cpu} CPU / ${memory} MB / ${disk} GB`,
  },
  install: {
    targetAriaLabel: "Agent 安装目标节点",
    selectNode: "选择节点",
    commandTitle: "安装命令",
    noCommand: "尚未生成命令。",
  },
  tasks: {
    title: "任务",
    logs: "任务日志",
    empty: "暂无任务。",
    select: "选择一个任务。",
    noLogs: "该任务暂无日志。",
    failed: (message: string) => `任务失败：${message}`,
    cancel: "取消任务",
    retry: "重试任务",
  },
  audit: {
    title: "审计日志",
    empty: "暂无审计记录。",
    noRequest: "无请求",
    noNode: "无节点",
    noTask: "无任务",
  },
  createVm: {
    node: "节点",
    noReadyNodes: "没有节点同时满足在线、心跳新鲜、可调度且可创建任务。",
    unreadyNodes: "未就绪节点：",
    ipPool: "IP 池",
    noReservation: "不预留",
    plan: "套餐",
    customSizing: "自定义规格",
    image: "镜像",
    sshPublicKey: "SSH 公钥",
    createTask: "创建任务",
  },
  vms: {
    empty: "暂无 VM 记录。",
    noIp: "无 IP",
    sshKey: "SSH 密钥",
    noSshKey: "无 SSH 密钥",
    taskActive: "任务进行中",
    noActions: "无操作",
  },
  vmActions: {
    "start-vm": "启动",
    "stop-vm": "停止",
    "reboot-vm": "重启",
    "reinstall-vm": "重装",
    "delete-vm": "删除",
  },
  confirm: {
    enableScheduling: (name: string) => `${name} 将在变更后接收新的 VM 任务。`,
    disableScheduling: (name: string) => `${name} 将停止接收新的 VM 任务，已分配任务不受影响。`,
    imageAvailability: (name: string, nextEnabled: boolean) =>
      `${name} 将${nextEnabled ? "可用于新的 VM 任务" : "不再用于后续创建或重装任务"}。`,
    planAvailability: (name: string, nextEnabled: boolean) =>
      `${name} 将${nextEnabled ? "可用于新的 VM 任务" : "不再用于后续 VM 任务"}。`,
    generateInstall: (name: string) =>
      `为 ${name} 生成一次性 bootstrap token？它会显示在安装命令中，并在 1 小时后过期。`,
    createVm: (name: string, node: string, cpu: number, memory: number, disk: number) =>
      `将 ${name} 的 create_vm 任务加入队列，目标节点 ${node}，${cpu} CPU、${memory} MB 内存、${disk} GB 磁盘。`,
    vmActionTitle: (label: string) => `${label} VM`,
    vmActionMessage: {
      "start-vm": (name: string) => `启动 VM ${name}？`,
      "stop-vm": (name: string) => `停止 VM ${name}？这可能会中断正在运行的工作负载。`,
      "reboot-vm": (name: string) => `重启 VM ${name}？这可能会中断正在运行的工作负载。`,
      "reinstall-vm": (name: string, id: string) => `重装 VM ${name}？这会替换客户机磁盘，并可能清除 ${id} 内的数据。`,
      "delete-vm": (name: string, id: string) => `删除 VM ${name}？这会排队删除 ${id} 的 libvirt 域和托管磁盘。`,
    },
    cancelTask: (kind: string) => `取消 ${kind} 任务？这只适用于主机工作开始前。`,
    retryTask: (kind: string) => `重试 ${kind} 任务？这会基于终止任务的 payload 排入一个新任务。`,
  },
};

const enUS: typeof zhCN = {
  language: {
    label: "Language",
    ariaLabel: "Choose interface language",
  },
  app: {
    brand: "VPS Master",
    eyebrow: "MVP Operations",
    generateAgentCommand: "Generate Agent Command",
    signOut: "Sign out",
  },
  nav: {
    dashboard: "Dashboard",
    nodes: "Nodes",
    plans: "Plans",
    images: "Images",
    ipPools: "IP Pools",
    install: "Install Agent",
    tasks: "Tasks",
    audit: "Audit",
    createVm: "Create VM",
    vms: "VMs",
  },
  login: {
    title: "Admin Login",
    username: "Username",
    password: "Password",
    submit: "Sign in",
    failed: "login failed",
  },
  common: {
    cancel: "Cancel",
    copy: "Copy",
    enabled: "enabled",
    disabled: "disabled",
    enable: "Enable",
    disable: "Disable",
    generate: "Generate",
    name: "Name",
    status: "Status",
    never: "never",
    notReported: "not reported",
    notRegistered: "not registered",
    requestFailed: "request failed",
  },
  dashboard: {
    overview: "Overview",
    runningVms: "Running VMs",
    pendingTasks: "Pending Tasks",
    recentTasks: "Recent Tasks",
    nodeHealth: "Node Health",
  },
  nodes: {
    add: "Add Node",
    detail: "Node Detail",
    scheduling: "Scheduling",
    agent: "Agent",
    libvirt: "Libvirt",
    lastSeen: "Last Seen",
    cpu: "CPU",
    memory: "Memory",
    dataDisk: "Data Disk",
    managedVms: "Managed VMs",
    hostChecks: "Host Checks",
    nodeId: "Node ID",
    empty: "No registered nodes.",
    select: "Select a node.",
    enableScheduling: "Enable Scheduling",
    disableScheduling: "Disable Scheduling",
    schedulingEnabledValue: "scheduling",
    schedulingMaintenanceValue: "maintenance",
    coresCommitted: (committed: number, total: number) => `${committed} / ${total} cores committed`,
    mbCommitted: (value: number) => `${value} MB committed`,
    gbCommitted: (value: number) => `${value} GB committed`,
    cpuUnknown: "CPU unknown",
    memoryUnknown: "memory unknown",
    diskUnknown: "disk unknown",
  },
  ipPools: {
    cidr: "CIDR",
    gateway: "Gateway",
    add: "Add Pool",
    empty: "No IP pools yet.",
    allocated: (count: number) => `${count} allocated`,
  },
  images: {
    fileName: "File Name",
    add: "Add Image",
    empty: "No images registered.",
    titleEnabled: "Enable Image",
    titleDisabled: "Disable Image",
  },
  plans: {
    slug: "Slug",
    memoryMb: "Memory MB",
    diskGb: "Disk GB",
    add: "Add Plan",
    empty: "No plans configured.",
    titleEnabled: "Enable Plan",
    titleDisabled: "Disable Plan",
    sizing: (cpu: number, memory: number, disk: number) => `${cpu} CPU / ${memory} MB / ${disk} GB`,
  },
  install: {
    targetAriaLabel: "Agent install target node",
    selectNode: "Select node",
    commandTitle: "Install Command",
    noCommand: "No command generated.",
  },
  tasks: {
    title: "Tasks",
    logs: "Task Logs",
    empty: "No tasks yet.",
    select: "Select a task.",
    noLogs: "No logs for this task.",
    failed: (message: string) => `Task failed: ${message}`,
    cancel: "Cancel Task",
    retry: "Retry Task",
  },
  audit: {
    title: "Audit Logs",
    empty: "No audit entries yet.",
    noRequest: "no request",
    noNode: "no node",
    noTask: "no task",
  },
  createVm: {
    node: "Node",
    noReadyNodes: "No node is online, heartbeating, schedulable, and available for create tasks.",
    unreadyNodes: "Unready nodes:",
    ipPool: "IP Pool",
    noReservation: "No reservation",
    plan: "Plan",
    customSizing: "Custom sizing",
    image: "Image",
    sshPublicKey: "SSH Public Key",
    createTask: "Create Task",
  },
  vms: {
    empty: "No VM records yet.",
    noIp: "no ip",
    sshKey: "ssh key",
    noSshKey: "no ssh key",
    taskActive: "Task active",
    noActions: "No actions",
  },
  vmActions: {
    "start-vm": "Start",
    "stop-vm": "Stop",
    "reboot-vm": "Reboot",
    "reinstall-vm": "Reinstall",
    "delete-vm": "Delete",
  },
  confirm: {
    enableScheduling: (name: string) => `${name} will accept newly assigned VM tasks after this change.`,
    disableScheduling: (name: string) => `${name} will stop receiving new VM tasks. Already assigned work is unchanged.`,
    imageAvailability: (name: string, nextEnabled: boolean) =>
      `${name} will ${nextEnabled ? "be available for new VM tasks" : "stop being available for future create or reinstall tasks"}.`,
    planAvailability: (name: string, nextEnabled: boolean) =>
      `${name} will ${nextEnabled ? "be available for new VM tasks" : "stop being available for future VM tasks"}.`,
    generateInstall: (name: string) =>
      `Generate a one-time bootstrap token for ${name}? It will be shown in the install command and expires in 1 hour.`,
    createVm: (name: string, node: string, cpu: number, memory: number, disk: number) =>
      `Queue create_vm for ${name} on ${node} with ${cpu} CPU, ${memory} MB memory, and ${disk} GB disk.`,
    vmActionTitle: (label: string) => `${label} VM`,
    vmActionMessage: {
      "start-vm": (name: string) => `Start VM ${name}?`,
      "stop-vm": (name: string) => `Stop VM ${name}? This can interrupt running workloads.`,
      "reboot-vm": (name: string) => `Reboot VM ${name}? This can interrupt running workloads.`,
      "reinstall-vm": (name: string, id: string) =>
        `Reinstall VM ${name}? This replaces the guest disk and can destroy data inside ${id}.`,
      "delete-vm": (name: string, id: string) =>
        `Delete VM ${name}? This schedules libvirt domain and managed disk removal for ${id}.`,
    },
    cancelTask: (kind: string) => `Cancel ${kind} task? This only applies before host work starts.`,
    retryTask: (kind: string) => `Retry ${kind} task? This queues a new task from the terminal task payload.`,
  },
};

export const translations = {
  "zh-CN": zhCN,
  "en-US": enUS,
};

export type I18nText = typeof zhCN;

export function isLanguage(value: string | null): value is Language {
  return supportedLanguages.some((option) => option.code === value);
}

export function readStoredLanguage(storage = browserStorage()): Language {
  const stored = storage?.getItem(languageStorageKey) ?? null;
  return isLanguage(stored) ? stored : defaultLanguage;
}

export function writeStoredLanguage(language: Language, storage = browserStorage()) {
  storage?.setItem(languageStorageKey, language);
}

function browserStorage(): Pick<Storage, "getItem" | "setItem"> | null {
  if (typeof window === "undefined") {
    return null;
  }
  return window.localStorage;
}
