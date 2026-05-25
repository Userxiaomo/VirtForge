#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_master_download_route() {
    caddyfile="$1"
    python3 - "$caddyfile" <<'PY'
from pathlib import Path
import sys

caddyfile = Path(sys.argv[1])
lines = caddyfile.read_text(encoding="utf-8").splitlines()

for index, line in enumerate(lines):
    stripped = line.strip()
    if not stripped.startswith("@installer path "):
        continue
    paths = stripped.split()[2:]
    if "/scripts/*" not in paths or "/downloads/*" not in paths:
        continue
    for next_line in lines[index + 1 : index + 6]:
        if next_line.strip() == "reverse_proxy @installer master:8080":
            sys.exit(0)

print(f"{caddyfile}: /scripts/* and /downloads/* must route to master through @installer", file=sys.stderr)
sys.exit(1)
PY
}

require_master_admin_api_route() {
    caddyfile="$1"
    python3 - "$caddyfile" <<'PY'
from pathlib import Path
import sys

caddyfile = Path(sys.argv[1])
lines = caddyfile.read_text(encoding="utf-8").splitlines()

for index, line in enumerate(lines):
    stripped = line.strip()
    if not stripped.startswith("@adminApi path "):
        continue
    paths = stripped.split()[2:]
    if "/api/admin/*" not in paths:
        continue
    for next_line in lines[index + 1 : index + 6]:
        if next_line.strip() == "reverse_proxy @adminApi master:8080":
            sys.exit(0)

print(f"{caddyfile}: /api/admin/* must route to master through @adminApi", file=sys.stderr)
sys.exit(1)
PY
}

require_no_caddy_env_defaults() {
    caddyfile="$1"
    python3 - "$caddyfile" <<'PY'
from pathlib import Path
import re
import sys

caddyfile = Path(sys.argv[1])
text = caddyfile.read_text(encoding="utf-8")

matches = re.findall(r"\{\$[A-Za-z_][A-Za-z0-9_]*:[^}]+}", text)
if matches:
    print(
        f"{caddyfile}: Caddy environment placeholders must not have defaults: {', '.join(matches)}",
        file=sys.stderr,
    )
    sys.exit(1)
PY
}

require_caddy_security_headers() {
    caddyfile="$1"
    expected_sites="$2"
    python3 - "$caddyfile" "$expected_sites" <<'PY'
from pathlib import Path
import sys

caddyfile = Path(sys.argv[1])
expected_sites = int(sys.argv[2])
text = caddyfile.read_text(encoding="utf-8")

required_headers = {
    "Strict-Transport-Security": '"max-age=31536000"',
    "X-Content-Type-Options": '"nosniff"',
    "X-Frame-Options": '"DENY"',
    "Referrer-Policy": '"no-referrer"',
}

for name, value in required_headers.items():
    count = text.count(f"{name} {value}")
    if count != expected_sites:
        print(
            f"{caddyfile}: expected {expected_sites} {name} header directives, found {count}",
            file=sys.stderr,
        )
        sys.exit(1)
PY
}

require_mtls_panel_blocks_agent_api() {
    caddyfile="$1"
    python3 - "$caddyfile" <<'PY'
from pathlib import Path
import sys

caddyfile = Path(sys.argv[1])
text = caddyfile.read_text(encoding="utf-8")

if "{$AGENT_DOMAIN}" not in text:
    print(f"{caddyfile}: split-domain Caddyfile must define AGENT_DOMAIN", file=sys.stderr)
    sys.exit(1)

panel_block = text.split("{$AGENT_DOMAIN}", 1)[0]
required = [
    "@agentApi path /api/agent/*",
    "respond @agentApi 404",
]
missing = [line for line in required if line not in panel_block]
if missing:
    print(
        f"{caddyfile}: PANEL_DOMAIN must explicitly reject /api/agent/* before frontend fallback; missing {', '.join(missing)}",
        file=sys.stderr,
    )
    sys.exit(1)
PY
}

