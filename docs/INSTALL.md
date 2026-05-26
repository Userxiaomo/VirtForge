# MVP Install Guide

This document describes the MVP deployment path for the Rust VPS provisioning
platform. The current implementation is intentionally direct: master and
frontend run behind a TLS reverse proxy, PostgreSQL stores control-plane state,
and each KVM host runs the agent as a systemd service.

## Components

- `master`: Rust/axum/sqlx service. The recommended deployment is Docker.
- `frontend`: Next.js/TypeScript panel, served behind the same reverse proxy.
- `postgres`: PostgreSQL database, with the host port bound to loopback in compose.
- `caddy`: TLS terminator and reverse proxy for panel, APIs, installer, and downloads.
- `agent`: Rust/tokio daemon installed on each KVM host and run by systemd.

Public operator and agent URLs must use HTTPS. Local development may use
loopback HTTP, and Docker compose may use internal HTTP between containers, but
production hosts and agents must reach master through TLS.

## Local Development

Install a current Rust toolchain. The workspace is tested with Rust 1.88 or
newer:

```powershell
rustup default stable
cargo fmt --all
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

The project intentionally keeps Rust dead-code warnings active under clippy.
Do not add crate-wide `#![allow(dead_code)]`; remove unused placeholders or use
a narrow, documented exception for a deliberate future contract.

Frontend development:

```powershell
cd frontend
npm install
npm run lint
npm run build
```

When running the panel locally, set the server-side master API origin:

```powershell
$env:MASTER_API_BASE_URL = "https://panel.example.com"
npm run dev
```

`MASTER_API_BASE_URL` is the server-side URL used by the Next.js BFF when it
forwards the HttpOnly admin secret to master. It must be only an HTTP or HTTPS
origin, for example `https://panel.example.com` or the compose-internal
`http://master:8080`; do not include a path, query string, fragment, embedded
credentials, whitespace, quotes, backslashes, or backticks. Do not use port `0`
or ports above `65535`. `http://` is accepted only for loopback hosts, RFC1918 private IPv4 addresses, or
single-label internal service names such as `master`; public hosts must use
HTTPS.

`MASTER_FETCH_TIMEOUT_MS` optionally bounds each server-side frontend request to
master. The default is `30000`; accepted values are integer milliseconds from
`1000` through `300000`. Leave it unset unless the link between frontend and
master needs a deliberate longer timeout. Frontend-to-master server-side fetches
also handle redirects manually, so a `3xx` response is returned through the BFF
instead of automatically resending the HttpOnly admin secret to the redirected
URL.

## Master Environment

Example production settings:

```text
MASTER_HTTP_BIND=127.0.0.1:8080
MASTER_PUBLIC_BASE_URL=https://panel.example.com
MASTER_INSTALLER_BASE_URL=https://panel.example.com
MASTER_INSTALLER_CA_CERT_PATH=/etc/ssl/certs/master-ca.pem # optional host path emitted into generated install commands
MASTER_INSTALLER_CLIENT_IDENTITY_PATH=/etc/vps-agent/client-identity.pem # optional host path emitted into generated install commands
DATABASE_URL=postgres://vps:<postgres-password>@postgres:5432/vps
MASTER_ADMIN_USERNAME=admin
MASTER_ADMIN_TOKEN_HASH=$argon2id$v=19$...
MASTER_READONLY_TOKEN_HASH=$argon2id$v=19$... # optional
MASTER_REQUEST_BODY_LIMIT_BYTES=65536
RUST_LOG=vps_master=info,tower_http=info
```

Generate the admin secret hash:

```powershell
$env:SECRET_TO_HASH = "replace-with-a-long-random-admin-token"
cargo run -p vps-master --bin hash-secret
```

Do not write the plaintext admin secret into `.env`, logs, tickets, or docs.
`MASTER_ADMIN_TOKEN_HASH` must contain the PHC-formatted Argon2 hash printed by
`hash-secret`; master rejects an empty value and rejects plaintext-looking
values at startup. `MASTER_READONLY_TOKEN_HASH` may be empty. When configured,
it must also be a PHC-formatted Argon2 hash.

## Master MVP API

Direct admin API requests use:

```text
Authorization: Bearer <admin-token>
```

Create a node:

```bash
curl -X POST https://panel.example.com/api/admin/nodes \
  -H "Authorization: Bearer <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{"name":"node-01"}'
```

Generate a one-time agent bootstrap token:

```bash
curl -X POST https://panel.example.com/api/admin/nodes/<node_id>/bootstrap-tokens \
  -H "Authorization: Bearer <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{"expires_at":"2026-05-19T12:00:00Z"}'
```

`expires_at` must stay short-lived. The current master implementation accepts at
most 24 hours into the future.

Register an agent with that one-time token:

```bash
curl -X POST https://panel.example.com/api/agent/register \
  -H "Content-Type: application/json" \
  -d '{"node_id":"<node_id>","bootstrap_token":"<one-time-token>","agent_version":"0.1.0"}'
```

During registration, master consumes the one-time bootstrap token and writes the
long-term node credential in one database transaction. Both updates must affect
exactly one row before master returns the credential to the agent.
Registration success and registration-boundary errors such as malformed JSON or
rate limits use no-store response headers, matching the one-time bootstrap
token response boundary.

Send an authenticated heartbeat after registration:

```bash
curl -X POST https://panel.example.com/api/agent/heartbeat \
  -H "X-Agent-Credential: <agent-credential>" \
  -H "Content-Type: application/json" \
  -d '{"node_id":"<node_id>","agent_version":"0.1.0","libvirt_status":"not_checked","host_checks":[],"cpu_total":0,"cpu_used":0,"memory_total":0,"memory_used":0,"disk_total":0,"disk_used":0,"vm_count":0}'
```

Create a `create_vm` task:

```bash
curl -X POST https://panel.example.com/api/admin/tasks/create-vm \
  -H "Authorization: Bearer <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{"vm":{"node_id":"<node_id>","name":"demo-01","image":"debian-12.qcow2","cpu_cores":1,"memory_mb":512,"disk_gb":10}}'
```

## Agent Config

Default target path:

```text
/etc/vps-agent/agent.toml
```

Development/mock example:

```toml
master_base_url = "https://panel.example.com"
node_id = "00000000-0000-0000-0000-000000000000"
credential = "replace-with-agent-credential"
data_dir = "/var/lib/vps-agent"
# Optional private CA and client identity paths:
# ca_cert_path = "/etc/ssl/certs/master-ca.pem"
# client_identity_path = "/etc/vps-agent/client-identity.pem"

[executor]
mode = "mock"
```

The config file must be owner-only:

```bash
chmod 700 /etc/vps-agent
chmod 600 /etc/vps-agent/agent.toml
```

`/etc/vps-agent/agent.toml` must be a real regular file, not a symlink. The
installer refuses to write the bootstrap token through a symlinked config
directory, a config directory not owned by the installer UID (root in
production), loose config directory, symlinked config path, or over an existing
config file that grants group or other permissions. It also rejects a symlinked
final `data_dir` and, in libvirt mode, a symlinked final `image_dir` before
creating managed storage. The agent refuses to load a symlinked, unowned, or
loose config file, and registration save applies the same owner-only rule to the
config directory and config file before writing the long-term credential.
Registration save also rejects an existing symlinked or non-agent-owned config
directory before and after parent directory creation, so the credential cannot
be written through a redirected or cross-user `/etc/vps-agent` path. On Unix,
both the installer bootstrap write and registration save write a `0600`
same-directory temporary file and rename it over `agent.toml`, so a config-file
symlink that appears between validation and persistence is replaced rather than
followed. New config files are created with `0600` mode, and missing config
directories are created owner-only.

`data_dir` is a controlled host-storage root. It must be an absolute Linux path,
must not be `/`, must not contain `..`, and must not contain whitespace, control
characters, quotes, backslashes, or backticks. When `executor.mode = "libvirt"`,
`image_dir` follows the same rule and must be under `data_dir`, for example
`/var/lib/vps-agent/images`. During real libvirt execution, `data_dir` must
already exist as a real directory and must not be a symlink or regular file.

## Agent Installer Flow

`scripts/install-agent.sh` is the MVP host installer. It:

1. Checks root privileges.
2. Validates that `--master-url` and `--agent-url` are HTTPS URLs.
3. Installs KVM/libvirt/qemu/cloud-init dependencies.
4. Downloads the agent binary over HTTPS without following redirects.
5. Writes a temporary config containing only the short-lived bootstrap token.
6. Preflights that the config path can safely persist the registered credential.
7. Writes or clears the non-secret agent SHA-256 proof file for later smoke evidence.
8. Installs the systemd service.
9. Runs `vps-agent doctor` against the bootstrap config.
10. Starts the systemd service so the agent can register on first start.

The installer must not contain a long-term credential. It may contain only the
short-lived one-time bootstrap token generated by master. On first start, the
agent can run with only `bootstrap_token`. The installer does not call the
registration endpoint itself; it leaves that network identity exchange to the
agent process that will keep running under systemd. Before calling master
registration, the agent checks the same local save target that will later hold
the long-term credential. After successful registration, the agent receives a
long-term `credential`, saves it to the same config file, and removes the
bootstrap token.

Agent config validation rejects configs that contain both `bootstrap_token` and
`credential`. Local token and credential values must be non-empty, must be 256
bytes or shorter, and must not contain whitespace, path separators, control
characters, or shell-sensitive characters. Master registration and signed agent
API entry points apply the same shape checks before hash or HMAC verification.

## Libvirt Executor

Enable real KVM/libvirt execution explicitly:

```toml
master_base_url = "https://panel.example.com"
node_id = "00000000-0000-0000-0000-000000000000"
credential = "replace-with-agent-credential"
data_dir = "/var/lib/vps-agent"
# Optional private CA and client identity paths:
# ca_cert_path = "/etc/ssl/certs/master-ca.pem"
# client_identity_path = "/etc/vps-agent/client-identity.pem"

[executor]
mode = "libvirt"
image_dir = "/var/lib/vps-agent/images"
network_name = "default"
bridge_name = "virbr0"
```

The host must provide:

- `/dev/kvm`;
- `virsh` access to `qemu:///system`;
- `qemu-img`;
- a working `cloud-localds` or `genisoimage`;
- a real qcow2 base image under `image_dir`;
- an active libvirt network whose bridge matches the configured `bridge_name`.

The MVP supports the libvirt `default` network first. Bridge/public-IP/NAT/IPv6
extensions are follow-up network modes, not prerequisites for the current smoke
path.

## Phase-One Verification

After the design skeleton is present, verify:

- `Cargo.toml` defines the Rust workspace.
- `shared`, `master`, and `agent` crates exist.
- `frontend/package.json` exists for the Next.js panel.
- `docs/DESIGN.md`, `docs/SECURITY.md`, and `docs/INSTALL.md` exist.
- `cargo fmt --all -- --check`, `cargo clippy --workspace --all-targets -- -D warnings`,
  and `cargo test --workspace` pass on a machine with the Rust toolchain installed.
