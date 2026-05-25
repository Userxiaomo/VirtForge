# VPS Platform Design

本文档描述 Rust 版商业化 VPS 切机平台的当前设计。当前实现已经覆盖 master MVP、agent MVP、frontend MVP、libvirt 执行层和部署闭环脚本；最终验收仍需要在真实 KVM Linux 宿主机上运行完整 smoke 流程来证明从安装 agent 到创建小 VPS 的端到端路径。

## 目标

- 一台 master 管理多台宿主机节点。
- agent 运行在宿主机上，主动连接 master，避免暴露 agent 端口。
- master 负责面板 API、节点、套餐、IP 池、任务、状态、日志和审计。
- agent 负责本机 KVM/libvirt 操作。
- master 不保存宿主机 root SSH 密码，也不通过 SSH 直接执行切机命令。

## 组件

### master

Rust 服务，使用 axum、tokio、sqlx、PostgreSQL 和 tracing。master 当前包含：

- `src/main.rs`：进程入口、配置加载、数据库迁移和 HTTP 服务启动。
- `src/config.rs`：环境变量配置、HTTPS URL、token hash、请求体大小、限流和安装器下载路径校验。
- `src/http/`：HTTP 路由入口，覆盖 admin API、agent 注册/心跳/任务通道、安装脚本下载和 agent 二进制下载。
- `src/auth/`：管理员 bearer token 校验、Argon2 hash、agent 请求签名认证和基础角色边界；MVP 先实现管理员。
- `src/nodes/`：节点、一次性 bootstrap token、agent credential hash、安装命令、心跳和容量/调度状态。
- `src/tasks/`：PostgreSQL 任务表队列、任务状态机、任务日志、取消、重试和 VM 操作任务。
- `src/audit/`：管理员和 agent 关键动作审计日志，包含请求 ID 和结构化详情。
- `src/images/`、`src/ipam/`、`src/plans/`、`src/vms/`：镜像目录、IP 池、套餐约束和 VM 资源归属 read model。

### agent

Rust 服务，建议 systemd 裸机运行。agent 通过 HTTPS 主动访问 master，不暴露宿主机端口。agent 当前包含：

- `src/main.rs`：进程入口、配置加载、bootstrap 注册、doctor 检查和服务循环。
- `src/config.rs`：读取 `/etc/vps-agent/agent.toml`，校验 master URL、本地 secret 文件、受控目录、bootstrap token 与长期 credential 的互斥关系，并保存 0600 配置。
- `src/client/`：master HTTPS 客户端、请求签名、超时、禁止重定向和可选 CA / client identity 配置。
- `src/heartbeat.rs`：采集资源和 libvirt host checks，上报心跳，拉取任务，提交任务日志和终态。
- `src/tasks/`：本地任务归属、状态和 payload 校验；先校验再进入 mock 或 libvirt executor。
- `src/libvirt/`、`src/network/`、`src/resources.rs`：KVM/libvirt preflight、qcow2、cloud-init、domain XML、VM 生命周期操作和资源采集。
- `src/security.rs`、`src/redaction.rs`：安全文件名、受控路径、路径穿越和日志脱敏工具。

### shared

共享 Rust crate，放 master 与 agent 之间稳定的数据契约。它相当于 C# 解决方案里的共享 DTO/contract 项目，master 和 agent 都依赖它，避免两边各自手写 JSON 形状。

- ID 类型：`NodeId`、`TaskId`、`VmId`。
- 任务状态机：`pending`、`assigned`、`running`、`succeeded`、`failed`、`canceled`。
- 任务类型：创建、开机、关机、重启、重装、删除 VM。
- DTO：注册、心跳、任务等 API payload。
- MVP 输入校验：VM 名称、镜像名、CPU、内存、磁盘。

这里类似 C# 里的共享 DTO 项目。Rust 中用 `serde` 控制 JSON 序列化，用 `Result<T, E>` 显式表达校验失败，而不是依赖运行时异常。

### Rust quality boundary

The workspace keeps dead-code warnings enabled for normal builds. Crate-wide
`#![allow(dead_code)]` is not allowed because it can hide obsolete placeholders
while the master/agent boundary is still evolving. Future-facing items need
either a concrete use in the MVP path or a narrow, documented exception, similar
to keeping C# analyzers enabled and suppressing only one intentional diagnostic
with a reason.

### frontend

Next.js + TypeScript 面板，不做营销页，第一屏就是可操作控制台。frontend 当前覆盖：

- 登录页和 HttpOnly、SameSite=strict、生产 Secure cookie 会话。
- Dashboard、节点列表、节点详情、节点调度开关和 host check 展示。
- agent 安装命令生成，并只在局部 React state 展示一次 bootstrap token。
- 套餐、镜像、IP 池、任务、审计日志和 VM read model。
- 创建 VM 表单，节点 readiness 筛选和服务端错误提示。
- VM 开机、关机、重启、重装、删除操作按钮；危险操作使用面板内确认弹窗。
- TanStack Query 管理 read model 刷新，TanStack Table 管理节点和任务表格结构。

## 通信模型

MVP 采用 agent 主动连接 master：

1. 管理员在 master 面板创建节点并生成一次性 bootstrap token。
2. master 生成安装命令，命令绑定 `node_id`、短期过期时间和一次性 token。
3. 用户 SSH 到宿主机，人工执行安装命令。
4. agent 使用 bootstrap token 向 master 注册。
5. master 验证 token 后立即作废，返回长期 agent credential。
6. agent 将 credential 写入本地 0600 配置；在 Unix 上该配置必须是真实普通文件，不能是 symlink。
7. agent 后续用认证 HTTPS 请求上报心跳、拉取任务、提交日志和结果。

后续可从 HTTPS 轮询升级到 WebSocket 或 gRPC streaming，但认证模型不变。

## 任务状态机

任务从 master 创建后进入：

1. `pending`：已创建，等待 agent 拉取或派发。
2. `assigned`：已分配给节点。
3. `running`：agent 正在执行。
4. `succeeded`：执行成功。
5. `failed`：执行失败，需记录错误。
6. `canceled`：管理员取消。

Master atomically claims pending work with `FOR UPDATE SKIP LOCKED` and immediately moves the row to `assigned`. The assignment update and `task.assigned` audit event are committed in the same transaction, so an audit write failure rolls the claim back instead of leaving work assigned without an audit trail. Agent-reported transitions are intentionally narrow: `assigned` can move to `running`, `failed`, or `canceled`; `running` can move to `succeeded`, `failed`, or `canceled`; terminal states cannot move backward. Status updates are written with the validated current status in the `WHERE` clause, so a concurrent cancellation or terminal update returns a conflict instead of being overwritten. This is the same shape as a C# background worker claiming a row in a transaction before starting work, then saving with an expected status or row-version predicate before allowing explicit forward status changes.

Administrators can cancel only tasks that have not started host work yet: `pending` or `assigned`. The cancel path first validates the current status, then updates the row with that same status as an optimistic concurrency predicate. If the task moves while cancellation is being processed, master returns a conflict instead of overwriting a newer `running` or terminal state. A successful cancel moves the task to `canceled`, writes an audit event, and applies the same VM/IP cleanup rules as agent-reported cancellation in one database transaction. If the audit write or resource cleanup cannot be persisted, master rolls back the cancel instead of splitting task history from VM/IP ownership. `running` tasks are not admin-cancelable in the MVP because the agent does not yet have cooperative interruption for libvirt/qemu-img operations; those tasks must finish as `succeeded`, `failed`, or be reported `canceled` by the agent itself. Finished tasks cannot be canceled again.

Administrators can also retry `failed` or `canceled` tasks. Retry creates a new `pending` task with the original typed payload, records `task.retry` in audit, and keeps the old task immutable for history. Before inserting the retry row, master rechecks the current VM lifecycle against the task kind and revalidates create/reinstall images against the enabled image catalog, so a stale terminal task cannot bypass current resource state. The retry task insert, retry-to-VM inventory update, and audit write are committed together; for `create_vm` tasks with an IP pool, the fresh IP reservation and allocation-to-task attachment are part of that same transaction. This is the same shape as a C# job table where retry appends a new job row linked by audit detail rather than mutating a terminal job back to pending.

Master only creates VM tasks for nodes that have completed agent registration and therefore have a stored `credential_hash`. A node record plus bootstrap token is not enough to receive work. This keeps the intended flow explicit: create node, install/register agent, then queue VM tasks.

所有状态变化都要写审计日志。审计日志至少记录发起人、节点、任务类型、时间、结果和失败原因。

## Rust 设计选择

- `Result<T, E>`：类似 C# 中返回 `OneOf<T, Error>` 或 `Result<T>`，调用方必须处理成功/失败。
- `trait`：agent libvirt 执行层已经用小的命令执行 trait 隔离真实 `tokio::process::Command` 和测试替身，类似 C# interface；业务层仍避免为了未来扩展提前堆抽象。
- async/await：Rust 的 async 类似 C# `Task`，但 Future 默认惰性，只有被 `.await` 或运行时调度后才执行。
- ownership：配置、DTO 这类小对象优先用显式 clone 或移动，先保证生命周期直观，不追求高级写法。

## 阶段边界

当前阶段边界：

- 本地开发和 CI 风格验证可以证明 Rust workspace、master、agent、shared、frontend、部署脚本和安全扫描都能通过自动化检查。
- mock executor smoke 可以证明 master-agent 注册、心跳、任务和审计闭环。
- real-host smoke 脚本可以在 KVM Linux 宿主机上证明 libvirt 创建、操作和清理真实 VM。
- 总目标只有在真实 KVM 宿主机运行完整 `scripts/kvm-host-smoke.sh` 并成功创建/验证小 VPS 后才算完成。

## 第二阶段 master MVP

第二阶段的 master 后端使用 PostgreSQL 作为事实来源和 MVP 任务队列：

- `nodes`：节点基础信息、agent credential hash、版本和最后心跳时间。
- `bootstrap_tokens`：一次性注册 token hash、过期时间和使用时间。当前实现把 token 过期时间限制在 24 小时以内，避免安装命令里的 bootstrap secret 变成长期注册凭据。
- `tasks`：任务类型、payload、状态和目标节点。
- `task_logs`：保存 agent 上报的任务日志和失败摘要诊断，日志内容先经过长度、控制字符和敏感信息边界处理。
- `audit_logs`：记录管理员和 agent 关键动作。

当前实现的 API 按使用者分组如下：