require_non_root_runtime_user() {
    dockerfile="$1"
    python3 - "$dockerfile" <<'PY'
from pathlib import Path
import sys

dockerfile = Path(sys.argv[1])
lines = dockerfile.read_text(encoding="utf-8").splitlines()
runtime_start = None

for index, line in enumerate(lines):
    stripped = line.strip()
    if stripped.startswith("FROM ") and " AS runtime" in stripped:
        runtime_start = index

if runtime_start is None:
    print(f"{dockerfile}: missing runtime stage", file=sys.stderr)
    sys.exit(1)

for line in lines[runtime_start + 1 :]:
    stripped = line.strip()
    if stripped.startswith("FROM "):
        break
    if stripped.startswith("USER "):
        user = stripped.split(maxsplit=1)[1]
        if user in {"root", "0"}:
            print(f"{dockerfile}: runtime USER must not be root", file=sys.stderr)
            sys.exit(1)
        sys.exit(0)

print(f"{dockerfile}: runtime stage must set a non-root USER", file=sys.stderr)
sys.exit(1)
PY
}

require_runtime_base_not_toolchain() {
    dockerfile="$1"
    python3 - "$dockerfile" <<'PY'
from pathlib import Path
import sys

dockerfile = Path(sys.argv[1])
lines = dockerfile.read_text(encoding="utf-8").splitlines()

for line in lines:
    stripped = line.strip()
    if not stripped.startswith("FROM ") or " AS runtime" not in stripped:
        continue
    image = stripped.split()[1].lower()
    if image.startswith("rust:"):
        print(f"{dockerfile}: runtime stage must not use a Rust toolchain image", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)

print(f"{dockerfile}: missing runtime stage", file=sys.stderr)
sys.exit(1)
PY
}

require_postgres_loopback_binding() {
    compose_file="$1"
    python3 - "$compose_file" <<'PY'
from pathlib import Path
import sys

compose_file = Path(sys.argv[1])
lines = compose_file.read_text(encoding="utf-8").splitlines()

in_postgres = False
in_ports = False
postgres_indent = 0
ports_indent = 0
found_postgres_port = False

for raw_line in lines:
    stripped = raw_line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    indent = len(raw_line) - len(raw_line.lstrip(" "))
    if stripped == "postgres:":
        in_postgres = True
        in_ports = False
        postgres_indent = indent
        continue
    if in_postgres and indent <= postgres_indent and stripped.endswith(":"):
        break
    if not in_postgres:
        continue
    if stripped == "ports:":
        in_ports = True
        ports_indent = indent
        continue
    if in_ports and indent <= ports_indent and not stripped.startswith("-"):
        in_ports = False
    if not in_ports or not stripped.startswith("-"):
        continue
    mapping = stripped[1:].strip().strip('"').strip("'")
    if mapping.endswith(":5432"):
        found_postgres_port = True
        if not mapping.startswith("127.0.0.1:"):
            print(f"{compose_file}: Postgres host port must bind to 127.0.0.1, got {mapping}", file=sys.stderr)
            sys.exit(1)

if not found_postgres_port:
    print(f"{compose_file}: Postgres host port mapping is missing", file=sys.stderr)
    sys.exit(1)
PY
}

require_no_postgres_password_default() {
    compose_file="$1"
    python3 - "$compose_file" <<'PY'
from pathlib import Path
import re
import sys

compose_file = Path(sys.argv[1])
text = compose_file.read_text(encoding="utf-8")

if re.search(r"\$\{POSTGRES_PASSWORD:-[^}]+}", text):
    print(f"{compose_file}: POSTGRES_PASSWORD must not have an insecure default", file=sys.stderr)
    sys.exit(1)
if "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}" not in text:
    print(f"{compose_file}: POSTGRES_PASSWORD must be required explicitly", file=sys.stderr)
    sys.exit(1)
PY
}

require_no_cmd_shell_healthchecks() {
    compose_file="$1"
    python3 - "$compose_file" <<'PY'
from pathlib import Path
import sys

compose_file = Path(sys.argv[1])
text = compose_file.read_text(encoding="utf-8")

if "CMD-SHELL" in text:
    print(f"{compose_file}: healthchecks must use CMD argument arrays, not CMD-SHELL", file=sys.stderr)
    sys.exit(1)
PY
}