- `scripts/security-scan.sh --json` scans source files only. If the CCG
  `verify-security` scanner is not in the default Codex skill location, set
  `SECURITY_SCANNER` to its `security_scanner.js` path. On WSL, the wrapper also
  checks the Windows `%USERPROFILE%` Codex and Agents skill directories, because
  Codex Desktop may store skills outside the Linux `$HOME`. The wrapper fails if
  a JSON scan reports zero scanned files. It also fails before scanning when a
  copied `flint/` source tree exists, preserving the rule that Flint can be used
  only as an external architecture reference, not vendored source, docs, or UI.

# VM Inventory API Update

The master MVP now exposes VM inventory in addition to task history.

List VM inventory:

```bash
curl https://panel.example.com/api/admin/vms \
  -H "Authorization: Bearer <admin-token>"
```

Create VM still creates a task, but it also creates a VM inventory record in `provisioning` status:

```bash
curl -X POST https://panel.example.com/api/admin/tasks/create-vm \
  -H "Authorization: Bearer <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{"vm":{"node_id":"<node_id>","name":"demo-01","image":"debian-12.qcow2","cpu_cores":1,"memory_mb":512,"disk_gb":10}}'
```

VM action tasks require the VM to belong to the target node:

```bash
curl -X POST https://panel.example.com/api/admin/tasks/stop-vm \
  -H "Authorization: Bearer <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{"node_id":"<node_id>","vm_id":"<vm_id>"}'
```

Create an IPv4 pool for optional VM address reservation:

```bash
curl -X POST https://panel.example.com/api/admin/ip-pools \
  -H "Authorization: Bearer <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{"name":"pool-01","cidr":"192.0.2.0/29","gateway_ip":"192.0.2.1"}'
```

Then pass `ip_pool_id` when creating a VM. Master assigns `assigned_ip`, `assigned_ip_prefix`, and `assigned_gateway_ip`; callers should not submit their own IP address. Master commits the IP reservation, task row, IP-to-task link, VM inventory row, and create audit entry in one database transaction, so the agent cannot poll a pending create task before its ownership records exist. The agent still revalidates that the metadata is complete, that the prefix is `/16` through `/30`, and that the guest and gateway IPv4 host addresses are different addresses in the same network before execution. When present, libvirt mode writes a managed cloud-init v2 `network-config` file and includes it in the seed ISO.

# Image Catalog

Before creating a VM, register the base image in master:

```bash
curl -X POST https://panel.example.com/api/admin/images \
  -H "Authorization: Bearer <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{"name":"Debian 12","file_name":"debian-12.qcow2","enabled":true}'
```

The `image` field in `create_vm` must match an enabled catalog `file_name`. The agent host must also have the matching file under its configured `image_dir`, for example `/var/lib/vps-agent/images/debian-12.qcow2`.
Image file names are restricted to safe ASCII file names such as `debian-12.qcow2`; leading dots, trailing dots, consecutive dots, slashes, backslashes, and parent traversal are rejected before task creation.
When the libvirt executor runs, it rechecks the base image path on the host. The configured `data_dir` and `image_dir` must be real directories, not symlinks. The image file must be a real regular file, not a symlink; its resolved path must stay under the configured `image_dir`, and both `image_dir` and the image file must stay under `data_dir`. Before create or reinstall builds a qcow2 overlay, the agent also runs `qemu-img info --output=json <base-image>` and requires the reported format to be `qcow2`.

Disable or re-enable an image for future create/reinstall requests:

```bash
curl -X POST https://panel.example.com/api/admin/images/<image-id>/enabled \
  -H "Authorization: Bearer <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{"enabled":false}'
```

Disabling an image does not modify existing VMs that already use that image.

Reinstall an existing VM with its current image:

```bash
curl -X POST https://panel.example.com/api/admin/tasks/reinstall-vm \
  -H "Authorization: Bearer <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{"node_id":"<node-id>","vm_id":"<vm-id>"}'
```

To reinstall with a replacement image, include `"image":"debian-12.qcow2"`. Master validates that image against the enabled image catalog, then uses the VM inventory name and disk size for the task so the browser cannot change those values during reinstall.

Master validates the VM lifecycle before queueing any VM action. While a VM is
`provisioning`, wait for the current create or reinstall task to finish instead
of queueing start, stop, reboot, reinstall, or delete. Also wait when the VM's
`last_task_id` points at a `pending`, `assigned`, or `running` task; master uses
that reservation to prevent overlapping host commands even when the lifecycle
has not changed yet. Running VMs may be stopped, rebooted, reinstalled, or
deleted; stopped or error VMs may be started, reinstalled, or deleted. When
master accepts a reinstall or delete task, the VM inventory row moves to
`provisioning` or `deleting` immediately, before the agent polls, so later API
calls and the panel see that a disk-replacement or destructive operation is
already queued.
Accepted VM action writes are transactional. Master commits the task row, audit
row, `last_task_id` reservation, and any immediate VM inventory transition
together; if one write fails, the task is not queued. Start, stop, and reboot
keep the VM lifecycle unchanged until the authenticated agent reports the
result, while reinstall and delete reserve the inventory row immediately as
`provisioning` or `deleting`. The `GET /api/admin/vms` read model includes both
`last_task_id` and the joined `last_task_status`; the panel mirrors the guard by
hiding VM action buttons when that status is `pending`, `assigned`, or
`running`, but direct API callers still rely on the master-side guard as the
authority.
Master also repeats the lifecycle check while holding a PostgreSQL row lock on
the `vms` record in the same transaction that inserts action, reinstall, or
retry task rows. Concurrent API calls therefore serialize on the VM ownership
row before a new `last_task_id` can be reserved.

# Plan Catalog

Create at least one VPS plan before using the panel in a commercial workflow:

```bash
curl -X POST https://panel.example.com/api/admin/plans \
  -H "Authorization: Bearer <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{"name":"Small 1","slug":"small-1","cpu_cores":1,"memory_mb":512,"disk_gb":10,"enabled":true}'
```

List plans:

```bash
curl https://panel.example.com/api/admin/plans \
  -H "Authorization: Bearer <admin-token>"
```

Disable or re-enable a plan for future orders:

```bash
curl -X POST https://panel.example.com/api/admin/plans/<plan-id>/enabled \
  -H "Authorization: Bearer <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{"enabled":false}'
```

When a VM create request includes `plan_id`, master uses the plan sizing and ignores caller-supplied `cpu_cores`, `memory_mb`, and `disk_gb`. The plan lookup runs inside the same create-task transaction and holds a shared lock on the plan row, so disabling a plan cannot race between sizing selection and task persistence. The concrete sizing is still persisted into the task and VM inventory so the agent receives a simple explicit payload.
Disabled plans are rejected for new VM creation, but existing VMs that were created from that plan are left unchanged.

# Local Master-Agent Smoke