- Health/download：`GET /healthz`、`GET /scripts/install-agent.sh`、`GET /downloads/vps-agent`。
- 管理员会话和审计：`POST /api/admin/session`、`GET /api/admin/audit-logs`。
- 节点：`GET /api/admin/nodes`、`POST /api/admin/nodes`、`POST /api/admin/nodes/:node_id/bootstrap-tokens`、`POST /api/admin/nodes/:node_id/scheduling`。
- 套餐、IP 池、镜像：`GET/POST /api/admin/plans`、`POST /api/admin/plans/:plan_id/enabled`、`GET/POST /api/admin/ip-pools`、`GET/POST /api/admin/images`、`POST /api/admin/images/:image_id/enabled`。
- agent 通道：`POST /api/agent/register`、`POST /api/agent/heartbeat`、`POST /api/agent/tasks/poll`、`POST /api/agent/tasks/:task_id/status`、`POST /api/agent/tasks/:task_id/logs`。
- 任务：`GET /api/admin/tasks`、`POST /api/admin/tasks/create-vm`、`POST /api/admin/tasks/start-vm`、`POST /api/admin/tasks/stop-vm`、`POST /api/admin/tasks/reboot-vm`、`POST /api/admin/tasks/reinstall-vm`、`POST /api/admin/tasks/delete-vm`、`GET /api/admin/tasks/:task_id`、`POST /api/admin/tasks/:task_id/cancel`、`POST /api/admin/tasks/:task_id/retry`、`GET /api/admin/tasks/:task_id/logs`。
- VM read model：`GET /api/admin/vms`。

admin API 使用 bearer token，master 只保存 Argon2 hash。agent API 使用注册后下发的长期 credential，master 同样只保存 hash。这个模型和 C# 中常见的“数据库保存 PasswordHash，登录时验证明文输入”相同，只是这里 token 也是同样处理。
VM task creation requires that registration has already produced the node credential hash. In C# terms, the node must have completed its provisioning state before a background job can be queued for it.

Node scheduling is intentionally separate from heartbeat status. A registered node may be online and still have `scheduling_enabled = false` while an operator performs maintenance. Master rejects new VM tasks for disabled nodes and the agent poll path does not assign still-pending tasks while the flag is disabled. Task insertion and task assignment both lock the target `nodes` row before trusting `scheduling_enabled`, so a maintenance toggle serializes with new work admission in the same way a C# service would guard a queue insert with a `SELECT ... FOR UPDATE` inside its `DbTransaction`. The scheduling flag update and `node.scheduling_update` audit row commit together; if audit cannot be written, the maintenance toggle rolls back instead of silently changing task admission. Tasks that were already assigned or running keep the normal task-state rules, so an operator can cancel assigned work or wait for running libvirt work to finish. Heartbeat telemetry remains visible throughout maintenance. The frontend mirrors that boundary by showing maintenance state in the node list and excluding maintenance nodes from the Create VM form.

Master also performs a conservative capacity admission check before inserting `create_vm` tasks or retrying failed/canceled create tasks. If a node has reported nonzero CPU, memory, or disk totals, master compares the requested VM size plus currently committed non-deleted VM inventory on that node against those totals. The check runs inside the task transaction after locking the target `nodes` row with `FOR UPDATE`, so same-node create/retry requests serialize before a task row and VM inventory row are committed. Nodes that have not reported capacity yet keep the early MVP behavior and are not blocked by unknown values. In C# terms, this is an application-service guard inside the same `DbTransaction` that appends the background job row; the agent still performs the final host-level checks before touching libvirt.

Create-VM admission now also requires a registered node to be `online`, to have a non-empty `agent_version`, and to have a fresh heartbeat recorded in `last_seen_at`. Master treats a heartbeat older than two hours as stale before inserting a new create task or retrying a create task. The threshold is intentionally two times the accepted maximum agent heartbeat interval (`3600s`), so a deployment using a long but valid interval can miss one loop without immediately blocking while a long-dead node cannot continue receiving new provisioning jobs. If the latest heartbeat explicitly reports `libvirt_status = "unavailable"`, master rejects new create tasks before inserting a background job. `libvirt_status = "not_checked"` remains admissible for the mock-executor MVP loop, while the real-host smoke harness applies the stricter `available` requirement before proving KVM work. In C# terms, master checks the worker read model before queueing a provisioning job, but keeps the fake worker path available for integration tests.

The node list API exposes the same committed CPU, memory, and disk totals used by the admission check, and the frontend shows those values next to reported host capacity. This gives operators a simple view of master-side allocation pressure without introducing a full scheduler or time-series capacity planner yet.

第三阶段 agent MVP 在第二阶段基础上继续增加：

- 首次启动时读取带 `bootstrap_token` 的 TOML 配置。
- 使用一次性 token 调用 `/api/agent/register`。
- 将返回的长期 credential 写回配置文件，并清除 bootstrap token。
- 注册接口的 credential 成功响应、malformed JSON、限流等注册边界错误都会带 no-store 响应头，避免 bootstrap/credential 交换边界被 HTTP 缓存保留。
- agent 加载配置时会校验本地 `bootstrap_token` / `credential` 形状，并拒绝同时包含两者的配置，避免手工编辑或失败恢复时把旧 bootstrap token 长期留在本机 secret 文件里。master 在注册和签名请求入口也执行同样的 secret 形状检查，先拒绝空值、超过 256 字节、空白、路径分隔符、控制字符和 shell 敏感字符，再进入 Argon2/HMAC 验证。
- 以长期 credential 调用 `/api/agent/heartbeat`、`/api/agent/tasks/poll`、`/api/agent/tasks/:task_id/status` 和 `/api/agent/tasks/:task_id/logs`。
- mock executor 先把拉到的任务标为 `running` 再标为 `succeeded`，用于验证 master-agent 闭环，不接触真实 libvirt。
- agent 在写任务开始日志、标记 `running`、或选择 mock/libvirt executor 之前先验证任务归属和 payload。任务的 `node_id` 必须匹配本机配置，然后才会校验 `reinstall_vm` 名称、镜像名、SSH 公钥或磁盘大小。这样即使开发环境使用 mock executor，也不会把错误节点或非法 payload 的任务当作有效任务处理。

## 第四阶段 KVM/libvirt 执行层

第四阶段开始在 agent 内加入真实 libvirt executor，但默认配置仍是 `mock`，防止开发机或测试环境误操作宿主机。只有配置为 `executor.mode = "libvirt"` 时，agent 才会调用宿主机命令。

当前 libvirt executor 覆盖：

- 检查 `/dev/kvm` 存在且是 KVM 字符设备，并区分缺失路径和错误文件类型。
- 检查 `virsh --connect qemu:///system version`。
- 检查 `qemu-img --version`。
- 检查 cloud-init seed ISO 工具，优先 `cloud-localds`；如果它不存在或预检命令失败，则回退到 `genisoimage`，两者都不可运行时拒绝真实宿主机 smoke。
- 为 VM 创建受控目录：`<data_dir>/vms/<vm_id>/`。libvirt executor 在构造 VM 路径前会先确认 `data_dir` 本身已经存在、是真实目录、不是符号链接。如果固定父目录 `<data_dir>/vms` 已存在，或该 VM 根路径已存在，都必须是真实目录，不能是普通文件、符号链接或解析到 `data_dir` 外。缺失目录会逐级创建，并在每一级创建后复查元数据，避免一次递归创建时穿过后来出现的符号链接父目录。
- 校验 `image_dir` 是真实目录而不是符号链接，base image 是真实普通文件而不是符号链接，解析路径仍位于 `image_dir` 内，并且 `data_dir`、`image_dir` 和 base image 都位于真实 agent `data_dir` 边界下。
- 在创建或重装 VM 前运行 `qemu-img info --output=json <base-image>`，要求 base image 的实际格式是 `qcow2`。
- 使用 `qemu-img create -f qcow2 -F qcow2 -b <base> <disk> <size>` 创建 qcow2。
- 生成 cloud-init `user-data`、`meta-data`；如果 create task 带有完整 IPAM 元数据，还会生成 cloud-init v2 `network-config`。
- 如果本地 artifact 准备阶段在 `virsh define` 之前失败，agent 只清理自己已知的 `disk.qcow2`、`seed.iso`、`network-config`、`domain.xml`、`user-data` 和 `meta-data`，然后用非递归 `remove_dir` 删除空 VM 目录；如果 `virsh define` 失败，agent 会先查询 `virsh domstate`，只有 libvirt 返回明确的 `Domain not found` / `failed to get domain` 类诊断时才清理本地 artifact；如果 `virsh start` 在 define 之后失败，agent 会先读取 `virsh domstate` 并要求 `shut off`，再 `undefine` domain 和清理本地 artifact。任何未知文件、符号链接、非普通文件、已存在或仍在运行的 domain、无法确认 domain 不存在、或 undefine 失败都会保留现场给人工检查。
- 重装 VM 时，agent 会在 `virsh destroy` 前先检查固定 `.reinstalling` 文件是否残留；如果残留则直接失败，不会先关闭 domain。确认 domain 已 `shut off` 后，agent 再把替换磁盘、seed ISO、`user-data` 和 `meta-data` 写到同一受控 VM 目录下的固定 `.reinstalling` 文件；如果 VM 已有 `network-config`，重装生成 seed ISO 时会继续包含它。提交替换前会先验证所有临时源文件和所有 live 目标文件，任何后续目标不安全都会让整个提交失败，不会先替换前面的磁盘。只有这些替换 artifact 全部准备成功且目标仍安全后，才替换正在使用的 `disk.qcow2` 和 `seed.iso`。重启 domain 后还会继续读取 `virsh domstate`，只有重新报告 `running` 才把重装任务视为成功。如果 seed ISO 生成等准备步骤失败，agent 只删除临时 `.reinstalling` 文件，保留原磁盘和原 seed ISO，避免一次失败重装破坏现有 VM 数据。
- 使用 `cloud-localds <seed.iso> <user-data> <meta-data> [network-config]` 生成 seed ISO；如果宿主机只提供 `genisoimage`，agent 使用 `genisoimage -output <seed.iso> -volid cidata -joliet -rock <user-data> <meta-data> [network-config]` 回退。
- 生成 libvirt domain XML。
- 使用 `virsh define` 和 `virsh start` 创建并启动 VM。
- 使用 `virsh shutdown`、`reboot`、`destroy`、`undefine` 操作 VM。`stop_vm` 不把 `virsh shutdown` 的返回当成最终完成；因为 shutdown 是异步关机请求，agent 会继续轮询 `virsh domstate`，只有状态变成 `shut off` 后才把任务上报为成功。`create_vm`、`start_vm` 和 `reboot_vm` 同样会在命令返回后读取 `domstate`，只有 domain 报告 `running` 后才成功，避免控制面板比宿主机真实状态更早显示任务完成。
- 创建、开机、关机、重启、重装和删除都会先校验 VM 目录仍是 agent 受控目录下的真实目录，不接受普通文件、符号链接或逃逸到受控目录外的路径；创建新 VM 时，固定输出路径 `disk.qcow2`、`seed.iso`、`network-config`、`domain.xml`、`user-data` 和 `meta-data` 必须不存在，避免覆盖或跟随预先放置的文件和符号链接；对已有 VM 操作还会解析 agent 创建时保存的 `domain.xml`。受控 qcow2 磁盘、seed ISO 和 domain XML 必须都是真实普通文件，不接受符号链接；只有真实 XML 元素中的 domain name、VM UUID、受控 qcow2 磁盘路径和 seed ISO 路径匹配时，才允许调用 `virsh`；注释或无关文本里的伪造片段不会通过校验。
- 重装 VM 会在归属校验后关闭 domain、替换 qcow2 磁盘、重新生成 cloud-init `user-data` / `meta-data` 和 seed ISO，并重新启动 domain。重写 `user-data` / `meta-data` 前会再次确认目标是 VM 目录内的真实普通文件或缺失路径；已有 `network-config` 会作为受控普通文件复用到新的 seed ISO。符号链接、目录、特殊文件、残留 `.reinstalling` 文件或逃逸到 `data_dir` 外的路径会在破坏性 host 命令前失败。`virsh destroy` 后会读取 `virsh domstate` 并要求状态为 `shut off`，避免运行中的 domain 磁盘被替换。替换 artifact 会先完整写入 `.reinstalling` 文件，并在提交替换前统一校验源和目标，准备成功后才替换 live 文件；准备失败只清理临时文件，不删除旧 `disk.qcow2` 和 `seed.iso`。`virsh start` 返回后还会等待 domain 重新进入 `running`，再上报重装成功。
- 删除 VM 时只删除 agent 已知 artifact：`disk.qcow2`、`seed.iso`、`network-config`、`domain.xml`、`user-data`、`meta-data`。如果 VM 目录里出现未知文件、目录、特殊文件或符号链接，agent 会在 `virsh destroy` / `undefine` 前失败，要求人工检查，而不是递归删除整个目录。`virsh destroy` 允许失败以兼容已经关机的 domain，但 agent 会随后读取 `virsh domstate` 并要求状态为 `shut off`；`virsh undefine` 也必须成功后才会删除本地受控文件，避免 libvirt 仍持有或运行 domain 时磁盘目录先被清理。