require_curl_healthchecks_disable_config() {
    compose_file="$1"
    python3 - "$compose_file" <<'PY'
import ast
from pathlib import Path
import sys

compose_file = Path(sys.argv[1])
lines = compose_file.read_text(encoding="utf-8").splitlines()

for line_number, raw_line in enumerate(lines, start=1):
    stripped = raw_line.strip()
    prefix = "test: "
    if not stripped.startswith(prefix):
        continue
    value = stripped[len(prefix):]
    try:
        test = ast.literal_eval(value)
    except (SyntaxError, ValueError):
        continue
    if not isinstance(test, list) or len(test) < 2:
        continue
    if test[:2] != ["CMD", "curl"]:
        continue
    if len(test) < 3 or test[2] != "-q":
        print(
            f"{compose_file}:{line_number}: curl healthchecks must pass -q before other arguments",
            file=sys.stderr,
        )
        sys.exit(1)
PY
}

require_no_new_privileges_service() {
    compose_file="$1"
    service_name="$2"
    python3 - "$compose_file" "$service_name" <<'PY'
import ast
from pathlib import Path
import sys

compose_file = Path(sys.argv[1])
service_name = sys.argv[2]
lines = compose_file.read_text(encoding="utf-8").splitlines()

in_service = False
in_security_opt = False
service_indent = 0
security_opt_indent = 0
security_opt_entries = []

for raw_line in lines:
    stripped = raw_line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    indent = len(raw_line) - len(raw_line.lstrip(" "))
    if stripped == f"{service_name}:":
        in_service = True
        in_security_opt = False
        service_indent = indent
        continue
    if in_service and indent <= service_indent and stripped.endswith(":"):
        break
    if not in_service:
        continue
    if stripped.startswith("security_opt:"):
        in_security_opt = True
        security_opt_indent = indent
        inline_value = stripped.removeprefix("security_opt:").strip()
        if inline_value:
            try:
                value = ast.literal_eval(inline_value)
            except (SyntaxError, ValueError):
                value = inline_value
            if isinstance(value, list):
                security_opt_entries.extend(str(item) for item in value)
            else:
                security_opt_entries.append(str(value))
        continue
    if in_security_opt and indent <= security_opt_indent:
        in_security_opt = False
    if in_security_opt and stripped.startswith("- "):
        security_opt_entries.append(stripped[2:].strip().strip("'\""))

if "no-new-privileges:true" not in security_opt_entries:
    print(
        f"{compose_file}: {service_name} service must set security_opt no-new-privileges:true",
        file=sys.stderr,
    )
    sys.exit(1)
PY
}

require_cap_drop_all_service() {
    compose_file="$1"
    service_name="$2"
    python3 - "$compose_file" "$service_name" <<'PY'
import ast
from pathlib import Path
import sys

compose_file = Path(sys.argv[1])
service_name = sys.argv[2]
lines = compose_file.read_text(encoding="utf-8").splitlines()

in_service = False
in_cap_drop = False
service_indent = 0
cap_drop_indent = 0
cap_drop_entries = []

for raw_line in lines:
    stripped = raw_line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    indent = len(raw_line) - len(raw_line.lstrip(" "))
    if stripped == f"{service_name}:":
        in_service = True
        in_cap_drop = False
        service_indent = indent
        continue
    if in_service and indent <= service_indent and stripped.endswith(":"):
        break
    if not in_service:
        continue
    if stripped.startswith("cap_drop:"):
        in_cap_drop = True
        cap_drop_indent = indent
        inline_value = stripped.removeprefix("cap_drop:").strip()
        if inline_value:
            try:
                value = ast.literal_eval(inline_value)
            except (SyntaxError, ValueError):
                value = inline_value
            if isinstance(value, list):
                cap_drop_entries.extend(str(item) for item in value)
            else:
                cap_drop_entries.append(str(value))
        continue
    if in_cap_drop and indent <= cap_drop_indent:
        in_cap_drop = False
    if in_cap_drop and stripped.startswith("- "):
        cap_drop_entries.append(stripped[2:].strip().strip("'\""))

if "ALL" not in cap_drop_entries:
    print(
        f"{compose_file}: {service_name} service must set cap_drop ALL",
        file=sys.stderr,
    )
    sys.exit(1)
PY
}

