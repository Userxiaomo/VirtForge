# VPS 部署平台

这是一个基于 Rust 的 VPS 管理平台，包含控制面 `master`、管理面板 `frontend`、节点守护进程 `agent`、PostgreSQL 和 Caddy。

## 组成

- `master`：提供管理 API、任务调度、节点注册和心跳。
- `frontend`：Next.js 管理面板。
- `agent`：安装在 KVM 主机上的 systemd 守护进程，负责执行 VM 创建、重装、开关机等任务。
- `postgres`：控制面数据库。
- `caddy`：TLS 反向代理，统一对外提供面板、API、安装脚本和下载入口。

## Linux VPS 部署

正式部署面向 Linux VPS。主控不需要手动运行 Rust 或前端构建命令，控制面由 Docker Compose 启动，包含 `postgres`、`master`、`frontend` 和 `caddy`。

部署入口在 `deploy/` 目录。正常情况下只需要编辑 `.env`，然后执行一个 Compose 启动命令：

```bash
cd deploy
cp .env.example .env
nano .env
docker compose up -d --build
```

`--build` 是让 Compose 自动按仓库里的 Dockerfile 构建 `master` 和 `frontend` 镜像，不是手动执行 `cargo build` 或 `npm run build`。如果你已经有预构建镜像，在 `.env` 里设置 `MASTER_IMAGE`、`FRONTEND_IMAGE` 后可以去掉 `--build`。

### 1. VPS 前置条件

- Linux VPS 一台，用于部署控制面。
- 已安装 Docker Engine 和 Docker Compose plugin。
- 域名 A/AAAA 记录指向这台 VPS。
- 防火墙开放 `80/tcp` 和 `443/tcp`。

### 2. 配置 `.env`

从模板复制：

```bash
cd deploy
cp .env.example .env
```

编辑 `.env`：

```bash
nano .env
```

至少需要设置：

- `DOMAIN`
- `MASTER_PUBLIC_BASE_URL`
- `MASTER_INSTALLER_BASE_URL`
- `POSTGRES_PASSWORD`
- `MASTER_ADMIN_USERNAME`
- `MASTER_ADMIN_TOKEN_HASH`

生成管理员登录 token 和 Argon2 哈希：

```bash
ADMIN_TOKEN="$(openssl rand -hex 32)"
echo "Admin token: ${ADMIN_TOKEN}"
SECRET_TO_HASH="${ADMIN_TOKEN}" docker compose run --rm --no-deps --build --entrypoint /usr/local/bin/hash-secret master
```

把输出的 Argon2 PHC hash 填入 `.env` 的 `MASTER_ADMIN_TOKEN_HASH`。这个值包含 `$`，在 `.env` 中要用单引号包起来：

```env
MASTER_ADMIN_TOKEN_HASH='$argon2id$v=19$...'
```

`Admin token` 是登录面板和调用管理 API 使用的明文口令，只显示这一次，自己保存好，不要写进 `.env`。

### 3. 启动控制面

在 `deploy/` 目录执行：

```bash
docker compose up -d --build
```

查看状态：

```bash
docker compose ps
docker compose logs -f master
```

启动后访问：

```text
https://panel.example.com
```

如果使用已经构建好的镜像：

```env
MASTER_IMAGE=your-registry/vps-master:tag
FRONTEND_IMAGE=your-registry/vps-frontend:tag
```

然后启动：

```bash
docker compose up -d
```

### 4. 安装 KVM 节点 agent

在面板中创建节点并生成一次性 bootstrap token，然后在 KVM 主机上安装 `agent`。生产环境通常直接使用面板生成的安装命令；手动执行时形如：

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

## 本地开发（可选）

下面这些命令只用于开发和提交前校验，不是生产部署步骤。

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