真实公网 IP、NAT、IPv6 和完整镜像分发还没有完成。当前网络先使用 libvirt network，例如 `default`，并要求 `virsh net-info` 返回的 `Bridge:` 与配置的 bridge（默认 `virbr0`）一致，且对应 bridge 接口存在。

## 第五阶段 frontend MVP

frontend 使用 Next.js App Router。浏览器端不直接保存 master admin token，也不写入 localStorage。登录时用户提交 admin token 到 Next route handler，route handler 验证 master 后写入 HttpOnly、SameSite=strict cookie；除显式 `NODE_ENV=development` 外，cookie 默认设置 Secure，类似 C# ASP.NET Core 里把生产级认证 cookie 的 `SecurePolicy` 设为只允许 HTTPS。后续 `/api/*` 前端代理从 cookie 读取 token，再以 `Authorization: Bearer` 调用 master。面板共享数据（节点、套餐、镜像、IP 池、任务、审计、VM）由 TanStack Query 缓存，命令型操作成功后统一失效该查询并重新读取，类似 C# 前端里用一个 typed client + cache invalidation 管理 DTO read model。一次性 bootstrap token 仍只保存在局部 React state 中，不写入 React Query cache，避免把只展示一次的敏感值留在通用数据缓存里；操作员切换安装页面的目标节点时，面板会清空已经生成的安装命令，避免把旧 node_id/token 组合按新的节点上下文复制。创建 VM、VM 电源/重装/删除操作和任务重试都会使用 master 返回的 `TaskDto.id` 自动切到任务视图并选中该任务，避免操作员在任务列表里手动查找刚创建的后台工作。只要任务列表里仍有 `pending`、`assigned` 或 `running` 任务，面板会周期性刷新任务 read model；选中的活动任务日志也会自动刷新，任务进入 `succeeded`、`failed` 或 `canceled` 后停止轮询。VM read model 由 master 把 `vms.last_task_id` 与 `tasks.status` 连接后返回 `last_task_status`；如果某台 VM 已经被活动任务保留，即使 lifecycle 仍是 `running` 或 `stopped`，面板也隐藏新的 VM 操作按钮并显示活动任务提示。这避免浏览器依赖有分页上限的最近任务列表来重建资源锁状态。节点表和任务表现在使用 TanStack Table 的 row/cell 模型渲染，在不改变当前紧凑运维 UI 的前提下，为后续排序、过滤、分页和列配置留下清晰扩展点。

Authenticated panel mutations now share a small action wrapper around the existing typed API calls. The wrapper clears the previous operator message, lets successful commands keep their normal TanStack Query invalidation or task-focus flow, and renders rejected BFF/master errors as a visible panel alert instead of leaving them as unhandled browser-console failures. In C# terms, this is the UI equivalent of a shared command handler that catches an application-service exception and updates a view-model error field.

当前面板覆盖：

- 登录页。
- Dashboard。
- 节点列表。
- 节点详情。
- 生成 agent 安装命令。
- 任务列表。
- 创建 VM 表单。
- VM 列表和开机、关机、重启、重装、删除确认按钮。

VM 操作按钮通过 Next.js 代理调用 master 任务 API。所有 VM 动作、任务取消/重试以及启用/禁用镜像和套餐都会先经过面板内确认弹窗，再创建任务或提交 catalog 变更；运行中只显示关机、重启、重装和删除，已停止或错误状态显示启动、重装和删除，创建中、删除中、已删除或 `last_task_status` 是活动状态时不显示动作。关机和重启提示会中断 workload，重装提示 guest disk 可能被替换并造成数据丢失，删除提示会调度 libvirt domain 和受控磁盘目录移除。确认弹窗打开后先聚焦 Cancel，支持 Escape 取消，并在关闭后把焦点还给触发按钮，方便键盘操作员恢复上下文。确认弹窗是 UI 防误触边界，master 的 VM 归属检查、任务状态机和 agent 的受控路径校验仍然是后端权威边界。后续可以把确认弹窗升级为二次输入或按动作要求输入 VM 名称。
Master creates node rows and their `node.create` audit events in one database
transaction. If audit persistence fails, the node insert rolls back, so later
bootstrap tokens and VM tasks cannot attach to an unaudited node. In C# terms,
the application service owns one `DbTransaction` for the aggregate row and its
audit record.

# VM Inventory Update

The MVP now keeps VM inventory separately from task history.

- `tasks` is the command/job table. It records what was requested and how the agent reported the task lifecycle.
- `vms` is the resource ownership table. It records `vm_id`, `node_id`, VM name, image, sizing, lifecycle status, and the last task that touched the VM.
- Creating a `create_vm` task also creates a `vms` row in `provisioning` status.

The master enforces the VM lifecycle and active-task reservation on the server
side, not just in the frontend. While a VM is `provisioning`, or while
`last_task_id` points at a `pending`, `assigned`, or `running` task, no new
`start_vm`, `stop_vm`, `reboot_vm`, `reinstall_vm`, or `delete_vm` task may be
queued for it. Once a VM reaches `running`, `stopped`, or `error` without an
active reserved task, the allowed actions match the panel buttons. In C# terms,
this belongs in the application service that owns the resource aggregate, not
in the UI.
- VM action APIs validate that the target `vm_id` belongs to the submitted `node_id` before creating start/stop/reboot/reinstall/delete tasks.
- Reinstall requests may optionally submit a new image. Master validates the image against the enabled image catalog, then puts the trusted VM name and disk size from inventory into the task payload. If no image is submitted, master reuses the VM inventory image.
- When a reinstall or delete task is queued, master immediately moves the VM
  row to `provisioning` or `deleting` before the agent polls. This narrows the
  window for overlapping destructive or disk-replacement operations; later
  agent status updates still provide the authoritative task outcome.
- Admin-created VM action tasks commit the task row, audit row, and any
  VM reservation or immediate inventory transition in one transaction. Every
  accepted VM action updates `vms.last_task_id` to the new task. Reinstall/delete
  also get an immediate inventory transition because they replace or remove
  managed disk state; start/stop/reboot keep the current lifecycle until the
  agent reports a terminal result. While `last_task_id` points at a `pending`,
  `assigned`, or `running` task, master rejects follow-up VM actions and retries
  for that VM. The later agent status update is also transactional.
- For action, reinstall, and retry task admission, master repeats the lifecycle
  check inside the same PostgreSQL transaction that inserts the new task and
  locks the `vms` row with `FOR UPDATE OF v`. This is like a C# service method
  doing the aggregate guard and job insert inside one `DbTransaction` with a row
  lock, so concurrent operators cannot reserve the same VM from stale reads.
- When the agent reports task status, master updates the task row, VM status for create/start/stop/reboot/reinstall/delete outcomes, status-update audit row, and failed-task summary log in one database transaction. If a task outcome maps to a VM lifecycle change, the VM update must affect exactly one inventory row; otherwise master rejects and rolls back the status update instead of silently accepting a task result whose VM ownership record was not changed.

This is intentionally similar to keeping a C# domain entity table separate from a background job table. A job can fail, retry, or be audited; the VM record is still the authoritative ownership boundary used by the panel and future deletion checks.

# Agent Installer Update

Master now serves the MVP installer script at `/scripts/install-agent.sh`, matching the install command returned by the bootstrap-token API.

The installer is deliberately simple:

- generated command passes `master_url`, `node_id`, and one-time `bootstrap_token`;
  before the command is formatted, master revalidates the generated token with
  the same agent-secret shape used by registration: 1-256 ASCII letters,
  numbers, dots, dashes, or underscores. In C# terms, the command builder checks
  the DTO value again before interpolating it into a shell command string;
- generated command downloads `install-agent.sh` to a temporary file before it
  invokes `sudo bash --`, registers an `EXIT` trap to remove that temporary
  file, and therefore cannot mask a failed HTTPS curl download with an empty
  installer process;