require_bounded_pids_limit_service() {
    compose_file="$1"
    service_name="$2"
    python3 - "$compose_file" "$service_name" <<'PY'
from pathlib import Path
import sys

compose_file = Path(sys.argv[1])
service_name = sys.argv[2]
lines = compose_file.read_text(encoding="utf-8").splitlines()

in_service = False
service_indent = 0
pids_limit = None

for raw_line in lines:
    stripped = raw_line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    indent = len(raw_line) - len(raw_line.lstrip(" "))
    if stripped == f"{service_name}:":
        in_service = True
        service_indent = indent
        continue
    if in_service and indent <= service_indent and stripped.endswith(":"):
        break
    if not in_service:
        continue
    if stripped.startswith("pids_limit:"):
        pids_limit = stripped.removeprefix("pids_limit:").strip().strip("'\"")
        break

if pids_limit is None:
    print(f"{compose_file}: {service_name} service must set pids_limit", file=sys.stderr)
    sys.exit(1)
try:
    parsed = int(pids_limit)
except ValueError:
    print(f"{compose_file}: {service_name} pids_limit must be an integer", file=sys.stderr)
    sys.exit(1)
if parsed < 32 or parsed > 256:
    print(
        f"{compose_file}: {service_name} pids_limit must be between 32 and 256",
        file=sys.stderr,
    )
    sys.exit(1)
PY
}

require_read_only_rootfs_with_tmpfs_service() {
    compose_file="$1"
    service_name="$2"
    python3 - "$compose_file" "$service_name" <<'PY'
from pathlib import Path
import sys

compose_file = Path(sys.argv[1])
service_name = sys.argv[2]
lines = compose_file.read_text(encoding="utf-8").splitlines()

in_service = False
in_tmpfs = False
service_indent = 0
tmpfs_indent = 0
read_only = None
tmpfs_entries = []

for raw_line in lines:
    stripped = raw_line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    indent = len(raw_line) - len(raw_line.lstrip(" "))
    if stripped == f"{service_name}:":
        in_service = True
        in_tmpfs = False
        service_indent = indent
        continue
    if in_service and indent <= service_indent and stripped.endswith(":"):
        break
    if not in_service:
        continue
    if stripped.startswith("read_only:"):
        read_only = stripped.removeprefix("read_only:").strip().strip("'\"").lower()
        continue
    if stripped.startswith("tmpfs:"):
        in_tmpfs = True
        tmpfs_indent = indent
        inline_value = stripped.removeprefix("tmpfs:").strip()
        if inline_value:
            tmpfs_entries.append(inline_value.strip("'\""))
        continue
    if in_tmpfs and indent <= tmpfs_indent:
        in_tmpfs = False
    if in_tmpfs and stripped.startswith("- "):
        tmpfs_entries.append(stripped[2:].strip().strip("'\""))

if read_only != "true":
    print(f"{compose_file}: {service_name} service must set read_only: true", file=sys.stderr)
    sys.exit(1)

if not any(entry.startswith("/tmp:") and "rw" in entry and "noexec" in entry and "nosuid" in entry for entry in tmpfs_entries):
    print(
        f"{compose_file}: {service_name} service must mount /tmp as bounded rw,noexec,nosuid tmpfs",
        file=sys.stderr,
    )
    sys.exit(1)
PY
}