Use the local smoke script to verify the current MVP control-plane loop:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/smoke-master-agent.ps1
```

The script starts PostgreSQL and master in Docker, creates a node, generates a one-time bootstrap token, writes a temporary agent config, runs the agent with the mock executor, and verifies:

- the agent registers through the bootstrap token;
- the bootstrap token is removed from the local agent config after registration;
- the long-term agent credential is persisted in the temporary config;
- the agent doctor command succeeds against the registered config, while failure
  messages suppress raw doctor output because that config contains the
  long-term credential;
- master container logs printed by the local smoke harness on startup timeout or
  top-level failure are bounded to the requested tail count and redacted before
  display, so generated admin, bootstrap, and agent credential-like values are
  not copied into terminal logs. Agent authentication headers such as
  `X-Agent-Credential` and `X-Agent-Signature` are treated as secret-like values
  in this smoke-log boundary;
- VM tasks are rejected until the node has completed agent registration;
- disabling node scheduling rejects new VM tasks and pauses assignment of existing pending tasks until an admin re-enables scheduling; task insertion and task polling lock the node row while checking `scheduling_enabled`, so a maintenance toggle cannot race a new task into `pending` or `assigned`;
- create-VM tasks are rejected when the node is not online, has not heartbeated,
  has a heartbeat older than two hours, or explicitly reports
  `libvirt_status=unavailable`; `not_checked` remains allowed for the mock
  executor smoke path;
- reported node capacity rejects oversized create-VM tasks before IP allocation or task insertion, with create/retry admission serialized by a PostgreSQL row lock on the target node;
- node list responses expose committed CPU, memory, and disk capacity used by the admission guard;
- the agent pulls and completes a `create_vm` task;

- master commits authenticated agent task status updates, task-driven VM inventory changes, status-update audit rows, and failed-task summary logs in one transaction, with each VM lifecycle update required to affect one matching inventory row;
- successful `delete_vm` releases the reserved IP pool allocation and rejects later actions against the deleted VM;
- task logs are queryable from the master admin API and include the mock executor lifecycle messages.
- failed task `error_message` values are persisted on the task row after redaction.
- failed or canceled tasks can be retried by an admin, creating a new pending
  task while preserving the original terminal task; retry also rechecks the
  current VM lifecycle and enabled image catalog before the new task is queued,
  then commits the new retry task, VM inventory update, audit row, and any fresh
  IPAM reservation in one transaction.
- audit logs are queryable and include the key node/bootstrap/IP pool/task/agent lifecycle events.
- a caller-provided `X-Request-Id` is preserved into the matching audit row only
  when it is a short ASCII correlation ID and does not contain secret-bearing
  words such as `token`, `credential`, `password`, `secret`, or `private_key`;
  invalid values are replaced with a generated UUID.
- a read-only token can call read APIs but receives `403 Forbidden` on mutation APIs.
- task logs containing common secret patterns, PEM private-key blocks, or URL
  userinfo credentials are redacted before they are stored.
- agent log appends are accepted only for `assigned` or `running` tasks; failed
  task summaries are stored by master during the authenticated status update.
  The log insert is also guarded by the active task status, so a concurrent
  terminal transition rejects the late append instead of storing it.
- after executor work succeeds, result-log append failures are best-effort and
  do not block the agent from reporting `succeeded`; the terminal task status
  and audit entry are the authoritative completion record.
- transient failures while reporting terminal task statuses are retried by the
  agent so completed host work is less likely to remain visible as `running`.
- master guards agent status updates with the status that passed transition
  validation, so concurrent task changes return a conflict instead of being
  overwritten; accepted status changes are rolled back if the matching VM
  lifecycle update, audit write, or failed-task summary log cannot be persisted.
- non-line ASCII control bytes in task logs and failed-task summaries, such as
  terminal color escapes, are stored as visible `\xNN` text while newlines and
  tabs remain readable; the escaped/redacted value must still fit the 4096-byte
  storage limit.
- task logs with empty messages, messages over 4096 bytes, or NUL bytes are
  rejected before persistence.
- create-VM tasks must reference an enabled image from the master image catalog.
- a signed agent heartbeat cannot be replayed with the same nonce.
- signed agent request signatures must be one SHA-256 HMAC digest encoded as
  exactly 64 ASCII hex characters.
- malformed JSON sent to signed agent endpoints is rejected as `400 Bad Request`
  without logging the request body.
- pending or assigned tasks can be canceled by an admin, while running or
  finished tasks cannot be admin-canceled. In-flight libvirt work must finish
  or be reported canceled by the agent itself. Master guards the cancel update
  with the status it just validated, so a concurrent agent status change returns
  a conflict instead of being overwritten.
- accepted admin VM action and cancel requests persist their task row, audit
  row, and any immediate VM inventory or IP ownership update through one
  database transaction, so task queue state is not visible without its matching
  resource/audit record.
- invalid VM parameters, bootstrap token replay, and wrong-node signed requests are rejected.
- agent task ownership, `assigned` status, and payload checks run before the agent writes task-start logs, marks a task `running`, or enters mock/libvirt execution, so tasks for a different envelope `node_id`, non-assigned task statuses, `create_vm` payloads whose `node_id` does not match the task envelope, `create_vm` tasks missing the master-assigned `vm_id`, malformed or partial `assigned_ip` / prefix / gateway metadata, and malformed reinstall task fields such as unsafe VM names, image names, SSH public keys, or disk sizes are rejected at the worker boundary. When the rejected task is already assigned to this node, the agent reports it as `failed` with a redacted diagnostic instead of leaving it stuck in `assigned`.
- libvirt VM actions also parse and verify the agent-written `domain.xml` before `virsh` is invoked; mismatched VM IDs, domain names, disk paths, seed ISO paths, malformed XML, non-regular managed artifact paths, or spoofed fragments in comments are ownership failures, not best-effort host operations.

This smoke intentionally uses `VPS_AGENT_ALLOW_INSECURE_MASTER=1` and loopback HTTP inside the local Docker test path only. The agent still rejects non-loopback HTTP when this flag is set. Production deployment must still expose master to agents through HTTPS/TLS.
It also sets `VPS_AGENT_ALLOW_INSECURE_CONFIG_PERMS=1` because the temporary config is mounted from the local development filesystem and must be rewritten after registration. Production agents must keep `/etc/vps-agent` as a real owner-only directory owned by the agent process user and `/etc/vps-agent/agent.toml` as a real `0600` file owned by that same user; the agent refuses wider Unix permissions, wrong owners, symlinked config directories during save, and symlinked local secret files by default. The override applies only to the mounted agent config path, not to `client_identity_path` private-key permissions. Unix saves use a same-directory temp file and rename so the final write does not follow a newly swapped config symlink.

# Admin Login

For the MVP panel, configure one admin username and one admin secret:

```text
MASTER_ADMIN_USERNAME=admin
MASTER_ADMIN_TOKEN_HASH=$argon2id$v=19$...
```

Generate the hash from the plaintext admin password/secret:

```powershell
$env:SECRET_TO_HASH = "replace-with-a-long-random-admin-secret"
cargo run -p vps-master --bin hash-secret
```

Operators sign in to the browser panel with `MASTER_ADMIN_USERNAME` and the plaintext secret that matches `MASTER_ADMIN_TOKEN_HASH`. The master binary defaults the username to `admin` only when the variable is unset for local runs, but the production compose file requires `MASTER_ADMIN_USERNAME` explicitly so the deployed login identity is not an implicit default. Use a short ASCII admin username: 1-64 bytes containing only letters, numbers, dots, underscores, and dashes. Blank values, surrounding whitespace, slashes, quotes, backslashes, backticks, controls, and non-ASCII text are rejected during master config validation. Because the MVP uses the same secret for browser login and direct bearer-token API calls, choose a bearer-compatible secret: 1-256 visible ASCII characters without whitespace, quotes, backslashes, or backticks. The Next.js frontend accepts username/password login only, stores the secret in an HttpOnly, SameSite=strict cookie with an eight-hour lifetime, and forwards server-side calls to master as bearer-token admin API requests. The cookie is Secure for every environment except explicit `NODE_ENV=development`, so staging and production panel deployments must be served over HTTPS through Caddy or another TLS reverse proxy. The direct API form remains:

```text
Authorization: Bearer <admin-secret>
```

Master applies that same bearer-compatible shape check to both direct API
bearer headers and browser login passwords before Argon2 verification.

The browser panel adds `X-VPS-Panel-Request: same-origin` on state-changing same-origin `/api/*` calls. The frontend route handlers require that marker, reject cross-origin `Origin`, reject `Sec-Fetch-Site: same-site` / `cross-site` metadata, reject malformed UUID path parameters before proxying to master, apply `MASTER_FETCH_TIMEOUT_MS`, refuse automatic redirect following on their server-side calls to master, and add no-store headers to proxy successes and BFF-generated auth/path/mutation/upstream errors. The direct master `POST /api/admin/session` response also uses no-store headers for login success and login-boundary errors. Operators and scripts should continue to use the direct master admin API under `/api/admin/*` with `Authorization: Bearer <admin-secret>` instead of automating through the frontend cookie proxy.

# Agent Installer Status

`scripts/install-agent.sh` is now an MVP installer, not a placeholder.

Master serves it at:

```text
GET /scripts/install-agent.sh
```

The generated install command has this shape:

```bash
(install_agent_script=""; cleanup_install_agent_script() { [ -z "$install_agent_script" ] || rm -f "$install_agent_script"; }; \
  trap cleanup_install_agent_script EXIT; \
  install_agent_script="$(mktemp)" \
  && curl -q -fsS --proto '=https' --connect-timeout 30 --max-time 300 \
    --cacert '/etc/ssl/certs/master-ca.pem' \
    -o "$install_agent_script" 'https://panel.example.com/scripts/install-agent.sh' \
  && sudo bash -- "$install_agent_script" \
  --master-url 'https://panel.example.com' \
  --node-id '<node_id>' \
  --bootstrap-token '<one-time-bootstrap-token>' \
  --agent-url 'https://panel.example.com/downloads/vps-agent' \
  --agent-sha256 '<agent-binary-sha256-if-configured>' \
  --ca-cert-path '/etc/ssl/certs/master-ca.pem' \
  --client-identity-path '/etc/vps-agent/client-identity.pem')
```

`--agent-sha256` is emitted when `MASTER_AGENT_BINARY_PATH` points at the
served binary artifact. The outer non-redirecting
`curl -q -fsS --proto '=https'` always includes `--connect-timeout 30` and
`--max-time 300`; `--cacert` and the installer `--ca-cert-path` argument are
emitted when `MASTER_INSTALLER_CA_CERT_PATH` is configured.
`--client-identity-path` is emitted when
`MASTER_INSTALLER_CLIENT_IDENTITY_PATH` is configured. These are target-host
paths: master validates the strings are clean absolute Linux paths before
showing the command, and the installer validates file existence and permissions
on the host before writing `agent.toml`.

The installer performs:

- root privilege check;
- fail-closed option parsing for every value-taking flag, so a missing value or a following `--option` token stops before dependency installation, config writes, binary installation, or systemd changes;
- HTTPS base URL validation for `--master-url` and `--agent-url`, including real host requirement, rejection of port-only authorities, ports outside `1..=65535`, malformed bracketed IPv6 hosts, and rejection of embedded credentials, query strings, fragments, whitespace, quotes, backslashes, backticks, literal or percent-encoded dot path segments, encoded path separators (`%2f` / `%5c`) in authorities or paths, and percent-encoded ASCII controls in authorities or paths;
- `--bootstrap-token` validation before writing `agent.toml`; accepted token text is limited to ASCII letters, numbers, dots, dashes, and underscores and must be 256 characters or shorter;
- optional `--agent-sha256 <expected-sha256-hex>` validation for the downloaded
  agent binary before it is installed, followed by writing the normalized
  non-secret digest to `/etc/vps-agent/agent.sha256` through a same-directory
  temporary file, atomic rename, and final-path revalidation that rejects
  symlinks, non-regular files, and group/world-writable proof paths;
- stale `/etc/vps-agent/agent.sha256` removal when `--agent-sha256` is omitted,
  so an unverified reinstall cannot accidentally reuse old final-acceptance
  evidence;
- pre-install validation that `/usr/local/bin/vps-agent`, if it already exists,
  is a real regular file rather than a symlink or directory, and that the binary
  directory is a real directory rather than a symlink;
- canonical 8-4-4-4-12 hex UUID `--node-id` validation, TOML-safe config value validation that rejects quotes and control characters, controlled `--data-dir` / `--image-dir` validation, and libvirt network/bridge identifier validation before writing config;
- KVM/libvirt/qemu/cloud-init dependency installation for `apt-get`, `dnf`, or `yum`;
- agent binary download to `/usr/local/bin/vps-agent` with curl `-q` first,
  constrained to HTTPS (`--proto '=https'`), without redirect following, with a
  30-second connect timeout and a 300-second total transfer timeout, so
  root/user `.curlrc` settings cannot add `--insecure`, redirects, or headers
  and a silent peer cannot stall the installer indefinitely. If curl fails, raw
  stdout/stderr is suppressed, a partial output file is not installed, and the
  installer reports only `agent download failed`. After a successful download
  and optional checksum verification, the installer writes the executable mode
  to a same-directory temporary file, revalidates the binary directory and
  `/usr/local/bin/vps-agent`, and commits with `mv -fT`, so a symlink swapped in
  during the download window is rejected before the final binary replacement;
- `/etc/vps-agent/agent.toml` creation through a same-directory temporary file and rename with `0600` permissions after rejecting a pre-existing symlinked config directory, unowned or loose config directory, symlinked config path, or an existing config file that is not owned by the installer UID or grants group/other permissions. The installer revalidates the final config path after the rename instead of chmodding that destination path, and the agent preflights and preserves the same real-directory and owner-only requirements before it asks master to consume the bootstrap token and when it later saves the long-term credential;
- optional `ca_cert_path` writing for private master CAs;
- optional `client_identity_path` writing for deployments that are preparing mTLS at the reverse proxy;
- `/var/lib/vps-agent` and image directory creation after rejecting symlinked final managed-directory paths, directories not owned by the installer UID (root in production), or loose pre-existing directory permissions;
- `vps-agent doctor` execution before service enable/start, unless `--skip-doctor` is passed; failed doctor output is suppressed and replaced with a bounded rerun hint because the config still contains the one-time bootstrap token;
- systemd unit installation after rejecting a pre-existing or pre-rename
  symlinked/non-regular `/etc/systemd/system/vps-agent.service` target and a
  systemd service directory that is not owned by the installer UID (root in
  production) or is group/world-writable, then writing the unit through
  a same-directory temporary file plus atomic rename;
- service enable/start through checked `systemctl` steps whose raw output is
  suppressed and replaced with a bounded failed-step message.

In `libvirt` mode, the agent reports `libvirt_status` and structured `host_checks` in heartbeat data. `available` means `data_dir` and `image_dir` are real controlled directories, any pre-existing `data_dir/vms` parent is also a real directory, `/dev/kvm` exists as a character device, `virsh`, the configured libvirt network is active and its `Bridge:` value matches the configured bridge, the bridge interface exists, `qemu-img`, and either `cloud-localds` or `genisoimage` passed preflight; `unavailable` means at least one host dependency check failed. The panel stores and shows these checks in node detail, including non-secret diagnostic messages for failed or not-yet-checked items, so an operator can fix the host before sending real VM tasks. The agent redacts common secret key/value shapes from failed host command stderr, failed preflight diagnostics, and host-check messages before local doctor output or master heartbeat storage can display them, and it escapes non-line ASCII control bytes such as ANSI color escapes before the heartbeat is sent. Master rejects any host-check message that still contains ASCII control bytes.

Heartbeat resource metrics are read-only. The agent does not create `data_dir`
while collecting disk capacity or VM count, and it does not follow symlinked
`data_dir` or `data_dir/vms` paths. If those paths are missing or unsafe, the
heartbeat reports zero disk capacity or zero managed VMs until the host storage
layout is fixed. Master rejects heartbeat metadata with an unsafe
`agent_version` and rejects impossible resource snapshots where `cpu_used`,
`memory_used`, or `disk_used` exceeds the corresponding total.

The installed agent is a daemon. It loops forever under systemd, with `heartbeat_interval_seconds = 30` written into `/etc/vps-agent/agent.toml` by default. Agent config validation accepts heartbeat intervals from 1 through 3600 seconds and rejects larger values before the service loop starts. Local smoke tests set `VPS_AGENT_RUN_ONCE=1`; production services should not set that variable. The service runs as root for the MVP libvirt path, but the unit enables systemd sandboxing: `NoNewPrivileges=true`, `ProtectSystem=strict`, `ReadWritePaths=/etc/vps-agent /var/lib/vps-agent`, `ProtectHome=true`, `PrivateTmp=true`, `ProtectClock=true`, `ProtectHostname=true`, kernel/control-group protections, empty `CapabilityBoundingSet=` / `AmbientCapabilities=`, `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK`, `MemoryDenyWriteExecute=true`, `RestrictSUIDSGID=true`, native syscall architecture filtering, `UMask=0077`, and `PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` for host tool lookup. `MemoryDenyWriteExecute=true` blocks writable executable memory mappings; the Rust daemon and non-JIT libvirt/qemu/cloud-init tools do not require them. `RestrictSUIDSGID=true` prevents the daemon or child tools from staging new setuid/setgid filesystem objects; this is not needed for VM provisioning.

Each HTTPS call from the agent to master has a bounded client timeout. The
default is 30 seconds. Set `VPS_AGENT_HTTP_TIMEOUT_SECONDS` on the systemd
service only when the deployment needs a different bound; accepted values are
`1..=300`. This behaves like C# `HttpClient.Timeout`: it limits a single silent
request, while the normal agent loop continues to authenticate, retry on the
next iteration, and report failures through tracing without logging secrets.
The agent client also refuses HTTP redirects; if master or the reverse proxy
returns a 3xx response, that request fails instead of resending the bootstrap
token or long-term agent credential to the redirected URL.

In `libvirt` mode, local host commands are also bounded. The agent starts
`virsh`, `qemu-img`, `cloud-localds`, and `genisoimage` with fixed argument
arrays and a five-minute per-command timeout. If a host tool hangs during
doctor, preflight, create, reinstall, power action, or delete, the current check
or task fails instead of leaving the `vps-agent` service stuck forever.

The written `master_base_url` must be a clean HTTPS base URL with a real host. Do not use a port-only authority such as `https://:8443`, do not use port `0` or ports above `65535`, do not leave bracketed IPv6 hosts unterminated, and do not include embedded credentials, query strings, fragments, whitespace, quotes, backslashes, backticks, literal / percent-encoded `.` / `..` path segments, encoded path separators (`%2f` / `%5c`), or percent-encoded ASCII controls. `VPS_AGENT_ALLOW_INSECURE_MASTER=1` only permits `http://` for loopback local smoke-test URLs such as `localhost`, `127.0.0.1`, or `[::1]`; it does not allow malformed, secret-bearing, or non-loopback HTTP URLs.

If an installer option that requires a value is passed without one, or if its next token is another `--option`, the script exits with an `install-agent:` error before making host changes. This keeps malformed generated commands and manual copy/paste mistakes inside the argument-validation boundary.

The written `data_dir` and libvirt `image_dir` are validated before the installer creates directories and again when the agent loads config. Keep the default `/var/lib/vps-agent` and `/var/lib/vps-agent/images` unless you have a dedicated absolute Linux path for the agent. Do not point either value at `/`, a relative path, a path containing `..`, or an image directory outside the data directory. On a real libvirt host, keep `data_dir` as an actual directory owned by root, not a symlink to another location; the executor rejects symlinked or non-directory data roots before creating VM paths. If these directories already exist, the installer fails closed when they are not owned by the installer UID (root in production), when the config directory grants any group/other access, or when data/image directories are group-writable or accessible by other users; newly-created directories use `0700` for config and `0750` for data/image storage.

The optional `ca_cert_path` and `client_identity_path` values are also validated
before being written and again when the agent loads config. Use clean absolute
Linux file paths such as `/etc/ssl/certs/master-ca.pem` or
`/etc/vps-agent/client-identity.pem`; do not use `/`, relative paths, `..`,
spaces, quotes, backslashes, backticks, tabs, or control characters.
The CA trust-anchor file may be system-readable, but it must be a real regular
file, not a symlink, and must not be group/world-writable. The client identity
PEM is a local secret and must be a real regular file, not a symlink, with
owner-only permissions and the same owner UID as the installer/agent process
user. The local smoke config-permission override does not relax this private-key
file rule.

Before creating the first VM on a new host, run the local doctor command:

```bash
VPS_AGENT_CONFIG=/etc/vps-agent/agent.toml vps-agent doctor
```

For `mock` mode, this verifies config loading, HTTPS/TLS file paths, and local secret-file permissions. For `libvirt` mode, it also runs the host preflight checks for controlled `data_dir` / `image_dir` storage, a safe pre-existing `data_dir/vms` parent, `/dev/kvm` as a KVM character device, `virsh --connect qemu:///system version`, `virsh --connect qemu:///system net-info <network_name>` with `Active: yes` and `Bridge: <bridge_name>`, `/sys/class/net/<bridge_name>`, `qemu-img --version`, and cloud-init seed ISO tooling (`cloud-localds` preferred, `genisoimage` accepted). Missing `/dev/kvm` and non-device `/dev/kvm` failures are reported distinctly. This gives an operator a quick host-readiness signal before the master sends a real `create_vm` task.

By default the installer downloads the agent binary from:

```text
https://panel.example.com/downloads/vps-agent
```

If the binary is hosted elsewhere, pass:

```bash
--agent-url https://downloads.example.com/vps-agent
```

To pin the expected binary, also pass its SHA-256:

```bash
--agent-sha256 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

If master uses a private CA, place the PEM file on the host first and add:

```bash
--ca-cert-path /etc/ssl/certs/master-ca.pem
```

The generated command uses that PEM file for the first installer-script
download with
`curl -q -fsS --proto '=https' --connect-timeout 30 --max-time 300 --cacert`
and does not follow redirects. The installer then uses the same file when
writing `ca_cert_path` into `agent.toml` and when downloading the agent binary
with the same non-redirecting HTTPS-only curl policy plus bounded connect and
transfer timeouts.
The CA file can be system-readable, but it must not be writable by group or
other users; use a mode such as `0644` or stricter, not `0660`, `0664`, or
`0666`.

If the deployment TLS boundary already requires agent client certificates, place one PEM file containing the agent client certificate and private key on the host first and add:

```bash
--client-identity-path /etc/vps-agent/client-identity.pem
```

This lets the agent present a certificate during the HTTPS handshake. The reverse proxy must still be configured separately to verify that certificate and bind it to the expected node identity.

Do not use `VPS_AGENT_ALLOW_INSECURE_MASTER=1` for this. That switch is reserved for the loopback local smoke test path.

To make the default download URL work, build a Linux agent binary and mount it into the master container:

On a Linux deployment host:

```bash
bash scripts/build-agent-binary.sh
```

On Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-agent-binary.ps1
```

This writes `dist/vps-agent`. The file is ignored by git because it is a build artifact.
Both helpers run Docker with structured arguments and separate the Cargo build
step from the artifact export step; they do not use `bash -c`, `sh -c`, or
chained shell command strings.
The JSON output includes `agent_sha256`, computed from the exported file after
the Docker build and copy steps. Use that value when comparing the mounted
artifact with generated installer commands:

```bash
bash scripts/build-agent-binary.sh
```

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-agent-binary.ps1 |
  ConvertFrom-Json |
  Select-Object agent_binary, agent_sha256
```

Then include the artifact compose override:

```bash
export MASTER_AGENT_BINARY_HOST_PATH="$(pwd)/dist/vps-agent"
docker compose -f deploy/docker-compose.yml -f deploy/docker-compose.agent-artifact.yml up -d --build
```

```powershell
$env:MASTER_AGENT_BINARY_HOST_PATH = (Resolve-Path .\dist\vps-agent).Path
docker compose -f deploy/docker-compose.yml -f deploy/docker-compose.agent-artifact.yml up -d --build
```

The override requires `MASTER_AGENT_BINARY_HOST_PATH` so compose fails before
startup if the operator has not selected the exact release artifact. It mounts
that host file into the master container at `/opt/releases/vps-agent` with a
read-only bind mount and `create_host_path: false`, so Docker Compose will not
silently create a directory when the selected artifact path is wrong. It sets:

```text
MASTER_AGENT_BINARY_PATH=/opt/releases/vps-agent
```

Master serves that file at `GET /downloads/vps-agent`. If `MASTER_AGENT_BINARY_PATH`
is configured and points at a readable regular file no larger than 128 MiB,
generated bootstrap install commands include `--agent-sha256` with the file's
current SHA-256. Symlinks, directories, special files, and oversized artifacts
are rejected before hashing or serving. If the path is unset, the download
endpoint returns 404 and generated commands omit the checksum; the installer
still supports explicit `--agent-url` downloads without a checksum, but pinned
checksums are preferred for production artifacts. If the path is configured but
unreadable, not a regular file, or too large, bootstrap-token creation fails
instead of returning an install command that cannot be verified.

The installer only writes the short-lived bootstrap token, using a same-directory temporary `agent.toml` file and rename so the local secret is not streamed directly into the final path. It revalidates the final config path after that rename, rather than applying a post-rename chmod to the destination. It never writes a long-term credential. The running agent checks that the same config path can safely persist a credential before exchanging the bootstrap token with master, then persists the returned credential locally and removes `bootstrap_token` from the config.

# Docker Compose Deployment

The MVP compose file now includes PostgreSQL, master, frontend, and Caddy:

```powershell
$env:DOMAIN = "panel.example.com"
$env:MASTER_PUBLIC_BASE_URL = "https://panel.example.com"
$env:MASTER_INSTALLER_BASE_URL = "https://panel.example.com"
$env:POSTGRES_PASSWORD = "<long-random-postgres-password>"
$env:MASTER_ADMIN_TOKEN_HASH = "<argon2-admin-token-hash>"
$env:MASTER_READONLY_TOKEN_HASH = "<optional-argon2-readonly-token-hash>"
$env:MASTER_REQUEST_BODY_LIMIT_BYTES = "65536"
docker compose -f deploy/docker-compose.yml up -d --build
```

On Windows, Docker Compose may use the Bake/Buildx path for `--build`. If the project lives in a non-ASCII path and Compose fails before reading the Dockerfiles, prebuild the images with the helper script and start Compose without rebuilding:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\build-docker-images.ps1
$env:MASTER_AGENT_BINARY_HOST_PATH = (Resolve-Path .\dist\vps-agent).Path
docker compose -f deploy/docker-compose.yml -f deploy/docker-compose.agent-artifact.yml up -d --no-build
```

The helper builds `vps-master:local` and `vps-frontend:local`, which match the default image names in `deploy/docker-compose.yml`. It uses Docker's host build network by default because some Docker Desktop build sandboxes fail Cargo or npm TLS fetches while normal containers can reach the registries. To use Docker's default build network instead, pass `-BuildNetwork default`.
Like the agent artifact builder, this helper invokes Docker through PowerShell
argument arrays and is covered by the build-script validation gate that rejects
`bash -c`, `sh -c`, and chained shell operators in build helpers.

The compose PostgreSQL healthcheck uses Docker's `CMD` array form:
`["CMD", "pg_isready", "-U", "vps", "-d", "vps"]`. The master healthcheck also
uses `CMD` array form and calls `curl -q -fsS` against `/healthz`, so curl does
not read container-local config files. Do not change these probes to
`CMD-SHELL`; deployment health probes should not need shell command strings.
Caddy also has an exec-form healthcheck:
`["CMD", "caddy", "validate", "--config", "/etc/caddy/Caddyfile"]`, so a bad
mounted Caddyfile or missing required domain environment marks the public proxy
unhealthy.
Compose also starts PostgreSQL, master, frontend, and Caddy with
`security_opt: no-new-privileges:true`, so container processes cannot gain new
privileges through setuid binaries or file capabilities after startup.
PostgreSQL can still drop to its `postgres` runtime user; this flag blocks
privilege gains, not privilege reduction.
Master and frontend also drop all Linux capabilities through `cap_drop: [ALL]`;
they run on high internal ports and do not need host-administration privileges.
PostgreSQL, master, frontend, and Caddy set `pids_limit: 256` to bound
process/thread growth inside database, public, and control-plane containers.
Master, frontend, and Caddy also run with read-only root filesystems and a
bounded `/tmp` tmpfs mounted `rw,noexec,nosuid,size=64m`. Caddy keeps its ACME
and runtime state in the named `caddy-data` and `caddy-config` volumes; master
and frontend should stay stateless at the container filesystem level.
All services use Docker `json-file` logging with `max-size: "10m"` and
`max-file: "5"` so deployment logs rotate instead of filling the master host
disk.
All base services also use `restart: unless-stopped`, so Docker restarts the
database, master, frontend, and TLS proxy after daemon restarts or unexpected
container exits while still respecting an explicit operator stop.

Generate the admin token hash before starting:

```powershell
$env:SECRET_TO_HASH = "replace-with-a-long-random-admin-token"
docker run --rm -v "${PWD}:/work" -w /work rust:1.88 cargo run -q -p vps-master --bin hash-secret
```

Services:

- `postgres`: PostgreSQL database and migration target. Its optional host port is bound to `127.0.0.1:${POSTGRES_HOST_PORT:-5432}` for local administration only; master and migrations use the internal `postgres:5432` Docker network address. Compose enables Docker `no-new-privileges` and gives it persistent storage, a bounded PID budget, bounded JSON-file logs, a healthcheck, and `restart: unless-stopped`.
- `master`: Rust axum API, migrations run on startup. The release binary is
  built in a Rust builder stage, then copied into a slim Debian runtime image
  that does not include the Rust compiler or Cargo. The runtime container runs
  as the non-root `vps` user, has Docker `no-new-privileges` enabled, drops
  all Linux capabilities, and uses a read-only root filesystem with bounded
  `/tmp`, with a bounded PID budget. Compose probes
  `http://127.0.0.1:8080/healthz` before dependent services are considered
  ready.
- `frontend`: Next.js panel. It waits for a healthy master before startup. It calls master through the internal `MASTER_API_BASE_URL=http://master:8080`, which is accepted because `master` is a single-label internal service name and the BFF validates this setting as an origin with any explicit port in `1..=65535` before forwarding the admin cookie secret. `MASTER_FETCH_TIMEOUT_MS` is passed through compose with a `30000` millisecond default, and the BFF handles master redirects manually rather than resending the cookie-derived bearer secret to redirect targets. Compose probes `http://127.0.0.1:3000/` before Caddy is considered ready. The runtime container runs as the non-root `node` user, has Docker `no-new-privileges` enabled, drops all Linux capabilities, uses a read-only root filesystem with bounded `/tmp`, and has a bounded PID budget.
- `MASTER_REQUEST_BODY_LIMIT_BYTES` defaults to `65536`; keep it small for JSON control-plane APIs and raise it only within the documented maximum if an operator has a concrete payload-size need.
- `caddy`: public HTTPS entrypoint. It waits for healthy master and frontend containers before starting its reverse proxy, validates the mounted Caddyfile through its own healthcheck, keeps writable state in named volumes, and compose enables Docker `no-new-privileges`, a read-only root filesystem with bounded `/tmp`, plus a bounded PID budget for the public-facing proxy process.

Master validates numeric and socket environment variables during startup. Invalid
values for settings such as `MASTER_HTTP_BIND`,
`MASTER_ADMIN_RATE_LIMIT_PER_MINUTE`, `MASTER_AGENT_RATE_LIMIT_PER_MINUTE`,
`MASTER_AGENT_REGISTRATION_RATE_LIMIT_PER_MINUTE`, or
`MASTER_REQUEST_BODY_LIMIT_BYTES` stop the service with a structured error
instead of a Rust panic. Master also validates that `MASTER_ADMIN_TOKEN_HASH` is
set to a PHC password hash and that a non-empty `MASTER_READONLY_TOKEN_HASH` is
also a PHC password hash. Treat those as deployment configuration failures and
fix the environment before restarting the container. Rate-limit values must stay
within `1..=60000` requests per minute; higher values are rejected so a typo does
not effectively disable throttling. Secret-derived rate-limit buckets use
in-memory SHA-256 labels, so bearer/bootstrap/agent secrets are not stored as
plaintext bucket keys.

`DOMAIN`, `MASTER_PUBLIC_BASE_URL`, `MASTER_INSTALLER_BASE_URL`,
`POSTGRES_PASSWORD`, and `MASTER_ADMIN_TOKEN_HASH` are required for compose
deployment and have no defaults. Use a long random database password, generate
the admin hash before startup, and set public URLs to the real HTTPS entrypoints
that agents and operators will use. `MASTER_ADMIN_TOKEN_HASH` must be the PHC
hash output from `hash-secret`, not the plaintext admin secret.
`MASTER_READONLY_TOKEN_HASH` is optional; leave it unset to disable the read-only
token, or set it to a PHC hash for a read-only operator secret.
`MASTER_INSTALLER_CA_CERT_PATH`
and `MASTER_INSTALLER_CLIENT_IDENTITY_PATH` are optional host-local paths that,
when set, are copied into generated bootstrap install commands as
`--ca-cert-path` and `--client-identity-path`.

The single-domain Caddyfile also requires `DOMAIN` when run outside compose.
There is no built-in localhost fallback in the production Caddyfile; use an
explicit local override only for an isolated lab.
Compose mounts the Caddyfile as an explicit read-only bind with
`create_host_path: false`, so a missing `deploy/caddy/Caddyfile` fails at
startup instead of being silently created as an empty host path.

Caddy routing:

- `/api/agent/*` goes directly to master for agent registration, heartbeat, task polling, logs, and status updates.
- `/api/admin/*` goes directly to master for operator scripts that use `Authorization: Bearer <admin-secret>`.
- `/scripts/*` goes directly to master so generated install commands can download `install-agent.sh`.
- `/downloads/*` goes directly to master so generated install commands can download the configured `vps-agent` binary artifact.
- `/healthz` goes to master.
- all other browser traffic goes to the frontend.

The Caddy sites also send `Strict-Transport-Security: max-age=31536000`,
`X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, and
`Referrer-Policy: no-referrer`. Use a deliberate local-only override if you need
to test an HTTP lab; production should keep these headers enabled.

For local smoke tests, `scripts/smoke-master-agent.ps1` still starts only the services it needs and remains separate from full compose deployment.

# Split-Domain Agent mTLS Deployment

The default `deploy/caddy/Caddyfile` is the MVP single-domain HTTPS deployment. For stricter agent transport identity, use the split-domain example:

```powershell
$env:PANEL_DOMAIN = "panel.example.com"
$env:AGENT_DOMAIN = "agents.example.com"
$env:DOMAIN = "panel.example.com"
$env:MASTER_PUBLIC_BASE_URL = "https://agents.example.com"
$env:MASTER_INSTALLER_BASE_URL = "https://panel.example.com"
$env:MASTER_INSTALLER_CLIENT_IDENTITY_PATH = "/etc/vps-agent/client-identity.pem"
$env:POSTGRES_PASSWORD = "<long-random-postgres-password>"
$env:AGENT_CLIENT_CA_PATH = "C:\secure\agent-client-ca.pem"
$env:MASTER_ADMIN_TOKEN_HASH = "<argon2-admin-token-hash>"
$env:MASTER_READONLY_TOKEN_HASH = "<optional-argon2-readonly-token-hash>"
docker compose -f deploy/docker-compose.yml -f deploy/docker-compose.mtls.yml up -d --build
```

In this mode:

- `https://panel.example.com` serves the browser panel, installer script, and agent binary download.
- `https://agents.example.com/api/agent/*` requires a client certificate signed by `AGENT_CLIENT_CA_PATH`.
- `https://panel.example.com/api/agent/*` returns 404, keeping agent traffic on
  the client-authenticated agent domain instead of falling through to the
  browser frontend.
- master generates install commands that download from `MASTER_INSTALLER_BASE_URL` but configure the agent with `--master-url https://agents.example.com`.
- if `MASTER_INSTALLER_CLIENT_IDENTITY_PATH` is set, generated commands include `--client-identity-path`; install that PEM on the host at the same path before running the command.

The client identity PEM should contain the client certificate and private key in a format accepted by reqwest/rustls. Keep that file readable only by root as a real non-symlink regular file before running the installer. The installer and agent both enforce that private-key file boundary even when local smoke config-permission overrides are enabled, and `/etc/vps-agent/agent.toml` must still be `0600` in production.
The mTLS compose override mounts both `deploy/caddy/Caddyfile.mtls.example` and
`AGENT_CLIENT_CA_PATH` as explicit read-only binds with `create_host_path:
false`, so missing proxy config or CA files fail as deployment errors before
Caddy serves the agent API domain.

# Optional VM SSH Public Key

When creating a VM, pass an OpenSSH public key if the guest should be reachable without a password:

```bash
curl -X POST https://panel.example.com/api/admin/tasks/create-vm \
  -H "Authorization: Bearer <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "vm": {
      "node_id": "<node-id>",
      "plan_id": "<plan-id>",
      "name": "demo-1",
      "image": "debian-12.qcow2",
      "ssh_public_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... operator@example"
    }
  }'
```

The agent injects this key through cloud-init for the guest `vps` user. Do not pass private keys or passwords; master rejects multiline and unsupported key values.

The agent also revalidates the SSH public key if it appears in a task payload, including reinstall tasks that normally copy the key from VM inventory. This is a host-side defense-in-depth check and applies before both mock and libvirt executors.

# Real KVM Host Smoke

After the master, frontend, and a libvirt-mode agent are deployed, run the
real-host smoke script on the Linux KVM host to verify the full create/delete
VM path. This is not a Windows or Docker-only check; it must run where
`/dev/kvm`, `virsh --connect qemu:///system`, and the agent-managed data
directory are available. WSL is rejected explicitly before the script checks
libvirt tools because it cannot prove the bare-metal KVM path.

Prerequisites:

- the node has already been created in master;
- the agent has registered successfully and is running with
  `executor.mode = "libvirt"`;
- master shows the node as online, schedulable, registered with an
  `agent_version`, heartbeating within the last two hours with `last_seen_at`,
  and reporting `libvirt_status=available`;
- `/etc/vps-agent/agent.toml` is a real non-symlink file owned by the agent
  process user with owner-only permissions, and its `node_id`, `data_dir`,
  `[executor].image_dir`,
  `[executor].network_name`, and `[executor].bridge_name` match the values used
  by the smoke script;
- `/usr/local/bin/vps-agent` is a real executable file, not a symlink, and
  `VPS_AGENT_CONFIG=/etc/vps-agent/agent.toml /usr/local/bin/vps-agent doctor`
  passes;
- `vps-agent.service` is active under systemd, its active `Environment`
  contains exactly one `VPS_AGENT_CONFIG=$AGENT_CONFIG_PATH` and exactly one
  `PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`, its
  active `ExecStart` uses `AGENT_BINARY_PATH`, its `ReadWritePaths` includes both the
  configured agent config directory and `DATA_DIR`, and key sandbox settings such as
  `NoNewPrivileges`, `MemoryDenyWriteExecute`, `PrivateTmp`, `ProtectClock`, `ProtectHome`, `ProtectHostname`, `ProtectSystem=strict`,
  `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK`, and
  `RestrictSUIDSGID`, `ProtectKernelTunables`, `ProtectKernelModules`,
  `ProtectControlGroups`, `LockPersonality`, `RestrictRealtime`, empty
  `CapabilityBoundingSet` / `AmbientCapabilities`,
  `SystemCallArchitectures=native`, plus `UMask=0077` are active;
- the host has `/dev/kvm` as a KVM character device, a working
  `virsh --connect qemu:///system version`, `qemu-img --version`, and either
  a successful `cloud-localds --help` or `genisoimage --version` probe;
- an enabled base image file exists under the agent image directory, for
  example `/var/lib/vps-agent/images/debian-12.qcow2`;
- the base image path is a real regular qcow2 file, not a symlink, directory,
  raw image, or other special file;
- the same image file name is registered in master, or the smoke script can
  register it through the admin API. If the file name already exists in the
  catalog but is disabled, the smoke script re-enables that existing image
  instead of creating a duplicate row. The script verifies the image API
  response contains the expected `file_name`, an image id shaped as UUID text,
  and `enabled=true` before it queues `create_vm`.

Example:

```bash
export MASTER_URL=https://panel.example.com
export ADMIN_TOKEN=replace-with-admin-secret
export NODE_ID=00000000-0000-0000-0000-000000000000
export IMAGE_FILE=debian-12.qcow2
export IMAGE_NAME="Debian 12"
export SSH_PUBLIC_KEY="ssh-ed25519 AAAA... operator@example"
sudo -E bash scripts/kvm-host-smoke.sh
```

`ADMIN_TOKEN` is the same admin secret used for direct master bearer-token API
calls. In full smoke mode it must be non-empty, at most 256 characters, and must
not contain whitespace, quotes, backslashes, backticks, or ASCII control
characters. This mirrors the master admin-token shape check before the script
builds `Authorization: Bearer ...` requests.

Useful optional values:

```bash
export VM_NAME=kvm-smoke-001
export IP_POOL_ID=<existing-ip-pool-uuid>
export IP_POOL_NAME=kvm-smoke-pool
export IP_POOL_CIDR=192.0.2.0/29
export IP_POOL_GATEWAY=192.0.2.1
export PLAN_ID=<existing-enabled-plan-uuid>
export PLAN_NAME="KVM Smoke Plan"
export PLAN_SLUG=kvm-smoke-plan
export SSH_PUBLIC_KEY="ssh-ed25519 AAAA... operator@example"
export LIBVIRT_NETWORK_NAME=default
export LIBVIRT_BRIDGE_NAME=virbr0
export CPU_CORES=1
export MEMORY_MB=512
export DISK_GB=10
export DATA_DIR=/var/lib/vps-agent
export IMAGE_DIR=/var/lib/vps-agent/images
export AGENT_CONFIG_PATH=/etc/vps-agent/agent.toml
export AGENT_BINARY_PATH=/usr/local/bin/vps-agent
export AGENT_BINARY_SHA256=<expected-agent-binary-sha256>
export AGENT_BINARY_SHA256_PATH=/etc/vps-agent/agent.sha256
export TIMEOUT_SECONDS=900
export POLL_SECONDS=5
export CURL_TIMEOUT_SECONDS=30
export ALLOW_HTTP=0
export CLEANUP=1
export PRECHECK_ONLY=0
export REINSTALL_AFTER_CREATE=1
export POWER_CYCLE_AFTER_CREATE=1
export FULL_LIFECYCLE_REQUIRED=1
```

To validate a real host before exposing an admin token or queueing a VM task,
run the same script with only the non-secret host inputs and
`PRECHECK_ONLY=1`:

```bash
export MASTER_URL=https://panel.example.com
export MASTER_CA_CERT_PATH=/etc/ssl/certs/master-ca.pem
export IMAGE_FILE=debian-12.qcow2
export LIBVIRT_NETWORK_NAME=default
export LIBVIRT_BRIDGE_NAME=virbr0
export DATA_DIR=/var/lib/vps-agent
export IMAGE_DIR=/var/lib/vps-agent/images
export AGENT_CONFIG_PATH=/etc/vps-agent/agent.toml
export AGENT_BINARY_PATH=/usr/local/bin/vps-agent
export AGENT_BINARY_SHA256=<expected-agent-binary-sha256>
export AGENT_BINARY_SHA256_PATH=/etc/vps-agent/agent.sha256
export PRECHECK_ONLY=1
sudo -E bash scripts/kvm-host-smoke.sh
```

Precheck-only mode still validates `MASTER_URL`, rejects WSL, checks local
installed agent binary's `doctor` command, active `vps-agent.service`, the
active libvirt network, `DATA_DIR`, `IMAGE_DIR`, and the base image path and
format, and it checks
`${MASTER_URL}/healthz`. It does not require `ADMIN_TOKEN`, does not call admin
APIs, and does not create catalog rows or tasks. When `AGENT_BINARY_SHA256` is
set, or when it can be loaded from `AGENT_BINARY_SHA256_PATH`, and it matches
the installed binary, the precheck JSON includes
`agent_binary_sha256_verified: true` and the normalized hash.
The service check also reads systemd `Environment`, `ExecStart`,
`ReadWritePaths`, and key sandbox properties. It requires the active unit to use
exactly one `VPS_AGENT_CONFIG` matching the value, exactly one
`PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`, and
exactly one `ExecStart` `path=` and one `argv[]`, both equal to the
`AGENT_BINARY_PATH` validated by the smoke script, allow writes to the directory
containing `AGENT_CONFIG_PATH` and to `DATA_DIR`, and keep `NoNewPrivileges=yes`,
`MemoryDenyWriteExecute=yes`, `PrivateTmp=yes`,
`ProtectClock=yes`, `ProtectHome=yes`, `ProtectHostname=yes`,
`ProtectSystem=strict`,
`RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK`,
`RestrictSUIDSGID=yes`, `ProtectKernelTunables=yes`,
`ProtectKernelModules=yes`, `ProtectControlGroups=yes`,
`LockPersonality=yes`, `RestrictRealtime=yes`, empty
`CapabilityBoundingSet=` / `AmbientCapabilities=`,
`SystemCallArchitectures=native`, and `UMask=0077`. This prevents a
stale or weakened unit from passing precheck before the script mutates master
state or queues KVM work.
On success, precheck-only mode prints JSON with non-secret diagnostics:
`master_url`, `data_dir`, `image_dir`, `image_file`, `ca_cert_configured`,
`libvirt_network_name`, `libvirt_bridge_name`, `base_image_format`,
`cloud_init_iso_tool`, `curl_timeout_seconds`, `timeout_seconds`, and
`poll_seconds`. It intentionally does not print `ADMIN_TOKEN`, `NODE_ID`, the
local `MASTER_CA_CERT_PATH`, the local `AGENT_CONFIG_PATH`, or doctor output.

If master uses a private CA, set `MASTER_CA_CERT_PATH` to the local PEM file.
The script validates that path and passes it to curl with `--cacert` for both
`/healthz` and admin API calls. KVM smoke curl calls also pass `-q` first so
local `.curlrc` files cannot add `--insecure`, redirects, or extra headers.
They also pass `--proto '=https'` unless `ALLOW_HTTP=1` is set and the
validated `MASTER_URL` itself is loopback HTTP for local testing; HTTPS master
URLs still use `--proto '=https'` even when that flag is present. Only the
loopback HTTP exception uses `--proto '=http,https'`.
The `--cacert` path is passed as a Bash array argument rather than through
unquoted command substitution, so the script does not split or glob the CA path
while building curl calls.
Do not use curl `--insecure` for real host verification.

`CURL_TIMEOUT_SECONDS` bounds each master `/healthz` and admin API curl request.
The default is `30`; raise it only for slow links, and keep it well below
`TIMEOUT_SECONDS`, which controls task polling duration. `POLL_SECONDS` must be
less than or equal to `TIMEOUT_SECONDS` so the task wait loop cannot sleep past
its own deadline; the final polling sleep is capped to the remaining timeout.

The script calls the normal authenticated master APIs, queues a `create_vm`
task, waits for the agent to finish it, verifies the local libvirt domain
`vps-<vm_id>` exists and reports `running`, verifies managed files under
`${DATA_DIR}/vms/<vm_id>`, then queues a `delete_vm` task when `CLEANUP=1`. Use
`CLEANUP=0` only when you want to inspect the VM manually, and delete it through
the panel or admin API afterward.
Before any catalog row is created, re-enabled, or selected for task scheduling,
the full smoke path reads `GET /api/admin/nodes` with the admin token and finds
`NODE_ID`. It requires that node to be `online`, `scheduling_enabled=true`, to
have non-empty `agent_version`, to have a `last_seen_at` value from the last two
hours, and to report `libvirt_status=available`. This proves the control-plane
read model has seen a registered, currently heartbeating libvirt agent before
the script mutates image, IP pool, plan, or task state. `PRECHECK_ONLY=1` still
avoids this admin node-list call and performs only local host readiness plus
`/healthz`.
The full smoke sequence treats each preflight, node-readiness, catalog-selection,
task-queue, task-log, and audit-check helper as an explicit boundary. If IP pool
setup fails, for example, the script returns before selecting a plan or queueing
`create_vm`; if no IP pool or plan selector is configured, those optional
selection helpers return a successful no-op.
For IPAM coverage, either set `IP_POOL_ID` to an existing master IP pool UUID,
or set `IP_POOL_CIDR` and `IP_POOL_GATEWAY`. In CIDR mode, the smoke script
normalizes and validates the IPv4 `/16` through `/30` pool locally, reuses an
existing master pool with the same CIDR/gateway when one exists, or creates a
new pool with `IP_POOL_NAME` before queueing `create_vm`. Do not set
`IP_POOL_ID` and CIDR/gateway variables at the same time. When an IP pool is
selected, the script includes it in the `create_vm` payload, requires the create
response to return complete `assigned_ip`, `assigned_ip_prefix`, and
`assigned_gateway_ip` metadata, and verifies the managed cloud-init
`network-config` file contains the assigned address/prefix, `dhcp4: false`, and
the default gateway.
For plan catalog coverage, either set `PLAN_ID` to an existing enabled plan
UUID, or set `PLAN_SLUG`. In slug mode, the smoke script validates
`PLAN_NAME`, `PLAN_SLUG`, and the CPU/memory/disk sizing locally, lists master
plans, reuses an enabled plan whose slug and sizing match, or creates an
enabled plan using `PLAN_NAME`, `PLAN_SLUG`, `CPU_CORES`, `MEMORY_MB`, and
`DISK_GB` before queueing `create_vm`. Do not set `PLAN_ID` and `PLAN_SLUG` at
the same time. If the slug already exists with different sizing or is disabled,
the script fails locally instead of creating a duplicate or silently changing
catalog state. When a plan is selected, the script includes `plan_id` in the
`create_vm` payload and requires the create-task response to echo the same
`kind.plan_id`; master still normalizes the concrete CPU, memory, and disk
values from that enabled plan before the task reaches the agent. The final
smoke JSON also includes `plan_id` when one was selected, so the real-host run
records which catalog package was exercised.
The `vm_id` returned by the `create_vm` response is validated as UUID text
before the script waits for the task, checks libvirt, builds
`${DATA_DIR}/vms/<vm_id>`, or attempts cleanup.
Task IDs returned by create, reinstall, power, and delete task APIs are also
validated as UUID text before they are used in task polling or log URLs. The
polling helper repeats that check before every `/api/admin/tasks/<task_id>`
request and requires each polling response `id` to match the requested task id.
While polling, the script accepts only `pending`, `assigned`, and
`running` as in-progress states; `succeeded` finishes the wait, `failed` and
`canceled` fail with task logs that are locally redacted and capped to 8 KiB,
and any other status fails immediately. Missing or malformed task id/status
responses fail with a bounded smoke-script error instead of a JSON parser
traceback, raw response-body output, or accepting a response for another task.
The failed-task log redactor covers common token/password/credential/signature
key-value shapes, authorization and agent authentication headers, cookie
headers, URL userinfo credentials, PEM private key blocks, and the exact
`ADMIN_TOKEN` value before stderr output.
After each successful create, reinstall, stop, start, reboot, or final delete
wait, the script also reads `GET /api/admin/tasks/<task_id>/logs` and requires
the strict non-secret start log message `task executor started` on a log row
whose `task_id` matches the waited task and whose `node_id` matches `NODE_ID`
before it trusts the task as smoke evidence. Successful executor result logs
remain best-effort, so the smoke check uses only that pre-execution start-log
invariant. If create or another post-create task succeeds but its matching
start log is missing or unreadable, the script attempts the normal delete
cleanup before returning a non-zero result. Successful smoke output includes
`"task_logs_verified": true`.
After those task-log checks pass, the script reads `GET /api/admin/audit-logs`
once and requires task-scoped audit entries for each create, optional reinstall,
optional power action, and cleanup delete task. For every task it checks the
admin action, assignment, succeeded status update, and task-log append audit rows
against the smoke `NODE_ID`, task ID, task kind, and VM ID. Failed audit
verification returns only a bounded smoke-script error; it does not print the raw
audit JSON. Successful smoke output includes `"audit_logs_verified": true`.
It also includes a `lifecycle_coverage` object with `create_vm`, `delete_vm`,
`reinstall_vm`, and `power_cycle` booleans plus a `full_lifecycle_required`
boolean. The summary also includes `"host_preflight_verified": true`,
`"master_health_verified": true`, and `"node_ready_verified": true` after local
host checks, the master health endpoint, and master node readiness have passed.
For final acceptance evidence, `FULL_LIFECYCLE_REQUIRED=1`, `ALLOW_HTTP=0`,
`REINSTALL_AFTER_CREATE=1`, `POWER_CYCLE_AFTER_CREATE=1`, and
`AGENT_BINARY_SHA256=<expected-agent-binary-sha256>` or a validated persisted
hash at `AGENT_BINARY_SHA256_PATH` should produce
`"full_lifecycle_required": true`, `agent_binary_sha256_verified: true`, all
three verification flags as `true`, and all four lifecycle values as `true`; a
create/delete-only run, or a full-action run without installed-agent artifact
proof, is useful preflight evidence but not proof of the full lifecycle
requirement.
The same JSON summary also includes non-secret run context: `master_url`,
`allow_http`, `ca_cert_configured`, `curl_timeout_seconds`, `node_id`,
`image_file`, `image_name`, `data_dir`, `image_dir`, `libvirt_network_name`,
`libvirt_bridge_name`, `base_image_format`, `cpu_cores`, `memory_mb`, and
`disk_gb`. When master assigned IPAM metadata, it also includes `assigned_ip`,
`assigned_ip_prefix`, and `assigned_gateway_ip`. Final-acceptance runs require
`AGENT_BINARY_SHA256` or a validated persisted hash at
`AGENT_BINARY_SHA256_PATH`, and after it is verified the output includes
`agent_binary_sha256_verified: true` and the normalized `agent_binary_sha256`
value. This lets an operator archive a single final smoke output and later see
which master URL, TLS mode, node, agent artifact, base image, sizing, storage
root, libvirt network, and static guest network were actually verified.
For reinstall, start, stop, reboot, and delete task responses, the script also
requires `kind.vm_id` to match the VM created earlier before it polls that task.
This keeps the smoke proof tied to the same VM instead of accepting a task id
for another VM and then inferring success from local state.
For create, power operations, and reinstall restarts, the agent itself waits
for the expected `virsh domstate` before it marks the task successful:
`create_vm`, `start_vm`, `reboot_vm`, and the final `reinstall_vm` restart wait
for `running`, while `stop_vm` waits for `shut off`. The smoke script's
host-side `domstate` checks remain end-to-end verification of that task
contract.
The smoke verifier requires the managed VM directory, `disk.qcow2`, `seed.iso`,
`domain.xml`, `user-data`, and `meta-data` to be real filesystem objects, not
symlinks. The cloud-init files must be bounded UTF-8 text: `meta-data` must
contain the created VM id as `instance-id` and the requested `VM_NAME` as
`local-hostname`, while `user-data` must contain the baseline hardening fields
`#cloud-config`, `ssh_pwauth: false`, and `disable_root: true`. It also runs
`qemu-img info --output=json` on the managed `disk.qcow2` and requires the
reported format to be `qcow2`, so the real-host proof checks the produced disk
artifact rather than only the domain path. When IPAM metadata is present, the
managed `network-config` file must also be a real regular file under the VM
directory and must match the assigned static IPv4 metadata returned by master.
It also parses `domain.xml` and requires the active XML elements to match the
created VM's `vps-<vm_id>` domain name and UUID. The managed disk must appear
as the single `device="disk"` source, and the managed seed ISO must appear as
the single `device="cdrom"` source. The managed `domain.xml` must be 1 MiB or
smaller, matching the agent metadata guard.
The agent-side create path rejects a pre-existing `${DATA_DIR}/vms` parent or
VM root that is not an actual managed directory before it creates disks or
cloud-init metadata. When those directories are missing, the agent creates them
one level at a time and rechecks the parent and VM root metadata after creation;
a symlinked parent that appears during create is still treated as an ownership
failure. The delete/reinstall/start/stop/reboot paths apply the same
root-directory check before reading disk metadata or calling `virsh`, so a stray
file or symlink at `${DATA_DIR}/vms` or `${DATA_DIR}/vms/<vm_id>` is treated as
an ownership failure rather than a cleanup target.
For a new VM, the fixed output paths `disk.qcow2`, `seed.iso`, `network-config`,
`domain.xml`, `user-data`, and `meta-data` must be absent before creation starts. The agent
rejects pre-existing files, directories, symlinks, or special files at those
paths instead of overwriting them.
On reinstall, existing `user-data` and `meta-data` are replaced only after the
agent rechecks that each target is a managed regular file or missing path under
the VM directory. Symlinked cloud-init metadata is rejected before the domain is
destroyed or the replacement disk is created. Stale `.reinstalling` files are
also rejected before `virsh destroy`, so a partial previous reinstall cannot
stop the VM. After best-effort `virsh destroy`, the agent requires
`virsh domstate` to report `shut off` before touching live disk artifacts. It
then stages the replacement `disk.qcow2`, `seed.iso`, `user-data`, and
`meta-data` as fixed `.reinstalling` files in the same managed VM directory. If
staging fails, those temporary files are removed and the existing disk and seed
ISO remain in place. Before replacing any live file, the agent validates every
prepared source and every live target, so a later unsafe target cannot leave the
VM with only the disk replaced. The live files are replaced only after the
replacement disk and seed ISO have both been created successfully and all live
targets are still managed regular files or safe missing paths. If an existing
`network-config` file is present, it is validated as a managed regular file and
included in the replacement seed ISO without being rewritten. After the live
artifacts are replaced, `reinstall_vm` starts the domain and waits for
`virsh domstate` to report `running` before reporting task success.
The managed `disk.qcow2`, `seed.iso`, and `domain.xml` artifacts must also be
real regular files. Symlinks are rejected before the agent trusts local domain
metadata or runs a VM operation.
If `create_vm` fails before the domain is defined in libvirt, the agent cleans
up only the known managed artifacts it just created and removes the empty VM
directory with non-recursive `remove_dir`. This keeps retry practical without
granting the agent permission to recursively delete arbitrary files.
If `virsh define` itself fails, the agent checks `virsh domstate` for the domain
name and only performs local artifact cleanup when libvirt does not report that
domain through a clear `Domain not found` / `failed to get domain` style
diagnostic. If libvirt reports a domain or returns an ambiguous `domstate`
failure, the directory is left for manual inspection.
If `virsh start` fails after the domain was defined, the agent first requires
`virsh domstate` to report `shut off`, then runs `virsh undefine` before the
same local artifact cleanup. If the domain is still running or undefine fails,
the VM directory is left for manual inspection.
During delete, the agent allows only `disk.qcow2`, `seed.iso`, `network-config`,
`domain.xml`, `user-data`, and `meta-data` inside the managed VM directory. Any extra file,
directory, special file, or symlink makes the task fail before `virsh destroy`
or host cleanup. `virsh destroy` is best-effort so an already-stopped domain
does not block deletion, but the agent then requires `virsh domstate` to report
`shut off`. `virsh undefine` must also succeed before local files are removed.
Known files are removed one by one and the VM directory is removed only after it
is empty; the agent does not recursively delete arbitrary directory contents.

The smoke script probes cloud-init ISO tooling before it queues the task. It
uses `cloud-localds --help` when available, falls back to
`genisoimage --version` if `cloud-localds` is missing or broken, and stops
before creating a VM if neither tool is runnable.
It also runs `virsh --connect qemu:///system net-info "$LIBVIRT_NETWORK_NAME"`
and requires `Active: yes` plus `Bridge: $LIBVIRT_BRIDGE_NAME`; the defaults are
the libvirt `default` network and `virbr0` bridge. If that libvirt metadata
probe fails, the smoke script hides raw `virsh` output and prints only a
bounded non-secret preflight message. The same bounded-output rule applies to
failed `virsh --connect qemu:///system version` and `qemu-img --version` probes.
The script also runs `qemu-img info --output=json "${IMAGE_DIR}/${IMAGE_FILE}"`
and requires the reported image `format` to be `qcow2`. This matches the agent's
libvirt executor, which creates qcow2 overlay disks with an explicit `-F qcow2`
base-format flag, so a raw or otherwise mismatched base image fails before any
task is queued. Failed base-image metadata probes also hide raw `qemu-img info`
stderr and print only a bounded non-secret preflight message.
By default the smoke queues `create_vm`, waits for the task result, verifies the
running libvirt domain and managed artifacts, then queues `delete_vm` when
`CLEANUP=1`. If a post-create action cannot be queued, a task wait fails, or a
host verification fails, the script still attempts the same `delete_vm` cleanup
before returning a non-zero result. If the domain existence probe fails during
host verification, raw `virsh dominfo` output is hidden and the script prints
only a bounded non-secret domain-unavailable message. If the domain state probe
fails, raw `virsh domstate` output is hidden and the script prints only a
bounded non-secret state-read failure. After cleanup delete, the smoke script
accepts a failed `virsh dominfo` probe only when libvirt reports a known
missing-domain diagnostic; ambiguous libvirt failures fail closed without
printing raw host-tool output.
Set
`REINSTALL_AFTER_CREATE=1` to also queue `reinstall_vm` for the created VM,
wait for it to succeed, and verify the running domain and managed artifacts
again before cleanup. Set `POWER_CYCLE_AFTER_CREATE=1` to also queue `stop_vm`,
wait for the agent to report success only after `virsh domstate` is `shut off`,
then queue `start_vm` and `reboot_vm` and verify the domain is running after
each operation; the agent side now also waits for `running` before those start
and reboot tasks succeed. These
options extend the same real-host smoke to the reinstall and power-operation
paths, including audit-log verification for every task they queue, without
changing the default create/delete acceptance flow.
For final acceptance runs, set `FULL_LIFECYCLE_REQUIRED=1` as well. That flag
fails during local argument validation unless `AGENT_BINARY_SHA256` is set or a
valid hash can be loaded from `AGENT_BINARY_SHA256_PATH`, and
`REINSTALL_AFTER_CREATE=1`, `POWER_CYCLE_AFTER_CREATE=1`, `CLEANUP=1`, and
`PRECHECK_ONLY=0` are all set. It also requires `ALLOW_HTTP=0`, so an
accidentally narrow or non-TLS smoke run cannot be mistaken for full lifecycle
proof. After the agent doctor check, final mode also
fails before host preflight or master calls unless the installed binary hash has
actually been compared with `sha256sum` and recorded as verified.

If cleanup fails after a post-create queue/wait/verification failure or after
final create verification, the script exits non-zero and prints a non-secret
manual inspection summary with the delete task id when available, or
`delete_task_id=unavailable` when master did not return a valid delete task,
plus the libvirt domain name and managed VM directory. Use that summary to
inspect master task logs, `virsh --connect qemu:///system dominfo vps-<vm_id>`,
and `${DATA_DIR}/vms/<vm_id>` before deciding whether manual host cleanup is
needed.

`MASTER_URL` must use HTTPS. `ALLOW_HTTP=1` exists only for an isolated local
lab where the master is deliberately exposed over HTTP on `localhost`,
`127.0.0.1`, or `[::1]`; do not use it for real hosts. The flag is rejected
whenever `FULL_LIFECYCLE_REQUIRED=1`.

Before contacting master or checking host files, the script validates its
environment. `MASTER_URL` must be a clean base URL with a real host and no
embedded credentials, query string, fragment, whitespace, quotes, backslashes,
backticks, literal / percent-encoded `.` / `..` path segments, encoded path
separators (`%2f` / `%5c`) in authorities or paths, or percent-encoded ASCII
controls in authorities or paths. URL, path, and
header-like inputs also reject every ASCII control character, including
non-whitespace controls that would be hard to see in logs. Port-only authorities
such as `https://:8443` and malformed bracketed IPv6 hosts are rejected. Ports
must be numeric and between 1 and 65535, and IPv6 literals must use brackets.
In full mode, `ADMIN_TOKEN` is validated as a bearer-compatible header value:
1-256 characters, no whitespace, quotes, backslashes, backticks, or ASCII
control characters. `PRECHECK_ONLY=1` skips `ADMIN_TOKEN` validation so the same
script can prove local host readiness without placing the admin secret in that
environment.
`DATA_DIR` and `IMAGE_DIR` must be absolute Linux paths, cannot be `/`, cannot
contain `..`, and `IMAGE_DIR` must be under `DATA_DIR`. `AGENT_CONFIG_PATH`
defaults to `/etc/vps-agent/agent.toml` and must be a clean absolute Linux file
path; the file must exist, must not be a symlink, and must not grant group or
other permissions. `AGENT_BINARY_PATH` defaults to `/usr/local/bin/vps-agent`
and must be a clean absolute Linux file path to a real executable file. The
optional `AGENT_BINARY_SHA256`, when set, must be a 64-character hex SHA-256
digest. If it is unset and `AGENT_BINARY_SHA256_PATH` exists, the script reads
the expected hash from that file after rejecting symlinks, non-regular files,
group/world-writable paths, and malformed content. The path defaults to
`/etc/vps-agent/agent.sha256`, which the installer writes after a
checksum-verified install. The script computes `sha256sum "$AGENT_BINARY_PATH"`
and fails before doctor or master contact if the installed binary does not
match. Use the `--agent-sha256` value from the generated install command, the
release artifact hash, or the persisted installer hash for this field. A
matching hash sets the smoke evidence field `agent_binary_sha256_verified`
before the script prints precheck or final JSON. The field is optional for
`PRECHECK_ONLY=1` and create/delete smoke runs, but direct or persisted hash
proof must be verified before any full-lifecycle run can proceed when
`FULL_LIFECYCLE_REQUIRED=1`.
The script then runs that binary with
`VPS_AGENT_CONFIG=$AGENT_CONFIG_PATH` and requires `vps-agent doctor: ok`; if
doctor fails, the script prints only a generic rerun hint instead of echoing
doctor output. It then requires
`systemctl is-active --quiet vps-agent.service` to succeed, then checks the
active unit's `Environment` for exactly one matching `VPS_AGENT_CONFIG` and
exactly one safe system `PATH`, its `ExecStart` executable path and full argv for
the same agent binary path with no extra arguments, and suppresses raw
`systemctl` output on failure.
During host precheck both directories must exist as real directories, not
symlinks, and must not be world-accessible or group-writable; this matches the
installer's `0750` data/image directory boundary. The script also
checks canonical 8-4-4-4-12 hex UUID shape, safe image file names with the same leading-dot, trailing-dot,
separator, and consecutive-dot rejection used by the image catalog, image
display names with the master catalog's ASCII letters/numbers/spaces/dash/underscore
rule, VM name characters, optional `SSH_PUBLIC_KEY` as a single OpenSSH public
key, libvirt network and bridge name characters, sizing ranges, timeout ranges,
and `0`/`1` flags for `CLEANUP`, `ALLOW_HTTP`, `PRECHECK_ONLY`,
`FULL_LIFECYCLE_REQUIRED`, `REINSTALL_AFTER_CREATE`, and
`POWER_CYCLE_AFTER_CREATE`.
`CURL_TIMEOUT_SECONDS` must be between 1 and 3600 seconds, and `POLL_SECONDS`
must not exceed `TIMEOUT_SECONDS`. While waiting for a task, the script sleeps
for the smaller of `POLL_SECONDS` and the remaining timeout. Numeric inputs are
validated as bounded decimal text, so oversized digit strings fail locally
instead of depending on Bash arithmetic behavior.
`MASTER_CA_CERT_PATH`, when set, must be a clean absolute Linux path to an
existing non-symlink regular file that is not group/world writable. The script
also verifies `/dev/kvm`, `virsh`, active libvirt network, `qemu-img`,
base-image qcow2 format, and cloud-init ISO tooling locally before creating any
master task.
The JSON payloads sent to master are built from the script's validated shell
state, so optional defaults such as `IMAGE_NAME`, `VM_NAME`, `SSH_PUBLIC_KEY`,
and sizing fields do not need to be exported separately when they are left at
their defaults.

# Generated Install Command URL Rules

`MASTER_PUBLIC_BASE_URL` is the URL written into the agent config as
`--master-url`. `MASTER_INSTALLER_BASE_URL` is the URL used to download
`install-agent.sh` and the agent binary. Both values must:

- start with `https://`;
- include a real host;
- reject port-only authorities such as `https://:8443`, ports outside `1..=65535`, malformed bracketed IPv6 hosts, and unbracketed IPv6 hosts;
- avoid embedded username/password values, query strings, fragments, whitespace, control characters, quotes, backslashes, and backticks;
- avoid literal or percent-encoded `.` / `..` path segments, encoded path separators (`%2f` / `%5c`) in authorities or paths, and percent-encoded ASCII controls in authorities or paths, so URL normalization cannot move the generated installer or agent download path to a different route.

The generated command invokes curl with `-q -fsS --proto '=https'`,
`--connect-timeout 30`, and `--max-time 300`, and deliberately omits `-L` /
`--location`, so curl ignores local config files, a silent peer cannot hang the
bootstrap command indefinitely, and a reverse-proxy redirect fails instead of
moving the bootstrap token to another URL. Master also revalidates the generated
bootstrap token before command formatting: it must be 1-256 characters and use
only ASCII letters, numbers, dots, dashes, or underscores. It writes the
installer to a temporary file, invokes `sudo bash --` only after curl succeeds,
and registers an `EXIT` trap to remove the temporary file. It single-quotes the
installer download URL and the installer arguments containing deployment data.
Master rejects unsafe values at startup and revalidates them while generating
the command, so the panel cannot display a malformed or shell-unsafe install
command.
Optional `MASTER_INSTALLER_CA_CERT_PATH` and
`MASTER_INSTALLER_CLIENT_IDENTITY_PATH` values must be clean absolute Linux file
paths with no parent traversal, whitespace, control characters, quotes,
backslashes, or backticks before they can be emitted as installer arguments.