- installer fails closed on missing values for value-taking flags, then validates HTTPS base URLs with real hosts, no port-only authorities, ports in the usable `1..=65535` range, closed IPv6 brackets, and no embedded credentials/query/fragment/whitespace/control characters, canonical 8-4-4-4-12 hex UUID node IDs, safe ASCII bootstrap token text, TOML-safe config values, and libvirt network/bridge identifiers before installing host dependencies, downloading `vps-agent`, writing `/etc/vps-agent/agent.toml` through a same-directory temporary file and rename with `0600`, revalidating the final config path after the atomic rename, running `vps-agent doctor`, and installing a systemd service. A pre-existing symlinked config directory, symlinked `agent.toml`, existing config with group/other permissions, unowned existing config file, or unowned/loose pre-existing config/data/image directory is rejected before the bootstrap token is written. If doctor fails, the installer suppresses doctor output and prints only a rerun hint, because the config still contains the one-time bootstrap token at that point. Service enable/start wraps each `systemctl` step, checks its exit code, and suppresses raw `systemctl` output so host service diagnostics cannot leak copied config values;
- installer validates controlled storage directories before creating them: `--data-dir` and libvirt `--image-dir` must be absolute Linux paths, cannot be `/`, cannot contain parent traversal, control characters, or shell-sensitive characters, `--image-dir` must remain under `--data-dir`, and symlinked, non-installer-owned, or loose pre-existing final managed-directory paths are rejected instead of followed or silently tightened;
- installer can verify the downloaded agent binary with optional
  `--agent-sha256 <expected-sha256-hex>` before installing it, giving operators
  a simple release-artifact pin in addition to HTTPS transport. The binary
  download uses curl with `-q`, `--proto '=https'`, and no redirect-following
  flags so host-local `.curlrc` settings cannot weaken TLS or add redirects.
  A verified install persists the normalized non-secret hash to
  `/etc/vps-agent/agent.sha256` through a same-directory temporary file and
  rename, then revalidates the final hash path before returning, rejecting
  symlinks, non-regular files, and group/world-writable proof paths. An install
  without `--agent-sha256` removes any stale hash proof so later final smoke runs
  cannot inherit evidence from an older binary.
  Before the download starts, the installer also rejects a pre-existing
  symlinked or non-regular `/usr/local/bin/vps-agent` target and a symlinked or
  non-directory binary directory. After download and checksum verification, it
  writes the executable mode to a same-directory temporary file, revalidates the
  binary directory and final binary path, and commits with `mv -fT`, so a
  final-path or parent-directory symlink swapped in during download fails before
  root-owned binary replacement;
- before writing the systemd unit, the installer rejects a pre-existing
  symlinked or non-regular `/etc/systemd/system/vps-agent.service` target and a
  systemd service directory that is not owned by the installer UID (root in
  production) or is group/world-writable, then rechecks the directory
  and final path immediately before renaming the same-directory temporary unit
  into place, so root-owned service installation cannot be redirected to an
  arbitrary file or written through a loose unit directory;
- if a private master CA is configured on master, the generated command uses it
  for the first installer-script download with
  `curl -q -fsS --proto '=https' --cacert` and no redirect following; the
  installer then uses the same value from `--ca-cert-path` for the
  non-redirecting HTTPS-only agent-binary curl download and writes that path
  into `agent.toml`. The CA trust-anchor file must be a real non-symlink
  regular file and must not be writable by group or other users. Omitting
  `--agent-sha256` explicitly skips checksum validation while still allowing
  explicit `--agent-url` installs, but it also clears the persisted hash proof;
- when `MASTER_AGENT_BINARY_PATH` points at a readable regular artifact, master
  includes that artifact's SHA-256 in generated install commands and serves it
  from `/downloads/vps-agent`. Symlinks, directories, and special files are
  rejected before hashing or download response generation. This keeps the
  panel's copy/paste command aligned with the binary actually served by
  `/downloads/vps-agent`;
- when `MASTER_INSTALLER_CA_CERT_PATH` is configured, master validates it as a
  clean target-host Linux file path and includes it in both the outer
  non-redirecting `curl -q -fsS --proto '=https' --cacert` and the installer's
  `--ca-cert-path` argument. When `MASTER_INSTALLER_CLIENT_IDENTITY_PATH` is
  configured, master validates it and includes the corresponding installer
  argument in generated commands;
- installer only bootstraps the agent; the initial bootstrap config and the later credential save both use a same-directory temporary file and rename, and the agent itself preflights the credential save target before registration, performs registration, and replaces the bootstrap token with a long-term credential while refusing to read or write that local secret through a symlinked or loose config path.

This keeps master out of the host SSH path. The operator still logs into the host manually, runs the generated command, and the agent takes over from there.

# Docker Deployment Update

The deploy layer now has a concrete MVP topology:

- `master/Dockerfile` builds the Rust master service as a release binary.
- `frontend/Dockerfile` builds and serves the Next.js panel.
- `deploy/docker-compose.yml` runs PostgreSQL, master, frontend, and Caddy.
- `deploy/caddy/Caddyfile` terminates public TLS and routes agent/script traffic to master while routing browser panel traffic to frontend.

The base compose file intentionally requires operators to provide `DOMAIN`,
`MASTER_PUBLIC_BASE_URL`, `MASTER_INSTALLER_BASE_URL`, `POSTGRES_PASSWORD`, and
`MASTER_ADMIN_TOKEN_HASH`. This keeps deployment configuration explicit: the
control plane should not start with localhost install URLs, a default database
password, or disabled admin authentication. Master validates the admin hash at
startup as a PHC password-hash string, and it applies the same PHC check to
`MASTER_READONLY_TOKEN_HASH` when the optional read-only token is configured.
This keeps a plaintext secret accidentally pasted into a hash variable from
becoming a delayed runtime auth failure.

The single-domain Caddyfile follows the same rule by using `{$DOMAIN}` without
a default value. This makes the reverse proxy fail closed when no public domain
is configured, instead of quietly serving the production route set as a
localhost site. Compose mounts the Caddyfile as an explicit read-only bind with
`create_host_path: false`, so a mistyped or missing TLS proxy config path fails
instead of letting Docker create a placeholder host directory.

Both Caddy deployment modes add basic HTTPS response hardening at the reverse
proxy: HSTS for one year, `X-Content-Type-Options: nosniff`,
`X-Frame-Options: DENY`, and `Referrer-Policy: no-referrer`. Keeping this at
the proxy avoids duplicating the same headers in the Rust API and the Next.js
panel while still covering admin APIs, agent APIs, installer script downloads,
and agent binary downloads.

The `scripts/build-agent-binary.ps1` helper builds the Linux agent artifact in
Docker without shell command strings. It invokes `cargo build` and the later
`install -m 0755` export as separate Docker argument arrays, so operator-side
artifact generation follows the same no-`sh -c` boundary as the agent executor.
After export it computes the file's SHA-256 with `Get-FileHash` and includes
`agent_sha256` in the JSON output, giving operators a direct value to compare
with the checksum master embeds in generated install commands.
The `scripts/build-docker-images.ps1` helper follows the same boundary for
master/frontend Docker image builds: each `docker build` call is assembled as a
PowerShell argument array instead of a shell-composed command string.
The `deploy/docker-compose.agent-artifact.yml` override requires
`MASTER_AGENT_BINARY_HOST_PATH` explicitly and mounts that selected host file at
`/opt/releases/vps-agent` through a read-only bind mount with
`create_host_path: false`; master then validates the mounted path as a regular
file before computing the installer checksum or serving `/downloads/vps-agent`.
The compose PostgreSQL, master, frontend, and Caddy healthchecks use Docker's
`CMD` exec form for the same reason: readiness probes do not need shell strings.
The master curl healthcheck passes `-q` before other curl arguments so container
local curl config files cannot change the probe. Master is considered ready
only after `/healthz` responds, frontend waits for that healthy master and then
exposes its own `127.0.0.1:3000` probe, and Caddy waits for both before serving
public traffic. Caddy also runs `caddy validate --config /etc/caddy/Caddyfile`
as its own healthcheck, which catches a bad mounted Caddyfile or missing
required domain environment before operators treat the public TLS boundary as
ready. This is the deployment analogue of a C# host using readiness checks
before putting a reverse proxy in front of dependent services.

The base compose file also pins `security_opt: no-new-privileges:true` on
PostgreSQL, master, frontend, and Caddy. Master and frontend already run as
non-root users; this additional runtime flag prevents setuid or file-capability
transitions from becoming a privilege-escalation path if one of those
control-plane processes is compromised. PostgreSQL is included because the
database is part of the trusted control-plane state boundary, and the flag still
allows the image to drop to its `postgres` runtime user. Caddy is included
because it is the public HTTPS entrypoint.
Master and frontend also set `cap_drop: [ALL]` because they only need ordinary
TCP listeners on high ports and outbound database/API connections. Caddy keeps
its capability profile separate because it owns the low-port public listener.
PostgreSQL, master, frontend, and Caddy set `pids_limit: 256` so a fork/thread
storm stays inside a bounded container budget. PostgreSQL still needs
database-specific connection tuning, but the compose PID limit is the outer
deployment quota for the database container.
Those same stateless/public services also set `read_only: true` and mount
`/tmp` as `rw,noexec,nosuid,size=64m`. Master and frontend should not write to
their image filesystems at runtime, and Caddy's durable ACME/config state stays
in explicit named volumes, so this keeps deployment writes intentional.
The compose services also use bounded Docker `json-file` logging
(`max-size: "10m"`, `max-file: "5"`). In C# terms, this is the deployment-side
log sink quota; it does not replace application redaction, but it keeps noisy
container logs from exhausting the control-plane disk.
All base compose services use `restart: unless-stopped`. Docker will restart
PostgreSQL, master, frontend, and Caddy after an unexpected container exit or
daemon restart, while an explicit operator stop remains respected.

The important design choice is that browser admin APIs still pass through frontend route handlers so the admin token can stay in an HttpOnly cookie. Agent APIs bypass frontend and go to master directly because they use `X-Agent-Credential`.

For the mTLS deployment path, `deploy/docker-compose.mtls.yml` and `deploy/caddy/Caddyfile.mtls.example` split the public entrypoints:

- `PANEL_DOMAIN` is the browser and installer/download domain.
- `AGENT_DOMAIN` is the agent-only API domain and requires Caddy client certificate verification.
- `MASTER_PUBLIC_BASE_URL` points at `AGENT_DOMAIN`, while `MASTER_INSTALLER_BASE_URL` points at `PANEL_DOMAIN`.
- `PANEL_DOMAIN` explicitly returns 404 for `/api/agent/*` before frontend fallback, so the agent API cannot be reached on the non-client-authenticated browser/installer domain by accident.
- `AGENT_CLIENT_CA_PATH` must be supplied explicitly so Caddy cannot start the
  mTLS entrypoint without a client CA bundle.
- The mTLS override mounts both the example Caddyfile and `AGENT_CLIENT_CA_PATH`
  as explicit read-only binds with `create_host_path: false`, so the agent API
  TLS boundary cannot accidentally start with an auto-created config or CA path.

That split matters because a new host must be able to download the installer before the running agent is configured with a client identity. Once installed, the agent can call the dedicated mTLS API domain with its configured `client_identity_path`. Deployments that use a standard host path can set `MASTER_INSTALLER_CLIENT_IDENTITY_PATH` so generated commands include that path instead of requiring operators to edit the command manually. The installer still requires that client identity PEM to be a root-owned, owner-only, non-symlink regular file on the target host before it writes the path into `agent.toml`.