require_restart_unless_stopped_service() {
    compose_file="$1"
    service_name="$2"
    python3 - "$compose_file" "$service_name" <<'PY'
from pathlib import Path
import sys

compose_file = Path(sys.argv[1])
service_name = sys.argv[2]
lines = compose_file.read_text(encoding="utf-8").splitlines()

in_service = False
service_indent = 0
restart = None

for raw_line in lines:
    stripped = raw_line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    indent = len(raw_line) - len(raw_line.lstrip(" "))
    if stripped == f"{service_name}:":
        in_service = True
        service_indent = indent
        continue
    if in_service and indent <= service_indent and stripped.endswith(":"):
        break
    if not in_service:
        continue
    if stripped.startswith("restart:"):
        restart = stripped.removeprefix("restart:").strip().strip("'\"")
        break

if restart != "unless-stopped":
    print(
        f"{compose_file}: {service_name} service must set restart: unless-stopped",
        file=sys.stderr,
    )
    sys.exit(1)
PY
}

require_bounded_json_file_logging_service() {
    compose_file="$1"
    service_name="$2"
    python3 - "$compose_file" "$service_name" <<'PY'
from pathlib import Path
import sys

compose_file = Path(sys.argv[1])
service_name = sys.argv[2]
lines = compose_file.read_text(encoding="utf-8").splitlines()

in_service = False
in_logging = False
service_indent = 0
logging_indent = 0
logging_lines = []

for raw_line in lines:
    stripped = raw_line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    indent = len(raw_line) - len(raw_line.lstrip(" "))
    if stripped == f"{service_name}:":
        in_service = True
        in_logging = False
        service_indent = indent
        continue
    if in_service and indent <= service_indent and stripped.endswith(":"):
        break
    if not in_service:
        continue
    if stripped == "logging:":
        in_logging = True
        logging_indent = indent
        continue
    if in_logging and indent <= logging_indent:
        in_logging = False
    if in_logging:
        logging_lines.append(stripped)

logging_text = "\n".join(logging_lines)
required = [
    "driver: json-file",
    "options:",
    'max-size: "10m"',
    'max-file: "5"',
]
missing = [item for item in required if item not in logging_text]
if missing:
    print(
        f"{compose_file}: {service_name} service must bound json-file logging; missing {', '.join(missing)}",
        file=sys.stderr,
    )
    sys.exit(1)
PY
}

require_service_healthcheck() {
    compose_file="$1"
    service_name="$2"
    expected_probe="$3"
    python3 - "$compose_file" "$service_name" "$expected_probe" <<'PY'
from pathlib import Path
import sys

compose_file = Path(sys.argv[1])
service_name = sys.argv[2]
expected_probe = sys.argv[3]
lines = compose_file.read_text(encoding="utf-8").splitlines()

in_service = False
in_healthcheck = False
service_indent = 0
healthcheck_indent = 0
healthcheck_lines = []

for raw_line in lines:
    stripped = raw_line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    indent = len(raw_line) - len(raw_line.lstrip(" "))
    if stripped == f"{service_name}:":
        in_service = True
        in_healthcheck = False
        service_indent = indent
        continue
    if in_service and indent <= service_indent and stripped.endswith(":"):
        break
    if not in_service:
        continue
    if stripped == "healthcheck:":
        in_healthcheck = True
        healthcheck_indent = indent
        continue
    if in_healthcheck and indent <= healthcheck_indent:
        in_healthcheck = False
    if in_healthcheck:
        healthcheck_lines.append(stripped)

if not healthcheck_lines:
    print(f"{compose_file}: {service_name} service must define a healthcheck", file=sys.stderr)
    sys.exit(1)

healthcheck_text = "\n".join(healthcheck_lines)
if 'test: ["CMD",' not in healthcheck_text:
    print(f"{compose_file}: {service_name} healthcheck must use a CMD argument array", file=sys.stderr)
    sys.exit(1)
if expected_probe not in healthcheck_text:
    print(f"{compose_file}: {service_name} healthcheck must probe {expected_probe}", file=sys.stderr)
    sys.exit(1)
PY
}

