# Security Design

本文档记录安全硬性要求和当前阶段的决策。任何后续安全相关改动都必须同步更新本文档。

## 不保存 SSH 密码

master 不保存宿主机 root SSH 密码，也不主动 SSH 到宿主机执行切机命令。SSH 只用于管理员人工登录宿主机并执行 agent 安装脚本。

这样可以把宿主机 root 凭据排除在业务系统之外，降低 master 数据库泄露后的影响面。

## TLS 要求

master 与 agent 通信禁止明文 HTTP。MVP 要求 HTTPS + token hash + 请求认证。

开发阶段本地健康检查可以监听 `127.0.0.1`，正式部署必须由 Caddy/Nginx 或 master 自身 TLS 入口提供 HTTPS。agent 配置中的 `master_base_url` 必须使用 `https://`。

第二阶段 master 启动时会检查 `MASTER_PUBLIC_BASE_URL`，如果不是 `https://` 开头则拒绝启动。这避免安装命令把 agent 指向明文 HTTP。

第四阶段 agent 启动时也会检查 `master_base_url`，默认拒绝非 HTTPS。只有测试环境显式设置 `VPS_AGENT_ALLOW_INSECURE_MASTER=1` 且目标是 loopback 主机（`localhost`、`127.0.0.1` 或 `[::1]`）时才允许 HTTP。

后续 mTLS 升级路径：

- master 为每个 agent 签发客户端证书。
- agent 校验 master 证书链和预期域名。
- master 校验 agent 客户端证书与 node_id 绑定关系。
- token 继续用于 bootstrap，mTLS 用于长期通道身份。

## Bootstrap Token

Bootstrap token creation is transactional with audit. Master inserts the
`bootstrap_tokens.token_hash` row and the `bootstrap_token.create` audit row in
one database transaction before returning the one-time install command. If the
audit write fails, the token hash rolls back too, so the database cannot retain
a usable registration token whose plaintext was never shown to the operator and
whose creation has no audit trail.

bootstrap token 只用于 agent 首次注册：

- 由 master 生成。
- 绑定 `node_id`。
- 绑定过期时间。
- 过期时间必须是短期窗口，当前实现限制为最多 24 小时。
- 只能使用一次。
- 使用后立即失效。
- 数据库只保存 hash，不保存明文。
- 安装脚本中只能包含短期一次性 bootstrap token，不能包含长期 credential。

注册时 master 先用 Argon2 hash 匹配未使用且未过期的 token，然后在同一注册事务里执行带 `used_at IS NULL` 和 `expires_at > now()` 条件的原子更新。只有 bootstrap token 消费更新、节点 `credential_hash` 更新和 `agent.register` audit 写入都成功时，master 才会提交事务并返回长期 credential；如果任一更新影响 0 行，注册请求返回未授权并回滚；如果影响多行，说明数据库不变量被破坏，注册失败为内部错误；如果审计写入失败，token 消费和 credential hash 也会回滚，agent 可以用同一个未消费 bootstrap token 重试。这等价于 C# 服务里检查乐观并发更新的 affected rows，并把注册状态和审计事件放在同一个 `DbTransaction` 里，避免并发注册把同一个一次性 token 换出多个长期凭据，也避免 token 已消费但节点 credential 或审计记录未按预期落库。

token 明文只展示一次。日志、测试快照和错误信息不得输出 token 明文。

## Agent Credential

agent 注册成功后，master 下发长期 agent credential。长期 credential 的安全要求：

- master 数据库只保存 hash。
- agent 本地配置保存明文 credential，但配置文件权限必须是 0600。
- credential 用于心跳、拉取任务、上报任务结果和日志。
- 所有 agent 请求必须认证。
- 支持后续轮换和吊销。

当前实现使用 Argon2 保存 bootstrap token、agent credential 和 admin/admin-readonly token 的 hash。agent 心跳、任务拉取、任务状态和任务日志接口通过 `X-Agent-Credential` 标识长期凭据，并通过 HMAC 请求签名证明该请求确实由持有长期 credential 的 agent 发出。服务端只拿请求头中的明文 credential 与数据库 hash 做本次验证，不记录明文。

Agent HTTP client methods that send heartbeat, task polling, task status, or task logs now require a local long-term credential before they build a network request. If the agent is still in bootstrap state or a future caller constructs a client without `credential`, those authenticated methods fail locally with `agent credential is missing` instead of sending an unauthenticated request to master. Registration remains the only client call that uses the one-time bootstrap token instead of the long-term credential.

## 请求认证和任务可信度

MVP 使用 HTTPS、长期 agent credential、HMAC 请求签名和 nonce 防重放。下发任务必须满足：

- agent 验证 master TLS 身份。
- After registration, agent requests are HMAC-signed before heartbeat, task polling, task status, or task log calls leave the host.
- master 先校验 `X-Agent-Credential` 的形状和 Argon2 hash，再校验签名。
- master 只返回属于该 node_id 的任务。
- task payload 来自认证且签名覆盖的通道。
- nonce table rejects replay for the same node, and timestamp skew is limited.

签名输入包含 HTTP method、path、body SHA-256、timestamp 和 nonce。The HMAC key is the long-term agent credential; master 数据库仍只保存它的 Argon2 hash，签名校验只使用请求头中本次提交的明文 credential。

## API 权限

权限分层：

- `Admin`：管理节点、任务、套餐、IP 池、用户和安装脚本。
- `ReadOnly`：查看节点、任务、日志和状态。
- `User`：普通 VPS 用户。

MVP 可先实现管理员，但代码边界要保留角色模型，避免后续把所有接口写死为单一权限。

第二阶段 admin API 使用 `Authorization: Bearer <admin-token>`。master 只读取 `MASTER_ADMIN_TOKEN_HASH`，不读取管理员 token 明文；本地可通过 `vps-master` 的 `hash-secret` 辅助二进制生成 Argon2 hash。master 启动校验要求 `MASTER_ADMIN_TOKEN_HASH` 存在并且是可解析的 PHC 格式密码哈希；可选的 `MASTER_READONLY_TOKEN_HASH` 如果配置，也必须是 PHC 格式。缺失或误填明文 secret 会让服务启动失败，而不是等到第一个管理请求才暴露配置错误。

第五阶段 frontend 不把管理员 token 写入 localStorage。登录 API 由 Next route handler 处理，验证成功后写入 HttpOnly、SameSite=strict cookie；除显式 `NODE_ENV=development` 外，cookie 默认设置 Secure，因此 staging、production 或未设置环境变量时都必须通过 HTTPS 访问面板。浏览器端后续只调用同源 `/api/*` 代理，由服务端读取 cookie 后转发到 master。

## VM 参数校验

VM 创建参数必须严格校验：

- VM 名称只能包含 ASCII 字母、数字、`-`、`_`。
- 镜像名只能包含 ASCII 字母、数字、`-`、`_`、`.`。
- CPU、内存、磁盘要有明确上下限。
- 不允许任意磁盘路径输入。
- 不允许路径穿越。
- 不允许 shell 字符串拼接。

agent 执行系统命令必须使用参数数组，例如 Rust `Command::new("qemu-img").arg("create")...`，不要使用 `sh -c` 拼接字符串。

## 受控目录

agent 只允许操作受控目录，例如 `/var/lib/vps-agent`。删除 VM 或磁盘前必须验证：

- 资源归属于该 node_id。
- 磁盘路径位于 agent data dir 内。
- VM 记录与 libvirt domain 元数据匹配。

第一阶段已在 `agent/src/security.rs` 放置路径归属校验边界，后续删除操作必须复用或强化该逻辑。
agent 配置加载时也会先校验受控目录配置：`data_dir` 和 libvirt `image_dir` 必须是绝对 Linux 路径，不能是 `/`，不能包含父目录跳转 `..`，也不能包含空白、控制字符、引号、反斜杠或反引号。`executor.mode = "libvirt"` 时，`image_dir` 必须位于 `data_dir` 下方。这个校验是词法校验，不要求目录已经存在，因此可以在安装脚本创建目录之前拦截危险配置。真实 libvirt executor 在使用路径前还会做一次文件系统边界校验：`data_dir` 本身必须已经存在、是真实目录、不能是符号链接或普通文件。

第四阶段 libvirt executor 的约束：