# Agent Request Signing Update

Agent requests after registration now use HMAC signing in addition to the long-term credential.

- The agent serializes the JSON body, computes `SHA256(body)`, then signs method, path, body hash, timestamp, and nonce.
- Master parses the body only to identify `node_id`, rejects malformed credential text, verifies the submitted credential against the stored Argon2 hash, verifies the HMAC, and records the nonce before applying business changes.
- Signed agent endpoints use an explicit request JSON parser after reading the raw body for HMAC verification. Malformed request JSON returns `400 Bad Request`, while JSON failures from persisted database payloads still surface as internal errors. In C# terms, this keeps controller model-binding failures separate from corrupted server-side state.
- The nonce table gives the control plane replay protection without needing Redis in the MVP.

For a C# analogy, this is similar to using a shared secret to sign a canonical `HttpRequestMessage` while still storing only a password/token hash in the database.

# Task Log Visibility Update

Task execution logs are now part of the admin API and panel workflow.

- Agents append task logs through the authenticated signed endpoint `POST /api/agent/tasks/:task_id/logs`.
- Master accepts public agent log appends only when the task is `assigned` or
  `running`. When an agent reports `failed` with an `error_message`, master
  writes the redacted failure summary inside the same transaction as the task
  status, VM lifecycle update, and audit row instead of relying on a later
  terminal-state log append.
- After executor work has completed successfully, the agent treats result-log
  append failures as best-effort diagnostics and still reports the terminal
  `succeeded` status. The status transition and audit entry are the authority
  for task completion; a transient log-write failure must not leave completed
  host work stuck as `running`.
- Terminal task status updates (`succeeded`, `failed`, or agent-reported
  `canceled`) are retried a small number of times after host work or worker-side
  validation finishes. The first `running` transition remains strict: it is the
  control-plane acknowledgment before the agent starts host work. This is the
  same distinction as a C# background worker requiring the job row to enter
  `running` before executing, then retrying the final completion write if the
  database/API briefly rejects it.
- Master stores task logs in `task_logs` and limits admin reads to the selected task through `GET /api/admin/tasks/:task_id/logs`.
- Agent task-log appends and their `task.log.append` audit rows are committed
  in one database transaction. If the audit write fails, the diagnostic log is
  rolled back too, so support evidence cannot exist without accountability
  metadata.
- When an agent reports a failed task with `error_message`, master stores a redacted copy on the `tasks` row so the task list and detail API show the failure reason without requiring the operator to open the full log stream.
- The frontend Tasks view lets an administrator select a task and inspect its log stream below the task table.
- Logs are ordered by creation time and capped in the API response so the panel stays predictable.
- Master can also serve the agent installer binary from `GET /downloads/vps-agent` when `MASTER_AGENT_BINARY_PATH` is configured. That artifact must be a readable non-symlink regular file no larger than 128 MiB before master hashes it for generated install commands or serves it to hosts.
- Master validates task log messages before persistence: they must be 1-4096
  bytes and cannot contain NUL bytes. This keeps malformed agent diagnostics out
  of PostgreSQL `text` rows and returns a control-plane validation error instead
  of a database/internal error.
- Agent log appends are inserted through an active-task predicate, so a task
  that moves out of `assigned` / `running` between validation and insert returns
  a conflict instead of receiving a late log line.
- Before persistence, master redacts task logs and failed-task `error_message`
  values, then escapes non-line ASCII control bytes such as terminal color
  escapes as `\xNN`. Newlines, carriage returns, and tabs remain available for
  readable multiline diagnostics. The normalized value must still fit inside the
  same 4096-byte storage limit, so escaping cannot expand a small hostile input
  into an oversized persisted diagnostic.

This keeps the Rust model close to a C# background-job system: `tasks` is the job state table with current status and last failure reason, `task_logs` is the per-job append-only diagnostic stream, and `audit_logs` remains the accountability trail for who initiated or reported important actions.

The agent redacts common secret key/value shapes, URL userinfo credentials, PEM private-key blocks, agent authentication header values such as `X-Agent-Credential` / `X-Agent-Signature`, and whole-line `Cookie` / `Set-Cookie` header values before sending executor logs or failure summaries to master. Master applies its own redaction again before persistence, including the same agent-authentication and cookie-header treatment, so the channel has defense in depth rather than relying on one side to be perfect.

# IP Pool MVP Update

Master now has a small IPv4-only IPAM boundary for the MVP.

- Admins can create IP pools with `POST /api/admin/ip-pools` and list them with `GET /api/admin/ip-pools`.
- IP pool creation and its `ip_pool.create` audit event are committed in one database transaction.
- VM creation may include `ip_pool_id`. Master reserves the next available usable IPv4 address from that pool and writes the assigned address into both the task payload and VM inventory.
- Callers cannot choose `assigned_ip`, `assigned_ip_prefix`, or `assigned_gateway_ip` directly; master clears caller-supplied values and only assigns from a known pool.
- Master commits the IP reservation, task row, allocation-to-task link, VM inventory row, and create audit row in one transaction. The task is not visible to agent polling until the VM/IPAM ownership records are also visible.
- Master requires the allocation-to-task update to affect exactly one row. A missing active allocation is a conflict, and multiple touched rows are an internal consistency fault, similar to checking `rowsAffected == 1` after a C# `UPDATE`.
- The shared task validator treats the assigned IP metadata as untrusted task payload text: either all three fields are absent, or `assigned_ip`, `assigned_ip_prefix`, and `assigned_gateway_ip` must describe valid IPv4 host networking before an agent executor can run. The prefix must be `/16` through `/30`, the assigned address and gateway must be different host addresses, and both addresses must be in the same network.
- When complete IPAM metadata is present, the libvirt executor writes cloud-init v2 `network-config` so the guest receives the static IPv4 address, prefix, and default gateway through the seed ISO.
- Failed or canceled `create_vm` tasks release the reservation. Successful `delete_vm` tasks release the reservation and clear the VM inventory address.
- The frontend exposes an IP Pools view and an optional IP pool selector in the Create VM form.

This is intentionally not full public-network provisioning yet: bridge selection, NAT/public routing, IPv6, and host firewall automation still need later design. The current boundary gives the control plane a resource ownership model and passes a typed static IPv4 contract to the host worker, similar to a C# service reserving inventory in one table before a background worker applies the host-side configuration.

# Image Catalog Update

Master keeps a first-class image catalog for base qcow2 file names.

- `images` stores operator-defined display name, safe file name, and enabled state.
- `GET /api/admin/images` lists images for the panel and read-only operators.
- `POST /api/admin/images` creates images and requires admin privileges.
- Image creation and its `image.create` audit event are committed in one database transaction.
- `POST /api/admin/images/{image_id}/enabled` toggles whether an image can be used for new VM creation or replacement-image reinstall tasks.
- Image enable/disable changes and their `image.enabled_update` audit event are committed in one database transaction.
- Disabling an image does not modify existing VMs that already reference that image.
- The safe file-name rule rejects separators, parent traversal, leading dots, trailing dots, and consecutive dots at the master boundary, matching the agent-side path safety rule before a task reaches libvirt.

This mirrors the plan catalog lifecycle. In C# terms, the image record is a catalog entity, while create/reinstall commands only carry a safe catalog reference that the application service validates before persisting a task.

# Plan Catalog Update

Master now has a first-class VPS plan catalog for commercial sizing.

- `plans` stores the operator-defined package name, slug, CPU cores, memory MB, disk GB, and enabled state.
- `GET /api/admin/plans` lists plans for the panel and read-only operators.
- `POST /api/admin/plans` creates plans and requires admin privileges.
- Plan creation and its `plan.create` audit event are committed in one database transaction.
- `POST /api/admin/plans/{plan_id}/enabled` toggles whether a plan can be used for new VM creation and requires admin privileges.
- Plan enable/disable changes and their `plan.enabled_update` audit event are committed in one database transaction.
- `create_vm` may include `plan_id`. When present, master loads the enabled plan inside the create transaction, holds a PostgreSQL `FOR SHARE` lock on that plan row, and overwrites the submitted CPU, memory, and disk values before creating the task and VM inventory row.
- `vms.plan_id` records which plan was used for the VM, while the task payload and VM row also store the concrete sizing that the agent will execute.

Disabling a plan prevents future `create_vm` requests from using it, but it does not change existing VMs. This keeps plan enforcement in master instead of trusting the browser. In C# terms, the plan is a catalog entity, and `CreateVmRequest` is normalized inside the same `DbTransaction` that persists the background task so catalog enable/disable cannot race the task decision.

# Agent Resource Heartbeat

The agent runs as a long-lived systemd service. On each loop iteration it sends heartbeat data, polls one pending task, executes it, and reports logs/status. The default interval is `heartbeat_interval_seconds = 30` in `agent.toml`; config validation accepts `1..=3600` seconds so a deployment typo cannot silently stretch heartbeats into multi-hour or multi-day gaps. `VPS_AGENT_RUN_ONCE=1` is reserved for local smoke tests so the process exits after a single iteration.

The MVP service keeps `User=root` so the libvirt executor can manage host VM
resources and so first registration can rewrite `/etc/vps-agent/agent.toml`.
The unit still narrows the process boundary with systemd sandboxing:
`NoNewPrivileges=true`, `ProtectSystem=strict`, writable paths limited to
`/etc/vps-agent` and `/var/lib/vps-agent`, private temp storage, home-directory
protection, clock and hostname protection, kernel/control-group protections,
native syscall architecture filtering, empty `CapabilityBoundingSet=` /
`AmbientCapabilities=`,
`RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK`,
`MemoryDenyWriteExecute=true`, `RestrictSUIDSGID=true`, `UMask=0077`, and a pinned
`PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` for host
tool lookup. In C# terms, this is the service-host equivalent of running a
Windows service under a powerful account but applying explicit service ACLs,
environment, and write boundaries around the directories it may mutate.
`MemoryDenyWriteExecute=true` is compatible with the Rust daemon and the
non-JIT libvirt/qemu/cloud-init tooling while removing a common exploit
primitive.
`RestrictSUIDSGID=true` prevents the daemon or child tools from staging new
setuid/setgid filesystem objects, which VM provisioning does not require.