require_depends_on_healthy() {
    compose_file="$1"
    service_name="$2"
    dependency_name="$3"
    python3 - "$compose_file" "$service_name" "$dependency_name" <<'PY'
from pathlib import Path
import sys

compose_file = Path(sys.argv[1])
service_name = sys.argv[2]
dependency_name = sys.argv[3]
lines = compose_file.read_text(encoding="utf-8").splitlines()

in_service = False
in_depends_on = False
in_dependency = False
service_indent = 0
depends_indent = 0
dependency_indent = 0

for raw_line in lines:
    stripped = raw_line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    indent = len(raw_line) - len(raw_line.lstrip(" "))
    if stripped == f"{service_name}:":
        in_service = True
        in_depends_on = False
        in_dependency = False
        service_indent = indent
        continue
    if in_service and indent <= service_indent and stripped.endswith(":"):
        break
    if not in_service:
        continue
    if stripped == "depends_on:":
        in_depends_on = True
        in_dependency = False
        depends_indent = indent
        continue
    if in_depends_on and indent <= depends_indent:
        in_depends_on = False
        in_dependency = False
    if not in_depends_on:
        continue
    if stripped == f"{dependency_name}:":
        in_dependency = True
        dependency_indent = indent
        continue
    if in_dependency and indent <= dependency_indent:
        in_dependency = False
    if in_dependency and stripped == "condition: service_healthy":
        sys.exit(0)

print(
    f"{compose_file}: {service_name} must wait for {dependency_name} with condition: service_healthy",
    file=sys.stderr,
)
sys.exit(1)
PY
}

require_required_compose_variable() {
    compose_file="$1"
    variable_name="$2"
    python3 - "$compose_file" "$variable_name" <<'PY'
from pathlib import Path
import re
import sys

compose_file = Path(sys.argv[1])
variable_name = sys.argv[2]
text = compose_file.read_text(encoding="utf-8")

default_pattern = re.compile(r"\$\{" + re.escape(variable_name) + r":-[^}]*}")
if default_pattern.search(text):
    print(f"{compose_file}: {variable_name} must not have a compose default", file=sys.stderr)
    sys.exit(1)

required = f"${{{variable_name}:?{variable_name} is required}}"
if required not in text:
    print(f"{compose_file}: {variable_name} must be required explicitly", file=sys.stderr)
    sys.exit(1)
PY
}

require_no_nonempty_compose_default() {
    compose_file="$1"
    variable_name="$2"
    python3 - "$compose_file" "$variable_name" <<'PY'
from pathlib import Path
import re
import sys

compose_file = Path(sys.argv[1])
variable_name = sys.argv[2]
text = compose_file.read_text(encoding="utf-8")

default_pattern = re.compile(r"\$\{" + re.escape(variable_name) + r":-[^}]+}")
if default_pattern.search(text):
    print(f"{compose_file}: {variable_name} must not have a non-empty compose default", file=sys.stderr)
    sys.exit(1)
PY
}

require_compose_service_env() {
    compose_file="$1"
    service_name="$2"
    variable_name="$3"
    python3 - "$compose_file" "$service_name" "$variable_name" <<'PY'
from pathlib import Path
import sys

compose_file = Path(sys.argv[1])
service_name = sys.argv[2]
variable_name = sys.argv[3]
lines = compose_file.read_text(encoding="utf-8").splitlines()

in_service = False
in_environment = False
service_indent = 0
environment_indent = 0

for raw_line in lines:
    stripped = raw_line.strip()
    if not stripped or stripped.startswith("#"):
        continue
    indent = len(raw_line) - len(raw_line.lstrip(" "))
    if stripped == f"{service_name}:":
        in_service = True
        in_environment = False
        service_indent = indent
        continue
    if in_service and indent <= service_indent and stripped.endswith(":"):
        break
    if not in_service:
        continue
    if stripped == "environment:":
        in_environment = True
        environment_indent = indent
        continue
    if in_environment and indent <= environment_indent:
        in_environment = False
    if in_environment and stripped.startswith(f"{variable_name}:"):
        sys.exit(0)

print(f"{compose_file}: {service_name} service must expose {variable_name} in environment", file=sys.stderr)
sys.exit(1)
PY
}