- executor 默认是 `mock`，必须显式配置 `executor.mode = "libvirt"` 才会执行宿主机命令。
- 所有系统命令通过 Rust `Command::new(program).args(args)` 传递参数数组，不使用 `sh -c`。
- `qemu-img`、`cloud-localds` / `genisoimage`、`virsh` 的参数由已校验的 VM 参数和受控路径生成。
- 镜像名必须是安全文件名，不允许 `/`、`\`、空段或 `..`。
- libvirt executor 在把 base image 传给 `qemu-img create` 前，会校验 `data_dir` 和 `image_dir` 是真实目录而不是符号链接，镜像路径是真实普通文件而不是符号链接，解析后的路径位于配置的 `image_dir` 内，且 `image_dir` 和镜像文件都位于 agent `data_dir` 下；随后运行 `qemu-img info --output=json <base-image>`，要求实际格式为 `qcow2`。
- VM 目录固定为 `<data_dir>/vms/<vm_id>`；创建 VM 前先校验 `data_dir` 本身是真实目录而不是符号链接或普通文件。如果固定父目录 `<data_dir>/vms` 或该 VM 根路径已存在，也必须是真实目录，不能是普通文件、符号链接或解析到 `data_dir` 外。创建缺失的父目录和 VM 根目录时，agent 使用逐级 `create_dir` 后立即复查元数据，而不是一次性递归创建并信任早前检查。
- 删除 VM 前验证目录和磁盘文件属于 agent `data_dir`，并且 VM 目录内只能包含 agent 已知 artifact。
- domain XML 中来自配置或路径的字符串必须 XML escape。

## 日志脱敏

不得将以下内容写入普通日志：

- bootstrap token 明文。
- agent credential 明文。
- 用户密码。
- 私钥。
- 数据库连接密码。

日志中如必须关联 secret，只能记录截断后的 hint，例如 `***abcd`。Short secret-shaped values of eight characters or fewer must use the fixed hint `***` instead of a suffix hint, so malformed or test-shaped bootstrap tokens and agent credentials cannot be revealed in full through debug output.

`install_command` is also treated as a sensitive field by the master and agent redactors. The command is operationally useful, but it carries the one-time bootstrap token; if an install command ever appears inside structured diagnostics or key-value text, the whole value is replaced with `[REDACTED]` instead of trying to parse individual shell arguments.

## 审计

所有任务必须有审计日志：

- 谁发起。
- 发给哪个节点。
- 执行了什么。
- 何时创建、开始、结束。
- 成功或失败。
- 失败原因。

审计日志用于商业化平台的追责和问题排查，不能只依赖普通 tracing 日志。

第二阶段已经为节点创建、bootstrap token 创建、agent 注册和 create_vm 任务创建写入 `audit_logs`。后续任务状态变化、任务日志和 VM 操作也必须继续写审计。

Task audit events now include structured non-secret task metadata:
`task_kind` and `vm_id` for create/start/stop/reboot/reinstall/delete/cancel,
agent assignment, and agent status-update events, plus `source_task_id` for
retries. These fields are operator correlation data. They must not include
bootstrap tokens, long-term agent credentials, admin secrets, passwords,
private keys, or command output.

Node creation and its `node.create` audit event are committed in one database
transaction. If audit persistence fails, the node insert rolls back too, so the
control plane cannot contain an unaudited node that can later receive bootstrap
tokens, credentials, or VM tasks.

# VM Ownership Boundary Update

Master now records VM ownership in a dedicated `vms` table instead of deriving VM existence from task history.

Security decisions:

- A VM action request must include both `node_id` and `vm_id`.
- Master checks that the VM exists and belongs to that node before creating start/stop/reboot/reinstall/delete tasks.
- Reinstall tasks use VM name and disk size from master inventory, not from the browser payload. An optional replacement image must already be enabled in the image catalog.
- Master enforces VM lifecycle state before it queues action tasks. VMs in
  `provisioning`, `deleting`, or `deleted` cannot receive follow-up VM action
  tasks, and action-specific guards prevent impossible requests such as
  stopping an already stopped VM. The browser hides invalid buttons and also
  hides VM action buttons when the VM read model's `last_task_status` is
  `pending`, `assigned`, or `running` as an operator convenience, but the master
  API remains the authoritative boundary.
- Queued reinstall and delete tasks move the VM row into `provisioning` or
  `deleting` immediately, before an agent polls the task. This makes the
  inventory table act as an early concurrency guard for disk replacement and
  destructive cleanup instead of waiting for the host worker to report
  `running`.
- Admin-created VM action tasks are persisted as one control-plane decision.
  Master commits the new task row, the audit event, and the VM `last_task_id`
  reservation in one database transaction. Reinstall and delete also include
  the immediate `provisioning` or `deleting` ownership row in that transaction;
  start, stop, and reboot keep their current lifecycle until the authenticated
  agent reports the final result. While the reserved task is still `pending`,
  `assigned`, or `running`, master rejects new actions and retries for that VM
  instead of allowing overlapping host commands against the same resource.
- Action, reinstall, and retry admission re-read the VM lifecycle inside that
  same transaction while locking the `vms` row with `FOR UPDATE OF v`. This
  closes the stale-read race where two admins could otherwise both pass the
  preflight check before either request writes the new `last_task_id`.
- Reinstall does not delete the VM directory. The agent only replaces disk, seed ISO, and regenerated cloud-init metadata files after proving they are under the controlled agent data directory. If an existing managed `network-config` file is present, the replacement seed ISO includes it but does not rewrite it. Required disk and seed ISO removal errors are not ignored; the replacement task fails instead of continuing toward `qemu-img create` with stale or unremoved artifacts.
- The agent validates every task before writing task-start logs, marking it `running`, or choosing the mock/libvirt executor. It rejects any task whose envelope `node_id` does not match the local agent config or whose envelope status is not `assigned`. For `create_vm`, the payload `node_id` must also match the task envelope, the payload must include the master-assigned `vm_id`, and assigned IPv4 metadata must be absent or complete as `assigned_ip` + `assigned_ip_prefix` + `assigned_gateway_ip`; the agent must never invent or default a node, VM identity, or guest network shape at the host boundary. For reinstall tasks this means VM name, replacement image file name, SSH public key, and disk size are checked again at the host boundary even though master normally derives them from trusted inventory. Same-node assigned tasks that fail this validation are reported back to master as `failed` with a redacted diagnostic before any task-start log, `running` status update, or host command is attempted.
- The agent still must validate local filesystem ownership before deleting disks; the master-side `vms` table is the control-plane ownership check, not a replacement for host-side path checks.
- Before create writes artifacts, `data_dir` itself must exist as a real directory and must not be a symlink or regular file. Any pre-existing fixed VM parent path (`<data_dir>/vms`) and any pre-existing VM root path must also be real directories under the agent data directory. A regular file, symlink, or path that canonicalizes outside the agent data directory is treated as an ownership failure before `qemu-img`, cloud-init, or `virsh`. Missing VM directories are created one level at a time and revalidated after each create, so a parent path that appears as a symlink during creation is rejected before artifacts are written. The fixed create outputs (`disk.qcow2`, `seed.iso`, `network-config`, `domain.xml`, `user-data`, and `meta-data`) must be absent before creation starts; a pre-existing file, directory, symlink, or other special file is rejected instead of being overwritten or followed. If local artifact setup fails before `virsh define`, the agent removes only those known managed artifacts and removes the now-empty VM directory with non-recursive `remove_dir`, so a retry is not blocked by partial local setup. If `virsh define` fails, the agent first checks `virsh domstate`; it cleans local artifacts only when libvirt returns a clear missing-domain diagnostic such as `Domain not found`. Generic `domstate` failures are treated as ambiguous ownership and preserve the directory. If `virsh start` fails after define, the agent first reads `virsh domstate` and requires `shut off`, then undefines the domain before removing known managed artifacts. If cleanup sees an unexpected entry, unsafe artifact type, existing/running domain, or undefine failure, cleanup fails and leaves the directory for manual inspection.
- Before start/stop/reboot/reinstall/delete reaches local artifact checks or `virsh`, the VM root path must exist as a real directory under the agent data directory. A missing path, regular file, symlink, or path that canonicalizes outside the agent data directory is treated as an ownership failure.
- Before start/stop/reboot/reinstall/delete reaches `virsh`, the agent parses the local `domain.xml` that it wrote during create. The active XML elements must contain the expected domain name, VM UUID, qcow2 disk path, and seed ISO path; comments or unrelated text do not count. The disk, seed ISO, and domain XML paths must all exist as real regular files under the agent data directory; symlinked artifacts are rejected even when the symlink target stays inside the data directory. The XML file must stay small enough to read safely. A mismatched, malformed, symlinked, non-regular, or oversized metadata file is treated as an ownership failure rather than a host command failure.
- Power tasks treat `virsh` return codes as command acceptance, not as final VM state. After `stop_vm` issues `virsh shutdown`, the agent polls `virsh domstate` and reports success only after libvirt returns `shut off`. After `create_vm`, `start_vm`, or `reboot_vm`, it reports success only after libvirt returns `running`. This avoids false-success windows where a follow-up destructive operation could be queued while the guest is still starting, or where the panel would show a brand-new VM as available before libvirt actually finished bringing it up.
- Before reinstall rewrites `user-data` or `meta-data`, the replacement VM name is validated again for cloud-init metadata safety, then those cloud-init paths are checked again as managed files under the VM directory. Existing regular files may be replaced with `create_new` semantics after removal; existing symlinks, directories, special files, or paths outside `data_dir` are rejected before the domain is destroyed or `qemu-img` is called. If `network-config` exists, it must also be a managed regular file before it can be included in the replacement seed ISO. The agent rejects any stale fixed `.reinstalling` file before `virsh destroy`, so an old partial reinstall cannot stop a running VM. After best-effort `virsh destroy`, the agent reads `virsh domstate` and requires `shut off` before touching disk artifacts. Replacement `disk.qcow2`, `seed.iso`, `user-data`, and `meta-data` are first built under fixed `.reinstalling` file names in the same managed VM directory. If replacement preparation fails, the agent removes only those staged files and leaves the existing disk and seed ISO intact. Before the commit step removes or renames any live artifact, it validates every prepared source and every live target; if any later target is unsafe, no earlier live artifact is replaced. Only after all staged artifacts and live targets are valid does the agent replace the live files and restart the domain, then it requires `virsh domstate` to report `running` before reporting reinstall success.
- Before delete reaches `virsh destroy` / `virsh undefine`, the agent also lists the VM directory and allows only `disk.qcow2`, `seed.iso`, `network-config`, `domain.xml`, `user-data`, and `meta-data`. Unknown entries, non-regular files, or symlinks are treated as ownership failures. `virsh destroy` is best-effort so already-stopped domains can still be deleted, but the agent then reads `virsh domstate` and requires `shut off` before `undefine` or local cleanup. `virsh undefine` must also succeed before local artifacts are removed. Cleanup then removes those known files individually and removes the now-empty VM directory with non-recursive `remove_dir`, so `delete_vm` cannot silently erase operator notes, unrelated files, nested directories, or managed disks for a domain that libvirt still owns or may still be running.
- Task status updates from authenticated agents update task state, VM lifecycle state, audit history, and any failed-task summary log in one database transaction. For any task outcome that maps to a VM lifecycle change, master requires exactly one matching VM inventory row to be updated before the status update can commit. A missing row is rejected instead of silently accepting a task result without moving the ownership record.

This supports the hard requirement that destructive VM/disk operations verify resource ownership before execution.

# Local Smoke Security Boundary

`scripts/smoke-master-agent.ps1` is a development-only test harness. It creates random temporary admin/bootstrap secrets, stores agent bootstrap material only in a temporary directory, and verifies that the agent removes `bootstrap_token` after registration.

The script sets `VPS_AGENT_ALLOW_INSECURE_MASTER=1` because it runs master over loopback HTTP inside a disposable Docker smoke environment. The agent still rejects non-loopback HTTP when this flag is set. This exception must not be used in production. Real deployments still require HTTPS/TLS between master and agent.

After registration, the local smoke harness runs `vps-agent doctor` against the
temporary agent config that now contains the long-term agent credential. If that
doctor command fails, the harness reports only the exit code and suppresses raw
doctor stdout/stderr, so a future parser or diagnostic change cannot copy
credential-like config values into CI or terminal logs.

When the local smoke harness prints Docker logs after master startup timeout or
top-level failure, it passes each line through the same conservative smoke
redaction boundary first. Common bootstrap token, credential, password, secret,
authorization-header, agent authentication header (`X-Agent-Credential` /
`X-Agent-Signature`), whole-line `Cookie` / `Set-Cookie`, private-key, and
URL-userinfo shapes are replaced with `[REDACTED]`, preserving ordinary
diagnostics without assuming every future master log line is secret-free.
If the master container was not created yet, the harness reports the missing-log
condition as a bounded diagnostic instead of masking the original failure.
Docker Compose startup failures use the same redaction boundary before their
diagnostics are printed, so compose interpolation or startup errors remain
actionable without copying generated admin, bootstrap, or agent secrets.

The smoke harness also covers negative security cases:

- invalid VM image names such as `../bad.qcow2` are rejected;
- a consumed bootstrap token cannot be reused for registration;
- a signed agent request claiming a different `node_id` is rejected;
- replaying a signed request with the same nonce is rejected.

# Installer Security Boundary

`scripts/install-agent.sh` is intentionally a bootstrap-only installer.

- It requires root because it writes `/etc/vps-agent/agent.toml`, `/usr/local/bin/vps-agent`, `/var/lib/vps-agent`, and a systemd unit.
- It rejects non-HTTPS `--master-url` and `--agent-url`; those URLs must include a real host, must not use a port-only authority such as `https://:8443`, must use closed brackets for IPv6 literals, any explicit port must be numeric and between 1 and 65535, and values must not include userinfo, query strings, fragments, whitespace, control characters, quotes, backslashes, backticks, literal / percent-encoded dot path segments, encoded path separators (`%2f` / `%5c`) in authorities or paths, or percent-encoded ASCII controls in authorities or paths.
- It downloads the agent binary with curl `-q` first, constrained to HTTPS
  (`--proto '=https'`), without redirect following, with a 30-second connect
  timeout and a 300-second total transfer timeout. `-q` disables root/user curl
  config files such as `.curlrc`, so local host defaults cannot silently add
  `--insecure`, redirects, or extra headers. When `--ca-cert-path` is
  configured, that same request also uses `--cacert`.
- Every value-taking installer option fails closed when its value is missing or when the next token is another `--option`, before dependency installation, config writes, binary installation, or systemd changes.
- `vps-agent doctor` also validates the written `master_base_url` as a clean base URL before the service is enabled.
- It rejects quote and control characters in values written to `agent.toml`, validates `--node-id` as canonical 8-4-4-4-12 hex UUID text, validates `--bootstrap-token` as short ASCII token text containing only letters, numbers, dots, dashes, and underscores, and validates libvirt `--network-name` / `--bridge-name` with the same short ASCII identifier rule used by the agent.
- It rejects unsafe `--data-dir` and `--image-dir` values before creating directories. Both must be absolute Linux paths, must not be `/`, must not contain `..`, whitespace, control characters, quotes, backslashes, or backticks, and libvirt `--image-dir` must be under `--data-dir`.
- If `--client-identity-path` is provided for the mTLS upgrade path, the file
  must already exist, be owned by the installer UID (root in production), and
  must not grant any group or other permissions. The installer rejects unowned
  files and loose modes such as `0644` before writing the path into
  `agent.toml`, because the file may contain a client private key.
- `--ca-cert-path` and `--client-identity-path` must be clean absolute Linux
  file paths. They must not be `/`, relative paths, parent-directory traversal,
  whitespace, quotes, backslashes, backticks, tabs, or control characters.
  The agent enforces the same path rule again when loading `agent.toml`, before
  it checks that the files exist.
- `--ca-cert-path` must also point at a real, non-symlink trust-anchor file
  that is not writable by group or other. The CA file may be readable by the
  system, but it must not be redirectable through a symlink or mutable by
  non-owner users.
- If `--ca-cert-path` is provided, the installer also passes it to the same
  non-redirecting HTTPS-only curl request with `--cacert` when downloading the
  agent binary. This keeps private-CA installs on the normal TLS verification
  path instead of requiring curl `--insecure`.
- It accepts a one-time bootstrap token from the generated install command and writes it once to the agent config through a same-directory temporary file with `0600` permissions, then renames it over `agent.toml` with `mv -fT` after rejecting whitespace, path separators, shell-sensitive characters, and oversized values. The `-T`/no-target-directory flag makes the final path stay a file replacement target even if a directory appears there after preflight.
- Before writing `agent.toml`, it rejects a pre-existing symlinked config directory, a config directory not owned by the installer UID (root in production), symlinked config path, existing config file not owned by the installer UID, or existing config file that grants group or other permissions, so the bootstrap token cannot be redirected into another file or written to a loose or cross-user local secret file before permissions are tightened.
- Before creating managed host storage, it rejects a symlinked final `data_dir` path and, in libvirt mode, a symlinked final `image_dir` path. The installer therefore does not create `/var/lib/vps-agent` or image storage through a directory symlink before the agent's own runtime preflight repeats the controlled-directory checks.
- It does not accept or write a long-term agent credential.
- It does not print the bootstrap token or any future credential.
- If `--agent-sha256` is provided, it must be a 64-character SHA-256 hex
  digest. The installer verifies the downloaded agent binary with `sha256sum`
  before installing it to `/usr/local/bin/vps-agent`, and aborts on mismatch.
  This lets operators pin a known release artifact in addition to using HTTPS.
  After a verified install, the installer writes the normalized digest to
  `/etc/vps-agent/agent.sha256` as a non-secret `0644` proof file using a
  same-directory temporary file and atomic rename, while rejecting a symlinked
  or non-regular final hash path. After `install -d` creates the config
  directory, the installer revalidates that directory before removing a stale
  proof or creating a new proof file, so a config directory symlink swapped in
  during creation cannot redirect the installed-binary evidence path.
- If `--agent-sha256` is omitted, checksum verification is skipped explicitly
  and the installer still installs the downloaded binary. Production generated
  commands should include the checksum whenever master serves a readable local
  artifact. In this unverified mode the installer removes any stale
  `/etc/vps-agent/agent.sha256` file so later smoke evidence cannot reuse a hash
  from an older verified install.
- Before downloading the agent binary, the installer rejects a pre-existing
  symlinked or non-regular `/usr/local/bin/vps-agent` target and rejects a
  symlinked or non-directory binary directory. After the download and optional
  checksum verification, it stages the executable into a same-directory
  temporary file, revalidates both the binary directory and final binary path
  immediately before `mv -fT`, and then atomically renames it into place. This
  keeps the root installer from following a hostile link or replacing an
  unexpected filesystem object, including a final-path or parent-directory
  symlink swapped in during the download window.
- Agent binary download is an explicitly checked boundary: failed `curl`
  stdout/stderr is suppressed, the installer prints only `agent download failed`,
  and a partial output file left by `curl` is not checksummed or installed.
- Before writing the systemd unit, the installer rejects a pre-existing
  symlinked or non-regular `/etc/systemd/system/vps-agent.service` target and a
  systemd service directory that is not owned by the installer UID (root in
  production) or is group/world-writable, then writes the unit through a
  same-directory temporary file plus atomic rename. The unit file is not a
  secret, but the installer runs as root and must not follow a filesystem
  redirect or trust a writable service directory while installing service
  configuration.
- When `MASTER_AGENT_BINARY_PATH` is configured, master hashes that artifact
  before returning a generated bootstrap install command and appends
  `--agent-sha256 <digest>`. The configured artifact must be a real regular
  file no larger than 128 MiB, not a symlink, directory, special file, or
  oversized blob. If it cannot be read or fails that boundary, master refuses to
  create the bootstrap token response instead of returning a command whose
  binary cannot be pinned. The download endpoint applies the same check before
  serving bytes, so a misconfigured artifact cannot become an unbounded public
  file read through `/downloads/vps-agent`.
- `scripts/build-agent-binary.sh` and `scripts/build-agent-binary.ps1` report
  the exported artifact hash as `agent_sha256` in their JSON output after the
  Docker build/export steps. This gives operators an audit-friendly value to
  compare with the checksum master later emits into generated install commands.
- The compose artifact override requires `MASTER_AGENT_BINARY_HOST_PATH`
  explicitly instead of defaulting to a repository-relative host path. That
  makes the operator choose the exact release artifact before container startup,
  and the override uses a read-only bind mount with `create_host_path: false` so
  Compose does not silently create a directory for a mistyped artifact path.
  Master still validates the mounted `/opt/releases/vps-agent` path as a regular
  file before hashing or serving it.
- When `MASTER_INSTALLER_CA_CERT_PATH` is configured, master validates that
  host-local path as a clean absolute Linux file path before using it in the
  generated command's outer non-redirecting
  `curl -q -fsS --proto '=https' --connect-timeout 30 --max-time 300 --cacert`
  and before appending `--ca-cert-path` for the installer. When
  `MASTER_INSTALLER_CLIENT_IDENTITY_PATH` is configured, master validates it
  before appending `--client-identity-path`. The installer still validates file
  existence and permissions on the target host.