Config load/save treats `agent.toml` and `client_identity_path` as local secret
files. On Unix they must be real non-symlink regular files owned by the agent
process user with owner-only permissions; this keeps registration credential
persistence from following a filesystem redirect or trusting a cross-user secret
path. The installer uses the same same-directory temporary file and rename
pattern for the initial bootstrap config. When registration saves the long-term
credential, the config parent directory is checked before and after directory
creation so a symlinked, non-agent-owned, or group/other-accessible
`/etc/vps-agent` path is rejected. Missing config directories are created
owner-only, a new config file is created with `0600` mode through a
same-directory temporary file and rename, and an existing config file must
already be owned by the agent process user with owner-only permissions before
the secret is written. The rename step means a config-file symlink swapped in
after validation is replaced as a path entry rather than followed. The only
exception is the local Docker smoke override
`VPS_AGENT_ALLOW_INSECURE_CONFIG_PERMS=1`, which relaxes mode-bit and owner-UID
checks only for the bind-mounted agent config file and directory, not for
`client_identity_path` private keys. Symlinked local secret files are still
rejected.
The local Docker smoke harness runs `vps-agent doctor` after registration, when
the temporary config contains the long-term credential. Its failure path reports
only the exit code and suppresses raw doctor output. This is the same defensive
shape as a C# integration test that avoids printing a connection string from a
failed options validator.
The same local harness redacts bounded Docker log tails before printing them on
startup timeout or top-level failure. It keeps normal log context but replaces
common token, credential, password, authorization, agent authentication header,
private-key, cookie, and URL-userinfo shapes with `[REDACTED]`, so the smoke
script is not relying on every lower layer to avoid secret-shaped diagnostics.

The agent fills the existing heartbeat resource fields before contacting master:

- `cpu_total`: logical CPU count reported by the operating system.
- `cpu_used`: `0` for the MVP because accurate CPU usage requires comparing two samples over a time window.
- `memory_total` and `memory_used`: Linux `/proc/meminfo` values in bytes, using `MemTotal - MemAvailable`.
- `disk_total` and `disk_used`: filesystem capacity for the configured `data_dir`, collected with `df -B1` only when `data_dir` already exists as a real directory and is not a symlink.
- `vm_count`: count of managed VM directories under a real `data_dir/vms` directory. Missing, non-directory, or symlinked storage roots report `0` instead of following redirected paths.

Master validates heartbeat metadata before storing it on the node row or audit detail. `agent_version` is limited to short semver-like ASCII text and cannot contain secret-bearing words, and `cpu_used`, `memory_used`, and `disk_used` cannot exceed their reported totals. In C# terms, this is the DTO validation layer rejecting impossible or audit-unsafe telemetry before persistence.

Master stores the latest values on the `nodes` row and also writes them into the heartbeat audit detail. The node row update and `agent.heartbeat` audit event commit in one database transaction, so the operational read model cannot advance without the matching signed telemetry audit trail. The node row is the current operational read model for the panel and future scheduling checks; audit detail preserves what a signed heartbeat reported at that point in time. A later capacity-planning phase can add a time-series table without changing the agent payload.

This mirrors a common C# service shape: the resource collector is a small service that returns a plain snapshot object, and the heartbeat client only maps that object into the API DTO. It also stays read-only: telemetry never creates the storage root just to make metrics work.

In `libvirt` mode, heartbeat now also carries structured host preflight checks. The agent reports `libvirt_status` plus a small `host_checks` array for controlled storage layout, `/dev/kvm` as a KVM character device, `virsh qemu:///system`, the configured active libvirt network whose `Bridge:` value matches the configured bridge, the configured bridge interface, `qemu-img`, and cloud-init ISO tooling. The storage check includes `data_dir`, `image_dir`, and any pre-existing fixed VM parent `data_dir/vms`, so the panel can surface a poisoned VM parent before a create task is queued. Master persists these fields on `nodes` and includes them in heartbeat audit detail so the panel can show why a node is not ready for real KVM work. This is intentionally a read model, similar to a C# health-check result table; task execution still performs the same checks immediately before running host commands.

The agent redacts common secret key/value shapes from failed libvirt host command stderr before it becomes an executor error, then redacts failed preflight diagnostics again before those messages become `host_checks` or local `check_host()` errors. It also redacts `host_checks` before building the heartbeat request and escapes non-line ASCII control bytes into visible `\xNN` text. That keeps diagnostics useful without treating health-check text as a trusted secret or terminal-control channel; master validation and audit redaction remain the server-side backstop, and master rejects control bytes if a malformed agent sends them anyway.

# Audit Visibility Update

Audit logs are now queryable from the admin plane and visible in the frontend.

- Master exposes `GET /api/admin/audit-logs`, returning the most recent 200 audit entries.
- The frontend has an Audit view with timestamp, actor role, action, result, node, and task columns.
- The smoke test verifies key lifecycle events are present: node creation, bootstrap token creation, IP pool creation, VM task creation, agent registration, and task status updates.

This is the audit read model for the MVP. In C# terms, `audit_logs` is the immutable-ish operational event table, while the API returns a simple DTO projection for support and compliance workflows.

# Admin Login Update

The frontend login screen now uses username/password fields.

Flow:

1. The browser posts `{ username, password }` to the same-origin Next.js route `POST /api/session`; token-only browser login payloads are rejected.
2. The Next.js route calls master `POST /api/admin/session`.
3. Master verifies `username` against `MASTER_ADMIN_USERNAME` and verifies `password` with the Argon2 hash stored in `MASTER_ADMIN_TOKEN_HASH`. The master binary defaults the username to `admin` only when the variable is unset for local runs, while production compose requires `MASTER_ADMIN_USERNAME` explicitly. Configured usernames must be 1-64 byte ASCII identifiers using only letters, numbers, dots, underscores, and dashes.
4. On success, the Next.js route stores the admin secret in an HttpOnly, SameSite=strict cookie with an eight-hour lifetime. The cookie is Secure unless `NODE_ENV=development` is set explicitly.
5. The direct master session response applies `Cache-Control: no-store, max-age=0`, `Pragma: no-cache`, and `Expires: 0` to login success, malformed JSON, rate-limit, and unauthorized results; the `/api/session` BFF route uses the same headers for login success, login failure, logout, and rejected mutation responses so session boundary responses are not intentionally retained by HTTP caches.
6. Later panel API calls stay same-origin. For state-changing routes, the React client adds `X-VPS-Panel-Request: same-origin`; the Next.js route rejects missing markers, cross-origin `Origin`, and browser fetch metadata other than `Sec-Fetch-Site: same-origin` or `none` before reading the cookie.
7. Next.js route handlers validate dynamic UUID path parameters before building internal master URLs, then forward accepted requests to master with `Authorization: Bearer <admin-secret>`.

Master applies a cheap admin-secret shape check before Argon2 verification for both direct bearer headers and browser login passwords: 1-256 visible ASCII characters, no whitespace, quotes, backslashes, or backticks. It also validates the configured admin username before the server starts, like validating a C# options object before dependency injection exposes it to controllers. The browser login path remains username/password shaped, but the password must be usable as the same bearer secret that the Next.js route handler forwards to master. This guard is the equivalent of a C# API filter rejecting malformed authorization values before calling a password hasher.

The unauthenticated master session endpoint also applies the global login rate
bucket and, when a reverse proxy sends `X-Forwarded-For`, an additional bucket
for the first hop only if it parses as an IP address. Malformed forwarded values
are ignored instead of becoming arbitrary in-memory bucket names. In C# terms,
this is the same kind of header normalization you would do before using proxy
metadata as a key in middleware.

This is deliberately close to a C# MVC/BFF pattern: browser code talks to the web app, the web app holds the server-side credential boundary, and the backend service still receives a bearer token. The panel mutation marker is similar to a small anti-forgery check around MVC controller actions. It is not a full multi-user identity system yet; that should come after the MVP control-plane loop is stable.

The BFF also validates its configured `MASTER_API_BASE_URL` before forwarding the admin secret to master. The value must be only an HTTP/HTTPS origin; explicit ports must be in `1..=65535`; paths, query strings, fragments, embedded credentials, whitespace, quotes, backslashes, and backticks are rejected. Plain HTTP is limited to loopback hosts, RFC1918 private IPv4 addresses, or single-label internal service names such as `master`; public hostnames and public IPs must use HTTPS. In C# terms, this is validating a typed `HttpClient.BaseAddress` before any controller action uses it to forward an authorization header. The BFF uses the same no-store response helper for proxied successes and for its own unauthorized, invalid path, invalid mutation marker, timeout, and upstream-failure JSON errors, so auth boundary failures are not left cacheable while normal successful responses are protected.

The BFF also bounds each server-side fetch to master with `MASTER_FETCH_TIMEOUT_MS`, defaulting to 30 seconds and accepting `1000..=300000` milliseconds. This covers the login verification call and proxied admin API calls, so a stalled master or reverse proxy cannot hold a Next.js route handler indefinitely while it carries the admin secret. The same fetch wrapper forces manual redirect handling, so the BFF does not automatically replay the cookie-derived bearer token to a `Location:` target. In C# terms, this is the same operational control as setting `HttpClient.Timeout` and disabling automatic redirects on the typed backend client; it does not replace authentication, CSRF, or URL validation.

When the BFF cannot obtain an HTTP response from master, it maps the failure to a fixed JSON gateway error instead of returning raw exception text. Timeout or abort failures become `504 {"error":"master request timed out"}`; other network failures become `502 {"error":"master unavailable"}`. This keeps outage behavior predictable for the panel and avoids echoing infrastructure details or operator values into browser-visible responses.

# Request ID Audit Boundary

Master attaches a request ID to audit events so operators can correlate API calls with task and audit history. Caller-provided `X-Request-Id` values are accepted only as short ASCII correlation IDs with no secret-bearing words such as `token`, `credential`, `password`, `secret`, or `private_key`. If the header is malformed or looks like it might contain secret material, master generates a fresh UUID instead of storing the caller value in `audit_logs` or echoing it back.

# VM SSH Public Key Update

VM creation now accepts an optional `ssh_public_key` field. Master validates that value as a single OpenSSH public key, stores it on the VM inventory row, and copies it into the `create_vm` task payload. Reinstall tasks reuse the trusted key from VM inventory, the same way they reuse the trusted VM name and disk size.

Agent does not accept passwords or private keys. When a key is present, the libvirt executor writes cloud-init `user-data` that creates a `vps` user with sudo access and the supplied authorized key. When no key is present, the minimal cloud-init payload is generated without adding a login user.

The C# analogy is a command DTO with an optional public field that is validated at the API boundary, then normalized into the persisted domain record before a background worker consumes it. The worker receives explicit data and does not reinterpret browser input.

# Real KVM Smoke Preflight Update

