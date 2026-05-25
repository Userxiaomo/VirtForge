# VPS 部署平台

这是一个基于 Rust 的 VPS 管理平台，包含控制面 `master`、管理面板 `frontend`、节点守护进程 `agent`、PostgreSQL 和 Caddy。

## 组成

- `master`：提供管理 API、任务调度、节点注册和心跳。
- `frontend`：Next.js 管理面板。
- `agent`：安装在 KVM 主机上的 systemd 守护进程，负责执行 VM 创建、重装、开关机等任务。
- `postgres`：控制面数据库。
- `caddy`：TLS 反向代理，统一对外提供面板、API、安装脚本和下载入口。

## 快速开始

### 本地开发

```powershell
cargo fmt --all
cargo test --workspace
```

前端单独开发：

```powershell
cd frontend
npm install
npm run lint
npm run build
```

本地运行前端时需要配置后端地址：

```powershell
$env:MASTER_API_BASE_URL = "http://master:8080"
npm run dev
```

## 部署

### 1. 准备环境变量

先生成管理员密码哈希：

```powershell
$env:SECRET_TO_HASH = "replace-with-a-long-random-admin-token"
cargo run -p vps-master --bin hash-secret
```

然后准备控制面所需环境变量：

```powershell
$env:DOMAIN = "panel.example.com"
$env:MASTER_PUBLIC_BASE_URL = "https://panel.example.com"
$env:MASTER_INSTALLER_BASE_URL = "https://panel.example.com"
$env:POSTGRES_PASSWORD = "<long-random-postgres-password>"
$env:MASTER_ADMIN_USERNAME = "admin"
$env:MASTER_ADMIN_TOKEN_HASH = "<argon2-hash-from-hash-secret>"
```

可选项：

- `MASTER_READONLY_TOKEN_HASH`
- `MASTER_AGENT_BINARY_PATH`
- `MASTER_INSTALLER_CA_CERT_PATH`
- `MASTER_INSTALLER_CLIENT_IDENTITY_PATH`
- `MASTER_FETCH_TIMEOUT_MS`

### 2. 启动控制面

```powershell
docker compose -f deploy/docker-compose.yml up -d --build
```

启动后通过 `https://panel.example.com` 访问面板。

### 3. 安装 agent

在 KVM 主机上安装 `agent`，推荐使用 master 生成的一次性 bootstrap token：

```bash
sudo scripts/install-agent.sh \
  --master-url https://panel.example.com \
  --node-id <node-id> \
  --bootstrap-token <one-time-token> \
  --executor-mode libvirt \
  --data-dir /var/lib/vps-agent \
  --image-dir /var/lib/vps-agent/images
```

可选参数：

- `--agent-url`
- `--agent-sha256`
- `--ca-cert-path`
- `--client-identity-path`
- `--skip-deps`
- `--skip-doctor`
- `--no-start`

安装后：

- 配置文件：`/etc/vps-agent/agent.toml`
- systemd 服务：`vps-agent`
- 数据目录：`/var/lib/vps-agent`

`executor-mode=libvirt` 时，主机需要具备 `/dev/kvm`、`virsh --connect qemu:///system`、`qemu-img` 和 `cloud-localds`。

## 使用方式

### 管理面板

1. 用 `MASTER_ADMIN_USERNAME` 和管理员明文口令登录面板。
2. 创建节点 `node`。
3. 生成一次性 bootstrap token。
4. 在 KVM 主机上运行 `scripts/install-agent.sh` 安装 agent。
5. 等待节点心跳上线后，创建镜像记录和 VM。
6. 在面板里对 VM 执行 `reinstall`、`stop`、`start`、`reboot`、`delete`。

### 管理 API

管理接口使用：

```text
Authorization: Bearer <admin-token>
```

常用接口：

- `POST /api/admin/nodes`
- `POST /api/admin/nodes/<node_id>/bootstrap-tokens`
- `POST /api/agent/register`
- `POST /api/agent/heartbeat`
- `POST /api/admin/tasks/create-vm`
- `POST /api/admin/tasks/reinstall-vm`
- `POST /api/admin/tasks/stop-vm`
- `POST /api/admin/tasks/start-vm`
- `POST /api/admin/tasks/reboot-vm`
- `POST /api/admin/tasks/delete-vm`

## 实机验证

项目提供了 KVM/libvirt 实机 smoke 脚本：

```bash
bash scripts/kvm-host-smoke.sh
```

它会验证真实的创建、重装、开关机、重启和删除链路。详细参数和前置条件见 `docs/INSTALL.md`。

## 其他文档

- `docs/INSTALL.md`：完整部署和安装说明
- `docs/DESIGN.md`：设计说明
- `docs/SECURITY.md`：安全说明