- It runs `vps-agent doctor` before enabling the systemd service so config permissions and libvirt/cloud-init preflight failures are caught before the daemon starts. If doctor fails, the installer suppresses doctor stdout/stderr and prints only a bounded rerun hint, because the freshly written config still contains the one-time bootstrap token. Operators can bypass this only with `--skip-doctor`.
- It wraps `systemctl daemon-reload`, `systemctl enable vps-agent.service`, and `systemctl restart vps-agent.service` as checked installer steps. Raw stdout/stderr from these host commands is suppressed on both success and failure; the installer prints only the failed step name, preventing service-manager diagnostics from copying bootstrap tokens, credentials, or future config secrets into terminal logs.
- It supports `--executor-mode mock` for development, but production installs should use the default `libvirt` mode.

The generated command still contains a short-lived bootstrap token, so operators should treat it like a temporary secret and avoid pasting it into shared logs or tickets. Before it calls master registration, the agent preflights the local credential save target using the same parent-directory and config-path checks used by `AgentConfig::save`. Master invalidates the token on first successful registration, so the agent must fail locally instead of consuming the one-time token when it already knows the long-term credential cannot be persisted safely.
The generated command writes `install-agent.sh` to a temporary file and runs
`sudo bash --` only after the HTTPS curl download succeeds. It registers an
`EXIT` trap to remove the temporary file, so failed or interrupted runs do not
leave the downloaded installer behind and failed downloads cannot be hidden by an
empty installer process.

# Agent Local Config Permission Boundary

The agent config contains either a short-lived bootstrap token before registration or the long-term agent credential after registration, so it is treated as a local secret file.

Rules:

- `scripts/install-agent.sh` writes `/etc/vps-agent/agent.toml` through a same-directory temporary file with `0600` permissions and then renames it into place with `mv -fT`. It refuses to write through a pre-existing symlinked config directory, unowned or loose config directory, symlinked config path, swapped directory target, or over an existing config file that is not owned by the installer UID or grants group/other permissions. After `install -d` creates the config/data/image directories, the installer revalidates those managed paths before opening the temporary config file, so a directory symlink swapped in during creation cannot receive the bootstrap-token-bearing `agent.toml`. After the final rename, it revalidates the config path again instead of chmodding the destination path, so a symlink swapped in after the rename is rejected rather than followed.
- The installer rejects a symlinked final `data_dir` and, in libvirt mode, a symlinked final `image_dir` before it creates those managed directories. If the managed directories already exist, they must be owned by the installer UID (root in production); config must not grant any group/other access, and data/image directories must not be group-writable or accessible by other users. This is an install-time guard; the agent still revalidates controlled directories before host work.
- The installer also rejects a symlinked or non-regular systemd service target before writing `vps-agent.service`, keeping root-owned service installation on the intended unit path. It validates that the systemd service directory is not a symlink, is a directory, is owned by the installer UID (root in production), and is not group/world writable before creating the temporary unit file, then validates both the directory and the final service path again immediately before the final `mv -fT`, so an unowned or loose service directory, service directory symlink, or service-path symlink swapped in during temp-file creation cannot redirect the root-owned unit write.
- The installer applies the same final-path discipline to `/usr/local/bin/vps-agent`: it validates the binary directory and final binary path, writes the executable mode to a same-directory temporary file, revalidates the binary directory and final path, and uses `mv -fT` for the commit step. A symlinked parent directory or target that appears between download and commit causes the install to fail before the final rename.
- When `--agent-sha256` is used, the installer writes the normalized non-secret
  hash proof through a same-directory temporary file, renames it with `mv -fT`,
  and revalidates `/etc/vps-agent/agent.sha256` after the rename instead of
  chmodding the destination path. A swapped symlink, non-regular file, or
  group/world-writable proof path is rejected and cannot be used as a chmod
  target or final smoke evidence source.
- `AgentConfig::save` creates missing Unix config directories with owner-only
  permissions, creates new Unix config files with `0600` mode, and sets `0600`
  again after registration clears `bootstrap_token` and persists `credential`.
  Before creating or rewriting the file, it rejects an existing symlinked config
  directory, config directory not owned by the agent process user, or config
  directory that grants group/other access, then rechecks the directory after
  creating any missing parent path. This keeps the long-term credential out of
  redirected, cross-user, or shared local config directories. On Unix, the
  contents are written to a new same-directory temporary file with `0600` mode
  and then renamed over `agent.toml`; this keeps the final write from following
  a config-file symlink that appears between validation and persistence.
- During bootstrap startup, the agent runs that save-target preparation before
  sending `/api/agent/register`. If the config parent is a symlink, a regular
  file, a loose Unix directory, or the existing config path is unsafe, the agent
  keeps the bootstrap token local and never asks master to consume it.
- When loading `agent.toml`, the agent rejects malformed `bootstrap_token` or `credential` values and rejects configs that contain both. A config is either in bootstrap state or credential state, not both.
- On Unix, `vps-agent` refuses to load a config file that is not owned by the agent process user or grants any group or other permissions.
- On Unix, `agent.toml` must be a real regular file, not a symlink, and both the config file and config directory must be owned by the agent process user. The config directory must not grant group or other access. `AgentConfig::save` checks the parent directory and the file path before writing the long-term credential, writes through a same-directory temporary file, and then checks the file again before setting permissions, so a pre-existing symlinked, unowned, or loose config directory or config path is rejected instead of followed. If the file already exists with a different owner or group/other permissions, save fails before writing the credential instead of writing a secret and tightening permissions afterward.
- On Unix, `client_identity_path` is treated as a local secret file because it may contain a private key. It must be a real regular file, not a symlink, must be owned by the agent process user, and must not grant group or other permissions.
- `VPS_AGENT_ALLOW_INSECURE_CONFIG_PERMS=1` is reserved for local smoke tests that run through a Windows bind mount where Unix mode bits and ownership are not reliable. It relaxes Unix mode-bit and owner-UID checks only while loading the temporary bootstrap config and while saving the registered credential back to that same mounted config file and directory; it does not allow symlinked local secret files and does not relax `client_identity_path` private-key permissions. It must not be used on production hosts.

# Agent systemd Service Boundary

The MVP agent service still runs as `root` because it installs on a KVM host and
must manage libvirt/qemu resources and rewrite `/etc/vps-agent/agent.toml` after
bootstrap registration. The systemd unit therefore uses process sandboxing
instead of pretending the daemon is unprivileged:

- `NoNewPrivileges=true` prevents the agent and child commands from gaining
  extra privileges through setuid/setgid executables;
- `ProtectSystem=strict` makes the host filesystem read-only by default;
- `ReadWritePaths=/etc/vps-agent /var/lib/vps-agent` keeps writes scoped to the
  agent config and managed VM data directories;
- `Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`
  pins child-process program lookup to root-owned system binary directories,
  so `virsh`, `qemu-img`, and cloud-init tooling do not inherit an operator or
  user `PATH`;
- `ProtectHome=true`, `PrivateTmp=true`, `ProtectClock=true`,
  `ProtectHostname=true`, `ProtectKernelTunables=true`,
  `ProtectKernelModules=true`, `ProtectControlGroups=true`,
  `LockPersonality=true`, `RestrictRealtime=true`,
  `MemoryDenyWriteExecute=true`, `RestrictSUIDSGID=true`,
  `CapabilityBoundingSet=`, `AmbientCapabilities=`,
  `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK`,
  `SystemCallArchitectures=native`, and `UMask=0077` reduce daemon blast radius
  without blocking the current libvirt executor model. The allowed address
  families cover libvirt Unix sockets, HTTPS/DNS traffic to master, and host
  network introspection without permitting unrelated protocol families. Clock
  and hostname protection keep the root-running daemon out of host identity and
  time-management operations, which are not part of VPS provisioning.
  `MemoryDenyWriteExecute=true` blocks writable executable memory mappings; the
  Rust daemon and its libvirt/qemu/cloud-init command-line tools do not require
  a JIT runtime.
  `RestrictSUIDSGID=true` prevents the daemon or child tools from staging new
  setuid/setgid filesystem objects; this is not needed for VM provisioning.

The empty capability bounding and ambient sets mean the root agent process does
not keep Linux capabilities such as `CAP_SYS_ADMIN`. The MVP still runs as UID
0 so it can read/write its owner-only config and connect to the libvirt system
socket, while privileged VM execution remains delegated to the libvirt daemon.
The unit intentionally does not enable `PrivateDevices` yet because real
libvirt/qemu host behavior still needs to prove device and socket access on
target distributions.

# Agent Host Diagnostics Boundary

When the agent runs in `libvirt` mode, it performs a host preflight before VM work and reports the result in heartbeat payloads.

Reported states:

- `available`: `data_dir` and `image_dir` are real controlled directories, `/dev/kvm` exists as a character device, `virsh`, `qemu-img`, and either `cloud-localds` or `genisoimage` were found and runnable;
- `unavailable`: host preflight failed;
- `not_checked`: mock executor mode.

This status is diagnostic only. It does not replace the actual task execution path, and it does not prove that the host can complete a specific create/start/stop/reinstall/delete operation beyond the preflight checks.

Failed libvirt host command stderr is redacted by the command wrapper before it becomes an executor error. Failed preflight diagnostics are redacted again at the executor boundary before they are returned as `host_checks` or converted into a `check_host()` error. Before sending `host_checks` to master, the agent also redacts each preflight message and escapes non-line ASCII control bytes such as ANSI escape or tab characters into visible `\xNN` text. Master still validates message shape, length, and absence of ASCII control bytes before storing the heartbeat, but redaction and normalization start at the agent boundary so host command diagnostics do not intentionally cross the network or appear in local doctor output with bootstrap tokens, long-term credentials, passwords, private keys, terminal control sequences, or similar unsafe values.

Operators can run the same local readiness path without starting the daemon:

```bash
VPS_AGENT_CONFIG=/etc/vps-agent/agent.toml vps-agent doctor
```

The doctor command loads the normal agent config, enforces the same config and client-identity permission checks, prints only non-secret paths and status lines, and runs libvirt host preflight when `executor.mode = "libvirt"`. The preflight includes a `storage` check that rejects symlinked or non-directory `data_dir` / `image_dir` paths and a pre-existing symlinked or non-directory `data_dir/vms` parent before host command checks. Missing `/dev/kvm` is reported as a missing KVM character device, and an existing non-device path is reported as not being a KVM character device. It must not print bootstrap tokens, long-term credentials, passwords, private keys, or database URLs.

# Reverse Proxy Boundary

The compose deployment uses Caddy as the public TLS boundary.

- Browser panel traffic goes to frontend.
- Browser admin API calls stay same-origin and are handled by Next.js route handlers, which require the panel mutation marker for state-changing calls, read the HttpOnly admin cookie, and call master over the internal Docker network.
- Direct operator admin API traffic under `/api/admin/*` goes to master and must use `Authorization: Bearer <admin-secret>`.
- Agent API traffic under `/api/agent/*` goes directly to master because agents do not use browser cookies.
- Installer and agent binary downloads under `/scripts/*` and `/downloads/*` go directly to master.
- The single-domain Caddyfile uses `{$DOMAIN}` without a `localhost`
  fallback. Direct Caddy usage and compose deployments must provide the public
  domain explicitly so the TLS boundary cannot silently start as a development
  localhost site.
- Compose mounts the Caddyfile, the split-domain mTLS Caddyfile, and the agent
  client CA bundle through explicit read-only bind mounts with
  `create_host_path: false`. This makes a missing reverse-proxy config or CA
  bundle fail as deployment configuration, rather than allowing Docker Compose
  to create an empty host path and leave the TLS boundary ambiguous.