The real-host KVM smoke script now performs local executor preflight before it
contacts master or queues a task. It checks `/dev/kvm`, `virsh --connect
qemu:///system version`, `virsh --connect qemu:///system net-info
$LIBVIRT_NETWORK_NAME` with `Active: yes` and `Bridge:
$LIBVIRT_BRIDGE_NAME`, `qemu-img --version`, `qemu-img info --output=json
"${IMAGE_DIR}/${IMAGE_FILE}"` with `format=qcow2`, and cloud-init ISO tooling
(`cloud-localds` preferred, `genisoimage` accepted), then validates the managed
data/image directories as real directories with non-loose permissions, plus the base image path. This keeps the final acceptance
script closer to a C# deployment validation command: prove the host has the
required local dependencies before asking the control plane to schedule work.
If `virsh version`, `virsh net-info`, `qemu-img --version`, or `qemu-img info`
fails, the script discards the raw tool stdout/stderr and emits only bounded
preflight diagnostics, so host-local error text cannot leak token-like or
password-like values during preflight.
After create succeeds, the smoke script verifies the running libvirt domain and
parses the managed `domain.xml` to confirm the domain name and VM UUID match
the VM it just created. It also checks that the qcow2 path is the single
`device="disk"` source and the seed ISO path is the single `device="cdrom"`
source, and it rejects managed `domain.xml` files larger than 1 MiB before
parsing. This keeps the final acceptance check aligned with the agent's
host-side ownership guard. If the libvirt domain or state probe itself fails,
the script suppresses raw `virsh dominfo` / `virsh domstate` output and reports
only bounded domain-unavailable or unreadable-state diagnostics before any
artifact checks.
After cleanup delete, a failed `dominfo` probe counts as success only when the
hidden libvirt diagnostic matches a known missing-domain message such as
`Domain not found`; ambiguous failures fail closed with a bounded non-secret
message.
`PRECHECK_ONLY=1` exposes that validation as a non-mutating mode: it checks the
master health endpoint, rejects WSL before dependency checks, validates local
KVM/libvirt/qemu/cloud-init tooling, and checks base image path/format without
requiring `ADMIN_TOKEN`, creating catalog entries, or queueing VM tasks. Its
success JSON includes only non-secret diagnostics such as validated
URL/path/image inputs, selected libvirt network and bridge names, base image
format, CA-cert-present status, selected cloud-init ISO tool, and timeout
values; it does not echo admin tokens, node IDs, or host-local CA paths.
Smoke-script calls to master use `CURL_TIMEOUT_SECONDS` for both connect and
total request timeouts, so a bad URL or broken network path fails as a bounded
deployment check instead of blocking the operator indefinitely.
The script also rejects `POLL_SECONDS` values greater than `TIMEOUT_SECONDS`,
keeping the task wait loop's sleep interval inside the configured overall
deadline. The final sleep is capped to the remaining timeout, so polling stays
bounded even when `TIMEOUT_SECONDS` is not a multiple of `POLL_SECONDS`. The
same numeric validator compares bounded decimal text, so oversized digit strings
cannot bypass the local smoke-script range checks through shell arithmetic
overflow behavior.
For private-CA deployments, `MASTER_CA_CERT_PATH` mirrors the agent installer
trust path: the smoke script validates the local PEM path as a non-symlink
regular file and passes it to curl with `-q` and `--cacert` instead of weakening
TLS verification with local curl config files or `--insecure`.
The script also keeps its HTTP escape hatch local-only: `ALLOW_HTTP=1` can be
used only with loopback `MASTER_URL` hosts such as `localhost`, `127.0.0.1`, or
`[::1]`; final `FULL_LIFECYCLE_REQUIRED=1` acceptance rejects that escape hatch,
so real host lifecycle proof must use HTTPS. The same URL guard rejects
port-only authorities such as `https://:8443` and malformed bracketed IPv6
hosts, rejects unbracketed IPv6 literals, and requires numeric ports between 1 and 65535 before any
master API call is made. It also rejects literal or percent-encoded `.` / `..`
path segments, encoded path separators (`%2f` / `%5c`), and percent-encoded
ASCII controls in URL authorities or paths so URL normalization cannot move the health check or admin API base to a different route. The smoke validators reject any ASCII control
character in URL, path, and header-like inputs, including non-whitespace
controls that would not be visible in operator logs.
The script's `IMAGE_FILE` validation mirrors the image catalog and agent rules,
including rejection of leading dots, trailing dots, separators, and consecutive
dots, so real-host smoke runs fail locally before sending a catalog entry that
the control plane or agent will reject. Its `IMAGE_NAME` validation also mirrors
the master image catalog display-name rule: 1-80 ASCII letters, numbers, spaces,
dashes, or underscores.
The script passes the validated shell variables explicitly into its Python JSON
payload builders, so defaults assigned by the script are used the same way as
operator-provided environment values.
If `SSH_PUBLIC_KEY` is provided, the script validates it as a single OpenSSH
public key and includes it in the `create_vm` payload so the real smoke VM can
receive a cloud-init login key. Invalid private-key-like, multiline, quoted, or
unsupported-key values fail before any master task is created.
If `IP_POOL_ID` is provided, the script validates it as a UUID and includes it
in the `create_vm` payload. Alternatively, `IP_POOL_CIDR` plus
`IP_POOL_GATEWAY` lets the smoke run validate an IPv4 pool locally, reuse a
matching master pool, or create one with `IP_POOL_NAME` before queuing the VM.
The two modes are mutually exclusive. When a pool is selected, the create
response must return complete assigned IPv4 metadata. The script then verifies
the managed cloud-init `network-config` file contains the assigned
address/prefix and default gateway, so the real-host smoke path can cover the
IPAM-to-guest-bootstrap contract.
If `PLAN_ID` is provided, the script validates it as a UUID and includes it in
the `create_vm` payload. Alternatively, `PLAN_SLUG` lets the smoke run validate
a commercial plan locally, list master plans, reuse an enabled plan whose slug
and CPU/memory/disk sizing match the smoke request, or create one with
`PLAN_NAME` before queueing the VM. The two plan modes are mutually exclusive.
Disabled matching plans, existing slugs with different sizing, unsafe plan
names/slugs, and create responses that do not echo the requested
slug/spec/enabled state fail before the VM task is queued. Master still owns
final plan enforcement: when `plan_id` is present, master reloads the enabled
catalog row and normalizes CPU, memory, and disk before it persists the VM
task. In C# terms, the shell selects or creates a catalog entity for the smoke
run, while the application service remains the authority that applies the
catalog to the command DTO. After the create task is queued, the smoke script
requires the response `kind.plan_id` to match the selected plan before polling
or touching host state, and it includes that `plan_id` in the final smoke JSON
as catalog evidence.
When the requested `IMAGE_FILE` already exists in the master image catalog but
is disabled, the script uses the normal authenticated image enable endpoint
rather than attempting to create a duplicate catalog row.
It verifies that image create/re-enable responses contain the expected
`file_name` and `enabled=true` before it queues `create_vm`, so a failed catalog
transition does not turn into a later task failure.
For disabled existing images, the catalog `id` from the list response is also
validated as UUID text before the script builds the image-enable URL.
After queueing `create_vm`, the smoke script also validates the returned
`kind.vm_id` as UUID text before it waits for the task or uses that value in a
libvirt domain name or managed VM directory path. This keeps the shell verifier
close to the Rust `VmId` type boundary; in C# terms, it is the same idea as
calling `Guid.TryParse` on response data before using it to build host paths.
When the create response includes assigned IPv4 metadata, the smoke script
applies the same all-or-none same-network check before it trusts that metadata
for host file verification.
The same response boundary applies to task ids from create/reinstall/start/stop/
reboot/delete task APIs before they are used in polling URLs. That keeps the
shell harness aligned with the Rust `TaskId` newtype instead of treating raw
JSON strings as trusted URL path segments. The polling helper repeats that UUID
check on its own argument before constructing `/api/admin/tasks/<task_id>`, and
then requires each polling response `id` to match before accepting the reported
status.
For VM action responses, the smoke script also requires `kind.vm_id` to match
the VM created by the run before it polls the returned task id. This keeps the
real-host acceptance path proving the requested VM's reinstall/power/delete
task, not just any successful task row.
The polling helper also whitelists task statuses: `pending`, `assigned`, and
`running` continue polling; `succeeded` returns success; `failed` and
`canceled` return failure with task logs; any other status fails immediately
without printing the raw status value. If the task response is malformed or
does not contain `status`, the helper emits one bounded smoke-script error
instead of a parser traceback.
After each task wait returns `succeeded`, the real-host smoke also reads the
admin task-log endpoint for that task and requires the fixed
`task executor started` message on a row with the same task id and node id
before moving to host-side verification or final success. That message is
appended before the agent marks a task `running`, while later executor result
logs are best-effort after host work, so the smoke proof uses the strict
start-log invariant rather than optional result messages or a stale row from
another task. The final smoke JSON includes `task_logs_verified: true` only
after create, optional reinstall/power tasks, and final cleanup delete have met
that read-model check.

The successful smoke summary is self-describing. In addition to task IDs and
lifecycle booleans, it records the non-secret master URL, local HTTP allowance
flag, CA-configured flag, curl timeout, node ID, image file/name, controlled
storage roots, libvirt network/bridge, base image format, requested VM sizing,
assigned IPv4 metadata when master allocated an address, and
`agent_config_registered: true` after the local config has proven it contains a
long-term `ag_` credential and no leftover bootstrap token or bootstrap-shaped
credential value. It also records `node_ready_verified: true` after master has
proven the target node is online, schedulable, registered, freshly
heartbeating, and reporting `libvirt_status=available`. Final-acceptance runs
with `FULL_LIFECYCLE_REQUIRED=1` require `ALLOW_HTTP=0`,
`AGENT_BINARY_SHA256` or a validated
persisted hash at `AGENT_BINARY_SHA256_PATH`; after it is verified against the
installed binary, the summary records `agent_binary_sha256_verified: true` and
the normalized hash so the archived smoke output identifies the tested release
artifact. Final mode now fails closed after the doctor step if the hash proof was
not actually verified, before host preflight or master mutation. Full-run output also
records `host_preflight_verified: true` and
`master_health_verified: true` after local host/tool/storage/base-image checks
and the master `/healthz` probe have passed. The summary does not print admin
tokens, bootstrap tokens, long-term credentials, TLS identity material, or raw
audit/task JSON.