require_agent_artifact_bind_mount() {
    compose_file="$1"
    python3 - "$compose_file" <<'PY'
from pathlib import Path
import sys

compose_file = Path(sys.argv[1])
text = compose_file.read_text(encoding="utf-8")

required = [
    "type: bind",
    "source: ${MASTER_AGENT_BINARY_HOST_PATH:?MASTER_AGENT_BINARY_HOST_PATH is required}",
    "target: /opt/releases/vps-agent",
    "read_only: true",
    "create_host_path: false",
]

missing = [item for item in required if item not in text]
if missing:
    print(
        f"{compose_file}: agent artifact volume must be an explicit read-only bind mount without host-path creation; missing {', '.join(missing)}",
        file=sys.stderr,
    )
    sys.exit(1)
PY
}

require_read_only_bind_without_host_path_creation() {
    compose_file="$1"
    source="$2"
    target="$3"
    python3 - "$compose_file" "$source" "$target" <<'PY'
from pathlib import Path
import sys

compose_file = Path(sys.argv[1])
source = sys.argv[2]
target = sys.argv[3]
text = compose_file.read_text(encoding="utf-8")

required = [
    "type: bind",
    f"source: {source}",
    f"target: {target}",
    "read_only: true",
    "create_host_path: false",
]

missing = [item for item in required if item not in text]
if missing:
    print(
        f"{compose_file}: {target} must be an explicit read-only bind mount without host-path creation; missing {', '.join(missing)}",
        file=sys.stderr,
    )
    sys.exit(1)
PY
}