- Public Caddy sites set `Strict-Transport-Security: max-age=31536000`,
  `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, and
  `Referrer-Policy: no-referrer`. HSTS makes browsers keep using HTTPS after
  the first successful visit, `nosniff` avoids content-type confusion on API,
  installer, and binary download responses, `DENY` blocks clickjacking frames,
  and `no-referrer` avoids leaking panel paths or task identifiers to external
  links opened from the browser UI.

This preserves the current security split: admin token is kept in an HttpOnly frontend cookie for browser use, while agent credentials are sent only to master on authenticated agent endpoints.

The compose PostgreSQL port is bound to `127.0.0.1` only. Public traffic should
terminate at Caddy; the database is for Docker-internal master access and local
operator administration, not a network-facing service.

Compose healthchecks use Docker `CMD` argument arrays instead of `CMD-SHELL`.
The PostgreSQL readiness probe calls `pg_isready`, master probes `/healthz`,
frontend probes its local Next.js listener, and Caddy validates
`/etc/caddy/Caddyfile` with the `caddy` binary without going through shell
strings. The master healthcheck passes curl `-q` before `-fsS`, so a container
local `.curlrc` cannot add redirects, proxy settings, or weaker TLS behavior to
the readiness probe. Frontend waits for a healthy master, and Caddy waits for
healthy master and frontend containers before serving public traffic; Caddy's
own health status also fails if the mounted Caddyfile or required environment
placeholders are invalid. This keeps deployment-time command execution aligned
with the agent host-command rule and avoids routing browsers or agents to
containers that have only started but are not ready.

The Windows helper that builds the Linux `vps-agent` artifact runs Docker with
PowerShell argument arrays and separates `cargo build` from the artifact export
step. It intentionally avoids `bash -c`, `sh -c`, and chained shell command
strings so release artifact generation follows the same command-boundary rule as
the host executor.

Compose deployment requires `POSTGRES_PASSWORD`, `DOMAIN`,
`MASTER_PUBLIC_BASE_URL`, `MASTER_INSTALLER_BASE_URL`, and
`MASTER_ADMIN_TOKEN_HASH` explicitly and does not provide fallback values for
them. Master also validates that `MASTER_ADMIN_TOKEN_HASH` is a PHC password
hash and that non-empty `MASTER_READONLY_TOKEN_HASH` values are PHC password
hashes. This prevents a production stack from accidentally booting with a
development database secret, a localhost public URL in generated install
commands, disabled admin authentication, or a plaintext admin secret where a
hash was expected. `MASTER_READONLY_TOKEN_HASH` remains optional; an empty value disables the read-only operator token instead of
creating a weak default.

The production master and frontend images also drop root in their runtime
stages: master runs as `vps`, and frontend runs as the base image's `node` user.
The master image keeps the Rust compiler and Cargo in the builder stage only;
the runtime stage is a slim Debian image containing the release binary and
operational runtime dependencies such as CA certificates and curl for the
healthcheck. This does not replace application authentication, but it reduces
the impact of a container escape or file-write bug inside the web processes and
keeps compiler tooling out of the running control-plane container.

Compose also sets `security_opt: no-new-privileges:true` on PostgreSQL, master,
frontend, and the public-facing Caddy service. This is similar to starting a C#
service under a restricted token: even if a compromised process reaches a
setuid or file-capability path inside the container, Docker will not let it
acquire new privileges. PostgreSQL may still drop from the image entrypoint's
startup user to the `postgres` runtime user; the flag blocks privilege gains,
not privilege reduction.

Compose also drops all Linux capabilities for master and frontend with
`cap_drop: [ALL]`. Those services listen on high ports, run as non-root users,
and do not perform host administration, so they should not retain ambient
container capabilities. Caddy is not part of this rule because it owns the
public `80/443` listener boundary.

PostgreSQL, master, frontend, and Caddy also set `pids_limit: 256`. This is a
deploy-time blast-radius guard: a request-handling bug, database misconfiguration,
or compromise cannot create unbounded processes or threads inside a
control-plane container. PostgreSQL connection limits still need database-level
tuning, but the compose PID budget provides a coarse outer boundary.

Master, frontend, and Caddy run with `read_only: true` root filesystems and a
bounded `/tmp` tmpfs mounted `rw,noexec,nosuid,size=64m`. Master and frontend
are stateless apart from PostgreSQL and outbound API calls, while Caddy keeps
its durable state in the explicit `caddy-data` and `caddy-config` volumes. This
keeps unexpected writes out of the image filesystem and gives temporary runtime
scratch space a narrow, non-executable boundary.

All base compose services use Docker `json-file` logging with `max-size: "10m"`
and `max-file: "5"`. Application and agent code must still avoid logging
secrets, but bounded container logs prevent noisy health checks, request errors,
or database diagnostics from filling the master host disk.

All base compose services also use `restart: unless-stopped`. This is an
availability boundary rather than an authentication boundary: Docker restarts
PostgreSQL, master, frontend, and Caddy after unexpected exits or daemon
restarts, but an explicit operator stop is still respected.

For deployments that want strict client-certificate enforcement on agent traffic, use the split-domain mTLS example instead of trying to turn mTLS on for only one path of the browser domain:

- `PANEL_DOMAIN` serves the frontend, `/scripts/*`, `/downloads/*`, and `/healthz` without requiring a client certificate.
- `AGENT_DOMAIN` serves only `/api/agent/*` and requires a valid client certificate signed by `agent-client-ca.pem`.
- `PANEL_DOMAIN` explicitly rejects `/api/agent/*` with 404 before proxying to
  frontend, so the non-client-authenticated browser/installer entrypoint cannot
  accidentally become an agent API path.
- `MASTER_PUBLIC_BASE_URL` should point at `https://AGENT_DOMAIN` so agents register, heartbeat, poll, and report status through the mTLS entrypoint.
- `MASTER_INSTALLER_BASE_URL` should point at `https://PANEL_DOMAIN` so generated install commands can still download the installer and agent binary before the host has a client certificate configured for the agent process.
- `MASTER_INSTALLER_CLIENT_IDENTITY_PATH`, when set, is copied into generated
  install commands as a host-local `--client-identity-path`; the PEM file must
  be placed on each target host before the installer runs.
- The mTLS compose override requires `PANEL_DOMAIN`, `AGENT_DOMAIN`, and
  `AGENT_CLIENT_CA_PATH` explicitly, and the base compose file still requires
  `DOMAIN`, `MASTER_PUBLIC_BASE_URL`, `MASTER_INSTALLER_BASE_URL`,
  `POSTGRES_PASSWORD`, and `MASTER_ADMIN_TOKEN_HASH` during interpolation.

Master still verifies bootstrap tokens, long-term credential hashes, and HMAC request signatures. Reverse-proxy mTLS is an additional transport identity boundary, not a replacement for application-layer authentication and audit.

# Agent Request Signing

Authenticated agent requests now require both the long-term credential and an HMAC request signature.

Required headers:

```text
X-Agent-Credential: <agent-credential>
X-Agent-Timestamp: <unix-seconds>
X-Agent-Nonce: <random-16-to-128-char-nonce>
X-Agent-Signature: <hex-hmac-sha256>
```

Canonical string:

```text
METHOD
PATH
SHA256_HEX(body)
TIMESTAMP
NONCE
```

The HMAC key is the long-term agent credential. Master still stores only the Argon2 hash of that credential; it uses the plaintext from the request header only to verify the Argon2 hash and the HMAC for that request. Before any Argon2 or HMAC verification, master rejects malformed bootstrap tokens and agent credentials: values must be 1-256 bytes and contain only ASCII letters, numbers, dots, underscores, or dashes. Signature text is also protocol-shaped before verification: it must be exactly one SHA-256 HMAC digest encoded as 64 ASCII hex characters. This mirrors the installer and agent-local config boundary and keeps whitespace, path-like values, control bytes, malformed signatures, and oversized junk out of expensive verification paths.

Signed agent endpoints read the raw request body so the HMAC covers the exact bytes on the wire. Master applies the global agent rate-limit bucket before parsing signed-agent JSON, so repeated malformed payloads are still bounded even when no trustworthy `node_id` can be extracted. Well-formed requests then also consume the node-specific bucket after `node_id` is parsed. After that envelope limit, malformed request JSON is treated as client input and returns `400 Bad Request` through an explicit parser boundary. Master does not log the malformed body, so broken or hostile requests cannot turn token-bearing payloads into ordinary logs. JSON errors that come from persisted internal data remain server-side failures.

Replay controls:

- timestamps must be within a five-minute window;
- nonce values are inserted into `agent_request_nonces`;
- reusing the same nonce for the same node is rejected;
- old nonce rows are cleaned opportunistically during verification.

This is an MVP signing scheme, not mTLS. It protects authenticated agent API requests against body tampering and simple replay while preserving the future mTLS upgrade path.

# Task Log Secret Boundary

Task logs are now visible through the admin API and frontend task detail panel, so they must be treated as operator-facing diagnostic data rather than a safe place for secrets.

Current rules:

- agent log append calls require the same HMAC-signed authenticated channel as heartbeat, poll, and status updates;
- the public agent log append endpoint accepts messages only while the task is
  `assigned` or `running`. Failure summaries are persisted by master during the
  authenticated `failed` status transition, so agents do not append arbitrary
  messages to pending or terminal tasks;
- the active-task rule is enforced again by the `task_logs` insert itself. If a
  concurrent status update moves the task out of `assigned` / `running` after
  pre-validation, the insert affects no rows and master returns a conflict
  instead of storing a log on a terminal task;
- master redacts common secret key/value patterns before writing task log messages;
- after redaction, master escapes non-line ASCII control bytes such as terminal
  color escapes as `\xNN` while preserving newline, carriage return, and tab for
  readable diagnostics. The escaped/redacted value must still fit within the
  4096-byte diagnostic storage limit;
- master rejects empty task log messages, messages over 4096 bytes, and messages
  containing NUL bytes before writing to PostgreSQL;
- master also redacts sensitive string fields in audit detail JSON before writing audit logs;
- master records audit metadata for each task assignment and task log append. The `assigned` task update and its `task.assigned` audit event are committed in one database transaction, so an audit write failure rolls the claim back instead of leaving unaudited work assigned to an agent;
- task-log append audit detail stores only message length. The task log row and its `task.log.append` audit event are committed in one database transaction, so an audit write failure rolls back the diagnostic log instead of leaving unaudited task evidence;
- agents must not write bootstrap tokens, long-term credentials, passwords, private keys, or database URLs into task log messages;
- smoke tests assert that expected non-sensitive executor messages are queryable from `GET /api/admin/tasks/:task_id/logs`.

The master-side redactor is a final safety net, not permission to log secrets. It covers common forms such as `token=...`, `password: ...`, `credential=...`, `signature=...`, `authorization=...`, authorization-header values with schemes such as `Authorization: Bearer <secret>`, agent authentication headers such as `X-Agent-Credential` and `X-Agent-Signature`, whole-line `Cookie` and `Set-Cookie` header values, PEM private-key blocks, and URL userinfo credentials such as `postgres://user:pass@host/db`. Future executor implementations must still keep command output filtering conservative. If a system command may print secrets, the executor should redact before appending the message to `task_logs`.

Agent now also applies the same conservative text redaction before it sends task log messages, reports failed task `error_message` values, or writes loop iteration errors to its own tracing logs. This includes URL userinfo credentials, bearer/basic-style authorization values, agent authentication header values, and whole-line `Cookie` / `Set-Cookie` header values, so a host diagnostic containing a database URL preserves the scheme and host for troubleshooting but replaces the embedded username/password with `[REDACTED]`, and an authorization, agent-authentication, or cookie diagnostic replaces the sensitive header value as one redacted value. This keeps sensitive diagnostics from crossing the host-to-master boundary in normal operation, while master redaction remains the server-side backstop for manually submitted or future agent messages.

Successful executor result logs are best-effort after host work has already
completed. If appending one of those logs fails, the agent logs a redacted local
warning and still reports the terminal `succeeded` status to master. This keeps
the task status/audit trail aligned with real host state; the pre-execution
start log and terminal status update remain strict control-plane operations.

Terminal task status updates are retried by the agent for transient
control-plane failures after host work or worker-side validation has already
finished. Retry warnings are written only to local tracing with redacted error
text. The retry loop does not relax authentication, request signing, task
ownership checks, or master-side transition validation; it only avoids leaving
completed host work stuck as `running` because a single terminal status request
failed.

Master guards each authenticated agent status update with the current task
status that passed transition validation. If another request moves the task
while the agent update is in flight, the write affects no rows and returns a
conflict instead of overwriting a newer admin cancellation or terminal state.
This preserves the task state machine under concurrent control-plane requests.
The accepted status row, VM lifecycle row, status-update audit event, and
redacted failed-task summary log are committed together. This is the same
transaction boundary as a C# service updating a job table, domain table, and
audit table through one `DbTransaction`; an audit or VM update failure rolls back
the task status change instead of leaving a terminal task with stale VM state.

# IPAM Ownership Boundary

IP addresses are now allocated by master, not supplied directly by panel callers.

Security decisions:

- `assigned_ip`, `assigned_ip_prefix`, and `assigned_gateway_ip` in create-VM input are ignored and overwritten by master.
- If a `create_vm` task payload contains assigned IPv4 metadata, shared task validation requires all three fields to be present before the agent writes logs, marks the task `running`, or dispatches to mock/libvirt execution.
- `assigned_ip` and `assigned_gateway_ip` must be different valid IPv4 host addresses, `assigned_ip_prefix` must be `/16` through `/30`, and both addresses must be in the same network.
- When that metadata is present, the libvirt executor writes a managed cloud-init v2 `network-config` file and includes it in the seed ISO so the guest receives static IPv4 configuration.
- A VM can only receive an address from an existing `ip_pools` row selected by `ip_pool_id`.
- IP pool creation and its `ip_pool.create` audit event are committed in one
  database transaction, so a schedulable address inventory source cannot appear
  without an audit trail.
- Active allocations are unique by `(ip_pool_id, ip_address)` and by `vm_id`.
- For new `create_vm` work with an IP pool, master reserves the address, inserts the task row, attaches the allocation to that task, creates VM inventory, and writes the create audit event in one database transaction. If any step fails before commit, none of those rows become visible to the agent poller. This prevents a pending task from existing without its VM/IPAM ownership record.
- The IP allocation attachment must update exactly one active `ip_allocations` row. If no active reservation remains, master returns a conflict inside the transaction; if more than one row is touched, master treats it as an internal consistency fault.
- Failed or canceled VM creation releases the reserved IP. Successful VM deletion releases the IP and clears the VM inventory address.
- MVP pools are IPv4 CIDR ranges from `/16` through `/30`; very large or unusable prefixes are rejected to keep allocation bounded and predictable.

The agent still must validate real network configuration locally when public bridge/NAT/IPv6 support is added. Master-side IPAM plus cloud-init `network-config` is an ownership and guest-bootstrap boundary, not proof that the host bridge, firewall, or upstream route makes the address reachable.

# Agent Resource Metrics Boundary

Heartbeat resource metrics are operational telemetry, not credentials. The MVP agent reports CPU count, memory totals, data-directory disk totals, and managed VM count over the same HMAC-authenticated agent channel used for heartbeat and task status calls. Master validates `agent_version` before registration or heartbeat persistence, limiting it to short semver-like ASCII text and rejecting secret-bearing words so version strings cannot become an audit-log escape hatch. Heartbeat totals are also internally consistent: `cpu_used`, `memory_used`, and `disk_used` must not exceed their reported totals.

Libvirt host preflight status is also operational telemetry. Agent heartbeat may include `host_checks` entries for storage layout, KVM, libvirt, the configured active libvirt network whose `Bridge:` value matches the configured bridge, the configured bridge interface, qemu-img, and cloud-init ISO tooling. The storage check covers `data_dir`, `image_dir`, and the fixed VM parent `data_dir/vms` when that parent already exists. Master validates the check names, statuses, message lengths, and absence of ASCII control bytes before storing them. These messages must remain single-line, non-secret diagnostics; they must not contain bootstrap tokens, long-term credentials, passwords, private keys, database URLs, or terminal control sequences.

Agent config validation restricts `network_name` and `bridge_name` to short ASCII identifiers containing only letters, numbers, dots, dashes, and underscores. The values are still passed to host commands as argument arrays and escaped in domain XML, but rejecting path-like or shell-like names at config load keeps the operator error boundary tight.

Security decisions:

- metrics are not accepted from anonymous agents;
- metrics update only the authenticated node's latest resource columns and the heartbeat audit detail, avoiding a separate unauthenticated metrics endpoint;
- the latest node telemetry update and `agent.heartbeat` audit event are
  committed in one database transaction, so a signed heartbeat cannot advance
  scheduling/read-model freshness without the matching audit trail;
- master rejects inconsistent resource payloads such as `memory_used > memory_total` or `disk_used > disk_total`;
- disk usage is scoped to the configured agent `data_dir`, not arbitrary paths supplied by master or a user;
- the resource collector does not create `data_dir` during telemetry collection and does not follow symlinked or non-directory `data_dir` paths; unsafe or missing data roots report zero disk capacity for that heartbeat instead of measuring a redirected path;
- VM count is derived only from a real `data_dir/vms` directory. A missing, non-directory, or symlinked VM parent reports `0`, preserving the agent-managed path boundary;
- CPU usage remains `0` until the agent has a proper sampled collector, avoiding misleading capacity decisions from a single instant read.

# Task Error Boundary

Agent-reported task failures may include operational diagnostics. Master stores a bounded, redacted copy of `error_message` on the `tasks` row only when the task moves to `failed`; running, succeeded, and canceled states clear the stored error.

The same master-side redactor, control-byte escaping, and post-normalization length cap used for task logs is applied before persistence. This gives the panel a useful failure summary while keeping bootstrap tokens, long-term credentials, passwords, private keys, database URLs, terminal escape bytes, and oversized escaped diagnostics out of the task read model.

The agent also redacts executor errors before submitting them as `error_message`, so both sides of the channel share responsibility: agent avoids transmitting obvious secrets, and master redacts again before storing or displaying the value.

# Master Error Logging Boundary

Master API database failures return only a fixed `database error` response to clients. The server-side log entry converts the `sqlx::Error` diagnostic to text and passes it through the same redaction filter before writing it to tracing. This prevents connection strings, token-shaped values, passwords, or future driver/source diagnostics from bypassing the normal task-log and audit-log redaction paths.

Master startup failures use the same redaction boundary before tracing writes the error. The top-level startup wrapper logs a sanitized diagnostic and returns only a generic startup failure to the process exit path, so database, migration, or bind errors cannot leak a raw connection string or other secret-bearing context through Rust's default `main` error printing.

Master configuration has a custom `Debug` implementation. It redacts URL userinfo in base URLs and `DATABASE_URL`, and it prints fixed `[REDACTED]` placeholders for `MASTER_ADMIN_TOKEN_HASH` and `MASTER_READONLY_TOKEN_HASH`, so future diagnostic logs cannot accidentally dump credential-bearing config values through derived struct formatting.

Agent configuration also has a custom `Debug` implementation. It redacts URL userinfo in `master_base_url` and relies on the shared redacted secret wrappers for `bootstrap_token` and `credential`, so debugging a malformed local config cannot print the full bootstrap token, long-term credential, or URL password.

The shared bootstrap-token response also has a custom `Debug` implementation. The response must serialize the generated `install_command` to the authenticated admin exactly once, but that command embeds the short-lived bootstrap token; debug formatting therefore prints only a fixed `[REDACTED INSTALL COMMAND]` placeholder for `install_command` while keeping `node_id`, `expires_at`, and the redacted token wrapper available for diagnostics.

Agent startup failures follow the same pattern. Config load, bootstrap registration, HTTP client construction, doctor, and heartbeat-loop errors are logged through the agent redactor before tracing writes them, then the top-level `main` returns only a generic `vps-agent startup failed` error. This keeps bootstrap tokens, long-term credentials, URL userinfo, passwords, private keys, and similar future diagnostics out of systemd process error output while preserving a redacted local diagnostic for operators.

# Task Retry Boundary

Only authenticated admins can retry tasks, and only terminal `failed` or `canceled` tasks are retryable. Master creates a new task row from the original structured `TaskKind`; it does not move the old task out of its terminal state. Succeeded tasks are rejected for retry. After the retry task is inserted, master updates the matching non-deleted VM inventory row with the new `last_task_id` and any retry lifecycle fields, and requires that update to affect exactly one row. A missing or already-deleted VM row is rejected instead of silently creating retry work without an ownership record.

Retry is still a fresh authorization and inventory decision, not a blind replay.
Before the new task row is inserted, master checks that the current VM status
still allows that task kind and that the VM `last_task_id` does not point at an
active `pending`, `assigned`, or `running` task. A failed `create_vm` can be
retried only while the VM inventory row is still in `error`;
start/stop/reboot/reinstall/delete retries reuse the same lifecycle and active
task guard as the normal action APIs. Create and reinstall retries also require
the referenced image to still exist and be enabled in the image catalog.

For `create_vm` tasks that use an IP pool, retry reserves a fresh address and attaches the new allocation to the retry task in the same database transaction that inserts the retry task, updates VM inventory, and writes `task.retry` audit detail. The attachment update must affect exactly one active allocation, matching the original create path. This avoids reusing an address that was released when the original create task failed or was canceled, and avoids queueing retry work whose IP reservation cannot be traced to its task. Every retry audit detail contains the source task ID.

# Task Cancellation Boundary

Admin cancellation is intentionally pre-run only in the MVP. Master accepts
admin cancellation for `pending` and `assigned` tasks, but rejects `running`
tasks because there is not yet a cooperative agent cancellation protocol for
in-flight libvirt/qemu-img work. A running task can still reach `canceled` only
when the authenticated agent reports that state through the signed status
endpoint. This avoids telling operators that host work was canceled while the
agent may still be creating, deleting, or reinstalling VM artifacts.

The cancel update is guarded by the status that master validated before the
write. If an agent moves a task to `running` or a terminal state while the admin
cancel request is in flight, the update affects no rows and master returns a
conflict instead of overwriting the newer state. This is the same optimistic
concurrency pattern as checking affected rows after a C# `UPDATE ... WHERE
Status = @expectedStatus`.

A successful admin cancel commits the canceled task row, the audit event, and
any VM/IP cleanup implied by the canceled task kind in one database transaction.
If the matching VM inventory update, IP release, or audit write cannot be
persisted, master rolls back the cancel instead of leaving task history and
resource ownership out of sync.

# Node Scheduling Boundary

VM tasks can only be created for nodes that have completed agent registration. Master checks that the node has a stored `credential_hash` before inserting a task row. A newly-created node with only a bootstrap token is still in the install/register phase and must not receive VM work yet.

This prevents tasks from being queued to placeholder nodes where no authenticated agent exists to poll, execute, or report results. It also keeps the bootstrap token boundary separate from the long-term authenticated task channel.

Admins can also disable node scheduling without changing the node heartbeat status or credential. The `scheduling_enabled` flag is only mutable through the authenticated admin API, every change writes `node.scheduling_update` audit detail, task insertion checks the flag before persisting new VM work, and the agent task-poll claim query only assigns pending tasks whose node is still schedulable. Task insertion admission and task polling both lock the target `nodes` row with `FOR UPDATE`, so a maintenance toggle cannot race between reading `scheduling_enabled` and inserting or assigning a task. The scheduling update and audit event are committed in one database transaction; if audit persistence fails, the maintenance-mode toggle rolls back too. This means maintenance mode pauses not-yet-assigned work without rewriting existing task history. Agent heartbeats update telemetry only; they cannot re-enable scheduling or override maintenance mode.

Create-VM task insertion has an additional node-readiness boundary. Master now requires the target node to be registered, `online`, heartbeating with a `last_seen_at` timestamp no older than two hours, and not explicitly reporting `libvirt_status=unavailable` before it inserts a new create task or retries a failed/canceled create task. The timestamp is written by master when it accepts an authenticated heartbeat, so the freshness check does not trust agent-supplied clock text. `libvirt_status=not_checked` is still allowed so the mock-executor MVP smoke can verify the master-agent task loop without pretending to be a libvirt host. Real KVM acceptance remains stricter: the host smoke script requires a fresh heartbeat and `libvirt_status=available` before it mutates catalog or task state.

Create-VM task insertion also checks reported node capacity when telemetry is available. Master locks the target `nodes` row with `FOR UPDATE` inside the same transaction that inserts the create or retry task, then sums committed VM inventory on that node for `provisioning`, `running`, `stopped`, and `deleting` VMs. A new create or retry request is rejected if CPU cores, memory MB, or disk GB would exceed the node's last reported totals. This serializes capacity admission per node so concurrent create requests cannot both pass from a stale committed-VM snapshot. It is still a master-side abuse and operator-error guard; it does not replace agent-side libvirt preflight or host command failure handling. Nodes with zero telemetry are treated as unknown capacity so the bootstrap/MVP flow remains usable before the first heartbeat.

The same committed totals are returned by the authenticated admin/read-only node list API. They are operational metadata derived from VM inventory and contain no credentials, token material, SSH keys, or host command output.

# Image Catalog Boundary

Master now keeps an `images` catalog for base VM image file names.

Security decisions:

- admins register images through `POST /api/admin/images`;
- admins enable or disable images through `POST /api/admin/images/{image_id}/enabled`;
- read-only operators can list images but cannot create or enable/disable them;
- image creation and its `image.create` audit event are committed in one
  database transaction, so a host-consumable base image reference cannot appear
  without an audit trail;
- `create_vm` and replacement-image `reinstall_vm` tasks must reference an enabled image from the catalog;
- image file names use the same restricted ASCII character set as VM task validation and cannot contain path separators, parent traversal, leading dots, trailing dots, or consecutive dots;
- disabling an image only blocks future create/reinstall requests and does not mutate existing VM inventory rows;
- image enable/disable changes and their `image.enabled_update` audit event are
  committed in one database transaction, so catalog availability cannot change
  without the matching audit trail;
- the agent still checks that the configured `image_dir` is a real directory, not a symlink, and that the referenced base image exists as a real regular file, not a symlink, before creating a qcow2 disk;
- the agent canonicalizes the configured `image_dir` and base image path at execution time and rejects them if they resolve outside the agent `data_dir` or outside `image_dir`;
- the agent runs `qemu-img info --output=json` and rejects base images whose reported format is not `qcow2` before creating a `-F qcow2` overlay disk.

This keeps panel input constrained to known image names while preserving the host-side ownership/path checks in the libvirt executor.

# Plan Catalog Boundary

Master now keeps a `plans` catalog for commercial VM package sizes.

Security decisions:

- admins create plans through `POST /api/admin/plans`;
- admins enable or disable plans through `POST /api/admin/plans/{plan_id}/enabled`;
- read-only operators can list plans but cannot create or enable/disable them;
- plan names and slugs are restricted to simple ASCII character sets;
- plan CPU, memory, and disk values use the same bounds as direct VM creation;
- plan creation and its `plan.create` audit event are committed in one database
  transaction, so a sellable package cannot appear without an audit trail;
- when `create_vm` includes `plan_id`, master ignores caller-supplied CPU, memory, and disk values and replaces them with the enabled plan's sizing before creating the task;
- plan sizing is loaded inside the same database transaction that validates the image, reserves any IP, checks node capacity, inserts the task, creates the VM inventory row, and writes audit. The lookup holds a PostgreSQL `FOR SHARE` row lock on the selected plan, so a concurrent plan enable/disable update waits until the create decision commits instead of racing between catalog validation and task persistence;
- disabled or unknown plans are rejected before IP allocation, task creation, or VM inventory creation;
- disabling a plan only blocks new VM creation with that plan and does not mutate existing VM inventory rows;
- plan enable/disable changes and their `plan.enabled_update` audit event are
  committed in one database transaction, so catalog availability cannot change
  without the matching audit trail;
- the selected `plan_id` is stored in the task payload and VM inventory for auditability.

The agent still validates the concrete VM payload it receives. The plan catalog is a control-plane product boundary, not a substitute for agent-side resource/path checks.

# Audit Read Boundary

Audit logs are now visible to authenticated admins through `GET /api/admin/audit-logs` and the panel Audit view.

Rules:

- audit reads require the same admin bearer-token authentication as other admin APIs;
- the API returns recent entries only, capped at 200 rows;
- audit detail must remain free of bootstrap tokens, long-term credentials, passwords, private keys, and database URLs;
- task log append audits store message length, not message body.

Future role support should allow read-only operators to view audit logs without granting mutation privileges.

# API Role Boundary

Master now supports two operator bearer-token roles:

- `Admin`: configured through `MASTER_ADMIN_TOKEN_HASH`; can call read and mutation admin APIs.
- `ReadOnly`: configured through `MASTER_READONLY_TOKEN_HASH`; can call read admin APIs only.

Read APIs currently include node, IP pool, VM, task, task log, and audit log listing/detail endpoints. Mutation APIs such as node creation, bootstrap-token creation, IP pool creation, VM task creation, and VM power/delete actions still require `Admin`.

Both token values are stored as Argon2 hashes only. A read-only token that attempts a mutation receives `403 Forbidden`, while an unknown token receives `401 Unauthorized`.

# Admin Login Boundary

The browser panel now presents a username/password login form instead of asking operators to paste a raw bearer token into the UI.

MVP decisions:

- `MASTER_ADMIN_USERNAME` configures the admin username. The binary keeps an
  `admin` default for local development, but production compose requires the
  variable explicitly so the browser login identity is a deliberate deploy-time
  choice. When configured, it is validated as a 1-64 byte ASCII identifier using
  only letters, numbers, dots, underscores, and dashes; blank values,
  surrounding whitespace, slashes, quotes, backslashes, backticks, controls, and
  non-ASCII text are rejected during master config validation instead of
  falling back to the local default.
- `MASTER_ADMIN_TOKEN_HASH` remains the stored Argon2 hash for the admin secret. For compatibility with the existing bearer-token API and smoke tests, the same secret acts as the admin password in the browser login flow, so it must be bearer-compatible: 1-256 visible ASCII characters without whitespace, quotes, backslashes, or backticks.
- `POST /api/admin/session` verifies `username` and `password` against the master config without requiring an existing bearer token. This endpoint is rate-limited separately from authenticated admin APIs and returns success, malformed JSON, rate-limit, and unauthorized responses with `Cache-Control: no-store, max-age=0`, `Pragma: no-cache`, and `Expires: 0`, so direct master login probes have the same cache boundary as the browser-facing session flow.
- The Next.js session route accepts only `{ username, password }` browser login payloads. The old token-only browser login shape is rejected so operators do not paste raw bearer tokens into the panel flow. Before it calls master to verify the login, the BFF rejects usernames that do not match the master `MASTER_ADMIN_USERNAME` shape and passwords that are not bearer-compatible using the same cheap shape check as cookie forwarding; malformed admin names or secrets stay inside the browser/BFF validation boundary instead of being sent to master.
- After master verifies the credentials, Next.js stores the admin secret in an HttpOnly, SameSite=strict cookie with an eight-hour `Max-Age`. The cookie is Secure for every environment except explicit `NODE_ENV=development`, so staging, production, and custom or unset environments must serve the panel over HTTPS. Browser code does not use localStorage for this secret.
- Before the BFF forwards a cookie-derived admin secret as `Authorization: Bearer ...`, it rechecks the same bearer-compatible shape used by master: non-empty, at most 256 visible ASCII characters, and no whitespace, quotes, backslashes, or backticks. Malformed cookie values are treated as unauthenticated and are not forwarded to master.
- TanStack Query caches only normal panel read models such as nodes, plans, images, IP pools, tasks, audit logs, VMs, and selected task logs. Generated bootstrap token responses remain in local component state and are not written into the React Query cache, so the one-time token keeps the same display-once boundary even though the rest of the panel uses shared query invalidation. Changing the selected install node clears the displayed install command before another node can be used, so a stale token-bearing command cannot be copied under the wrong node context.
- The master bootstrap-token endpoint returns one-time secret responses with `Cache-Control: no-store, max-age=0`, `Pragma: no-cache`, and `Expires: 0`, and bootstrap-token boundary errors such as malformed JSON, rate limits, and authorization failures use the same headers. The direct master admin-session endpoint uses the same no-store JSON boundary for login success and login-boundary errors. The agent registration endpoint uses the same no-store response boundary for the long-term `credential` returned after consuming a bootstrap token, and registration-boundary errors such as malformed JSON or rate limits use the same headers. The Next.js BFF applies the same browser-facing headers to proxied master responses, to `/api/session` login/logout responses, and to its own authorization, invalid-path, CSRF-marker, timeout, and upstream-failure JSON errors, so generated install commands, bootstrap-token boundary responses, admin-session boundary responses, and agent registration boundary responses are not intentionally retained by browser, framework, or intermediary HTTP caches.
- The panel polls only while task status is active (`pending`, `assigned`, or `running`) and stops polling once tasks are terminal. Polling still goes through the same Next.js BFF routes, HttpOnly cookie, CSRF marker on mutations, and master bearer-token authentication; it is a read-model freshness mechanism, not a separate authorization channel.
- Browser-facing Next.js routes that mutate state require `X-VPS-Panel-Request: same-origin`, reject cross-origin `Origin`, and accept only `Sec-Fetch-Site: same-origin` or `none` before reading the HttpOnly cookie or forwarding to master. `same-site` metadata is rejected to keep sibling subdomains outside the panel mutation boundary. This is the frontend CSRF boundary; it is not a replacement for master-side bearer-token authentication.
- Browser-facing Next.js routes with dynamic IDs validate those path parameters as UUID text before constructing the internal master URL. This keeps malformed values such as traversal-like strings, encoded slashes, or query-bearing segments inside the BFF validation boundary instead of letting them shape a proxied admin path.
- Before reading the HttpOnly admin cookie or attaching `Authorization: Bearer <admin-secret>`, the shared Next.js forwarding helper now requires the target path to be a clean `/api/admin/...` path with no scheme-relative URL, absolute URL, query string, fragment, whitespace/control characters, quotes, backslashes, backticks, dot segments, or encoded slash/backslash separators. This is a defense-in-depth SSRF and credential-forwarding boundary for future BFF routes; agent endpoints and arbitrary master paths are not valid browser-cookie forwarding targets.
- `MASTER_API_BASE_URL`, used only by the Next.js BFF to reach master, is normalized to an HTTP or HTTPS origin before any admin secret is forwarded. It must include a host, any explicit port must be in `1..=65535`, and it must not include username/password, path, query, fragment, whitespace, quotes, backslashes, or backticks. `http://` is accepted only for loopback hosts, RFC1918 private IPv4 addresses, or single-label internal service names such as the compose service `master`; public hostnames and public IP addresses must use HTTPS. Compose intentionally uses `http://master:8080` on the private Docker network; public browser and agent traffic still terminates at HTTPS.
- Next.js BFF requests to master use an `AbortSignal` timeout before forwarding login credentials or the HttpOnly admin secret. `MASTER_FETCH_TIMEOUT_MS` defaults to `30000` and must be an integer in `1000..=300000`; invalid values fail the route handler instead of silently disabling the bound. The same BFF fetch options force `redirect: "manual"` so a master or reverse-proxy `3xx` response cannot resend the admin secret to a `Location:` target. This is an availability and credential-forwarding boundary like C# `HttpClient.Timeout` plus disabled auto-redirects; it does not change master bearer-token authentication, frontend CSRF checks, or `MASTER_API_BASE_URL` validation.
- If a frontend-to-master fetch times out or fails before an HTTP response is received, the BFF returns only a sanitized JSON error: `504` with `master request timed out` for timeout/abort failures, or `502` with `master unavailable` for other network failures. Raw exception messages are not returned to the browser because they can contain URLs, infrastructure details, or operator-supplied values.
- Authenticated panel action failures are displayed through the shared panel alert using the same JSON `error` string returned by the BFF/master boundary. The panel does not render raw thrown exception objects, request bodies, bootstrap tokens, long-term credentials, admin secrets, or stack traces; generated bootstrap responses remain in local component state and are still shown only through the dedicated install-command flow.
- Dangerous panel actions use an in-panel confirmation dialog instead of `window.confirm`. This includes VM creation, VM power/reinstall/delete tasks, task cancel/retry, image/plan availability changes, node scheduling changes, and generating a one-time bootstrap install command. The create-VM confirmation summarizes only the non-secret scheduling shape (node, CPU, memory, disk) and does not echo SSH public key text. The dialog focuses Cancel first, lets Escape cancel, and restores focus to the triggering control when closed so keyboard operators can back out without accidentally confirming a destructive, resource-consuming, or secret-bearing operation. This improves operator intent capture and keeps confirmation text inside the React UI, but it remains only a UI 防误触 layer: master still performs bearer-token authentication, CSRF-marker enforcement through the BFF, role checks, VM ownership validation, task lifecycle guards, token display-once handling, and audit writes before any state change is accepted.
- Existing admin API calls still use `Authorization: Bearer <admin-secret>` from the Next.js route handlers to master. Direct bearer headers and browser login passwords are accepted only when the secret text is bearer-compatible; malformed values are rejected before Argon2 verification or secret-derived rate-limit bucket creation.
- Wrong username/password attempts return `401 Unauthorized` and must not disclose whether the username or password was wrong.

This is still an MVP single-admin model. The production user model should split human account passwords from API bearer tokens, store per-user password hashes in PostgreSQL, add session IDs or signed session cookies, and apply role checks per account instead of relying on one shared admin secret.

This is still an MVP role model. The `User` role remains reserved for future tenant-facing VPS ownership APIs, where access decisions will need row-level ownership checks in addition to role checks.

# Request ID Boundary

Master now assigns every HTTP request a request ID and returns it in `X-Request-Id`.

Rules:

- callers may provide `X-Request-Id` when it is an ASCII value between 8 and 128 characters using letters, digits, `.`, `_`, or `-`;
- invalid or missing request IDs are replaced with a generated UUID;
- audit events created during a request store the request ID in `audit_logs.request_id`;
- the admin audit API and panel expose `request_id` so an operator can correlate an API call, master logs, task logs, and audit records.

Request IDs are correlation identifiers, not authentication data. They must never contain bearer tokens, bootstrap tokens, agent credentials, passwords, private keys, or database URLs. Master accepts caller-provided `X-Request-Id` values only when they are short ASCII correlation IDs and do not contain secret-bearing words such as `token`, `credential`, `password`, `secret`, or `private_key`; otherwise it ignores the header and generates a fresh UUID before writing audit rows or response headers.

# Agent TLS Trust Boundary

Agent HTTPS clients use rustls certificate validation by default.

Production rules:

- `master_base_url` must be a valid base URL with a host, any explicit port must be in `1..=65535`, and production URLs must use `https://`;
- `master_base_url` must not include username/password userinfo, query strings, fragments, whitespace, control characters, quotes, backslashes, backticks, literal / percent-encoded `.` / `..` path segments, encoded path separators (`%2f` / `%5c`), or percent-encoded ASCII controls;
- public CA certificates are validated through the default reqwest/rustls trust roots;
- private or self-signed deployment CAs should be configured with `ca_cert_path` in `agent.toml`;
- the installer can write this field with `--ca-cert-path /path/to/master-ca.pem`;
- on Unix, configured CA files must be real non-symlink regular files and must
  not be writable by group or other; this is a trust-anchor integrity rule, not
  a secret-file rule;
- agents may also present a client certificate/key bundle with `client_identity_path`;
- the installer can write that field with `--client-identity-path /path/to/client-identity.pem`;
- both TLS paths must point to existing PEM files and are preserved when the agent clears its bootstrap token after registration;
- agent HTTP clients do not follow redirects. A 3xx response fails the current registration, heartbeat, task polling, log append, or status update request instead of replaying a bootstrap token or `X-Agent-Credential` to a `Location:` target.

`client_identity_path` is the first implementation hook for the mTLS upgrade path. It expects one PEM file containing the client certificate and private key in a format accepted by reqwest/rustls. Enabling actual client-certificate enforcement still belongs at the TLS boundary, for example Caddy/Nginx validating client certificates before proxying `/api/agent/*` to master and binding the validated certificate identity to `node_id`.

Both TLS file paths are treated as configuration boundary values. They must be
absolute Linux paths with no parent traversal or shell-sensitive characters, and
the agent rejects invalid path syntax before file lookup. This keeps installer
validation and manual `agent.toml` edits on the same rule set.

`ca_cert_path` is an integrity-sensitive trust anchor and may be system-readable,
but on Unix it must be a real non-symlink regular file and must not be
group/world-writable. `client_identity_path` is a local secret file and is
stricter: on Unix it must be a non-symlink regular file owned by the agent
process user with owner-only permissions. The local smoke config-permission
override does not weaken that client identity private-key rule.

`VPS_AGENT_ALLOW_INSECURE_MASTER=1` exists only for local smoke tests where master runs over disposable loopback HTTP inside Docker. Even with this flag set, the agent accepts `http://` only for `localhost`, `127.0.0.1`, or `[::1]` loopback-style hosts. It must not be used for production nodes.

# Agent Master Request Timeout Boundary

Agent calls to master use a bounded reqwest client timeout. The default is 30
seconds and operators may set `VPS_AGENT_HTTP_TIMEOUT_SECONDS` within
`1..=300`. Invalid, zero, or oversized values stop client construction instead
of silently falling back to an unsafe runtime setting.

This timeout is an availability guard: a connected-but-silent master, reverse
proxy, or network path should fail one loop iteration instead of blocking
heartbeat, task polling, or task status reporting indefinitely. It does not
weaken HTTPS validation, optional custom CA trust, optional client identity,
redirect refusal, or HMAC request signing. In C# terms, this is the same
operational boundary as setting `HttpClient.Timeout` while keeping the existing
authentication handlers unchanged.

# Agent Host Command Timeout Boundary

When the libvirt executor runs host tools such as `virsh`, `qemu-img`,
`cloud-localds`, or `genisoimage`, each child process is started with fixed
program names and argument arrays and is bounded by a five-minute timeout. A
timeout is treated as a host command failure for the current preflight or task,
not as a reason for the agent daemon to hang indefinitely. This is the Rust
equivalent of starting a C# `Process` with `ArgumentList` and enforcing a
per-command cancellation deadline.

Agent heartbeat scheduling is also bounded in config. The default
`heartbeat_interval_seconds` is 30 seconds, and accepted values are `1..=3600`.
Oversized values stop config validation before the daemon loop starts, so a
typo cannot silently turn node monitoring and task polling into a multi-hour or
multi-day interval.

# Rate Limit Boundary

Master now applies an in-process fixed-window rate limit to sensitive control-plane endpoints.

Protected buckets:

- admin API requests, including failed bearer-token attempts;
- admin login attempts, globally and by the first `X-Forwarded-For` hop only
  when that hop parses as an IP address;
- agent bootstrap registration attempts;
- authenticated agent heartbeat, task polling, task status, and task log calls.

Configuration:

- `MASTER_ADMIN_RATE_LIMIT_PER_MINUTE`, default `120`;
- `MASTER_AGENT_REGISTRATION_RATE_LIMIT_PER_MINUTE`, default `30`;
- `MASTER_AGENT_RATE_LIMIT_PER_MINUTE`, default `600`.

Master parses these environment variables through structured startup config
loading. Accepted rate-limit values are `1..=60000` requests per minute; zero
or oversized values stop startup instead of silently removing meaningful
throttling. Non-numeric values, invalid socket bind addresses, and non-UTF-8
config values return startup errors instead of Rust panics. This keeps
deployment misconfiguration inside the normal error path and avoids panic output
that could include unnecessary process diagnostics.

Admin session creation applies the `admin:session` bucket before parsing the login JSON, and it also applies the optional parsed-IP `X-Forwarded-For` bucket before parsing when that header is usable. This keeps repeated malformed browser login payloads inside the same login throttling boundary as wrong-password attempts.

Admin mutation endpoints that accept JSON payloads authenticate the bearer token and consume the authenticated admin rate-limit buckets before parsing the mutation JSON. This includes node, plan, IP pool, image, bootstrap-token, create-VM, reinstall-VM, and VM power/delete task routes. Repeated malformed mutation payloads from a valid admin token therefore stay inside the same admin throttling boundary as well-formed mutation attempts.

Agent registration applies the global `agent-register:all` bucket before parsing the registration JSON, so repeated malformed bootstrap requests are still bounded even when no trustworthy `node_id` or bootstrap token can be extracted. Well-formed registration attempts then also consume a secret-derived bucket scoped by node ID and bootstrap token. Signed post-registration agent APIs follow the same envelope pattern with `agent:all` before JSON parsing and the node-specific bucket after `node_id` is parsed.

The limiter stores only bucket names and SHA-256 hashed secret-derived bucket keys in memory. It does not write bearer tokens, bootstrap tokens, or agent credentials to logs or the database. The hash is a bucket label for rate limiting only; it is not used as credential storage or authentication proof.

`X-Forwarded-For` is treated as proxy metadata, not trusted identity. Master uses
it only for an extra admin-session rate bucket after parsing the first comma
separated value as an IP address. Malformed values, hostnames, ports, and
secret-looking text are ignored so an unauthenticated caller cannot create
arbitrary high-cardinality limiter keys.

This is an MVP single-process control. It protects a small deployment from accidental loops and simple brute-force pressure, but it is not a distributed abuse-prevention layer. If master is scaled horizontally, this should move to a shared store such as Redis or a reverse-proxy rate limiter while keeping the same endpoint categories.

# Request Body Size Boundary

Master applies an explicit request body limit to all HTTP routes before JSON extraction or signed agent body parsing.

Configuration:

- `MASTER_REQUEST_BODY_LIMIT_BYTES`, default `65536`;
- minimum accepted value: `1024`;
- maximum accepted value: `1048576`.

The default is intentionally small because control-plane payloads are structured JSON: heartbeats, task logs, VM creation requests, and admin catalog changes are all bounded by separate field-level validation. Operators can raise the value within the configured maximum for a larger deployment, but large file uploads should not be added to these APIs. Base images and agent binaries should continue to use controlled filesystem or object-storage paths rather than browser/API uploads.

# VM SSH Key Boundary

VM provisioning supports only optional OpenSSH public keys for guest login bootstrap.

Rules:

- `create_vm.ssh_public_key` must be a single-line OpenSSH public key with an allowed key type;
- multiline values, shell-like comments, unsupported key types, oversized keys, passwords, and private keys are rejected before task creation. The optional public-key comment must be printable ASCII without spaces and must not contain command substitution, separator, redirection, glob, bracket, history, or shell-comment metacharacters such as backticks, `$`, `;`, `|`, `&`, `<`, `>`, brackets, `*`, `?`, `!`, or `#`;
- master may persist the public key in `vms.ssh_public_key` because public keys are not secrets, but private keys must never be accepted, stored, logged, or displayed;
- reinstall tasks use the key already stored on VM inventory instead of trusting a browser-supplied replacement value;
- agent writes the key only into cloud-init `authorized_keys` for the guest `vps` user.

This does not replace tenant identity or per-customer authorization. It is only the MVP guest-access bootstrap boundary for operator-created VMs.

# Real KVM Host Smoke Boundary

`scripts/kvm-host-smoke.sh` is an operator verification tool for a real Linux
KVM host after the agent has registered and is configured with
`executor.mode = "libvirt"`.

Security decisions:

- the admin secret is supplied through the `ADMIN_TOKEN` environment variable
  and is sent only as an `Authorization: Bearer` header to master;
- the smoke script passes that authorization header to curl through a curl
  config file descriptor instead of placing the token in curl's command-line
  arguments, and rejects token values containing whitespace, quotes, backslashes,
  backticks, or any ASCII control character, including non-whitespace controls;
- while generating that curl config, the script temporarily suppresses shell
  xtrace output so `bash -x scripts/kvm-host-smoke.sh` does not echo the
  `Authorization` header value into debug logs;
- every curl call made by the smoke script uses bounded connect and total
  request timeouts from `CURL_TIMEOUT_SECONDS`, so a bad master URL or broken
  network path fails the verification instead of hanging indefinitely;
- if `MASTER_CA_CERT_PATH` is set, the smoke script validates that it is a clean
  absolute Linux path to an existing non-symlink regular file that is not
  group/world writable, then passes it to curl with `-q` and `--cacert` for
  health and admin API requests. This supports private deployment CAs without
  allowing local curl config files or `--insecure` smoke verification. The
  `--cacert` value is passed through a Bash argument array, not unquoted command
  substitution, so unusual but valid path characters cannot split or glob into
  extra curl arguments;
- the script must not print `ADMIN_TOKEN`, bootstrap tokens, agent credentials,
  passwords, private keys, or database URLs;
- `PRECHECK_ONLY=1` is a non-mutating host readiness mode. It validates the
  master health endpoint, rejects WSL before dependency checks, validates local
  agent config shape and permissions, the installed agent binary's `doctor`
  command, optional installed-agent SHA-256 pin, the active
  `vps-agent.service` systemd state including its `VPS_AGENT_CONFIG` environment
  and `ExecStart` binary identity,
  KVM/libvirt/qemu/cloud-init tooling, controlled directories, and the selected
  base image path and qcow2 format without requiring `ADMIN_TOKEN` and without
  calling authenticated admin APIs or queueing VM tasks;
- successful precheck-only output is JSON that includes only non-secret
  diagnostics: validated master URL, data directory, image directory, image
  file, selected libvirt network and bridge names, base image format,
  `agent_config_registered: true` after the local config proves credential
  state, `master_health_verified: true` after the master `/healthz` probe,
  CA-cert-present boolean, selected cloud-init ISO tool, and timeout/poll
  values. It deliberately does not print `ADMIN_TOKEN`, `NODE_ID`, or the
  host-local `MASTER_CA_CERT_PATH`, `AGENT_CONFIG_PATH`, or doctor output;
- `MASTER_URL` must use HTTPS unless `ALLOW_HTTP=1` is explicitly set for an
  isolated local lab; even then, HTTP is accepted only for loopback hosts such
  as `localhost`, `127.0.0.1`, or `[::1]`. It must not include userinfo, query
  strings, fragments, whitespace, ASCII control characters, quotes, backslashes,
  backticks, literal / percent-encoded `.` / `..` path segments, encoded path
  separators (`%2f` / `%5c`) in authorities or paths, or percent-encoded ASCII
  controls in authorities or paths, and the URL
  authority must contain a real host rather than only a port, must use numeric
  ports between 1 and 65535, must reject malformed bracketed IPv6 text, and must reject unbracketed
  IPv6 text. The local HTTP exception is rejected when
  `FULL_LIFECYCLE_REQUIRED=1`;
- `DATA_DIR` and `IMAGE_DIR` must be absolute Linux paths, must not be `/`, must
  not contain parent traversal, ASCII control characters, or shell-sensitive
  characters, and `IMAGE_DIR` must stay under `DATA_DIR`;
- `AGENT_CONFIG_PATH` defaults to `/etc/vps-agent/agent.toml` and must be a
  clean absolute Linux file path. Before contacting master, the smoke script
  rejects missing, symlinked, non-regular, non-UTF-8, or group/other-accessible
  config files. It parses only non-secret fields and requires `node_id` to be a
  UUID, a long-term `credential` with the current master-generated `ag_` prefix
  to be present, `bootstrap_token` to be absent, `[executor].mode` to be
  `libvirt`, and the configured `data_dir`, `image_dir`, `network_name`, and
  `bridge_name` to match the smoke inputs. This prevents a leftover
  bootstrap-shaped `bt_` value in the credential field from being accepted as
  registered-agent evidence. In full mode, the config `node_id` must also match
  `NODE_ID`; in
  `PRECHECK_ONLY=1`, `NODE_ID` is still not required and is not printed;
- `AGENT_BINARY_PATH` defaults to `/usr/local/bin/vps-agent` and must be a
  clean absolute Linux file path to an existing non-symlink regular executable.
  The smoke script rejects group/world-writable binaries. If
  `AGENT_BINARY_SHA256` is set, it must be a 64-character SHA-256 hex digest.
  If it is omitted but `AGENT_BINARY_SHA256_PATH` exists, the script reads the
  expected digest from that non-secret proof file after rejecting symlinks,
  non-regular files, malformed hashes, and group/world-writable paths. The
  smoke script then verifies the installed binary with `sha256sum` before
  doctor, service-state, or master checks. This lets a real-host smoke prove
  the installed file still matches the release artifact pinned by the generated
  install command. The script then runs
  `VPS_AGENT_CONFIG="$AGENT_CONFIG_PATH" "$AGENT_BINARY_PATH" doctor`. It
  requires doctor output to include `vps-agent doctor: ok`, but it does not echo
  doctor output on failure; this keeps malformed config parse errors or future
  diagnostics from becoming a second secret-log channel. It also requires
  `systemctl is-active --quiet vps-agent.service` to succeed, then reads the
  unit's `Environment`, `ExecStart`, and `ReadWritePaths`. The active unit must
  contain exactly one `VPS_AGENT_CONFIG="$AGENT_CONFIG_PATH"` and exactly one
  `PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`, have
  exactly one `ExecStart` `path=` and one `argv[]`, both equal to
  `AGENT_BINARY_PATH`, and allow writes to both the directory containing
  `AGENT_CONFIG_PATH` and `DATA_DIR`. It also checks the active systemd sandbox
  values for `NoNewPrivileges=yes`, `MemoryDenyWriteExecute=yes`,
  `PrivateTmp=yes`, `ProtectClock=yes`, `ProtectHome=yes`,
  `ProtectHostname=yes`, `ProtectSystem=strict`,
  `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK`,
  `RestrictSUIDSGID=yes`, `ProtectKernelTunables=yes`,
  `ProtectKernelModules=yes`, `ProtectControlGroups=yes`,
  `LockPersonality=yes`, `RestrictRealtime=yes`, empty
  `CapabilityBoundingSet=` / `AmbientCapabilities=`,
  `SystemCallArchitectures=native`, and `UMask=0077`. Raw `systemctl` output is
  suppressed on failure, so service diagnostics cannot become a secret-log
  channel;
- before contacting master, the script resolves `DATA_DIR`, `IMAGE_DIR`, and
  the selected base image on the host; missing paths, symlinked data or image
  directories, non-regular or symlinked base image files, canonical escapes
  outside the controlled directories, world-accessible or group-writable data
  and image directories, and group/world-writable base-image paths are rejected;
- after path validation, the script runs `qemu-img info --output=json
  "${IMAGE_DIR}/${IMAGE_FILE}"` and requires the reported image `format` to be
  `qcow2`. This rejects raw or mismatched catalog/configuration mistakes before
  queueing a task, matching the agent's explicit `-F qcow2` base-image overlay
  contract. If the probe fails before returning JSON, the script suppresses raw
  `qemu-img info` stderr and prints only the bounded base-image read failure;
- the libvirt executor repeats the symlinked or non-directory `data_dir`
  rejection, the symlink/non-regular base-image rejection, and the non-qcow2
  base-image rejection before invoking `qemu-img create`, so manual
  catalog/config mistakes cannot reach the overlay creation boundary;
- before contacting master, the script also checks local executor prerequisites:
  `/dev/kvm` must exist as a character device, `virsh --connect qemu:///system
  version` must work, `virsh --connect qemu:///system net-info
  "$LIBVIRT_NETWORK_NAME"` must report `Active: yes` and
  `Bridge: $LIBVIRT_BRIDGE_NAME`, `qemu-img --version` must work, and either
  `cloud-localds --help` or `genisoimage --version` must succeed. If
  `cloud-localds` is installed but fails its probe, the smoke script falls back
  to `genisoimage`; if both probes fail, host verification stops before creating
  a VM. The agent repeats the libvirt active-network and bridge-match check, the
  `/dev/kvm` KVM character-device check in heartbeat/doctor/task preflight and
  reports missing and wrong-file-type failures distinctly. This prevents an
  obviously unready host from creating or running master tasks that the agent
  cannot complete. If the smoke script cannot read libvirt version metadata,
  libvirt network metadata, qemu-img version metadata, or qemu-img base-image
  metadata, it suppresses raw host tool stdout/stderr and prints only bounded
  non-secret preflight errors.
- all smoke-script curl calls to master pass `-q` and a `--proto` allow-list.
  The normal path uses `--proto '=https'`; HTTPS master URLs keep that allow-list
  even when `ALLOW_HTTP=1` is set. The local-only exception uses
  `--proto '=http,https'` only after the validated `MASTER_URL` itself is
  loopback HTTP. This keeps host-local curl configuration or malformed future URL
  handling from broadening the accepted transport protocol during acceptance
  runs;
- `ADMIN_TOKEN`, `NODE_ID`, `IMAGE_FILE`, `IMAGE_NAME`, `VM_NAME`, optional `SSH_PUBLIC_KEY`,
  optional `MASTER_CA_CERT_PATH`, optional `AGENT_CONFIG_PATH`,
  optional `AGENT_BINARY_PATH`, optional `AGENT_BINARY_SHA256`,
  optional `AGENT_BINARY_SHA256_PATH`,
  `LIBVIRT_NETWORK_NAME`, `LIBVIRT_BRIDGE_NAME`, sizing fields,
  `TIMEOUT_SECONDS`, `POLL_SECONDS`, `CURL_TIMEOUT_SECONDS`, `CLEANUP`,
  `ALLOW_HTTP`, `PRECHECK_ONLY`, `FULL_LIFECYCLE_REQUIRED`,
  `REINSTALL_AFTER_CREATE`, and `POWER_CYCLE_AFTER_CREATE` are
  validated before the script checks local files or calls master. Numeric range
  checks reject overlong digit strings instead of relying on shell arithmetic
  overflow behavior. `POLL_SECONDS`
  must be less than or equal to
  `TIMEOUT_SECONDS`, so a
  smoke run cannot configure a polling sleep longer than its overall task
  deadline. The wait loop also caps the final sleep to the remaining timeout,
  keeping timeout enforcement bounded even when the interval does not divide
  the total duration evenly.
  `NODE_ID` must be canonical 8-4-4-4-12 hex UUID text outside precheck-only mode, matching the
  Rust `Uuid` boundary. `IMAGE_FILE` uses the same safe file-name boundary as the image
  catalog, including rejection of leading dots, trailing dots, separators, and
  consecutive dots. `IMAGE_NAME` uses the master image catalog display-name
  boundary: 1-80 ASCII letters, numbers, spaces, dashes, or underscores.
  `SSH_PUBLIC_KEY`, when provided, must be a single OpenSSH public key with an
  allowed key type and base64-like body; private-key blocks, multiline values,
  quotes, backslashes, and shell-like comment metacharacters are rejected
  locally before any task is queued.
  `LIBVIRT_NETWORK_NAME` and `LIBVIRT_BRIDGE_NAME` must be 1-64 ASCII letters,
  numbers, dots, dashes, or underscores;
- in full mode, `ADMIN_TOKEN` must match the same bearer-compatible shape master
  accepts for admin secrets: non-empty, at most 256 characters, no whitespace,
  quotes, backslashes, backticks, or ASCII control characters. `PRECHECK_ONLY=1`
  deliberately skips this requirement so operators can prove host readiness
  before exposing an admin secret on the KVM host;
- in full mode, after `/healthz` but before any image, IP pool, plan, or task
  mutation, the script reads `GET /api/admin/nodes` through the authenticated
  admin API and selects only the configured `NODE_ID`. The node must be
  `online`, `scheduling_enabled=true`, have non-empty `agent_version` and
  `last_seen_at` values from the last two hours, and report
  `libvirt_status=available`. Failures are
  reduced to bounded smoke-script messages and the raw node-list JSON is not
  printed, so the readiness proof does not create a broad admin read leak.
  `PRECHECK_ONLY=1` does not call this admin endpoint;
- `FULL_LIFECYCLE_REQUIRED=1` is a final-acceptance guard. It is validated before
  host checks or master calls and requires `PRECHECK_ONLY=0`, `ALLOW_HTTP=0`,
  `CLEANUP=1`, `REINSTALL_AFTER_CREATE=1`, `POWER_CYCLE_AFTER_CREATE=1`, and either a
  non-empty `AGENT_BINARY_SHA256` or a validated hash file at
  `AGENT_BINARY_SHA256_PATH`. After `vps-agent doctor`, the script also requires
  `agent_binary_sha256_verified` to have been set by an actual `sha256sum`
  comparison before it proceeds to host preflight or master calls. This makes a
  create/delete-only smoke run or a run
  without installed-agent artifact proof useful for incremental host checks but
  unable to masquerade as the full create/reinstall/power/delete proof;
- the full smoke sequence explicitly checks and returns on each preflight,
  readiness, catalog-selection, task-queue, task-log, and audit-verification
  helper failure instead of relying on Bash `errexit`. Optional IP pool and plan
  selection no-op paths return success only when no corresponding selector was
  configured. A failed IP pool setup therefore cannot fall through into plan
  selection or `create_vm` queueing under a caller that invokes `main` from an
  `if` condition or command substitution;
- the script passes the validated shell state explicitly into Python JSON
  payload builders. It does not rely on ambient exported environment variables
  for image or VM task payloads, so script defaults and operator overrides follow
  the same validation path;
- when `IMAGE_FILE` already exists in the master image catalog but is disabled,
  the script re-enables that existing image through the authenticated admin API
  instead of trying to create a duplicate catalog row for the same file name.
  The create/re-enable response must return the expected `file_name` and
  `enabled=true` before the script queues a VM task;
- when a disabled catalog entry is re-enabled, the image id returned by
  `GET /api/admin/images` is validated as canonical UUID text before it is used
  in `/api/admin/images/<image_id>/enabled`. A hostile or malformed catalog
  response cannot redirect the smoke script to a different admin URL path;
- after `create_vm` is queued, the script treats the returned `kind.vm_id` as
  response data and validates it as canonical UUID text before waiting for the
  task, checking `vps-<vm_id>` in libvirt, building managed filesystem paths, or
  attempting cleanup. This mirrors the Rust `VmId` boundary in the shell smoke
  harness instead of trusting raw JSON strings for host operations;
- IPAM smoke input is explicit and non-ambiguous: the operator may set either
  `IP_POOL_ID`, which is validated as canonical UUID text, or
  `IP_POOL_CIDR` plus `IP_POOL_GATEWAY`, which are locally validated as an IPv4
  `/16` through `/30` pool with a usable gateway host. Setting both modes fails
  before any admin API mutation. In CIDR mode, the script reuses an existing
  master pool with the same CIDR/gateway or creates one with the validated
  `IP_POOL_NAME` before queueing `create_vm`. The create response must then
  include a complete assigned IPv4 tuple: `assigned_ip`, `assigned_ip_prefix`,
  and `assigned_gateway_ip`. The smoke verifier checks that tuple for the same
  network relationship as the Rust shared validator before trusting it for host
  file verification;
- plan smoke input is also explicit and non-ambiguous: the operator may set
  either `PLAN_ID`, which is validated as canonical UUID text, or `PLAN_SLUG`,
  which enables local plan catalog selection. In slug mode, `PLAN_NAME`,
  `PLAN_SLUG`, `CPU_CORES`, `MEMORY_MB`, and `DISK_GB` are validated before
  mutation. The script reuses only an enabled plan with the same slug and
  sizing, creates a new enabled plan when the slug is absent, and rejects a
  disabled matching plan or an existing slug with different sizing instead of
  creating a duplicate or silently changing catalog state. Plan create
  responses must echo the requested slug, concrete sizing, and `enabled=true`
  before the resulting `plan_id` is used in `create_vm`; once `create_vm`
  returns, the response must echo the same selected `kind.plan_id` before the
  smoke script polls the task, checks host state, or attempts cleanup;
- every task id returned by create/reinstall/start/stop/reboot/delete task APIs
  is also validated as canonical UUID text before the script interpolates it
  into `/api/admin/tasks/<task_id>` polling or log URLs. Failed response-id
  validation stops the current function immediately, so Bash command
  substitution cannot collapse an invalid id into an empty path segment and
  continue toward polling or host verification. The task polling helper also
  validates its `task_id` argument directly before any API call, so future smoke
  paths cannot bypass the response-id extractor and still build unsafe task
  URLs. Malformed JSON in those task responses becomes the same bounded
  response-field failure; the script does not print Python parser tracebacks or
  raw response bodies. Each polling response must also return the same `id`
  before its status is accepted, so a stale or cross-task response cannot
  satisfy the wait;
- reinstall/start/stop/reboot/delete task responses must also return a
  `kind.vm_id` that matches the VM created by the smoke run before the script
  polls the returned task id. A malformed or cross-VM response is rejected as
  weak acceptance evidence rather than being treated as proof of the requested
  VM action;
- task polling treats only `pending`, `assigned`, and `running` as in-progress
  states, `succeeded` as success, and `failed` / `canceled` as terminal failure.
  Any other status from master fails immediately without echoing the raw status
  value or polling until timeout. Missing or malformed status fields are also
  converted into a single non-secret smoke-script error instead of leaking JSON
  parser diagnostics. When a failed or canceled task does fetch task logs for
  operator context, the smoke script passes those logs through a local bounded
  redaction filter before printing to stderr. That filter redacts common
  token/password/credential/signature key-value shapes, authorization and agent
  authentication headers, cookie headers, URL userinfo credentials, PEM private
  key blocks, and the exact `ADMIN_TOKEN` value, then caps printed diagnostics
  at 8 KiB;
- after a task reaches `succeeded`, the smoke script reads
  `/api/admin/tasks/<task_id>/logs` and requires the fixed non-secret
  `task executor started` message on a row whose `task_id` matches the waited
  task and whose `node_id` matches the smoke `NODE_ID` before accepting create,
  optional lifecycle tasks, or cleanup delete as proven. This validates the
  task-log read model without depending on best-effort executor result logs,
  stale cross-task rows, or printing raw log response bodies;
- after all task-log and host-state checks pass, the smoke script reads
  `GET /api/admin/audit-logs` once and verifies task-scoped audit entries for
  create, optional reinstall, optional power actions, and cleanup delete. For
  each queued task it requires the admin task action, `task.assigned`,
  `task.status_update` with `status=succeeded`, and `task.log.append` with a
  positive byte count for the same `NODE_ID`, task id, task kind, and VM id. A
  missing or mismatched audit trail fails the smoke with a bounded message and
  does not print raw audit JSON;
- the script does not bypass platform controls: it queues normal authenticated
  admin API tasks, and the agent still validates VM parameters, image names,
  command arguments, libvirt paths, and controlled-directory ownership before
  touching host resources;
- all host command checks use fixed command names and argument arrays, not
  shell-built command strings, and the agent applies its own bounded timeout to
  each libvirt host command it starts;
- cleanup defaults to `CLEANUP=1`, which queues `delete_vm` after successful
  create verification. If a post-create action queue, task wait, or host
  verification fails, the smoke script attempts the same cleanup before
  returning failure, so a failed acceptance run does not silently leave the
  created VM behind. If `CLEANUP=0` is used for inspection, the operator must
  delete the VM afterward and verify the managed directory is removed.
- if cleanup fails, the script prints only non-secret manual inspection state:
  delete task id when available, `delete_task_id=unavailable` when master did
  not return a valid delete task, libvirt domain name, and managed VM
  directory. It does not print bearer tokens or embed destructive cleanup
  commands in the output.
- create verification requires the libvirt domain `vps-<vm_id>` to exist and
  report `running` through `virsh domstate`; a merely defined or paused domain
  is not accepted as a successful real-host smoke result. If the initial
  `virsh dominfo` probe fails, the smoke script suppresses raw host-tool output
  and prints only a bounded domain-unavailable message. If the `virsh domstate`
  probe fails, it likewise suppresses raw host-tool output and prints only a
  bounded unreadable-state message.
- cleanup delete verification treats a failed `virsh dominfo` probe as
  successful domain absence only when the hidden libvirt diagnostic is a known
  missing-domain message. Connection failures, permission failures, or other
  ambiguous host-tool errors fail closed without echoing raw `virsh` output.
- create verification also requires the managed VM directory plus `disk.qcow2`,
  `seed.iso`, `domain.xml`, `user-data`, and `meta-data` to be real filesystem
  objects, not symlinks. A symlinked managed artifact is treated as a failed
  smoke result even if its target exists. The cloud-init source files must be
  bounded UTF-8 text; `meta-data` must match the smoke VM id and `VM_NAME`, and
  `user-data` must include `#cloud-config`, `ssh_pwauth: false`, and
  `disable_root: true`. After domain metadata verification, the smoke script
  also runs `qemu-img info --output=json` on the managed `disk.qcow2` and
  requires the reported format to be `qcow2`, so a path that exists but is not a
  qcow2 VM disk is not accepted as real-host evidence. Because Bash disables
  `errexit` inside functions used as `if` conditions, the smoke script
  explicitly propagates non-shell helper failures with `return 1` at this
  boundary.
- when assigned IPv4 metadata is present, create verification also requires the
  managed cloud-init `network-config` file to be a real regular file under the
  VM directory. The file must be UTF-8, bounded in size, free of unexpected
  control bytes, and contain the assigned address/prefix, `dhcp4: false`, and
  default gateway returned by master. This makes real-host smoke cover the
  IPAM-to-guest-bootstrap path instead of only checking disk/domain artifacts.
- the smoke script parses the managed `domain.xml` after create and requires
  the active XML elements to contain the expected `vps-<vm_id>` name and VM
  UUID. The managed qcow2 path must be the single `device="disk"` source, and
  the managed seed ISO path must be the single `device="cdrom"` source. Spoofed,
  stale, or device-swapped local metadata is not accepted as evidence that the
  real libvirt create path worked. The smoke verifier also rejects
  `domain.xml` files larger than 1 MiB before parsing them, matching the agent's
  host-side metadata limit.
- successful smoke output includes explicit `lifecycle_coverage` booleans for
  `create_vm`, `delete_vm`, `reinstall_vm`, and `power_cycle`, plus
  `full_lifecycle_required`, `agent_config_registered`,
  `host_preflight_verified`, `master_health_verified`, `node_ready_verified`,
  and the task-log and audit verification flags.
  `host_preflight_verified` means the local agent config, installed binary,
  systemd service, KVM/libvirt/qemu/cloud-init tooling, controlled directories,
  and selected qcow2 base image passed before master mutations.
  `master_health_verified` means the smoke script reached the configured
  master `/healthz` endpoint using the same TLS/CA boundary as later admin API
  calls.
  `node_ready_verified` means the master node read model matched the requested
  `NODE_ID`, was online and schedulable, had completed registration, had a
  heartbeat newer than the two-hour smoke window, and reported
  `libvirt_status=available` before catalog mutation or task creation.
  This keeps acceptance evidence honest: a create/delete-only run cannot be
  mistaken for the full create, reinstall, power-cycle, and delete proof required
  before the overall platform goal is considered complete.
- the same successful smoke output includes only non-secret run context:
  `master_url`, `allow_http`, `ca_cert_configured`, `curl_timeout_seconds`,
  `node_id`, image file/name, controlled data/image directories, libvirt
  network/bridge names, base image format, VM sizing, and assigned IPv4 metadata
  when present. It records whether a CA certificate was configured, but never
  prints `MASTER_CA_CERT_PATH` or TLS private material. Final-acceptance runs
  require `AGENT_BINARY_SHA256` or a validated persisted hash at
  `AGENT_BINARY_SHA256_PATH`; after it is verified, the output includes
  `agent_binary_sha256_verified: true` and the normalized hash so the final
  evidence identifies the tested agent artifact.
  It deliberately does not
  echo `ADMIN_TOKEN`, bootstrap tokens, long-term agent credentials, CA
  material, client identity paths, or raw task and audit JSON.

This smoke script can prove the end-to-end libvirt path only when it is run on
an actual KVM-capable Linux host. Passing local Windows, Docker, or mock-executor
checks is not evidence that real VM creation is working. WSL kernels are
rejected explicitly so missing libvirt dependencies do not hide the more basic
host mismatch.

# Generated Install Command URL Boundary

Master validates both `MASTER_PUBLIC_BASE_URL` and `MASTER_INSTALLER_BASE_URL`
at startup and revalidates them inside install-command generation before
serving generated agent install commands.

Rules:

- both values must start with `https://`;
- both values must include a real host;
- both values must not use port-only authorities such as `https://:8443`;
- bracketed IPv6 authorities must have a closing bracket and any port must be
  numeric and between 1 and 65535;
- unbracketed IPv6 authorities are rejected;
- both values must not include username/password userinfo, query strings, or
  fragments;
- both values must not contain whitespace, control characters, quotes,
  backslashes, or backticks;
- URL authorities and paths must not contain encoded path separators (`%2f` /
  `%5c`) or percent-encoded ASCII controls, and URL paths must not contain
  literal or percent-encoded `.` / `..` segments, so generated installer and agent
  download URLs cannot be normalized to a different route by a client or
  reverse proxy;
- optional `MASTER_INSTALLER_CA_CERT_PATH` and
  `MASTER_INSTALLER_CLIENT_IDENTITY_PATH` values must be clean absolute Linux
  file paths with no parent traversal, whitespace, control characters, quotes,
  backslashes, or backticks before they can be emitted into the generated
  command;
- the generated bootstrap token is revalidated before command formatting and
  must remain a 1-256 character agent-secret-shaped value using only ASCII
  letters, numbers, dots, dashes, or underscores. If that invariant is ever
  broken, master refuses to return an install command instead of embedding
  unsafe token text in `--bootstrap-token`;
- the generated command downloads `install-agent.sh` with
  `curl -q -fsS --proto '=https' --connect-timeout 30 --max-time 300` and no
  `-L` / `--location`, so local `.curlrc` options are ignored, silent peers are
  bounded, and redirects fail instead of carrying a bootstrap token to a
  different URL;
- the generated command writes the installer to a temporary file, invokes
  `sudo bash --` only after curl succeeds, and registers an `EXIT` trap to
  remove the temporary file;
- the generated command quotes the optional `--cacert` value, the installer
  download URL passed to `curl`, and all installer arguments that contain
  deployment data.

This protects the command shown in the panel from deployment misconfiguration.
The generated command still contains a short-lived bootstrap token, so it must
remain copy/paste material for the target host only, not a string written into
shared logs or tickets.

# Source Security Scan Gate

Use `scripts/security-scan.sh --json` for the repo-local security scan. The
wrapper runs the CCG `verify-security` scanner against the source tree and
excludes generated dependency/build directories: `.next`, `target`, and
`node_modules`. It fails before invoking the scanner if a copied `flint/` source
tree is present. This keeps the explicit project rule enforceable: Flint may be
consulted externally for KVM/libvirt/cloud-init ideas, but its source, docs,
README, and UI must not live in this repository. Set `SECURITY_SCANNER` when the
scanner is not installed in the default Codex skill locations. On WSL, the
wrapper also checks the Windows `%USERPROFILE%` Codex and Agents skill
directories through `cmd.exe` plus
`wslpath`, because Codex Desktop may store skills under the Windows profile
while Bash sees a separate Linux `$HOME`. On WSL, the wrapper can call
`node.exe` and converts both the scanner path and scan root to Windows paths so
the scanner does not report a false `files_scanned: 0`. When `--json` is used,
the wrapper requires the scanner output to be valid JSON and fails closed if
`files_scanned` is missing, non-numeric, or not positive, or if `passed` is not
the boolean value `true`, because invalid JSON, a zero-file "pass", or a failed
scanner result is not evidence that source security checks ran and passed.