Before any master mutation, the same smoke script now proves that the installed
agent binary can load the same config the service uses. It validates
`AGENT_CONFIG_PATH`, validates `AGENT_BINARY_PATH`, optionally checks
`AGENT_BINARY_SHA256` or the persisted `AGENT_BINARY_SHA256_PATH` hash against
the installed file with `sha256sum`, and runs
`VPS_AGENT_CONFIG="$AGENT_CONFIG_PATH" "$AGENT_BINARY_PATH" doctor`, requiring
`vps-agent doctor: ok` while suppressing doctor output on failure. It also
requires `systemctl is-active --quiet vps-agent.service` to succeed, checks
that the active systemd `Environment` contains exactly one matching
`VPS_AGENT_CONFIG` and exactly one safe system `PATH`, the active `ExecStart`
has exactly one executable path and one argv entry, both equal to
`AGENT_BINARY_PATH`,
`ReadWritePaths` includes the
directory containing `AGENT_CONFIG_PATH` plus `DATA_DIR`, and verifies key
active sandbox values: `NoNewPrivileges=yes`, `MemoryDenyWriteExecute=yes`,
`PrivateTmp=yes`,
`ProtectClock=yes`, `ProtectHome=yes`, `ProtectHostname=yes`,
`ProtectSystem=strict`,
`RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK`,
`RestrictSUIDSGID=yes`, and
`UMask=0077` before contacting master or queueing tasks. In C# terms, this is
the acceptance harness checking
the deployed Windows service executable still matches the expected release
hash, calling it with its production config, and then checking the running
service instance points at that same executable/config with the write ACLs and
service restrictions it needs before exercising remote API workflows.

Full smoke mode also checks the master node read model before it writes catalog
state or queues the first task. After `/healthz` and local host preflight pass,
the script calls `GET /api/admin/nodes`, finds the configured `NODE_ID`, and
requires the row to be online, schedulable, registered with an `agent_version`,
heartbeating with a `last_seen_at` value from the last two hours, and reporting
`libvirt_status=available`.
The same smoke client passes `-q` and a `--proto` allow-list to every curl call:
`=https` for normal runs and for HTTPS master URLs even when `ALLOW_HTTP=1` is
set, or `=http,https` only when the validated `MASTER_URL` itself is loopback
HTTP for the explicit local test exception. This mirrors constructing a C#
`HttpClientHandler` with known protocol policy instead of inheriting local curl
configuration.
The full-mode `ADMIN_TOKEN` input is checked against the same bearer-compatible
shape as the master admin API before the script builds any Authorization header:
1-256 visible characters, no whitespace, quotes, backslashes, backticks, or
control characters. Precheck-only mode does not require this token, so a host can
prove local KVM, service, image, and TLS-readiness without first receiving an
admin secret.
This is the same design boundary as a C# background-job acceptance test checking
the control-plane projection before it enqueues a job for a worker service:
the task executor still performs its own preflight, but the smoke harness now
fails earlier when master has not yet observed a ready libvirt agent.

# Source Security Scan Update

The repository now has `scripts/security-scan.sh` as a stable wrapper around the
CCG `verify-security` scanner. It scans the platform source tree while excluding
generated `.next` output, Rust `target`, and frontend `node_modules`. It fails
fast if a copied `flint/` source tree is present, because this project may use
Flint only as an external reference for KVM/libvirt/cloud-init ideas, not as
vendored source, docs, or UI. In C# terms, this is a build-step adapter around a
static-analysis executable plus a repository hygiene guard: the wrapper fixes
the input set and path conversion rules so developers do not have to remember
tool-specific flags before trusting the result. For JSON runs it also treats
`files_scanned: 0` as a failed gate,
because a zero-file pass proves scanner misconfiguration rather than source
security.

# Bootstrap Token Concurrency Update

Bootstrap token creation uses the same transaction boundary as the one-time
response. Master inserts the token hash and writes `bootstrap_token.create`
audit before commit; if either step fails, no install command is returned and no
usable registration token remains in the database without audit evidence.

Agent registration treats bootstrap token consumption, node credential persistence, and audit persistence as one database concurrency boundary. Master only commits registration after the `bootstrap_tokens` update confirms exactly one still-unused and unexpired row was consumed, the `nodes` credential update confirms exactly one node row was updated, and the `agent.register` audit row is written. If the audit write fails, the bootstrap token remains unconsumed and no credential hash is stored, so the agent can retry instead of losing the only plaintext long-term credential. In C# terms, these are the affected-row checks you would put after optimistic concurrency updates inside the same `DbTransaction` before issuing a durable credential.

# Install Command URL Validation Update

Master validates `MASTER_PUBLIC_BASE_URL` and `MASTER_INSTALLER_BASE_URL` at startup and again while generating install commands. Both values must be HTTPS URLs with real hosts, no port-only authorities, no ports outside `1..=65535`, no malformed bracketed IPv6, no unbracketed IPv6, no userinfo, no query or fragment, no literal or percent-encoded dot path segments, no encoded path separators (`%2f` / `%5c`) in authorities or paths, and no percent-encoded ASCII controls in authorities or paths. They must also avoid whitespace, control characters, quotes, backslashes, and backticks. Optional installer TLS path settings must be clean absolute Linux file paths with no parent traversal or shell-sensitive characters. The generated bootstrap token is revalidated as an agent-secret-shaped value before the command is formatted, so a future token generator change cannot accidentally put whitespace, quotes, slashes, shell metacharacters, or oversized text into `--bootstrap-token`. The generated command downloads the installer with `curl -q -fsS --proto '=https'` and no redirect-following flags into a temporary file, invokes `sudo bash --` only after that download succeeds, registers an `EXIT` trap to clean up the temporary file, and quotes the optional `--cacert` value, the installer download URL passed to `curl`, and the installer arguments that contain deployment data. Passing `-q` first makes curl ignore host-local config files, which is the shell-script equivalent of constructing a C# `HttpClientHandler` with known redirect and TLS options instead of inheriting process-wide defaults. This keeps the operator-facing shell command a product of validated deployment configuration rather than raw environment text.

# Master Request Body Limit Update

Master now applies an explicit axum request body limit to every route. The default is `65536` bytes, configurable through `MASTER_REQUEST_BODY_LIMIT_BYTES` within `1024..=1048576`.

This is a coarse guard before DTO validation. In C# terms, it is similar to setting a small request-size limit for controller endpoints before model binding, while still keeping per-field validators for names, image file names, SSH public keys, task logs, and heartbeat diagnostics.

# Master Startup Config Update

`MasterConfig::try_from_env` now returns `Result<MasterConfig>` instead of using
panic-based parsing for deployment environment variables. Invalid bind addresses,
non-numeric limits, and non-UTF-8 environment values fail through the same
startup error path as URL validation and database connection failures.

In C# terms, this is closer to validating `IOptions<T>` during host startup and
letting the process exit with a configuration error, instead of throwing from a
static parser before the service has a chance to report context.

# Agent Master URL Validation Update

Agent config validation now treats `master_base_url` as a base URL, not just a string prefix. It must parse as a URL, include a host, reject explicit port `0`, use HTTPS unless the local smoke-test override is set for a loopback HTTP host, and must not include userinfo, query, fragment, whitespace, control characters, quotes, backslashes, backticks, literal or percent-encoded dot path segments, encoded path separators (`%2f` / `%5c`), or percent-encoded ASCII controls.

This matters because the agent prints `master_base_url` in doctor output and appends API paths to it when building signed requests. In C# terms, this is the same boundary as validating a configured `HttpClient.BaseAddress` before constructing request URLs from it.

# Agent HTTP Timeout Update

`MasterClient` builds one reqwest client with a bounded total request timeout.
The default is 30 seconds and can be adjusted with
`VPS_AGENT_HTTP_TIMEOUT_SECONDS` in the range `1..=300`.

The design intent is to keep the long-running agent loop responsive when a
master or reverse proxy accepts a TCP connection but stops responding. In C#
terms, it is equivalent to configuring `HttpClient.Timeout` on the typed client
used by the background service. The timeout wraps registration, heartbeat, task
polling, log append, and status update calls. The client also disables redirects
so the configured master origin cannot move a bootstrap token or long-term
credential-bearing request to another `Location:` target. These transport guards
do not change the HTTPS trust model or the HMAC signing model.

# Agent Host Command Timeout Update

The libvirt executor also bounds local host command execution. Calls to
`virsh`, `qemu-img`, `cloud-localds`, and `genisoimage` still use fixed program
names and argument arrays, and each child process now has a five-minute
deadline. If the host tool hangs, the current preflight or task fails and the
agent loop can continue. In C# terms, this is the same infrastructure-adapter
boundary as starting `ProcessStartInfo` with `ArgumentList` and enforcing a
per-process cancellation timeout.

# Agent Controlled Directory Validation Update

Agent config validation now treats host storage roots as a security boundary. `data_dir` and libvirt `image_dir` must be absolute Linux paths, must not be the filesystem root, must not contain `..`, and must avoid whitespace, control characters, quotes, backslashes, and backticks. In libvirt mode, `image_dir` must be a child of `data_dir`.

This check is lexical rather than `canonicalize`-based so the installer and `vps-agent doctor` can validate configuration before the directories exist. In C# terms, this is input validation on a configured storage root before any service creates directories or passes paths to a process executor.

At libvirt execution time, the lexical config check is followed by a real filesystem boundary check: `data_dir` itself must exist as a real directory and must not be a symlink before VM paths or base image paths are accepted. This prevents a configured storage root from being redirected through a symlink after installation.

# Agent Task Payload Validation Update

The agent now validates task ownership, executable status, and `TaskKind` payloads before writing task-start logs, moving the task to `running`, or dispatching it to either mock or libvirt execution. A task row returned by master must have the same `node_id` as the local agent config and must already be in `assigned` status. For `create_vm`, the payload `node_id` must match the task envelope, the payload must include the master-assigned `vm_id`, and assigned IPv4 metadata must be absent or complete as `assigned_ip` + `assigned_ip_prefix` + `assigned_gateway_ip`. When present, those fields must form a valid same-network host/gateway pair, so the host worker cannot silently create work under a default or mismatched identity or carry malformed IP text into cloud-init networking. `reinstall_vm` now reuses the same host-side checks for VM name, image file name, SSH public key, and disk size. If a same-node assigned task fails this worker-side validation, the agent reports it as `failed` with a redacted diagnostic while it is still in the `assigned -> failed` transition; it still does not append a start log or mark the task `running` before validation passes.

This keeps the mock loop useful as a security test path instead of a permissive bypass. In C# terms, this is a worker-service guard clause that validates a deserialized job command before calling either a fake executor or the real infrastructure adapter.

# Libvirt Base Image Boundary Update

The libvirt executor now resolves the requested base image through a dedicated helper before `create_vm` or `reinstall_vm` calls `qemu-img`. The helper validates the safe image file name, requires `data_dir` and `image_dir` to exist as real directories rather than symlinks, requires the file to exist as a real regular file rather than a symlink, and canonicalizes both `image_dir` and the base image path to prove that the file stays under the configured `image_dir` and the agent `data_dir`. The executor then runs `qemu-img info --output=json` and requires `format=qcow2` before creating the overlay disk with `-F qcow2`.

This is defense in depth beyond master image catalog validation. In C# terms, the infrastructure adapter validates its filesystem dependency immediately before handing the path to `ProcessStartInfo.ArgumentList`.