require_master_download_route "$repo_root/deploy/caddy/Caddyfile"
require_master_download_route "$repo_root/deploy/caddy/Caddyfile.mtls.example"
require_master_admin_api_route "$repo_root/deploy/caddy/Caddyfile"
require_master_admin_api_route "$repo_root/deploy/caddy/Caddyfile.mtls.example"
require_no_caddy_env_defaults "$repo_root/deploy/caddy/Caddyfile"
require_no_caddy_env_defaults "$repo_root/deploy/caddy/Caddyfile.mtls.example"
require_caddy_security_headers "$repo_root/deploy/caddy/Caddyfile" 1
require_caddy_security_headers "$repo_root/deploy/caddy/Caddyfile.mtls.example" 2
require_mtls_panel_blocks_agent_api "$repo_root/deploy/caddy/Caddyfile.mtls.example"
require_non_root_runtime_user "$repo_root/master/Dockerfile"
require_non_root_runtime_user "$repo_root/frontend/Dockerfile"
require_runtime_base_not_toolchain "$repo_root/master/Dockerfile"
require_postgres_loopback_binding "$repo_root/deploy/docker-compose.yml"
require_no_postgres_password_default "$repo_root/deploy/docker-compose.yml"
require_no_cmd_shell_healthchecks "$repo_root/deploy/docker-compose.yml"
require_curl_healthchecks_disable_config "$repo_root/deploy/docker-compose.yml"
require_no_new_privileges_service "$repo_root/deploy/docker-compose.yml" "postgres"
require_no_new_privileges_service "$repo_root/deploy/docker-compose.yml" "master"
require_no_new_privileges_service "$repo_root/deploy/docker-compose.yml" "frontend"
require_no_new_privileges_service "$repo_root/deploy/docker-compose.yml" "caddy"
require_cap_drop_all_service "$repo_root/deploy/docker-compose.yml" "master"
require_cap_drop_all_service "$repo_root/deploy/docker-compose.yml" "frontend"
require_bounded_pids_limit_service "$repo_root/deploy/docker-compose.yml" "postgres"
require_bounded_pids_limit_service "$repo_root/deploy/docker-compose.yml" "master"
require_bounded_pids_limit_service "$repo_root/deploy/docker-compose.yml" "frontend"
require_bounded_pids_limit_service "$repo_root/deploy/docker-compose.yml" "caddy"
require_read_only_rootfs_with_tmpfs_service "$repo_root/deploy/docker-compose.yml" "master"
require_read_only_rootfs_with_tmpfs_service "$repo_root/deploy/docker-compose.yml" "frontend"
require_read_only_rootfs_with_tmpfs_service "$repo_root/deploy/docker-compose.yml" "caddy"
require_bounded_json_file_logging_service "$repo_root/deploy/docker-compose.yml" "postgres"
require_bounded_json_file_logging_service "$repo_root/deploy/docker-compose.yml" "master"
require_bounded_json_file_logging_service "$repo_root/deploy/docker-compose.yml" "frontend"
require_bounded_json_file_logging_service "$repo_root/deploy/docker-compose.yml" "caddy"
require_restart_unless_stopped_service "$repo_root/deploy/docker-compose.yml" "postgres"
require_restart_unless_stopped_service "$repo_root/deploy/docker-compose.yml" "master"
require_restart_unless_stopped_service "$repo_root/deploy/docker-compose.yml" "frontend"
require_restart_unless_stopped_service "$repo_root/deploy/docker-compose.yml" "caddy"
require_service_healthcheck "$repo_root/deploy/docker-compose.yml" "master" "/healthz"
require_service_healthcheck "$repo_root/deploy/docker-compose.yml" "frontend" "127.0.0.1:3000"
require_service_healthcheck "$repo_root/deploy/docker-compose.yml" "caddy" "/etc/caddy/Caddyfile"
require_depends_on_healthy "$repo_root/deploy/docker-compose.yml" "frontend" "master"
require_depends_on_healthy "$repo_root/deploy/docker-compose.yml" "caddy" "master"
require_depends_on_healthy "$repo_root/deploy/docker-compose.yml" "caddy" "frontend"
require_required_compose_variable "$repo_root/deploy/docker-compose.yml" "DOMAIN"
require_required_compose_variable "$repo_root/deploy/docker-compose.yml" "MASTER_PUBLIC_BASE_URL"
require_required_compose_variable "$repo_root/deploy/docker-compose.yml" "MASTER_INSTALLER_BASE_URL"
require_required_compose_variable "$repo_root/deploy/docker-compose.yml" "MASTER_ADMIN_USERNAME"
require_required_compose_variable "$repo_root/deploy/docker-compose.yml" "MASTER_ADMIN_TOKEN_HASH"
require_no_nonempty_compose_default "$repo_root/deploy/docker-compose.yml" "MASTER_INSTALLER_CA_CERT_PATH"
require_no_nonempty_compose_default "$repo_root/deploy/docker-compose.yml" "MASTER_INSTALLER_CLIENT_IDENTITY_PATH"
require_no_nonempty_compose_default "$repo_root/deploy/docker-compose.yml" "MASTER_READONLY_TOKEN_HASH"
require_compose_service_env "$repo_root/deploy/docker-compose.yml" "frontend" "MASTER_FETCH_TIMEOUT_MS"
require_read_only_bind_without_host_path_creation "$repo_root/deploy/docker-compose.yml" "./caddy/Caddyfile" "/etc/caddy/Caddyfile"
require_required_compose_variable "$repo_root/deploy/docker-compose.mtls.yml" "PANEL_DOMAIN"
require_required_compose_variable "$repo_root/deploy/docker-compose.mtls.yml" "AGENT_DOMAIN"
require_required_compose_variable "$repo_root/deploy/docker-compose.mtls.yml" "AGENT_CLIENT_CA_PATH"
require_read_only_bind_without_host_path_creation "$repo_root/deploy/docker-compose.mtls.yml" "./caddy/Caddyfile.mtls.example" "/etc/caddy/Caddyfile"
require_read_only_bind_without_host_path_creation "$repo_root/deploy/docker-compose.mtls.yml" '${AGENT_CLIENT_CA_PATH:?AGENT_CLIENT_CA_PATH is required}' "/etc/caddy/agent-client-ca.pem"
require_required_compose_variable "$repo_root/deploy/docker-compose.agent-artifact.yml" "MASTER_AGENT_BINARY_HOST_PATH"
require_agent_artifact_bind_mount "$repo_root/deploy/docker-compose.agent-artifact.yml"

echo "deploy config validation tests passed"
