#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Load smoke helpers without executing main.
source <(sed '/^main "\$@"/d' "$repo_root/scripts/kvm-host-smoke.sh")

bash "$repo_root/scripts/kvm-host-smoke.sh" --help >/dev/null

ORIGINAL_API_FUNCTION="$(declare -f api)"
SAFE_SYSTEMD_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

restore_api() {
    eval "$ORIGINAL_API_FUNCTION"
}

expect_help_includes_final_acceptance_command() {
    local help_output
    help_output="$(bash "$repo_root/scripts/kvm-host-smoke.sh" --help)"

    for expected in \
        "Final acceptance command:" \
        "FULL_LIFECYCLE_REQUIRED=1" \
        "REINSTALL_AFTER_CREATE=1" \
        "POWER_CYCLE_AFTER_CREATE=1" \
        "CLEANUP=1" \
        "PRECHECK_ONLY=0" \
        "ALLOW_HTTP=0" \
        "AGENT_BINARY_SHA256=<expected-installed-agent-sha256>" \
        "AGENT_BINARY_SHA256_PATH=/etc/vps-agent/agent.sha256" \
        "sudo -E bash scripts/kvm-host-smoke.sh"
    do
        case "$help_output" in
            *"$expected"*) ;;
            *)
                echo "kvm-host-smoke --help is missing final acceptance guidance: $expected" >&2
                exit 1
                ;;
        esac
    done
}

stub_node_ready() {
    ensure_node_ready() {
        echo "node-ready" >> "$marker"
    }
}

reset_smoke_state() {
    MASTER_URL="https://panel.example.com"
    MASTER_CA_CERT_PATH=""
    ADMIN_TOKEN="admin-token"
    NODE_ID="00000000-0000-0000-0000-000000000000"
    IMAGE_FILE="debian-12.qcow2"
    IMAGE_NAME="Debian 12"
    IP_POOL_ID=""
    IP_POOL_NAME="kvm-smoke-pool"
    IP_POOL_CIDR=""
    IP_POOL_GATEWAY=""
    PLAN_ID=""
    PLAN_NAME="KVM Smoke Plan"
    PLAN_SLUG=""
    VM_NAME="kvm-smoke-test"
    SSH_PUBLIC_KEY=""
    LIBVIRT_NETWORK_NAME="default"
    LIBVIRT_BRIDGE_NAME="virbr0"
    CPU_CORES="1"
    MEMORY_MB="512"
    DISK_GB="10"
    DATA_DIR="/var/lib/vps-agent"
    IMAGE_DIR="${DATA_DIR}/images"
    AGENT_CONFIG_PATH="/etc/vps-agent/agent.toml"
    AGENT_BINARY_PATH="/usr/local/bin/vps-agent"
    AGENT_BINARY_SHA256=""
    AGENT_BINARY_SHA256_PATH="/etc/vps-agent/agent.sha256"
    AGENT_BINARY_SHA256_VERIFIED="0"
    TIMEOUT_SECONDS="900"
    POLL_SECONDS="5"
    CURL_TIMEOUT_SECONDS="30"
    CLEANUP="1"
    ALLOW_HTTP="0"
    PRECHECK_ONLY="0"
    REINSTALL_AFTER_CREATE="0"
    POWER_CYCLE_AFTER_CREATE="0"
    FULL_LIFECYCLE_REQUIRED="0"
}

expect_valid() {
    reset_smoke_state
    "$@"
    validate_args
}

expect_invalid() {
    reset_smoke_state
    "$@"
    if ( validate_args ) >/dev/null 2>&1; then
        echo "expected validation failure: $*" >&2
        exit 1
    fi
}

make_host_paths() {
    HOST_TMP_DIR="$(mktemp -d)"
    DATA_DIR="${HOST_TMP_DIR}/data"
    IMAGE_DIR="${DATA_DIR}/images"
    mkdir -p "$IMAGE_DIR"
    printf 'base image' > "${IMAGE_DIR}/${IMAGE_FILE}"
    chmod 0750 "$DATA_DIR" "$IMAGE_DIR"
    chmod 0640 "${IMAGE_DIR}/${IMAGE_FILE}"
}

make_ca_cert_path() {
    CA_TMP_DIR="$(mktemp -d)"
    MASTER_CA_CERT_PATH="${CA_TMP_DIR}/master-ca.pem"
    printf '%s\n' '-----BEGIN CERTIFICATE-----' 'MIIB' '-----END CERTIFICATE-----' > "$MASTER_CA_CERT_PATH"
    chmod 0640 "$MASTER_CA_CERT_PATH"
}

cleanup_host_paths() {
    if [ -n "${HOST_TMP_DIR:-}" ]; then
        rm -rf "$HOST_TMP_DIR"
        HOST_TMP_DIR=""
    fi
}

cleanup_ca_cert_path() {
    if [ -n "${CA_TMP_DIR:-}" ]; then
        rm -rf "$CA_TMP_DIR"
        CA_TMP_DIR=""
        MASTER_CA_CERT_PATH=""
    fi
}

make_agent_config() {
    AGENT_TMP_DIR="$(mktemp -d)"
    AGENT_CONFIG_PATH="${AGENT_TMP_DIR}/agent.toml"
    cat > "$AGENT_CONFIG_PATH" <<EOF
master_base_url = "$MASTER_URL"
node_id = "$NODE_ID"
credential = "ag_test-credential.1"
data_dir = "$DATA_DIR"

[executor]
mode = "libvirt"
image_dir = "$IMAGE_DIR"
network_name = "$LIBVIRT_NETWORK_NAME"
bridge_name = "$LIBVIRT_BRIDGE_NAME"
EOF
    chmod 0600 "$AGENT_CONFIG_PATH"
}

cleanup_agent_config() {
    if [ -n "${AGENT_TMP_DIR:-}" ]; then
        rm -rf "$AGENT_TMP_DIR"
        AGENT_TMP_DIR=""
        AGENT_CONFIG_PATH="/etc/vps-agent/agent.toml"
    fi
}

make_agent_binary() {
    AGENT_BINARY_TMP_DIR="$(mktemp -d)"
    AGENT_BINARY_PATH="${AGENT_BINARY_TMP_DIR}/vps-agent"
    cat > "$AGENT_BINARY_PATH" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[ "\${1:-}" = "doctor" ] || exit 41
[ "\${VPS_AGENT_CONFIG:-}" = "$AGENT_CONFIG_PATH" ] || exit 42
echo "vps-agent doctor: ok"
EOF
    chmod 0750 "$AGENT_BINARY_PATH"
}

cleanup_agent_binary() {
    if [ -n "${AGENT_BINARY_TMP_DIR:-}" ]; then
        rm -rf "$AGENT_BINARY_TMP_DIR"
        AGENT_BINARY_TMP_DIR=""
        AGENT_BINARY_PATH="/usr/local/bin/vps-agent"
        AGENT_BINARY_SHA256=""
    fi
}

set_agent_binary_sha256() {
    AGENT_BINARY_SHA256="$(sha256sum "$AGENT_BINARY_PATH" | awk '{print $1}')"
}

set_wrong_agent_binary_sha256() {
    AGENT_BINARY_SHA256="$(printf 'different-agent-binary' | sha256sum | awk '{print $1}')"
}

make_agent_binary_sha256_file() {
    AGENT_BINARY_SHA256_TMP_DIR="$(mktemp -d)"
    AGENT_BINARY_SHA256_PATH="${AGENT_BINARY_SHA256_TMP_DIR}/agent.sha256"
    printf '%s\n' "${1:-0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef}" > "$AGENT_BINARY_SHA256_PATH"
    chmod "${2:-0644}" "$AGENT_BINARY_SHA256_PATH"
}

cleanup_agent_binary_sha256_file() {
    if [ -n "${AGENT_BINARY_SHA256_TMP_DIR:-}" ]; then
        rm -rf "$AGENT_BINARY_SHA256_TMP_DIR"
        AGENT_BINARY_SHA256_TMP_DIR=""
        AGENT_BINARY_SHA256_PATH="/etc/vps-agent/agent.sha256"
    fi
}

expect_full_lifecycle_loads_persisted_agent_binary_sha256() {
    reset_smoke_state
    make_agent_binary_sha256_file "ABCDEFabcdef0123456789abcdef0123456789abcdef0123456789abcdef0123"
    AGENT_BINARY_SHA256=""
    FULL_LIFECYCLE_REQUIRED="1"
    REINSTALL_AFTER_CREATE="1"
    POWER_CYCLE_AFTER_CREATE="1"
    CLEANUP="1"

    validate_args

    if [ "$AGENT_BINARY_SHA256" != "abcdefabcdef0123456789abcdef0123456789abcdef0123456789abcdef0123" ]; then
        echo "kvm-host-smoke did not load and normalize the persisted agent SHA-256" >&2
        cleanup_agent_binary_sha256_file
        exit 1
    fi

    cleanup_agent_binary_sha256_file
}

expect_persisted_agent_binary_sha256_file_rejects_invalid_digest() {
    reset_smoke_state
    make_agent_binary_sha256_file "not-a-sha256"
    AGENT_BINARY_SHA256=""

    if ( validate_args ) >/dev/null 2>&1; then
        echo "kvm-host-smoke accepted an invalid persisted agent SHA-256" >&2
        cleanup_agent_binary_sha256_file
        exit 1
    fi

    cleanup_agent_binary_sha256_file
}

expect_persisted_agent_binary_sha256_file_rejects_loose_permissions() {
    reset_smoke_state
    make_agent_binary_sha256_file "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" "0664"
    AGENT_BINARY_SHA256=""

    if ( validate_args ) >/dev/null 2>&1; then
        echo "kvm-host-smoke accepted a group-writable persisted agent SHA-256 file" >&2
        cleanup_agent_binary_sha256_file
        exit 1
    fi

    cleanup_agent_binary_sha256_file
}

expect_persisted_agent_binary_sha256_file_rejects_symlink() {
    reset_smoke_state
    AGENT_BINARY_SHA256_TMP_DIR="$(mktemp -d)"
    local target="${AGENT_BINARY_SHA256_TMP_DIR}/target.sha256"
    AGENT_BINARY_SHA256_PATH="${AGENT_BINARY_SHA256_TMP_DIR}/agent.sha256"
    printf '%s\n' "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" > "$target"
    chmod 0644 "$target"
    ln -s "$target" "$AGENT_BINARY_SHA256_PATH"
    AGENT_BINARY_SHA256=""

    if ( validate_args ) >/dev/null 2>&1; then
        echo "kvm-host-smoke accepted a symlinked persisted agent SHA-256 file" >&2
        cleanup_agent_binary_sha256_file
        exit 1
    fi

    cleanup_agent_binary_sha256_file
}

set_default_systemctl_active() {
    systemctl() {
        if [ "$#" -eq 3 ] && [ "$1" = "is-active" ] && [ "$2" = "--quiet" ] && [ "$3" = "vps-agent.service" ]; then
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ReadWritePaths" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s %s\n' "${AGENT_CONFIG_PATH%/*}" "$DATA_DIR"
            return 0
        fi
        if [ "$#" -eq 12 ] && [ "$1" = "show" ] && [ "${12}" = "vps-agent.service" ]; then
            printf '%s\n' \
                "NoNewPrivileges=yes" \
                "MemoryDenyWriteExecute=yes" \
                "PrivateTmp=yes" \
                "ProtectClock=yes" \
                "ProtectHome=yes" \
                "ProtectHostname=yes" \
                "ProtectSystem=strict" \
                "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK" \
                "RestrictSUIDSGID=yes" \
                "UMask=0077"
            return 0
        fi
        if is_extra_hardening_show_call "$@"; then
            print_default_extra_hardening_properties
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=Environment" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "RUST_LOG=vps_agent=info VPS_AGENT_CONFIG=${AGENT_CONFIG_PATH} PATH=${SAFE_SYSTEMD_PATH}"
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ExecStart" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "{ path=${AGENT_BINARY_PATH} ; argv[]=${AGENT_BINARY_PATH} ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
            return 0
        fi
        echo "unexpected systemctl call: $*" >&2
        return 45
    }
}

set_default_systemctl_active

is_extra_hardening_show_call() {
    [ "$#" -eq 10 ] &&
        [ "$1" = "show" ] &&
        [ "$2" = "--property=ProtectKernelTunables" ] &&
        [ "$3" = "--property=ProtectKernelModules" ] &&
        [ "$4" = "--property=ProtectControlGroups" ] &&
        [ "$5" = "--property=LockPersonality" ] &&
        [ "$6" = "--property=RestrictRealtime" ] &&
        [ "$7" = "--property=CapabilityBoundingSet" ] &&
        [ "$8" = "--property=AmbientCapabilities" ] &&
        [ "$9" = "--property=SystemCallArchitectures" ] &&
        [ "${10}" = "vps-agent.service" ]
}

print_default_extra_hardening_properties() {
    printf '%s\n' \
        "ProtectKernelTunables=yes" \
        "ProtectKernelModules=yes" \
        "ProtectControlGroups=yes" \
        "LockPersonality=yes" \
        "RestrictRealtime=yes" \
        "CapabilityBoundingSet=" \
        "AmbientCapabilities=" \
        "SystemCallArchitectures=native"
}

task_started_logs_json() {
    local task_id="$1"
    printf '[{"id":1,"task_id":"%s","node_id":"%s","message":"task executor started","created_at":"2026-05-23T00:00:00Z"}]' \
        "$task_id" "$NODE_ID"
}

smoke_audit_logs_json() {
    local create_task_id="$1"
    local vm_id="$2"
    local include_status_update="${3:-1}"
    if [ "$#" -gt 3 ]; then
        shift 3
    else
        set --
    fi

    python3 - "$NODE_ID" "$create_task_id" "$vm_id" "$include_status_update" "$@" <<'PY'
import json
import sys

node_id, create_task_id, vm_id, include_status_update = sys.argv[1:5]
extra_specs = sys.argv[5:]

if len(extra_specs) % 3 != 0:
    sys.exit(1)


def task_logs(admin_action, task_id, task_kind):
    logs = [{
        "action": admin_action,
        "node_id": node_id,
        "task_id": task_id,
        "detail": {"task_kind": task_kind, "vm_id": vm_id},
    }, {
        "action": "task.assigned",
        "node_id": node_id,
        "task_id": task_id,
        "detail": {"task_kind": task_kind, "vm_id": vm_id},
    }, {
        "action": "task.log.append",
        "node_id": node_id,
        "task_id": task_id,
        "detail": {"message_bytes": 21},
    }]
    if include_status_update == "1":
        logs.append({
            "action": "task.status_update",
            "node_id": node_id,
            "task_id": task_id,
            "detail": {"task_kind": task_kind, "vm_id": vm_id, "status": "succeeded"},
        })
    return logs


task_specs = [("task.create_vm", create_task_id, "create_vm")]
task_specs.extend(
    (extra_specs[index], extra_specs[index + 1], extra_specs[index + 2])
    for index in range(0, len(extra_specs), 3)
)

logs = []
for admin_action, task_id, task_kind in task_specs:
    logs.extend(task_logs(admin_action, task_id, task_kind))

print(json.dumps(logs))
PY
}
node_ready_list_json() {
    local node_id="${1:-$NODE_ID}"
    local status="${2:-online}"
    local scheduling_enabled="${3:-true}"
    local agent_version="${4:-0.1.0}"
    local last_seen_at="${5:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    local libvirt_status="${6:-available}"

    python3 - "$node_id" "$status" "$scheduling_enabled" "$agent_version" "$last_seen_at" "$libvirt_status" <<'PY'
import json
import sys

node_id, status, scheduling_enabled, agent_version, last_seen_at, libvirt_status = sys.argv[1:7]


def nullable(value):
    return None if value == "null" else value


print(json.dumps([{
    "id": node_id,
    "name": "node-01",
    "status": status,
    "scheduling_enabled": scheduling_enabled == "true",
    "agent_version": nullable(agent_version),
    "last_seen_at": nullable(last_seen_at),
    "libvirt_status": libvirt_status,
    "host_checks": [],
    "cpu_total": 4,
    "cpu_used": 1,
    "memory_total": 8192,
    "memory_used": 1024,
    "disk_total": 100,
    "disk_used": 10,
    "committed_cpu": 0,
    "committed_memory_mb": 0,
    "committed_disk_gb": 0,
    "vm_count": 0,
    "created_at": "2026-05-23T00:00:00Z",
}]))
PY
}

expect_host_valid() {
    reset_smoke_state
    make_host_paths
    "$@"
    validate_args
    validate_host_paths
    cleanup_host_paths
}

expect_host_invalid() {
    reset_smoke_state
    make_host_paths
    "$@"
    validate_args
    if ( validate_host_paths ) >/dev/null 2>&1; then
        echo "expected host path validation failure: $*" >&2
        cleanup_host_paths
        exit 1
    fi
    cleanup_host_paths
}

expect_ca_cert_valid() {
    reset_smoke_state
    make_ca_cert_path
    "$@"
    validate_args
    validate_ca_cert_path
    cleanup_ca_cert_path
}

expect_ca_cert_invalid() {
    reset_smoke_state
    make_ca_cert_path
    "$@"
    validate_args
    if ( validate_ca_cert_path ) >/dev/null 2>&1; then
        echo "expected CA certificate validation failure: $*" >&2
        cleanup_ca_cert_path
        exit 1
    fi
    cleanup_ca_cert_path
}

expect_agent_config_valid() {
    reset_smoke_state
    make_agent_config
    "$@"
    validate_args
    validate_agent_config
    cleanup_agent_config
}

expect_agent_config_invalid() {
    reset_smoke_state
    make_agent_config
    "$@"
    validate_args
    if ( validate_agent_config ) >/dev/null 2>&1; then
        echo "expected agent config validation failure: $*" >&2
        cleanup_agent_config
        exit 1
    fi
    cleanup_agent_config
}

expect_agent_doctor_valid() {
    reset_smoke_state
    make_agent_config
    make_agent_binary
    "$@"
    validate_args
    validate_agent_doctor
    cleanup_agent_binary
    cleanup_agent_config
}

expect_agent_doctor_invalid() {
    reset_smoke_state
    make_agent_config
    make_agent_binary
    "$@"
    validate_args
    if ( validate_agent_doctor ) >/dev/null 2>&1; then
        echo "expected agent doctor validation failure: $*" >&2
        cleanup_agent_binary
        cleanup_agent_config
        exit 1
    fi
    cleanup_agent_binary
    cleanup_agent_config
}

expect_agent_doctor_hides_failed_output() {
    reset_smoke_state
    make_agent_config
    make_agent_binary
    cat > "$AGENT_BINARY_PATH" <<'EOF'
#!/usr/bin/env bash
echo "credential=ag_should_not_print"
echo "password=hunter2" >&2
exit 47
EOF
    chmod 0750 "$AGENT_BINARY_PATH"
    validate_args

    local output
    if output="$(validate_agent_doctor 2>&1 >/dev/null)"; then
        echo "expected agent doctor failure" >&2
        cleanup_agent_binary
        cleanup_agent_config
        exit 1
    fi

    case "$output" in
        *ag_should_not_print*|*hunter2*)
            echo "agent doctor failure leaked doctor output" >&2
            printf '%s\n' "$output" >&2
            cleanup_agent_binary
            cleanup_agent_config
            exit 1
            ;;
    esac

    cleanup_agent_binary
    cleanup_agent_config
}

expect_agent_doctor_rejects_mismatched_binary_sha256() {
    expect_agent_doctor_invalid set_wrong_agent_binary_sha256
}

expect_agent_doctor_records_verified_sha256() {
    reset_smoke_state
    make_agent_config
    make_agent_binary
    set_agent_binary_sha256
    validate_args

    validate_agent_doctor

    if [ "$AGENT_BINARY_SHA256_VERIFIED" != "1" ]; then
        echo "agent doctor did not record verified AGENT_BINARY_SHA256 evidence" >&2
        cleanup_agent_binary
        cleanup_agent_config
        exit 1
    fi

    cleanup_agent_binary
    cleanup_agent_config
}

expect_agent_service_valid() {
    reset_smoke_state
    validate_agent_service
}

expect_agent_service_invalid_when_inactive() {
    reset_smoke_state
    systemctl() {
        if [ "$#" -eq 3 ] && [ "$1" = "is-active" ] && [ "$2" = "--quiet" ] && [ "$3" = "vps-agent.service" ]; then
            return 3
        fi
        echo "unexpected systemctl call: $*" >&2
        return 45
    }

    if ( validate_agent_service ) >/dev/null 2>&1; then
        echo "inactive vps-agent systemd service was accepted" >&2
        set_default_systemctl_active
        exit 1
    fi

    set_default_systemctl_active
}

expect_agent_service_hides_failed_output() {
    reset_smoke_state
    systemctl() {
        echo "credential=ag_should_not_print"
        echo "password=hunter2" >&2
        return 3
    }

    local output
    if output="$(validate_agent_service 2>&1 >/dev/null)"; then
        echo "expected agent service validation failure" >&2
        set_default_systemctl_active
        exit 1
    fi

    case "$output" in
        *ag_should_not_print*|*hunter2*)
            echo "agent service failure leaked systemctl output" >&2
            printf '%s\n' "$output" >&2
            set_default_systemctl_active
            exit 1
            ;;
    esac

    set_default_systemctl_active
}

expect_agent_service_rejects_missing_writable_data_dir() {
    reset_smoke_state
    systemctl() {
        if [ "$#" -eq 3 ] && [ "$1" = "is-active" ] && [ "$2" = "--quiet" ] && [ "$3" = "vps-agent.service" ]; then
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ReadWritePaths" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "/etc/vps-agent"
            return 0
        fi
        echo "unexpected systemctl call: $*" >&2
        return 45
    }

    if ( validate_agent_service ) >/dev/null 2>&1; then
        echo "vps-agent service without DATA_DIR in ReadWritePaths was accepted" >&2
        set_default_systemctl_active
        exit 1
    fi

    set_default_systemctl_active
}

expect_agent_service_rejects_missing_no_new_privileges() {
    reset_smoke_state
    systemctl() {
        if [ "$#" -eq 3 ] && [ "$1" = "is-active" ] && [ "$2" = "--quiet" ] && [ "$3" = "vps-agent.service" ]; then
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ReadWritePaths" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s %s\n' "${AGENT_CONFIG_PATH%/*}" "$DATA_DIR"
            return 0
        fi
        if [ "$#" -eq 12 ] && [ "$1" = "show" ] && [ "${12}" = "vps-agent.service" ]; then
            printf '%s\n' \
                "NoNewPrivileges=no" \
                "MemoryDenyWriteExecute=yes" \
                "PrivateTmp=yes" \
                "ProtectClock=yes" \
                "ProtectHome=yes" \
                "ProtectHostname=yes" \
                "ProtectSystem=strict" \
                "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK" \
                "RestrictSUIDSGID=yes" \
                "UMask=0077"
            return 0
        fi
        echo "unexpected systemctl call: $*" >&2
        return 45
    }

    if ( validate_agent_service ) >/dev/null 2>&1; then
        echo "vps-agent service without NoNewPrivileges was accepted" >&2
        set_default_systemctl_active
        exit 1
    fi

    set_default_systemctl_active
}

expect_agent_service_rejects_missing_memory_deny_write_execute() {
    reset_smoke_state
    systemctl() {
        if [ "$#" -eq 3 ] && [ "$1" = "is-active" ] && [ "$2" = "--quiet" ] && [ "$3" = "vps-agent.service" ]; then
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ReadWritePaths" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s %s\n' "${AGENT_CONFIG_PATH%/*}" "$DATA_DIR"
            return 0
        fi
        if [ "$#" -eq 12 ] && [ "$1" = "show" ] && [ "${12}" = "vps-agent.service" ]; then
            printf '%s\n' \
                "NoNewPrivileges=yes" \
                "PrivateTmp=yes" \
                "ProtectClock=yes" \
                "ProtectHome=yes" \
                "ProtectHostname=yes" \
                "ProtectSystem=strict" \
                "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK" \
                "RestrictSUIDSGID=yes" \
                "UMask=0077"
            return 0
        fi
        if is_extra_hardening_show_call "$@"; then
            print_default_extra_hardening_properties
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=Environment" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "RUST_LOG=vps_agent=info VPS_AGENT_CONFIG=${AGENT_CONFIG_PATH} PATH=${SAFE_SYSTEMD_PATH}"
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ExecStart" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "{ path=${AGENT_BINARY_PATH} ; argv[]=${AGENT_BINARY_PATH} ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
            return 0
        fi
        echo "unexpected systemctl call: $*" >&2
        return 45
    }

    if ( validate_agent_service ) >/dev/null 2>&1; then
        echo "vps-agent service without MemoryDenyWriteExecute was accepted" >&2
        set_default_systemctl_active
        exit 1
    fi

    set_default_systemctl_active
}

expect_agent_service_rejects_missing_restrict_address_families() {
    reset_smoke_state
    systemctl() {
        if [ "$#" -eq 3 ] && [ "$1" = "is-active" ] && [ "$2" = "--quiet" ] && [ "$3" = "vps-agent.service" ]; then
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ReadWritePaths" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s %s\n' "${AGENT_CONFIG_PATH%/*}" "$DATA_DIR"
            return 0
        fi
        if [ "$#" -eq 12 ] && [ "$1" = "show" ] && [ "${12}" = "vps-agent.service" ]; then
            printf '%s\n' \
                "NoNewPrivileges=yes" \
                "MemoryDenyWriteExecute=yes" \
                "PrivateTmp=yes" \
                "ProtectClock=yes" \
                "ProtectHome=yes" \
                "ProtectHostname=yes" \
                "ProtectSystem=strict" \
                "RestrictSUIDSGID=yes" \
                "UMask=0077"
            return 0
        fi
        if is_extra_hardening_show_call "$@"; then
            print_default_extra_hardening_properties
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=Environment" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "RUST_LOG=vps_agent=info VPS_AGENT_CONFIG=${AGENT_CONFIG_PATH} PATH=${SAFE_SYSTEMD_PATH}"
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ExecStart" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "{ path=${AGENT_BINARY_PATH} ; argv[]=${AGENT_BINARY_PATH} ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
            return 0
        fi
        echo "unexpected systemctl call: $*" >&2
        return 45
    }

    if ( validate_agent_service ) >/dev/null 2>&1; then
        echo "vps-agent service without RestrictAddressFamilies was accepted" >&2
        set_default_systemctl_active
        exit 1
    fi

    set_default_systemctl_active
}

expect_agent_service_rejects_missing_clock_hostname_protection() {
    reset_smoke_state
    systemctl() {
        if [ "$#" -eq 3 ] && [ "$1" = "is-active" ] && [ "$2" = "--quiet" ] && [ "$3" = "vps-agent.service" ]; then
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ReadWritePaths" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s %s\n' "${AGENT_CONFIG_PATH%/*}" "$DATA_DIR"
            return 0
        fi
        if [ "$#" -eq 12 ] && [ "$1" = "show" ] && [ "${12}" = "vps-agent.service" ]; then
            printf '%s\n' \
                "NoNewPrivileges=yes" \
                "MemoryDenyWriteExecute=yes" \
                "PrivateTmp=yes" \
                "ProtectHome=yes" \
                "ProtectSystem=strict" \
                "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK" \
                "RestrictSUIDSGID=yes" \
                "UMask=0077"
            return 0
        fi
        if is_extra_hardening_show_call "$@"; then
            print_default_extra_hardening_properties
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=Environment" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "RUST_LOG=vps_agent=info VPS_AGENT_CONFIG=${AGENT_CONFIG_PATH} PATH=${SAFE_SYSTEMD_PATH}"
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ExecStart" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "{ path=${AGENT_BINARY_PATH} ; argv[]=${AGENT_BINARY_PATH} ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
            return 0
        fi
        echo "unexpected systemctl call: $*" >&2
        return 45
    }

    if ( validate_agent_service ) >/dev/null 2>&1; then
        echo "vps-agent service without ProtectClock/ProtectHostname was accepted" >&2
        set_default_systemctl_active
        exit 1
    fi

    set_default_systemctl_active
}

expect_agent_service_rejects_missing_restrict_suid_sgid() {
    reset_smoke_state
    systemctl() {
        if [ "$#" -eq 3 ] && [ "$1" = "is-active" ] && [ "$2" = "--quiet" ] && [ "$3" = "vps-agent.service" ]; then
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ReadWritePaths" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s %s\n' "${AGENT_CONFIG_PATH%/*}" "$DATA_DIR"
            return 0
        fi
        if [ "$#" -eq 12 ] && [ "$1" = "show" ] && [ "${12}" = "vps-agent.service" ]; then
            printf '%s\n' \
                "NoNewPrivileges=yes" \
                "MemoryDenyWriteExecute=yes" \
                "PrivateTmp=yes" \
                "ProtectClock=yes" \
                "ProtectHome=yes" \
                "ProtectHostname=yes" \
                "ProtectSystem=strict" \
                "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK" \
                "UMask=0077"
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=Environment" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "RUST_LOG=vps_agent=info VPS_AGENT_CONFIG=${AGENT_CONFIG_PATH} PATH=${SAFE_SYSTEMD_PATH}"
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ExecStart" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "{ path=${AGENT_BINARY_PATH} ; argv[]=${AGENT_BINARY_PATH} ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
            return 0
        fi
        echo "unexpected systemctl call: $*" >&2
        return 45
    }

    if ( validate_agent_service ) >/dev/null 2>&1; then
        echo "vps-agent service without RestrictSUIDSGID was accepted" >&2
        set_default_systemctl_active
        exit 1
    fi

    set_default_systemctl_active
}

expect_agent_service_rejects_nonempty_capability_bounding_set() {
    reset_smoke_state
    systemctl() {
        if [ "$#" -eq 3 ] && [ "$1" = "is-active" ] && [ "$2" = "--quiet" ] && [ "$3" = "vps-agent.service" ]; then
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ReadWritePaths" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s %s\n' "${AGENT_CONFIG_PATH%/*}" "$DATA_DIR"
            return 0
        fi
        if [ "$#" -eq 12 ] && [ "$1" = "show" ] && [ "${12}" = "vps-agent.service" ]; then
            printf '%s\n' \
                "NoNewPrivileges=yes" \
                "MemoryDenyWriteExecute=yes" \
                "PrivateTmp=yes" \
                "ProtectClock=yes" \
                "ProtectHome=yes" \
                "ProtectHostname=yes" \
                "ProtectSystem=strict" \
                "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK" \
                "RestrictSUIDSGID=yes" \
                "UMask=0077"
            return 0
        fi
        if is_extra_hardening_show_call "$@"; then
            print_default_extra_hardening_properties | sed 's/^CapabilityBoundingSet=$/CapabilityBoundingSet=cap_sys_admin/'
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=Environment" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "RUST_LOG=vps_agent=info VPS_AGENT_CONFIG=${AGENT_CONFIG_PATH} PATH=${SAFE_SYSTEMD_PATH}"
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ExecStart" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "{ path=${AGENT_BINARY_PATH} ; argv[]=${AGENT_BINARY_PATH} ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
            return 0
        fi
        echo "unexpected systemctl call: $*" >&2
        return 45
    }

    if ( validate_agent_service ) >/dev/null 2>&1; then
        echo "vps-agent service with nonempty CapabilityBoundingSet was accepted" >&2
        set_default_systemctl_active
        exit 1
    fi

    set_default_systemctl_active
}

expect_agent_service_rejects_nonempty_ambient_capabilities() {
    reset_smoke_state
    systemctl() {
        if [ "$#" -eq 3 ] && [ "$1" = "is-active" ] && [ "$2" = "--quiet" ] && [ "$3" = "vps-agent.service" ]; then
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ReadWritePaths" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s %s\n' "${AGENT_CONFIG_PATH%/*}" "$DATA_DIR"
            return 0
        fi
        if [ "$#" -eq 12 ] && [ "$1" = "show" ] && [ "${12}" = "vps-agent.service" ]; then
            printf '%s\n' \
                "NoNewPrivileges=yes" \
                "MemoryDenyWriteExecute=yes" \
                "PrivateTmp=yes" \
                "ProtectClock=yes" \
                "ProtectHome=yes" \
                "ProtectHostname=yes" \
                "ProtectSystem=strict" \
                "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK" \
                "RestrictSUIDSGID=yes" \
                "UMask=0077"
            return 0
        fi
        if is_extra_hardening_show_call "$@"; then
            print_default_extra_hardening_properties | sed 's/^AmbientCapabilities=$/AmbientCapabilities=cap_net_admin/'
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=Environment" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "RUST_LOG=vps_agent=info VPS_AGENT_CONFIG=${AGENT_CONFIG_PATH} PATH=${SAFE_SYSTEMD_PATH}"
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ExecStart" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "{ path=${AGENT_BINARY_PATH} ; argv[]=${AGENT_BINARY_PATH} ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
            return 0
        fi
        echo "unexpected systemctl call: $*" >&2
        return 45
    }

    if ( validate_agent_service ) >/dev/null 2>&1; then
        echo "vps-agent service with nonempty AmbientCapabilities was accepted" >&2
        set_default_systemctl_active
        exit 1
    fi

    set_default_systemctl_active
}

expect_agent_service_rejects_missing_kernel_tunable_protection() {
    reset_smoke_state
    systemctl() {
        if [ "$#" -eq 3 ] && [ "$1" = "is-active" ] && [ "$2" = "--quiet" ] && [ "$3" = "vps-agent.service" ]; then
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ReadWritePaths" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s %s\n' "${AGENT_CONFIG_PATH%/*}" "$DATA_DIR"
            return 0
        fi
        if [ "$#" -eq 12 ] && [ "$1" = "show" ] && [ "${12}" = "vps-agent.service" ]; then
            printf '%s\n' \
                "NoNewPrivileges=yes" \
                "MemoryDenyWriteExecute=yes" \
                "PrivateTmp=yes" \
                "ProtectClock=yes" \
                "ProtectHome=yes" \
                "ProtectHostname=yes" \
                "ProtectSystem=strict" \
                "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK" \
                "RestrictSUIDSGID=yes" \
                "UMask=0077"
            return 0
        fi
        if is_extra_hardening_show_call "$@"; then
            print_default_extra_hardening_properties | sed '/^ProtectKernelTunables=/d'
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=Environment" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "RUST_LOG=vps_agent=info VPS_AGENT_CONFIG=${AGENT_CONFIG_PATH} PATH=${SAFE_SYSTEMD_PATH}"
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ExecStart" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "{ path=${AGENT_BINARY_PATH} ; argv[]=${AGENT_BINARY_PATH} ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
            return 0
        fi
        echo "unexpected systemctl call: $*" >&2
        return 45
    }

    if ( validate_agent_service ) >/dev/null 2>&1; then
        echo "vps-agent service without ProtectKernelTunables was accepted" >&2
        set_default_systemctl_active
        exit 1
    fi

    set_default_systemctl_active
}

expect_agent_service_rejects_missing_native_syscall_architecture() {
    reset_smoke_state
    systemctl() {
        if [ "$#" -eq 3 ] && [ "$1" = "is-active" ] && [ "$2" = "--quiet" ] && [ "$3" = "vps-agent.service" ]; then
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ReadWritePaths" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s %s\n' "${AGENT_CONFIG_PATH%/*}" "$DATA_DIR"
            return 0
        fi
        if [ "$#" -eq 12 ] && [ "$1" = "show" ] && [ "${12}" = "vps-agent.service" ]; then
            printf '%s\n' \
                "NoNewPrivileges=yes" \
                "MemoryDenyWriteExecute=yes" \
                "PrivateTmp=yes" \
                "ProtectClock=yes" \
                "ProtectHome=yes" \
                "ProtectHostname=yes" \
                "ProtectSystem=strict" \
                "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK" \
                "RestrictSUIDSGID=yes" \
                "UMask=0077"
            return 0
        fi
        if is_extra_hardening_show_call "$@"; then
            print_default_extra_hardening_properties | sed 's/^SystemCallArchitectures=native$/SystemCallArchitectures=/'
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=Environment" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "RUST_LOG=vps_agent=info VPS_AGENT_CONFIG=${AGENT_CONFIG_PATH} PATH=${SAFE_SYSTEMD_PATH}"
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ExecStart" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "{ path=${AGENT_BINARY_PATH} ; argv[]=${AGENT_BINARY_PATH} ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
            return 0
        fi
        echo "unexpected systemctl call: $*" >&2
        return 45
    }

    if ( validate_agent_service ) >/dev/null 2>&1; then
        echo "vps-agent service without native SystemCallArchitectures was accepted" >&2
        set_default_systemctl_active
        exit 1
    fi

    set_default_systemctl_active
}

expect_agent_service_rejects_wrong_config_environment() {
    reset_smoke_state
    systemctl() {
        if [ "$#" -eq 3 ] && [ "$1" = "is-active" ] && [ "$2" = "--quiet" ] && [ "$3" = "vps-agent.service" ]; then
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ReadWritePaths" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s %s\n' "${AGENT_CONFIG_PATH%/*}" "$DATA_DIR"
            return 0
        fi
        if [ "$#" -eq 12 ] && [ "$1" = "show" ] && [ "${12}" = "vps-agent.service" ]; then
            printf '%s\n' \
                "NoNewPrivileges=yes" \
                "MemoryDenyWriteExecute=yes" \
                "PrivateTmp=yes" \
                "ProtectClock=yes" \
                "ProtectHome=yes" \
                "ProtectHostname=yes" \
                "ProtectSystem=strict" \
                "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK" \
                "RestrictSUIDSGID=yes" \
                "UMask=0077"
            return 0
        fi
        if is_extra_hardening_show_call "$@"; then
            print_default_extra_hardening_properties
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=Environment" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "RUST_LOG=vps_agent=info VPS_AGENT_CONFIG=/etc/vps-agent/other.toml PATH=${SAFE_SYSTEMD_PATH}"
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ExecStart" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "{ path=${AGENT_BINARY_PATH} ; argv[]=${AGENT_BINARY_PATH} ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
            return 0
        fi
        echo "unexpected systemctl call: $*" >&2
        return 45
    }

    if ( validate_agent_service ) >/dev/null 2>&1; then
        echo "vps-agent service with wrong VPS_AGENT_CONFIG environment was accepted" >&2
        set_default_systemctl_active
        exit 1
    fi

    set_default_systemctl_active
}

expect_agent_service_rejects_duplicate_config_environment() {
    reset_smoke_state
    systemctl() {
        if [ "$#" -eq 3 ] && [ "$1" = "is-active" ] && [ "$2" = "--quiet" ] && [ "$3" = "vps-agent.service" ]; then
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ReadWritePaths" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s %s\n' "${AGENT_CONFIG_PATH%/*}" "$DATA_DIR"
            return 0
        fi
        if [ "$#" -eq 12 ] && [ "$1" = "show" ] && [ "${12}" = "vps-agent.service" ]; then
            printf '%s\n' \
                "NoNewPrivileges=yes" \
                "MemoryDenyWriteExecute=yes" \
                "PrivateTmp=yes" \
                "ProtectClock=yes" \
                "ProtectHome=yes" \
                "ProtectHostname=yes" \
                "ProtectSystem=strict" \
                "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK" \
                "RestrictSUIDSGID=yes" \
                "UMask=0077"
            return 0
        fi
        if is_extra_hardening_show_call "$@"; then
            print_default_extra_hardening_properties
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=Environment" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "RUST_LOG=vps_agent=info VPS_AGENT_CONFIG=/etc/vps-agent/other.toml VPS_AGENT_CONFIG=${AGENT_CONFIG_PATH} PATH=${SAFE_SYSTEMD_PATH}"
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ExecStart" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "{ path=${AGENT_BINARY_PATH} ; argv[]=${AGENT_BINARY_PATH} ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
            return 0
        fi
        echo "unexpected systemctl call: $*" >&2
        return 45
    }

    if ( validate_agent_service ) >/dev/null 2>&1; then
        echo "vps-agent service with duplicate VPS_AGENT_CONFIG environment was accepted" >&2
        set_default_systemctl_active
        exit 1
    fi

    set_default_systemctl_active
}

expect_agent_service_rejects_missing_safe_path_environment() {
    reset_smoke_state
    systemctl() {
        if [ "$#" -eq 3 ] && [ "$1" = "is-active" ] && [ "$2" = "--quiet" ] && [ "$3" = "vps-agent.service" ]; then
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ReadWritePaths" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s %s\n' "${AGENT_CONFIG_PATH%/*}" "$DATA_DIR"
            return 0
        fi
        if [ "$#" -eq 12 ] && [ "$1" = "show" ] && [ "${12}" = "vps-agent.service" ]; then
            printf '%s\n' \
                "NoNewPrivileges=yes" \
                "MemoryDenyWriteExecute=yes" \
                "PrivateTmp=yes" \
                "ProtectClock=yes" \
                "ProtectHome=yes" \
                "ProtectHostname=yes" \
                "ProtectSystem=strict" \
                "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK" \
                "RestrictSUIDSGID=yes" \
                "UMask=0077"
            return 0
        fi
        if is_extra_hardening_show_call "$@"; then
            print_default_extra_hardening_properties
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=Environment" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "RUST_LOG=vps_agent=info VPS_AGENT_CONFIG=${AGENT_CONFIG_PATH}"
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ExecStart" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "{ path=${AGENT_BINARY_PATH} ; argv[]=${AGENT_BINARY_PATH} ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
            return 0
        fi
        echo "unexpected systemctl call: $*" >&2
        return 45
    }

    if ( validate_agent_service ) >/dev/null 2>&1; then
        echo "vps-agent service without safe PATH environment was accepted" >&2
        set_default_systemctl_active
        exit 1
    fi

    set_default_systemctl_active
}

expect_agent_service_rejects_duplicate_safe_path_environment() {
    reset_smoke_state
    systemctl() {
        if [ "$#" -eq 3 ] && [ "$1" = "is-active" ] && [ "$2" = "--quiet" ] && [ "$3" = "vps-agent.service" ]; then
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ReadWritePaths" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s %s\n' "${AGENT_CONFIG_PATH%/*}" "$DATA_DIR"
            return 0
        fi
        if [ "$#" -eq 12 ] && [ "$1" = "show" ] && [ "${12}" = "vps-agent.service" ]; then
            printf '%s\n' \
                "NoNewPrivileges=yes" \
                "MemoryDenyWriteExecute=yes" \
                "PrivateTmp=yes" \
                "ProtectClock=yes" \
                "ProtectHome=yes" \
                "ProtectHostname=yes" \
                "ProtectSystem=strict" \
                "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK" \
                "RestrictSUIDSGID=yes" \
                "UMask=0077"
            return 0
        fi
        if is_extra_hardening_show_call "$@"; then
            print_default_extra_hardening_properties
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=Environment" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "RUST_LOG=vps_agent=info VPS_AGENT_CONFIG=${AGENT_CONFIG_PATH} PATH=${SAFE_SYSTEMD_PATH} PATH=${SAFE_SYSTEMD_PATH}"
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ExecStart" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "{ path=${AGENT_BINARY_PATH} ; argv[]=${AGENT_BINARY_PATH} ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
            return 0
        fi
        echo "unexpected systemctl call: $*" >&2
        return 45
    }

    if ( validate_agent_service ) >/dev/null 2>&1; then
        echo "vps-agent service with duplicate safe PATH environment was accepted" >&2
        set_default_systemctl_active
        exit 1
    fi

    set_default_systemctl_active
}

expect_agent_service_rejects_wrong_exec_start() {
    reset_smoke_state
    systemctl() {
        if [ "$#" -eq 3 ] && [ "$1" = "is-active" ] && [ "$2" = "--quiet" ] && [ "$3" = "vps-agent.service" ]; then
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ReadWritePaths" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s %s\n' "${AGENT_CONFIG_PATH%/*}" "$DATA_DIR"
            return 0
        fi
        if [ "$#" -eq 12 ] && [ "$1" = "show" ] && [ "${12}" = "vps-agent.service" ]; then
            printf '%s\n' \
                "NoNewPrivileges=yes" \
                "MemoryDenyWriteExecute=yes" \
                "PrivateTmp=yes" \
                "ProtectClock=yes" \
                "ProtectHome=yes" \
                "ProtectHostname=yes" \
                "ProtectSystem=strict" \
                "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK" \
                "RestrictSUIDSGID=yes" \
                "UMask=0077"
            return 0
        fi
        if is_extra_hardening_show_call "$@"; then
            print_default_extra_hardening_properties
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=Environment" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "RUST_LOG=vps_agent=info VPS_AGENT_CONFIG=${AGENT_CONFIG_PATH} PATH=${SAFE_SYSTEMD_PATH}"
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ExecStart" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "{ path=/usr/local/bin/other-agent ; argv[]=/usr/local/bin/other-agent ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
            return 0
        fi
        echo "unexpected systemctl call: $*" >&2
        return 45
    }

    if ( validate_agent_service ) >/dev/null 2>&1; then
        echo "vps-agent service with wrong ExecStart was accepted" >&2
        set_default_systemctl_active
        exit 1
    fi

    set_default_systemctl_active
}

expect_agent_service_rejects_wrong_exec_start_path_even_with_matching_argv() {
    reset_smoke_state
    systemctl() {
        if [ "$#" -eq 3 ] && [ "$1" = "is-active" ] && [ "$2" = "--quiet" ] && [ "$3" = "vps-agent.service" ]; then
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ReadWritePaths" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s %s\n' "${AGENT_CONFIG_PATH%/*}" "$DATA_DIR"
            return 0
        fi
        if [ "$#" -eq 12 ] && [ "$1" = "show" ] && [ "${12}" = "vps-agent.service" ]; then
            printf '%s\n' \
                "NoNewPrivileges=yes" \
                "MemoryDenyWriteExecute=yes" \
                "PrivateTmp=yes" \
                "ProtectClock=yes" \
                "ProtectHome=yes" \
                "ProtectHostname=yes" \
                "ProtectSystem=strict" \
                "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK" \
                "RestrictSUIDSGID=yes" \
                "UMask=0077"
            return 0
        fi
        if is_extra_hardening_show_call "$@"; then
            print_default_extra_hardening_properties
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=Environment" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "RUST_LOG=vps_agent=info VPS_AGENT_CONFIG=${AGENT_CONFIG_PATH} PATH=${SAFE_SYSTEMD_PATH}"
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ExecStart" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "{ path=/usr/local/bin/other-agent ; argv[]=${AGENT_BINARY_PATH} ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
            return 0
        fi
        echo "unexpected systemctl call: $*" >&2
        return 45
    }

    if ( validate_agent_service ) >/dev/null 2>&1; then
        echo "vps-agent service with wrong ExecStart path but matching argv was accepted" >&2
        set_default_systemctl_active
        exit 1
    fi

    set_default_systemctl_active
}

expect_agent_service_rejects_extra_exec_start_arguments() {
    reset_smoke_state
    systemctl() {
        if [ "$#" -eq 3 ] && [ "$1" = "is-active" ] && [ "$2" = "--quiet" ] && [ "$3" = "vps-agent.service" ]; then
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ReadWritePaths" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s %s\n' "${AGENT_CONFIG_PATH%/*}" "$DATA_DIR"
            return 0
        fi
        if [ "$#" -eq 12 ] && [ "$1" = "show" ] && [ "${12}" = "vps-agent.service" ]; then
            printf '%s\n' \
                "NoNewPrivileges=yes" \
                "MemoryDenyWriteExecute=yes" \
                "PrivateTmp=yes" \
                "ProtectClock=yes" \
                "ProtectHome=yes" \
                "ProtectHostname=yes" \
                "ProtectSystem=strict" \
                "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK" \
                "RestrictSUIDSGID=yes" \
                "UMask=0077"
            return 0
        fi
        if is_extra_hardening_show_call "$@"; then
            print_default_extra_hardening_properties
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=Environment" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "RUST_LOG=vps_agent=info VPS_AGENT_CONFIG=${AGENT_CONFIG_PATH} PATH=${SAFE_SYSTEMD_PATH}"
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ExecStart" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "{ path=${AGENT_BINARY_PATH} ; argv[]=${AGENT_BINARY_PATH} ; argv[]=--unsafe-extra-argument ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
            return 0
        fi
        echo "unexpected systemctl call: $*" >&2
        return 45
    }

    if ( validate_agent_service ) >/dev/null 2>&1; then
        echo "vps-agent service with extra ExecStart arguments was accepted" >&2
        set_default_systemctl_active
        exit 1
    fi

    set_default_systemctl_active
}

expect_node_ready_valid() {
    reset_smoke_state
    api() {
        case "$1:$2" in
            "GET:/api/admin/nodes") node_ready_list_json ;;
            *)
                echo "unexpected api call in node ready test: $*" >&2
                return 45
                ;;
        esac
    }

    ensure_node_ready
    restore_api
}

expect_node_ready_rejects_missing_node() {
    reset_smoke_state
    api() {
        case "$1:$2" in
            "GET:/api/admin/nodes") printf '[]' ;;
            *)
                echo "unexpected api call in missing node test: $*" >&2
                return 45
                ;;
        esac
    }

    if ( ensure_node_ready ) >/dev/null 2>&1; then
        echo "missing NODE_ID was accepted as ready" >&2
        restore_api
        exit 1
    fi
    restore_api
}

expect_node_ready_rejects_unregistered_node() {
    reset_smoke_state
    api() {
        case "$1:$2" in
            "GET:/api/admin/nodes") node_ready_list_json "$NODE_ID" "registering" "true" "null" "null" "not_checked" ;;
            *)
                echo "unexpected api call in unregistered node test: $*" >&2
                return 45
                ;;
        esac
    }

    if ( ensure_node_ready ) >/dev/null 2>&1; then
        echo "unregistered NODE_ID was accepted as ready" >&2
        restore_api
        exit 1
    fi
    restore_api
}

expect_node_ready_rejects_unschedulable_node() {
    reset_smoke_state
    api() {
        case "$1:$2" in
            "GET:/api/admin/nodes") node_ready_list_json "$NODE_ID" "online" "false" "0.1.0" "2026-05-23T00:00:00Z" "available" ;;
            *)
                echo "unexpected api call in unschedulable node test: $*" >&2
                return 45
                ;;
        esac
    }

    if ( ensure_node_ready ) >/dev/null 2>&1; then
        echo "unschedulable NODE_ID was accepted as ready" >&2
        restore_api
        exit 1
    fi
    restore_api
}

expect_node_ready_rejects_unavailable_libvirt_status() {
    reset_smoke_state
    api() {
        case "$1:$2" in
            "GET:/api/admin/nodes") node_ready_list_json "$NODE_ID" "online" "true" "0.1.0" "2026-05-23T00:00:00Z" "unavailable" ;;
            *)
                echo "unexpected api call in unavailable libvirt node test: $*" >&2
                return 45
                ;;
        esac
    }

    if ( ensure_node_ready ) >/dev/null 2>&1; then
        echo "unavailable libvirt_status was accepted as ready" >&2
        restore_api
        exit 1
    fi
    restore_api
}

expect_node_ready_rejects_stale_heartbeat() {
    reset_smoke_state
    api() {
        case "$1:$2" in
            "GET:/api/admin/nodes") node_ready_list_json "$NODE_ID" "online" "true" "0.1.0" "2000-01-01T00:00:00Z" "available" ;;
            *)
                echo "unexpected api call in stale heartbeat node test: $*" >&2
                return 45
                ;;
        esac
    }

    if ( ensure_node_ready ) >/dev/null 2>&1; then
        echo "stale node heartbeat was accepted as ready" >&2
        restore_api
        exit 1
    fi
    restore_api
}

expect_api_hides_admin_token_from_curl_args() {
    reset_smoke_state
    MASTER_URL="https://panel.example.com"
    ADMIN_TOKEN="admin-token-without-spaces"
    local config_seen=0

    curl() {
        local previous=""
        for arg in "$@"; do
            case "$arg" in
                *"$ADMIN_TOKEN"*)
                    echo "admin token leaked into curl arguments" >&2
                    return 42
                    ;;
            esac
            if [ "$previous" = "--config" ]; then
                config_seen=1
                grep -q "$ADMIN_TOKEN" "$arg" || {
                    echo "curl auth config did not contain admin token" >&2
                    return 43
                }
            fi
            previous="$arg"
        done
        [ "$config_seen" = "1" ] || {
            echo "curl auth config was not used" >&2
            return 44
        }
        printf '{}'
    }

    api GET "/api/admin/images" >/dev/null
    unset -f curl
}

expect_api_hides_admin_token_from_trace_output() {
    reset_smoke_state
    MASTER_URL="https://panel.example.com"
    ADMIN_TOKEN="admin-token-without-spaces"

    curl() {
        printf '{}'
    }

    local trace_file
    trace_file="$(mktemp)"
    if ! (
        exec 2>"$trace_file"
        set -x
        api GET "/api/admin/images" >/dev/null
    ); then
        echo "api call failed while checking trace output" >&2
        rm -f "$trace_file"
        unset -f curl
        exit 1
    fi
    unset -f curl

    local trace_output
    trace_output="$(cat "$trace_file")"
    rm -f "$trace_file"

    case "$trace_output" in
        *"$ADMIN_TOKEN"*)
            echo "admin token leaked into shell trace output" >&2
            exit 1
            ;;
    esac
}

expect_api_uses_bounded_curl_timeouts() {
    reset_smoke_state
    ADMIN_TOKEN="admin-token-without-spaces"
    CURL_TIMEOUT_SECONDS="17"
    local disables_curl_config=0
    local connect_timeout_seen=0
    local max_time_seen=0
    local proto_seen=0

    curl() {
        local previous=""
        if [ "${1:-}" = "-q" ]; then
            disables_curl_config=1
        fi
        for arg in "$@"; do
            if [ "$previous" = "--connect-timeout" ] && [ "$arg" = "$CURL_TIMEOUT_SECONDS" ]; then
                connect_timeout_seen=1
            fi
            if [ "$previous" = "--max-time" ] && [ "$arg" = "$CURL_TIMEOUT_SECONDS" ]; then
                max_time_seen=1
            fi
            if [ "$previous" = "--proto" ] && [ "$arg" = "=https" ]; then
                proto_seen=1
            fi
            previous="$arg"
        done
        printf '{}'
    }

    api GET "/api/admin/images" >/dev/null
    unset -f curl

    if [ "$disables_curl_config" != "1" ]; then
        echo "admin API curl call did not pass -q before other arguments" >&2
        exit 1
    fi
    if [ "$connect_timeout_seen:$max_time_seen" != "1:1" ]; then
        echo "admin API curl call did not include bounded timeout arguments" >&2
        exit 1
    fi
    if [ "$proto_seen" != "1" ]; then
        echo "admin API curl call did not restrict protocols to HTTPS" >&2
        exit 1
    fi
}

expect_api_keeps_https_proto_when_allow_http_flag_is_set_for_https_url() {
    reset_smoke_state
    ADMIN_TOKEN="admin-token-without-spaces"
    MASTER_URL="https://panel.example.com"
    ALLOW_HTTP="1"
    local proto_arg=""

    curl() {
        local previous=""
        for arg in "$@"; do
            if [ "$previous" = "--proto" ]; then
                proto_arg="$arg"
            fi
            previous="$arg"
        done
        printf '{}'
    }

    api GET "/api/admin/images" >/dev/null
    unset -f curl

    if [ "$proto_arg" != "=https" ]; then
        echo "admin API curl call broadened protocol allow-list for an HTTPS master URL: $proto_arg" >&2
        exit 1
    fi
}

expect_api_uses_configured_ca_certificate() {
    reset_smoke_state
    make_ca_cert_path
    local cacert_seen=0

    curl() {
        local previous=""
        for arg in "$@"; do
            if [ "$previous" = "--cacert" ] && [ "$arg" = "$MASTER_CA_CERT_PATH" ]; then
                cacert_seen=1
            fi
            previous="$arg"
        done
        printf '{}'
    }

    api GET "/api/admin/images" >/dev/null
    unset -f curl

    if [ "$cacert_seen" != "1" ]; then
        echo "admin API curl call did not use configured CA certificate" >&2
        cleanup_ca_cert_path
        exit 1
    fi
    cleanup_ca_cert_path
}

expect_api_keeps_ca_certificate_path_as_single_argument() {
    reset_smoke_state
    CA_TMP_DIR="$(mktemp -d)"
    MASTER_CA_CERT_PATH="${CA_TMP_DIR}/master-*.pem"
    local extra_match="${CA_TMP_DIR}/master-extra.pem"
    printf '%s\n' 'literal star cert' > "$MASTER_CA_CERT_PATH"
    printf '%s\n' 'extra cert' > "$extra_match"
    chmod 0640 "$MASTER_CA_CERT_PATH" "$extra_match"
    local exact_cacert_seen=0
    local extra_match_seen=0

    curl() {
        local previous=""
        for arg in "$@"; do
            if [ "$previous" = "--cacert" ] && [ "$arg" = "$MASTER_CA_CERT_PATH" ]; then
                exact_cacert_seen=1
            fi
            if [ "$arg" = "$extra_match" ]; then
                extra_match_seen=1
            fi
            previous="$arg"
        done
        printf '{}'
    }

    api GET "/api/admin/images" >/dev/null
    unset -f curl
    cleanup_ca_cert_path

    if [ "$exact_cacert_seen:$extra_match_seen" != "1:0" ]; then
        echo "admin API curl call did not keep configured CA certificate as one argument" >&2
        exit 1
    fi
}

expect_cleanup_failure_reports_manual_state() {
    reset_smoke_state
    local vm_id="11111111-2222-3333-4444-555555555555"
    local delete_task_id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    api() {
        case "$2" in
            /api/admin/tasks/delete-vm)
                printf '{"id":"%s","kind":{"vm_id":"%s"}}' "$delete_task_id" "$vm_id"
                ;;
            *)
                echo "unexpected api call: $*" >&2
                return 45
                ;;
        esac
    }
    wait_for_task() {
        echo "simulated delete failure" >&2
        return 46
    }
    verify_deleted_vm_on_host() {
        echo "delete verification should not run after failed task" >&2
        return 47
    }

    local output
    if output="$(cleanup_created_vm "$vm_id" 2>&1 >/dev/null)"; then
        echo "expected cleanup_created_vm to fail" >&2
        unset -f api wait_for_task verify_deleted_vm_on_host
        exit 1
    fi
    unset -f api wait_for_task verify_deleted_vm_on_host

    case "$output" in
        *"$ADMIN_TOKEN"*)
            echo "cleanup failure output leaked admin token" >&2
            exit 1
            ;;
    esac
    case "$output" in
        *"delete_task_id=${delete_task_id}"*\
*"domain=vps-${vm_id}"*\
*"managed_dir=${DATA_DIR}/vms/${vm_id}"*)
            ;;
        *)
            echo "cleanup failure output did not include manual state summary" >&2
            printf '%s\n' "$output" >&2
            exit 1
            ;;
    esac
}

expect_cleanup_rejects_invalid_delete_task_id_before_polling() {
    reset_smoke_state
    local vm_id="11111111-2222-3333-4444-555555555555"
    local marker
    marker="$(mktemp)"

    api() {
        case "$2" in
            /api/admin/tasks/delete-vm)
                echo "delete-task" >> "$marker"
                printf '{"id":"../../delete"}'
                ;;
            *)
                echo "unexpected api call: $*" >&2
                return 45
                ;;
        esac
    }
    wait_for_task() {
        echo "wait:$1" >> "$marker"
    }
    verify_deleted_vm_on_host() {
        echo "verify-deleted:$1" >> "$marker"
    }

    local output
    if output="$(cleanup_created_vm "$vm_id" 2>&1 >/dev/null)"; then
        echo "cleanup accepted an invalid delete response task id" >&2
        cat "$marker" >&2
        rm -f "$marker"
        unset -f api wait_for_task verify_deleted_vm_on_host
        exit 1
    fi

    unset -f api wait_for_task verify_deleted_vm_on_host

    case "$output" in
        *"delete response task id must be a UUID"*) ;;
        *)
            echo "invalid delete task id failure did not explain the rejected response field" >&2
            printf '%s\n' "$output" >&2
            cat "$marker" >&2
            rm -f "$marker"
            exit 1
            ;;
    esac
    case "$output" in
        *"delete_task_id=unavailable"*\
*"domain=vps-${vm_id}"*\
*"managed_dir=${DATA_DIR}/vms/${vm_id}"*)
            ;;
        *)
            echo "invalid delete task id failure did not include manual state summary" >&2
            printf '%s\n' "$output" >&2
            cat "$marker" >&2
            rm -f "$marker"
            exit 1
            ;;
    esac

    if grep -Eq '^(wait|verify)' "$marker"; then
        echo "invalid delete response task id reached polling or host verification" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    rm -f "$marker"
}

expect_cleanup_rejects_malformed_delete_response_without_parser_details() {
    reset_smoke_state
    local vm_id="11111111-2222-3333-4444-555555555555"
    local marker
    marker="$(mktemp)"

    api() {
        case "$2" in
            /api/admin/tasks/delete-vm)
                echo "delete-task" >> "$marker"
                printf '{not-json "token=should-not-print"}'
                ;;
            *)
                echo "unexpected api call: $*" >&2
                return 45
                ;;
        esac
    }
    wait_for_task() {
        echo "wait:$1" >> "$marker"
    }
    verify_deleted_vm_on_host() {
        echo "verify-deleted:$1" >> "$marker"
    }

    local output
    if output="$(cleanup_created_vm "$vm_id" 2>&1 >/dev/null)"; then
        echo "cleanup accepted a malformed delete response" >&2
        cat "$marker" >&2
        rm -f "$marker"
        unset -f api wait_for_task verify_deleted_vm_on_host
        exit 1
    fi

    unset -f api wait_for_task verify_deleted_vm_on_host

    case "$output" in
        *"delete response task id must be a UUID"*) ;;
        *)
            echo "malformed delete response failure did not explain the rejected response field" >&2
            printf '%s\n' "$output" >&2
            cat "$marker" >&2
            rm -f "$marker"
            exit 1
            ;;
    esac
    case "$output" in
        *"Traceback"*|*"JSONDecodeError"*|*"should-not-print"*)
            echo "malformed delete response leaked parser details or raw response content" >&2
            printf '%s\n' "$output" >&2
            cat "$marker" >&2
            rm -f "$marker"
            exit 1
            ;;
    esac
    case "$output" in
        *"delete_task_id=unavailable"*\
*"domain=vps-${vm_id}"*\
*"managed_dir=${DATA_DIR}/vms/${vm_id}"*)
            ;;
        *)
            echo "malformed delete response failure did not include manual state summary" >&2
            printf '%s\n' "$output" >&2
            cat "$marker" >&2
            rm -f "$marker"
            exit 1
            ;;
    esac

    if grep -Eq '^(wait|verify)' "$marker"; then
        echo "malformed delete response reached polling or host verification" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    rm -f "$marker"
}

expect_wait_for_task_rejects_invalid_task_id_before_api_call() {
    reset_smoke_state
    source <(sed '/^main "\$@"/d' "$repo_root/scripts/kvm-host-smoke.sh")
    local marker
    marker="$(mktemp)"

    api() {
        echo "api:$*" >> "$marker"
        printf '{"status":"succeeded"}'
    }

    local output
    if output="$(wait_for_task "../../tasks" 2>&1 >/dev/null)"; then
        echo "wait_for_task accepted an invalid task id" >&2
        cat "$marker" >&2
        rm -f "$marker"
        unset -f api
        exit 1
    fi
    unset -f api

    case "$output" in
        *"task id must be a UUID"*) ;;
        *)
            echo "invalid task id failure did not explain the rejected field" >&2
            printf '%s\n' "$output" >&2
            cat "$marker" >&2
            rm -f "$marker"
            exit 1
            ;;
    esac

    if [ -s "$marker" ]; then
        echo "invalid task id reached the task polling API" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    rm -f "$marker"
}

expect_wait_for_task_rejects_unknown_status_without_polling_until_timeout() {
    reset_smoke_state
    source <(sed '/^main "\$@"/d' "$repo_root/scripts/kvm-host-smoke.sh")
    TIMEOUT_SECONDS="1"
    POLL_SECONDS="1"
    local task_id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    local marker
    marker="$(mktemp)"

    api() {
        echo "api:$*" >> "$marker"
        printf '{"id":"%s","status":"mystery"}' "$task_id"
    }
    sleep() {
        echo "sleep:$1" >> "$marker"
        command sleep "$1"
    }

    local output
    if output="$(wait_for_task "$task_id" 2>&1 >/dev/null)"; then
        echo "wait_for_task accepted an unknown task status" >&2
        cat "$marker" >&2
        rm -f "$marker"
        unset -f api sleep
        exit 1
    fi
    unset -f api sleep

    case "$output" in
        *"returned unexpected task status"*) ;;
        *)
            echo "unknown task status failure did not explain the response problem" >&2
            printf '%s\n' "$output" >&2
            cat "$marker" >&2
            rm -f "$marker"
            exit 1
            ;;
    esac

    if grep -q '^sleep:' "$marker"; then
        echo "unknown task status reached the polling sleep path" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    rm -f "$marker"
}

expect_wait_for_task_rejects_mismatched_response_id_before_accepting_status() {
    reset_smoke_state
    source <(sed '/^main "\$@"/d' "$repo_root/scripts/kvm-host-smoke.sh")
    TIMEOUT_SECONDS="1"
    POLL_SECONDS="1"
    local task_id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    local other_task_id="bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee"
    local marker
    marker="$(mktemp)"

    api() {
        echo "api:$*" >> "$marker"
        printf '{"id":"%s","status":"succeeded"}' "$other_task_id"
    }
    sleep() {
        echo "sleep:$1" >> "$marker"
        command sleep "$1"
    }

    local output
    if output="$(wait_for_task "$task_id" 2>&1 >/dev/null)"; then
        echo "wait_for_task accepted a response for a different task id" >&2
        cat "$marker" >&2
        rm -f "$marker"
        unset -f api sleep
        exit 1
    fi
    unset -f api sleep

    case "$output" in
        *"task polling response id did not match requested task"*) ;;
        *)
            echo "mismatched task id failure did not explain the response problem" >&2
            printf '%s\n' "$output" >&2
            cat "$marker" >&2
            rm -f "$marker"
            exit 1
            ;;
    esac

    if grep -q '^sleep:' "$marker"; then
        echo "mismatched task id reached the polling sleep path" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    rm -f "$marker"
}

expect_wait_for_task_rejects_missing_status_without_polling_until_timeout() {
    reset_smoke_state
    source <(sed '/^main "\$@"/d' "$repo_root/scripts/kvm-host-smoke.sh")
    TIMEOUT_SECONDS="1"
    POLL_SECONDS="1"
    local task_id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    local marker
    marker="$(mktemp)"

    api() {
        echo "api:$*" >> "$marker"
        printf '{"id":"%s"}' "$task_id"
    }
    sleep() {
        echo "sleep:$1" >> "$marker"
        command sleep "$1"
    }

    local output
    if output="$(wait_for_task "$task_id" 2>&1 >/dev/null)"; then
        echo "wait_for_task accepted a response without status" >&2
        cat "$marker" >&2
        rm -f "$marker"
        unset -f api sleep
        exit 1
    fi
    unset -f api sleep

    case "$output" in
        *"task polling response did not include a status"*) ;;
        *)
            echo "missing status failure did not explain the response problem" >&2
            printf '%s\n' "$output" >&2
            cat "$marker" >&2
            rm -f "$marker"
            exit 1
            ;;
    esac

    if grep -q '^sleep:' "$marker"; then
        echo "missing task status reached the polling sleep path" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    rm -f "$marker"
}

expect_wait_for_task_redacts_and_bounds_failed_task_logs() {
    reset_smoke_state
    source <(sed '/^main "\$@"/d' "$repo_root/scripts/kvm-host-smoke.sh")
    TIMEOUT_SECONDS="1"
    POLL_SECONDS="1"
    ADMIN_TOKEN="admin-token-without-spaces"
    local task_id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    api() {
        case "$1:$2" in
            "GET:/api/admin/tasks/${task_id}")
                printf '{"id":"%s","status":"failed"}' "$task_id"
                ;;
            "GET:/api/admin/tasks/${task_id}/logs")
                python3 - <<'PY'
import json

message = "\n".join([
    "token=bootstrap-secret",
    "credential=ag_long_term_secret",
    "Authorization: Bearer admin-token-without-spaces",
    "X-Agent-Credential: ag_header_secret",
    "postgres://vps:dbpass@postgres/vps",
    "-----BEGIN OPENSSH PRIVATE KEY-----",
    "private-key-body",
    "-----END OPENSSH PRIVATE KEY-----",
    "filler=" + ("x" * 9000),
])
print(json.dumps([{"message": message}]))
PY
                ;;
            *)
                echo "unexpected api call while checking failed task log redaction: $*" >&2
                return 45
                ;;
        esac
    }

    local output
    if output="$(wait_for_task "$task_id" 2>&1 >/dev/null)"; then
        echo "wait_for_task accepted a failed task" >&2
        unset -f api
        exit 1
    fi
    unset -f api

    case "$output" in
        *bootstrap-secret*|*ag_long_term_secret*|*admin-token-without-spaces*|*ag_header_secret*|*dbpass*|*"BEGIN OPENSSH PRIVATE KEY"*)
            echo "failed task log diagnostics leaked secret-shaped content" >&2
            printf '%s\n' "$output" >&2
            exit 1
            ;;
    esac
    case "$output" in
        *"[REDACTED]"*) ;;
        *)
            echo "failed task log diagnostics did not show redaction markers" >&2
            printf '%s\n' "$output" >&2
            exit 1
            ;;
    esac
    case "$output" in
        *"truncated"*) ;;
        *)
            echo "failed task log diagnostics were not bounded" >&2
            printf '%s\n' "$output" >&2
            exit 1
            ;;
    esac
}

expect_poll_sleep_caps_to_remaining_timeout() {
    reset_smoke_state

    if [ "$(poll_sleep_seconds 7 10)" != "7" ]; then
        echo "poll sleep changed when full poll interval fits inside timeout" >&2
        exit 1
    fi
    if [ "$(poll_sleep_seconds 7 3)" != "3" ]; then
        echo "poll sleep did not cap to remaining timeout" >&2
        exit 1
    fi
    if [ "$(poll_sleep_seconds 7 7)" != "7" ]; then
        echo "poll sleep changed when remaining timeout equals poll interval" >&2
        exit 1
    fi
}

expect_created_vm_verification_hides_failed_dominfo_output() {
    reset_smoke_state
    local vm_id="11111111-2222-3333-4444-555555555555"

    virsh() {
        [ "$1" = "--connect" ] || return 49
        [ "$2" = "qemu:///system" ] || return 50
        [ "$3" = "dominfo" ] || return 51
        [ "$4" = "vps-${vm_id}" ] || return 52
        printf '%s\n' "credential=domain_secret_should_not_leak" >&2
        return 47
    }

    local output
    if output="$(verify_created_vm_on_host "$vm_id" 2>&1)"; then
        echo "created VM verification accepted failed dominfo" >&2
        unset -f virsh
        exit 1
    fi

    case "$output" in
        *domain_secret_should_not_leak*)
            echo "created VM verification leaked failed dominfo output" >&2
            printf '%s\n' "$output" >&2
            unset -f virsh
            exit 1
            ;;
    esac

    case "$output" in
        *"libvirt domain vps-${vm_id} is unavailable"*) ;;
        *)
            echo "created VM verification did not return a safe dominfo failure message" >&2
            printf '%s\n' "$output" >&2
            unset -f virsh
            exit 1
            ;;
    esac

    unset -f virsh
}

expect_created_vm_verification_hides_failed_domstate_output() {
    reset_smoke_state
    local vm_id="11111111-2222-3333-4444-555555555555"

    virsh() {
        [ "$1" = "--connect" ] || return 49
        [ "$2" = "qemu:///system" ] || return 50
        case "$3" in
            dominfo)
                [ "$4" = "vps-${vm_id}" ] || return 51
                ;;
            domstate)
                [ "$4" = "vps-${vm_id}" ] || return 52
                printf '%s\n' "password=state_secret_should_not_leak" >&2
                return 47
                ;;
            *)
                return 53
                ;;
        esac
    }

    local output
    if output="$(verify_created_vm_on_host "$vm_id" 2>&1)"; then
        echo "created VM verification accepted failed domstate" >&2
        unset -f virsh
        exit 1
    fi

    case "$output" in
        *state_secret_should_not_leak*)
            echo "created VM verification leaked failed domstate output" >&2
            printf '%s\n' "$output" >&2
            unset -f virsh
            exit 1
            ;;
    esac

    case "$output" in
        *"unable to read libvirt domain state for vps-${vm_id}"*) ;;
        *)
            echo "created VM verification did not return a safe domstate failure message" >&2
            printf '%s\n' "$output" >&2
            unset -f virsh
            exit 1
            ;;
    esac

    unset -f virsh
}

expect_deleted_vm_verification_hides_ambiguous_dominfo_output() {
    reset_smoke_state
    local vm_id="11111111-2222-3333-4444-555555555555"
    HOST_TMP_DIR="$(mktemp -d)"
    DATA_DIR="${HOST_TMP_DIR}/data"
    mkdir -p "${DATA_DIR}/vms"

    virsh() {
        [ "$1" = "--connect" ] || return 49
        [ "$2" = "qemu:///system" ] || return 50
        [ "$3" = "dominfo" ] || return 51
        [ "$4" = "vps-${vm_id}" ] || return 52
        printf '%s\n' "bootstrap_token=deleted_dominfo_should_not_leak" >&2
        printf '%s\n' "password=deleted_dominfo_password_should_not_leak" >&2
        return 53
    }

    local output
    if output="$(verify_deleted_vm_on_host "$vm_id" 2>&1)"; then
        echo "deleted VM verification accepted ambiguous dominfo failure" >&2
        cleanup_host_paths
        unset -f virsh
        exit 1
    fi

    case "$output" in
        *deleted_dominfo_should_not_leak*|*deleted_dominfo_password_should_not_leak*)
            echo "deleted VM verification leaked failed dominfo output" >&2
            printf '%s\n' "$output" >&2
            cleanup_host_paths
            unset -f virsh
            exit 1
            ;;
    esac

    case "$output" in
        *"unable to confirm libvirt domain vps-${vm_id} is absent"*) ;;
        *)
            echo "deleted VM verification did not return a safe ambiguous-dominfo failure message" >&2
            printf '%s\n' "$output" >&2
            cleanup_host_paths
            unset -f virsh
            exit 1
            ;;
    esac

    cleanup_host_paths
    unset -f virsh
}

expect_created_vm_verification_rejects_symlink_artifacts() {
    reset_smoke_state
    local vm_id="11111111-2222-3333-4444-555555555555"
    local vm_dir="${DATA_DIR}/vms/${vm_id}"
    local real_disk
    real_disk="$(mktemp)"
    HOST_TMP_DIR="$(mktemp -d)"
    DATA_DIR="${HOST_TMP_DIR}/data"
    vm_dir="${DATA_DIR}/vms/${vm_id}"
    mkdir -p "$vm_dir"
    printf 'disk' > "$real_disk"
    ln -s "$real_disk" "${vm_dir}/disk.qcow2"
    printf 'seed' > "${vm_dir}/seed.iso"
    printf '<domain />' > "${vm_dir}/domain.xml"

    virsh() {
        [ "$1" = "--connect" ] || return 49
        [ "$2" = "qemu:///system" ] || return 50
        case "$3" in
            dominfo)
                [ "$4" = "vps-${vm_id}" ] || return 51
                ;;
            domstate)
                [ "$4" = "vps-${vm_id}" ] || return 52
                printf 'running\n'
                ;;
            *)
                return 53
                ;;
        esac
    }

    if ( verify_created_vm_on_host "$vm_id" ) >/dev/null 2>&1; then
        echo "created VM verification accepted a symlinked managed disk" >&2
        rm -f "$real_disk"
        cleanup_host_paths
        unset -f virsh
        exit 1
    fi

    rm -f "$real_disk"
    cleanup_host_paths
    unset -f virsh
}

expect_created_vm_verification_rejects_mismatched_domain_metadata() {
    reset_smoke_state
    local vm_id="11111111-2222-3333-4444-555555555555"
    local other_vm_id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    local stderr_path
    local vm_dir
    HOST_TMP_DIR="$(mktemp -d)"
    stderr_path="$(mktemp)"
    DATA_DIR="${HOST_TMP_DIR}/data"
    vm_dir="${DATA_DIR}/vms/${vm_id}"
    mkdir -p "$vm_dir"
    printf 'disk' > "${vm_dir}/disk.qcow2"
    printf 'seed' > "${vm_dir}/seed.iso"
    printf '#cloud-config\nssh_pwauth: false\ndisable_root: true\n' > "${vm_dir}/user-data"
    printf 'instance-id: %s\nlocal-hostname: %s\n' "$vm_id" "$VM_NAME" > "${vm_dir}/meta-data"
    cat > "${vm_dir}/domain.xml" <<EOF
<domain>
  <name>vps-${other_vm_id}</name>
  <uuid>${other_vm_id}</uuid>
  <devices>
    <disk type="file" device="disk"><source file="${vm_dir}/disk.qcow2"/></disk>
    <disk type="file" device="cdrom"><source file="${vm_dir}/seed.iso"/></disk>
  </devices>
</domain>
EOF

    virsh() {
        [ "$1" = "--connect" ] || return 49
        [ "$2" = "qemu:///system" ] || return 50
        case "$3" in
            dominfo)
                [ "$4" = "vps-${vm_id}" ] || return 51
                ;;
            domstate)
                [ "$4" = "vps-${vm_id}" ] || return 52
                printf 'running\n'
                ;;
            *)
                return 53
            ;;
        esac
    }
    qemu-img() {
        [ "$1" = "info" ] || return 54
        [ "$2" = "--output=json" ] || return 55
        [ "$3" = "${vm_dir}/disk.qcow2" ] || return 56
        printf '{"format":"qcow2"}'
    }

    if ( verify_created_vm_on_host "$vm_id" ) >/dev/null 2>"$stderr_path"; then
        echo "created VM verification accepted mismatched domain metadata" >&2
        rm -f "$stderr_path"
        cleanup_host_paths
        unset -f virsh qemu-img
        exit 1
    fi
    if ! grep -F "managed VM domain XML name mismatch" "$stderr_path" >/dev/null; then
        echo "created VM verification rejected mismatched domain metadata for the wrong reason" >&2
        cat "$stderr_path" >&2
        rm -f "$stderr_path"
        cleanup_host_paths
        unset -f virsh qemu-img
        exit 1
    fi

    rm -f "$stderr_path"
    cleanup_host_paths
    unset -f virsh qemu-img
}

expect_created_vm_verification_rejects_non_qcow2_managed_disk() {
    reset_smoke_state
    local vm_id="11111111-2222-3333-4444-555555555555"
    local vm_dir
    HOST_TMP_DIR="$(mktemp -d)"
    DATA_DIR="${HOST_TMP_DIR}/data"
    vm_dir="${DATA_DIR}/vms/${vm_id}"
    mkdir -p "$vm_dir"
    printf 'disk' > "${vm_dir}/disk.qcow2"
    printf 'seed' > "${vm_dir}/seed.iso"
    printf '#cloud-config\nssh_pwauth: false\ndisable_root: true\n' > "${vm_dir}/user-data"
    printf 'instance-id: %s\nlocal-hostname: %s\n' "$vm_id" "$VM_NAME" > "${vm_dir}/meta-data"
    cat > "${vm_dir}/domain.xml" <<EOF
<domain>
  <name>vps-${vm_id}</name>
  <uuid>${vm_id}</uuid>
  <devices>
    <disk type="file" device="disk"><source file="${vm_dir}/disk.qcow2"/></disk>
    <disk type="file" device="cdrom"><source file="${vm_dir}/seed.iso"/></disk>
  </devices>
</domain>
EOF

    virsh() {
        [ "$1" = "--connect" ] || return 49
        [ "$2" = "qemu:///system" ] || return 50
        case "$3" in
            dominfo)
                [ "$4" = "vps-${vm_id}" ] || return 51
                ;;
            domstate)
                [ "$4" = "vps-${vm_id}" ] || return 52
                printf 'running\n'
                ;;
            *)
                return 53
                ;;
        esac
    }
    qemu-img() {
        [ "$1" = "info" ] || return 54
        [ "$2" = "--output=json" ] || return 55
        [ "$3" = "${vm_dir}/disk.qcow2" ] || return 56
        printf '{"format":"raw"}'
    }

    if ( verify_created_vm_on_host "$vm_id" ) >/dev/null 2>&1; then
        echo "created VM verification accepted a non-qcow2 managed disk" >&2
        cleanup_host_paths
        unset -f virsh qemu-img
        exit 1
    fi

    cleanup_host_paths
    unset -f virsh qemu-img
}

expect_managed_disk_format_verification_accepts_qcow2_json() {
    reset_smoke_state
    local disk_path
    disk_path="$(mktemp)"
    printf 'disk' > "$disk_path"

    qemu-img() {
        [ "$1" = "info" ] || return 54
        [ "$2" = "--output=json" ] || return 55
        [ "$3" = "$disk_path" ] || return 56
        printf '{"format":"qcow2"}'
    }

    if ! require_qcow2_image "$disk_path" "managed VM disk"; then
        echo "managed disk format verification rejected qcow2 qemu-img JSON" >&2
        rm -f "$disk_path"
        unset -f qemu-img
        exit 1
    fi

    rm -f "$disk_path"
    unset -f qemu-img
}

expect_created_vm_verification_requires_cloud_init_artifacts() {
    reset_smoke_state
    local vm_id="11111111-2222-3333-4444-555555555555"
    local vm_dir
    HOST_TMP_DIR="$(mktemp -d)"
    DATA_DIR="${HOST_TMP_DIR}/data"
    vm_dir="${DATA_DIR}/vms/${vm_id}"
    mkdir -p "$vm_dir"
    printf 'disk' > "${vm_dir}/disk.qcow2"
    printf 'seed' > "${vm_dir}/seed.iso"
    cat > "${vm_dir}/domain.xml" <<EOF
<domain>
  <name>vps-${vm_id}</name>
  <uuid>${vm_id}</uuid>
  <devices>
    <disk type="file" device="disk"><source file="${vm_dir}/disk.qcow2"/></disk>
    <disk type="file" device="cdrom"><source file="${vm_dir}/seed.iso"/></disk>
  </devices>
</domain>
EOF

    virsh() {
        [ "$1" = "--connect" ] || return 49
        [ "$2" = "qemu:///system" ] || return 50
        case "$3" in
            dominfo)
                [ "$4" = "vps-${vm_id}" ] || return 51
                ;;
            domstate)
                [ "$4" = "vps-${vm_id}" ] || return 52
                printf 'running\n'
                ;;
            *)
                return 53
                ;;
        esac
    }
    qemu-img() {
        [ "$1" = "info" ] || return 54
        [ "$2" = "--output=json" ] || return 55
        [ "$3" = "${vm_dir}/disk.qcow2" ] || return 56
        printf '{"format":"qcow2"}'
    }

    if ( verify_created_vm_on_host "$vm_id" ) >/dev/null 2>&1; then
        echo "created VM verification accepted missing cloud-init artifacts" >&2
        cleanup_host_paths
        unset -f virsh qemu-img
        exit 1
    fi

    cleanup_host_paths
    unset -f virsh qemu-img
}

expect_created_vm_verification_rejects_stale_cloud_init_metadata() {
    reset_smoke_state
    local vm_id="11111111-2222-3333-4444-555555555555"
    local other_vm_id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    local vm_dir
    HOST_TMP_DIR="$(mktemp -d)"
    DATA_DIR="${HOST_TMP_DIR}/data"
    vm_dir="${DATA_DIR}/vms/${vm_id}"
    mkdir -p "$vm_dir"
    printf 'disk' > "${vm_dir}/disk.qcow2"
    printf 'seed' > "${vm_dir}/seed.iso"
    printf '#cloud-config\nssh_pwauth: false\ndisable_root: true\n' > "${vm_dir}/user-data"
    printf 'instance-id: %s\nlocal-hostname: wrong-host\n' "$other_vm_id" > "${vm_dir}/meta-data"
    cat > "${vm_dir}/domain.xml" <<EOF
<domain>
  <name>vps-${vm_id}</name>
  <uuid>${vm_id}</uuid>
  <devices>
    <disk type="file" device="disk"><source file="${vm_dir}/disk.qcow2"/></disk>
    <disk type="file" device="cdrom"><source file="${vm_dir}/seed.iso"/></disk>
  </devices>
</domain>
EOF

    virsh() {
        [ "$1" = "--connect" ] || return 49
        [ "$2" = "qemu:///system" ] || return 50
        case "$3" in
            dominfo)
                [ "$4" = "vps-${vm_id}" ] || return 51
                ;;
            domstate)
                [ "$4" = "vps-${vm_id}" ] || return 52
                printf 'running\n'
                ;;
            *)
                return 53
                ;;
        esac
    }
    qemu-img() {
        [ "$1" = "info" ] || return 54
        [ "$2" = "--output=json" ] || return 55
        [ "$3" = "${vm_dir}/disk.qcow2" ] || return 56
        printf '{"format":"qcow2"}'
    }

    if ( verify_created_vm_on_host "$vm_id" ) >/dev/null 2>&1; then
        echo "created VM verification accepted stale cloud-init metadata" >&2
        cleanup_host_paths
        unset -f virsh qemu-img
        exit 1
    fi

    cleanup_host_paths
    unset -f virsh qemu-img
}

expect_created_vm_verification_rejects_swapped_domain_disk_devices() {
    reset_smoke_state
    local vm_id="11111111-2222-3333-4444-555555555555"
    local stderr_path
    local vm_dir
    HOST_TMP_DIR="$(mktemp -d)"
    stderr_path="$(mktemp)"
    DATA_DIR="${HOST_TMP_DIR}/data"
    vm_dir="${DATA_DIR}/vms/${vm_id}"
    mkdir -p "$vm_dir"
    printf 'disk' > "${vm_dir}/disk.qcow2"
    printf 'seed' > "${vm_dir}/seed.iso"
    printf '#cloud-config\nssh_pwauth: false\ndisable_root: true\n' > "${vm_dir}/user-data"
    printf 'instance-id: %s\nlocal-hostname: %s\n' "$vm_id" "$VM_NAME" > "${vm_dir}/meta-data"
    cat > "${vm_dir}/domain.xml" <<EOF
<domain>
  <name>vps-${vm_id}</name>
  <uuid>${vm_id}</uuid>
  <devices>
    <disk type="file" device="disk"><source file="${vm_dir}/seed.iso"/></disk>
    <disk type="file" device="cdrom"><source file="${vm_dir}/disk.qcow2"/></disk>
  </devices>
</domain>
EOF

    virsh() {
        [ "$1" = "--connect" ] || return 49
        [ "$2" = "qemu:///system" ] || return 50
        case "$3" in
            dominfo)
                [ "$4" = "vps-${vm_id}" ] || return 51
                ;;
            domstate)
                [ "$4" = "vps-${vm_id}" ] || return 52
                printf 'running\n'
                ;;
            *)
                return 53
            ;;
        esac
    }
    qemu-img() {
        [ "$1" = "info" ] || return 54
        [ "$2" = "--output=json" ] || return 55
        [ "$3" = "${vm_dir}/disk.qcow2" ] || return 56
        printf '{"format":"qcow2"}'
    }

    if ( verify_created_vm_on_host "$vm_id" ) >/dev/null 2>"$stderr_path"; then
        echo "created VM verification accepted swapped domain disk devices" >&2
        rm -f "$stderr_path"
        cleanup_host_paths
        unset -f virsh qemu-img
        exit 1
    fi
    if ! grep -F "managed VM domain XML disk device does not reference the managed disk" "$stderr_path" >/dev/null; then
        echo "created VM verification rejected swapped domain disk devices for the wrong reason" >&2
        cat "$stderr_path" >&2
        rm -f "$stderr_path"
        cleanup_host_paths
        unset -f virsh qemu-img
        exit 1
    fi

    rm -f "$stderr_path"
    cleanup_host_paths
    unset -f virsh qemu-img
}

expect_created_vm_verification_rejects_oversized_domain_metadata() {
    reset_smoke_state
    local vm_id="11111111-2222-3333-4444-555555555555"
    local stderr_path
    local vm_dir
    HOST_TMP_DIR="$(mktemp -d)"
    stderr_path="$(mktemp)"
    DATA_DIR="${HOST_TMP_DIR}/data"
    vm_dir="${DATA_DIR}/vms/${vm_id}"
    mkdir -p "$vm_dir"
    printf 'disk' > "${vm_dir}/disk.qcow2"
    printf 'seed' > "${vm_dir}/seed.iso"
    printf '#cloud-config\nssh_pwauth: false\ndisable_root: true\n' > "${vm_dir}/user-data"
    printf 'instance-id: %s\nlocal-hostname: %s\n' "$vm_id" "$VM_NAME" > "${vm_dir}/meta-data"
    {
        printf '<domain><name>vps-%s</name><uuid>%s</uuid><metadata>' "$vm_id" "$vm_id"
        python3 - <<'PY'
print("x" * (1024 * 1024 + 1), end="")
PY
        printf '</metadata><devices>'
        printf '<disk type="file" device="disk"><source file="%s"/></disk>' "${vm_dir}/disk.qcow2"
        printf '<disk type="file" device="cdrom"><source file="%s"/></disk>' "${vm_dir}/seed.iso"
        printf '</devices></domain>'
    } > "${vm_dir}/domain.xml"

    virsh() {
        [ "$1" = "--connect" ] || return 49
        [ "$2" = "qemu:///system" ] || return 50
        case "$3" in
            dominfo)
                [ "$4" = "vps-${vm_id}" ] || return 51
                ;;
            domstate)
                [ "$4" = "vps-${vm_id}" ] || return 52
                printf 'running\n'
                ;;
            *)
                return 53
            ;;
        esac
    }
    qemu-img() {
        [ "$1" = "info" ] || return 54
        [ "$2" = "--output=json" ] || return 55
        [ "$3" = "${vm_dir}/disk.qcow2" ] || return 56
        printf '{"format":"qcow2"}'
    }

    if ( verify_created_vm_on_host "$vm_id" ) >/dev/null 2>"$stderr_path"; then
        echo "created VM verification accepted oversized domain metadata" >&2
        rm -f "$stderr_path"
        cleanup_host_paths
        unset -f virsh qemu-img
        exit 1
    fi
    if ! grep -F "managed VM domain XML metadata is too large" "$stderr_path" >/dev/null; then
        echo "created VM verification rejected oversized domain metadata for the wrong reason" >&2
        cat "$stderr_path" >&2
        rm -f "$stderr_path"
        cleanup_host_paths
        unset -f virsh qemu-img
        exit 1
    fi

    rm -f "$stderr_path"
    cleanup_host_paths
    unset -f virsh qemu-img
}

expect_created_vm_verification_requires_network_config_for_ipam_metadata() {
    reset_smoke_state
    local vm_id="11111111-2222-3333-4444-555555555555"
    local vm_dir
    HOST_TMP_DIR="$(mktemp -d)"
    DATA_DIR="${HOST_TMP_DIR}/data"
    vm_dir="${DATA_DIR}/vms/${vm_id}"
    mkdir -p "$vm_dir"
    printf 'disk' > "${vm_dir}/disk.qcow2"
    printf 'seed' > "${vm_dir}/seed.iso"
    cat > "${vm_dir}/domain.xml" <<EOF
<domain>
  <name>vps-${vm_id}</name>
  <uuid>${vm_id}</uuid>
  <devices>
    <disk type="file" device="disk"><source file="${vm_dir}/disk.qcow2"/></disk>
    <disk type="file" device="cdrom"><source file="${vm_dir}/seed.iso"/></disk>
  </devices>
</domain>
EOF

    virsh() {
        [ "$1" = "--connect" ] || return 49
        [ "$2" = "qemu:///system" ] || return 50
        case "$3" in
            dominfo)
                [ "$4" = "vps-${vm_id}" ] || return 51
                ;;
            domstate)
                [ "$4" = "vps-${vm_id}" ] || return 52
                printf 'running\n'
                ;;
            *)
                return 53
                ;;
        esac
    }

    if ( verify_created_vm_on_host "$vm_id" "192.0.2.2" "29" "192.0.2.1" ) >/dev/null 2>&1; then
        echo "created VM verification accepted missing network-config for IPAM metadata" >&2
        cleanup_host_paths
        unset -f virsh
        exit 1
    fi

    cleanup_host_paths
    unset -f virsh
}

expect_host_tool_preflight_checks_kvm_qemu_and_cloud_init() {
    reset_smoke_state
    local curl_seen=0
    local python_seen=0
    local virsh_seen=0
    local qemu_seen=0
    local kvm_seen=0
    local cloud_seen=0
    local network_marker
    network_marker="$(mktemp)"

    require_command() {
        case "$1" in
            curl) curl_seen=1 ;;
            python3) python_seen=1 ;;
            virsh) virsh_seen=1 ;;
            qemu-img) qemu_seen=1 ;;
            *)
                echo "unexpected required command: $1" >&2
                return 48
                ;;
        esac
    }
    validate_kvm_device() {
        kvm_seen=1
    }
    validate_cloud_init_tool() {
        cloud_seen=1
    }
    validate_not_wsl_host() {
        :
    }
    virsh() {
        [ "$1" = "--connect" ] || return 49
        [ "$2" = "qemu:///system" ] || return 50
        case "$3" in
            version)
                return 0
                ;;
            net-info)
                [ "$4" = "$LIBVIRT_NETWORK_NAME" ] || return 51
                printf '1' > "$network_marker"
                printf '%s\n' "Name: ${LIBVIRT_NETWORK_NAME}" "Active: yes" "Bridge: ${LIBVIRT_BRIDGE_NAME}"
                ;;
            *)
                return 52
                ;;
        esac
    }
    qemu-img() {
        [ "$1" = "--version" ] || return 53
    }

    validate_host_tools

    unset -f require_command validate_kvm_device validate_not_wsl_host virsh qemu-img
    source <(sed '/^main "\$@"/d' "$repo_root/scripts/kvm-host-smoke.sh")

    if [ "$curl_seen:$python_seen:$virsh_seen:$qemu_seen:$kvm_seen:$cloud_seen" != "1:1:1:1:1:1" ] ||
        [ "$(cat "$network_marker")" != "1" ]; then
        echo "host tool preflight did not check all required dependencies" >&2
        rm -f "$network_marker"
        exit 1
    fi
    rm -f "$network_marker"
}

expect_host_tool_preflight_hides_failed_virsh_version_output() {
    reset_smoke_state

    require_command() {
        :
    }
    validate_not_wsl_host() {
        :
    }
    validate_kvm_device() {
        :
    }
    validate_libvirt_network() {
        echo "network preflight should not run after failed virsh version" >&2
        return 48
    }
    validate_cloud_init_tool() {
        echo "cloud-init preflight should not run after failed virsh version" >&2
        return 49
    }
    virsh() {
        [ "$1" = "--connect" ] || return 50
        [ "$2" = "qemu:///system" ] || return 51
        [ "$3" = "version" ] || return 52
        printf '%s\n' "credential=ag_should_not_leak" >&2
        return 47
    }
    qemu-img() {
        [ "$1" = "--version" ] || return 53
    }

    local output
    if output="$(validate_host_tools 2>&1)"; then
        echo "failed virsh version passed host preflight" >&2
        unset -f require_command validate_not_wsl_host validate_kvm_device validate_libvirt_network validate_cloud_init_tool virsh qemu-img
        exit 1
    fi

    case "$output" in
        *ag_should_not_leak*)
            echo "host tool preflight leaked failed virsh version output" >&2
            printf '%s\n' "$output" >&2
            unset -f require_command validate_not_wsl_host validate_kvm_device validate_libvirt_network validate_cloud_init_tool virsh qemu-img
            exit 1
            ;;
    esac

    case "$output" in
        *"virsh qemu:///system is unavailable"*) ;;
        *)
            echo "host tool preflight did not return a safe virsh failure message" >&2
            printf '%s\n' "$output" >&2
            unset -f require_command validate_not_wsl_host validate_kvm_device validate_libvirt_network validate_cloud_init_tool virsh qemu-img
            exit 1
            ;;
    esac

    unset -f require_command validate_not_wsl_host validate_kvm_device validate_libvirt_network validate_cloud_init_tool virsh qemu-img
    source <(sed '/^main "\$@"/d' "$repo_root/scripts/kvm-host-smoke.sh")
}

expect_host_tool_preflight_hides_failed_qemu_img_version_output() {
    reset_smoke_state

    require_command() {
        :
    }
    validate_not_wsl_host() {
        :
    }
    validate_kvm_device() {
        :
    }
    validate_libvirt_network() {
        :
    }
    validate_cloud_init_tool() {
        echo "cloud-init preflight should not run after failed qemu-img version" >&2
        return 49
    }
    virsh() {
        [ "$1" = "--connect" ] || return 50
        [ "$2" = "qemu:///system" ] || return 51
        [ "$3" = "version" ] || return 52
    }
    qemu-img() {
        [ "$1" = "--version" ] || return 53
        printf '%s\n' "token=qemu_should_not_leak" >&2
        return 47
    }

    local output
    if output="$(validate_host_tools 2>&1)"; then
        echo "failed qemu-img version passed host preflight" >&2
        unset -f require_command validate_not_wsl_host validate_kvm_device validate_libvirt_network validate_cloud_init_tool virsh qemu-img
        exit 1
    fi

    case "$output" in
        *qemu_should_not_leak*)
            echo "host tool preflight leaked failed qemu-img version output" >&2
            printf '%s\n' "$output" >&2
            unset -f require_command validate_not_wsl_host validate_kvm_device validate_libvirt_network validate_cloud_init_tool virsh qemu-img
            exit 1
            ;;
    esac

    case "$output" in
        *"qemu-img is unavailable"*) ;;
        *)
            echo "host tool preflight did not return a safe qemu-img failure message" >&2
            printf '%s\n' "$output" >&2
            unset -f require_command validate_not_wsl_host validate_kvm_device validate_libvirt_network validate_cloud_init_tool virsh qemu-img
            exit 1
            ;;
    esac

    unset -f require_command validate_not_wsl_host validate_kvm_device validate_libvirt_network validate_cloud_init_tool virsh qemu-img
    source <(sed '/^main "\$@"/d' "$repo_root/scripts/kvm-host-smoke.sh")
}

expect_wsl_kernel_rejected_before_host_tool_checks() {
    reset_smoke_state
    local os_release_file
    local error_file
    os_release_file="$(mktemp)"
    error_file="$(mktemp)"
    printf '%s\n' "6.6.87.2-microsoft-standard-WSL2" > "$os_release_file"

    if ( validate_not_wsl_host "$os_release_file" ) > /dev/null 2>"$error_file"; then
        echo "expected WSL kernel validation failure" >&2
        rm -f "$os_release_file" "$error_file"
        exit 1
    fi

    if ! grep -q "WSL" "$error_file"; then
        echo "WSL validation failure did not explain the host mismatch" >&2
        cat "$error_file" >&2
        rm -f "$os_release_file" "$error_file"
        exit 1
    fi

    rm -f "$os_release_file" "$error_file"
}

expect_libvirt_network_preflight_requires_active_network() {
    reset_smoke_state

    virsh() {
        [ "$1" = "--connect" ] || return 49
        [ "$2" = "qemu:///system" ] || return 50
        [ "$3" = "net-info" ] || return 51
        [ "$4" = "$LIBVIRT_NETWORK_NAME" ] || return 52
        printf '%s\n' "Name: ${LIBVIRT_NETWORK_NAME}" "Active: no" "Bridge: ${LIBVIRT_BRIDGE_NAME}"
    }

    if ( validate_libvirt_network ) >/dev/null 2>&1; then
        echo "inactive libvirt network passed host preflight" >&2
        unset -f virsh
        exit 1
    fi
    unset -f virsh
}

expect_libvirt_network_preflight_requires_expected_bridge() {
    reset_smoke_state

    virsh() {
        [ "$1" = "--connect" ] || return 49
        [ "$2" = "qemu:///system" ] || return 50
        [ "$3" = "net-info" ] || return 51
        [ "$4" = "$LIBVIRT_NETWORK_NAME" ] || return 52
        printf '%s\n' "Name: ${LIBVIRT_NETWORK_NAME}" "Active: yes" "Bridge: virbr1"
    }

    if ( validate_libvirt_network ) >/dev/null 2>&1; then
        echo "libvirt network with unexpected bridge passed host preflight" >&2
        unset -f virsh
        exit 1
    fi
    unset -f virsh
}

expect_libvirt_network_preflight_hides_failed_virsh_output() {
    reset_smoke_state

    virsh() {
        [ "$1" = "--connect" ] || return 49
        [ "$2" = "qemu:///system" ] || return 50
        [ "$3" = "net-info" ] || return 51
        [ "$4" = "$LIBVIRT_NETWORK_NAME" ] || return 52
        printf '%s\n' "Name: ${LIBVIRT_NETWORK_NAME}" "token=bootstrap_should_not_leak"
        printf '%s\n' "password=host_secret_should_not_leak" >&2
        return 47
    }

    local output
    if output="$(validate_libvirt_network 2>&1)"; then
        echo "failed virsh net-info passed host preflight" >&2
        unset -f virsh
        exit 1
    fi

    case "$output" in
        *bootstrap_should_not_leak*|*host_secret_should_not_leak*)
            echo "libvirt network preflight leaked failed virsh output" >&2
            printf '%s\n' "$output" >&2
            unset -f virsh
            exit 1
            ;;
    esac

    case "$output" in
        *"unable to read libvirt network ${LIBVIRT_NETWORK_NAME}"*) ;;
        *)
            echo "libvirt network preflight did not return a safe failure message" >&2
            printf '%s\n' "$output" >&2
            unset -f virsh
            exit 1
            ;;
    esac

    unset -f virsh
}

expect_base_image_format_preflight_requires_qcow2() {
    reset_smoke_state
    make_host_paths

    qemu-img() {
        [ "$1" = "info" ] || return 49
        [ "$2" = "--output=json" ] || return 50
        [ "$3" = "${IMAGE_DIR}/${IMAGE_FILE}" ] || return 51
        printf '{"format":"raw"}'
    }

    if ( validate_base_image_format ) >/dev/null 2>&1; then
        echo "non-qcow2 base image passed host preflight" >&2
        cleanup_host_paths
        unset -f qemu-img
        exit 1
    fi

    cleanup_host_paths
    unset -f qemu-img
}

expect_base_image_format_preflight_hides_failed_qemu_img_info_output() {
    reset_smoke_state
    make_host_paths

    qemu-img() {
        [ "$1" = "info" ] || return 49
        [ "$2" = "--output=json" ] || return 50
        [ "$3" = "${IMAGE_DIR}/${IMAGE_FILE}" ] || return 51
        printf '%s\n' "password=image_secret_should_not_leak" >&2
        return 47
    }

    local output
    if output="$(validate_base_image_format 2>&1)"; then
        echo "failed qemu-img info passed host preflight" >&2
        cleanup_host_paths
        unset -f qemu-img
        exit 1
    fi

    case "$output" in
        *image_secret_should_not_leak*)
            echo "base image format preflight leaked failed qemu-img info output" >&2
            printf '%s\n' "$output" >&2
            cleanup_host_paths
            unset -f qemu-img
            exit 1
            ;;
    esac

    case "$output" in
        *"qemu-img cannot read base image: ${IMAGE_FILE}"*) ;;
        *)
            echo "base image format preflight did not return a safe qemu-img info failure message" >&2
            printf '%s\n' "$output" >&2
            cleanup_host_paths
            unset -f qemu-img
            exit 1
            ;;
    esac

    cleanup_host_paths
    unset -f qemu-img
}

expect_base_image_format_preflight_records_qcow2() {
    reset_smoke_state
    make_host_paths

    qemu-img() {
        [ "$1" = "info" ] || return 49
        [ "$2" = "--output=json" ] || return 50
        [ "$3" = "${IMAGE_DIR}/${IMAGE_FILE}" ] || return 51
        printf '{"format":"qcow2"}'
    }

    BASE_IMAGE_FORMAT=""
    validate_base_image_format
    unset -f qemu-img
    cleanup_host_paths

    if [ "$BASE_IMAGE_FORMAT" != "qcow2" ]; then
        echo "base image format preflight did not record qcow2" >&2
        exit 1
    fi
    BASE_IMAGE_FORMAT=""
}

expect_cloud_init_tool_rejects_broken_candidates() {
    reset_smoke_state
    local old_path="$PATH"
    local tool_dir
    tool_dir="$(mktemp -d)"

    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'exit 42'
    } > "${tool_dir}/cloud-localds"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'exit 43'
    } > "${tool_dir}/genisoimage"
    chmod +x "${tool_dir}/cloud-localds" "${tool_dir}/genisoimage"

    PATH="${tool_dir}:${PATH}"
    if ( validate_cloud_init_tool ) >/dev/null 2>&1; then
        echo "broken cloud-init ISO tools passed validation" >&2
        PATH="$old_path"
        rm -rf "$tool_dir"
        exit 1
    fi

    PATH="$old_path"
    rm -rf "$tool_dir"
}

expect_cloud_init_tool_records_cloud_localds_when_available() {
    reset_smoke_state
    local old_path="$PATH"
    local tool_dir
    tool_dir="$(mktemp -d)"

    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'exit 0'
    } > "${tool_dir}/cloud-localds"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'exit 43'
    } > "${tool_dir}/genisoimage"
    chmod +x "${tool_dir}/cloud-localds" "${tool_dir}/genisoimage"

    CLOUD_INIT_ISO_TOOL=""
    PATH="${tool_dir}:${PATH}"
    validate_cloud_init_tool
    PATH="$old_path"

    if [ "$CLOUD_INIT_ISO_TOOL" != "cloud-localds" ]; then
        echo "cloud-init ISO preflight did not record cloud-localds" >&2
        rm -rf "$tool_dir"
        exit 1
    fi

    CLOUD_INIT_ISO_TOOL=""
    rm -rf "$tool_dir"
}

expect_cloud_init_tool_falls_back_when_cloud_localds_is_broken() {
    reset_smoke_state
    local old_path="$PATH"
    local tool_dir
    local marker
    tool_dir="$(mktemp -d)"
    marker="${tool_dir}/genisoimage-used"

    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'exit 42'
    } > "${tool_dir}/cloud-localds"
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf 'printf x > %q\n' "$marker"
        printf '%s\n' 'exit 0'
    } > "${tool_dir}/genisoimage"
    chmod +x "${tool_dir}/cloud-localds" "${tool_dir}/genisoimage"

    PATH="${tool_dir}:${PATH}"
    CLOUD_INIT_ISO_TOOL=""
    validate_cloud_init_tool
    PATH="$old_path"

    if [ ! -f "$marker" ]; then
        echo "cloud-init ISO preflight did not fall back to genisoimage" >&2
        rm -rf "$tool_dir"
        exit 1
    fi
    if [ "$CLOUD_INIT_ISO_TOOL" != "genisoimage" ]; then
        echo "cloud-init ISO preflight did not record genisoimage fallback" >&2
        rm -rf "$tool_dir"
        exit 1
    fi

    CLOUD_INIT_ISO_TOOL=""
    rm -rf "$tool_dir"
}

expect_payload_builders_use_validated_shell_state() {
    reset_smoke_state
    export -n NODE_ID IMAGE_FILE IMAGE_NAME VM_NAME SSH_PUBLIC_KEY CPU_CORES MEMORY_MB DISK_GB

    validate_args

    local image_payload
    image_payload="$(make_image_payload)"
    [ "$(printf '%s' "$image_payload" | json_get name)" = "$IMAGE_NAME" ] || {
        echo "image payload did not use IMAGE_NAME from shell state" >&2
        exit 1
    }
    [ "$(printf '%s' "$image_payload" | json_get file_name)" = "$IMAGE_FILE" ] || {
        echo "image payload did not use IMAGE_FILE from shell state" >&2
        exit 1
    }

    local create_payload
    create_payload="$(make_create_vm_payload)"
    [ "$(printf '%s' "$create_payload" | json_get vm.node_id)" = "$NODE_ID" ] || {
        echo "create VM payload did not use NODE_ID from shell state" >&2
        exit 1
    }
    [ "$(printf '%s' "$create_payload" | json_get vm.name)" = "$VM_NAME" ] || {
        echo "create VM payload did not use VM_NAME from shell state" >&2
        exit 1
    }
    [ "$(printf '%s' "$create_payload" | json_get vm.cpu_cores)" = "$CPU_CORES" ] || {
        echo "create VM payload did not use CPU_CORES from shell state" >&2
        exit 1
    }
}

expect_create_payload_includes_optional_ssh_public_key() {
    reset_smoke_state
    SSH_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb operator@example"
    export -n SSH_PUBLIC_KEY

    validate_args

    local create_payload
    create_payload="$(make_create_vm_payload)"
    [ "$(printf '%s' "$create_payload" | json_get vm.ssh_public_key)" = "$SSH_PUBLIC_KEY" ] || {
        echo "create VM payload did not include SSH_PUBLIC_KEY from shell state" >&2
        exit 1
    }
}

expect_create_payload_includes_optional_ip_pool_id() {
    reset_smoke_state
    IP_POOL_ID="99999999-aaaa-bbbb-cccc-dddddddddddd"
    export -n IP_POOL_ID

    validate_args

    local create_payload
    create_payload="$(make_create_vm_payload)"
    [ "$(printf '%s' "$create_payload" | json_get vm.ip_pool_id)" = "$IP_POOL_ID" ] || {
        echo "create VM payload did not include IP_POOL_ID from shell state" >&2
        exit 1
    }
}

expect_create_payload_includes_optional_plan_id() {
    reset_smoke_state
    PLAN_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    export -n PLAN_ID

    validate_args

    local create_payload
    create_payload="$(make_create_vm_payload)"
    [ "$(printf '%s' "$create_payload" | json_get vm.plan_id)" = "$PLAN_ID" ] || {
        echo "create VM payload did not include PLAN_ID from shell state" >&2
        exit 1
    }
}

expect_ip_pool_cidr_reuses_existing_matching_pool() {
    reset_smoke_state
    IP_POOL_CIDR="192.0.2.0/29"
    IP_POOL_GATEWAY="192.0.2.1"
    local existing_pool_id="99999999-aaaa-bbbb-cccc-dddddddddddd"
    local marker
    marker="$(mktemp)"

    api() {
        case "$1:$2" in
            "GET:/api/admin/ip-pools")
                echo "list-pools" >> "$marker"
                printf '[{"id":"%s","name":"pool-01","cidr":"%s","gateway_ip":"%s","allocated_count":0}]' \
                    "$existing_pool_id" "$IP_POOL_CIDR" "$IP_POOL_GATEWAY"
                ;;
            "POST:/api/admin/ip-pools")
                echo "create-pool:${3:-}" >> "$marker"
                return 45
                ;;
            *)
                echo "unexpected api call while ensuring IP pool: $*" >&2
                return 46
                ;;
        esac
    }

    ensure_ip_pool_selected
    unset -f api

    if [ "$IP_POOL_ID" != "$existing_pool_id" ]; then
        echo "matching IP pool was not selected" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi
    if grep -q '^create-pool:' "$marker"; then
        echo "matching IP pool was recreated instead of reused" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    rm -f "$marker"
}

expect_ip_pool_cidr_creates_pool_when_missing() {
    reset_smoke_state
    IP_POOL_NAME="kvm-smoke-pool-01"
    IP_POOL_CIDR="192.0.2.0/29"
    IP_POOL_GATEWAY="192.0.2.1"
    local created_pool_id="99999999-aaaa-bbbb-cccc-dddddddddddd"
    local marker
    marker="$(mktemp)"

    api() {
        case "$1:$2" in
            "GET:/api/admin/ip-pools")
                echo "list-pools" >> "$marker"
                printf '[]'
                ;;
            "POST:/api/admin/ip-pools")
                echo "create-pool:${3:-}" >> "$marker"
                printf '{"id":"%s","name":"%s","cidr":"%s","gateway_ip":"%s","allocated_count":0}' \
                    "$created_pool_id" "$IP_POOL_NAME" "$IP_POOL_CIDR" "$IP_POOL_GATEWAY"
                ;;
            *)
                echo "unexpected api call while creating IP pool: $*" >&2
                return 46
                ;;
        esac
    }

    ensure_ip_pool_selected
    unset -f api

    if [ "$IP_POOL_ID" != "$created_pool_id" ]; then
        echo "created IP pool id was not selected" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi
    if ! grep -q '^create-pool:' "$marker"; then
        echo "missing IP pool did not trigger create request" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi
    if grep '^create-pool:' "$marker" |
        grep -vq "\"name\":\"$IP_POOL_NAME\".*\"cidr\":\"$IP_POOL_CIDR\".*\"gateway_ip\":\"$IP_POOL_GATEWAY\""; then
        echo "IP pool create payload did not include validated pool fields" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    rm -f "$marker"
}

expect_ip_pool_create_response_must_match_request() {
    reset_smoke_state
    IP_POOL_NAME="kvm-smoke-pool-01"
    IP_POOL_CIDR="192.0.2.0/29"
    IP_POOL_GATEWAY="192.0.2.1"
    local created_pool_id="99999999-aaaa-bbbb-cccc-dddddddddddd"

    api() {
        case "$1:$2" in
            "GET:/api/admin/ip-pools")
                printf '[]'
                ;;
            "POST:/api/admin/ip-pools")
                printf '{"id":"%s","name":"%s","cidr":"198.51.100.0/29","gateway_ip":"198.51.100.1","allocated_count":0}' \
                    "$created_pool_id" "$IP_POOL_NAME"
                ;;
            *)
                echo "unexpected api call while checking IP pool response: $*" >&2
                return 46
                ;;
        esac
    }

    if ( ensure_ip_pool_selected ) >/dev/null 2>&1; then
        echo "mismatched IP pool create response was accepted" >&2
        unset -f api
        exit 1
    fi
    unset -f api
}

expect_plan_slug_reuses_existing_enabled_matching_plan() {
    reset_smoke_state
    PLAN_SLUG="kvm-smoke-plan"
    local existing_plan_id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    local marker
    marker="$(mktemp)"

    api() {
        case "$1:$2" in
            "GET:/api/admin/plans")
                echo "list-plans" >> "$marker"
                printf '[{"id":"%s","name":"%s","slug":"%s","cpu_cores":%s,"memory_mb":%s,"disk_gb":%s,"enabled":true}]' \
                    "$existing_plan_id" "$PLAN_NAME" "$PLAN_SLUG" "$CPU_CORES" "$MEMORY_MB" "$DISK_GB"
                ;;
            "POST:/api/admin/plans")
                echo "create-plan:${3:-}" >> "$marker"
                return 45
                ;;
            *)
                echo "unexpected api call while ensuring plan: $*" >&2
                return 46
                ;;
        esac
    }

    ensure_plan_selected
    unset -f api

    if [ "$PLAN_ID" != "$existing_plan_id" ]; then
        echo "matching plan was not selected" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi
    if grep -q '^create-plan:' "$marker"; then
        echo "matching plan was recreated instead of reused" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    rm -f "$marker"
}

expect_plan_slug_creates_plan_when_missing() {
    reset_smoke_state
    PLAN_NAME="KVM Smoke Plan 01"
    PLAN_SLUG="kvm-smoke-plan-01"
    CPU_CORES="2"
    MEMORY_MB="1024"
    DISK_GB="20"
    local created_plan_id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    local marker
    marker="$(mktemp)"

    api() {
        case "$1:$2" in
            "GET:/api/admin/plans")
                echo "list-plans" >> "$marker"
                printf '[]'
                ;;
            "POST:/api/admin/plans")
                echo "create-plan" >> "$marker"
                [ "$(printf '%s' "${3:-}" | json_get name)" = "$PLAN_NAME" ] || return 45
                [ "$(printf '%s' "${3:-}" | json_get slug)" = "$PLAN_SLUG" ] || return 46
                [ "$(printf '%s' "${3:-}" | json_get cpu_cores)" = "$CPU_CORES" ] || return 47
                [ "$(printf '%s' "${3:-}" | json_get memory_mb)" = "$MEMORY_MB" ] || return 48
                [ "$(printf '%s' "${3:-}" | json_get disk_gb)" = "$DISK_GB" ] || return 49
                [ "$(printf '%s' "${3:-}" | json_get enabled)" = "True" ] || return 50
                printf '{"id":"%s","name":"%s","slug":"%s","cpu_cores":%s,"memory_mb":%s,"disk_gb":%s,"enabled":true}' \
                    "$created_plan_id" "$PLAN_NAME" "$PLAN_SLUG" "$CPU_CORES" "$MEMORY_MB" "$DISK_GB"
                ;;
            *)
                echo "unexpected api call while creating plan: $*" >&2
                return 51
                ;;
        esac
    }

    ensure_plan_selected
    unset -f api

    if [ "$PLAN_ID" != "$created_plan_id" ]; then
        echo "created plan id was not selected" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi
    if ! grep -q '^create-plan$' "$marker"; then
        echo "missing plan did not trigger create request" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    rm -f "$marker"
}

expect_plan_create_response_must_match_request() {
    reset_smoke_state
    PLAN_NAME="KVM Smoke Plan 01"
    PLAN_SLUG="kvm-smoke-plan-01"
    local created_plan_id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    api() {
        case "$1:$2" in
            "GET:/api/admin/plans")
                printf '[]'
                ;;
            "POST:/api/admin/plans")
                printf '{"id":"%s","name":"%s","slug":"other-plan","cpu_cores":%s,"memory_mb":%s,"disk_gb":%s,"enabled":true}' \
                    "$created_plan_id" "$PLAN_NAME" "$CPU_CORES" "$MEMORY_MB" "$DISK_GB"
                ;;
            *)
                echo "unexpected api call while checking plan response: $*" >&2
                return 46
                ;;
        esac
    }

    if ( ensure_plan_selected ) >/dev/null 2>&1; then
        echo "mismatched plan create response was accepted" >&2
        unset -f api
        exit 1
    fi
    unset -f api
}

expect_disabled_matching_plan_is_rejected_without_create() {
    reset_smoke_state
    PLAN_SLUG="kvm-smoke-plan"
    local existing_plan_id="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    local marker
    marker="$(mktemp)"

    api() {
        case "$1:$2" in
            "GET:/api/admin/plans")
                echo "list-plans" >> "$marker"
                printf '[{"id":"%s","name":"%s","slug":"%s","cpu_cores":%s,"memory_mb":%s,"disk_gb":%s,"enabled":false}]' \
                    "$existing_plan_id" "$PLAN_NAME" "$PLAN_SLUG" "$CPU_CORES" "$MEMORY_MB" "$DISK_GB"
                ;;
            "POST:/api/admin/plans")
                echo "create-plan:${3:-}" >> "$marker"
                return 45
                ;;
            *)
                echo "unexpected api call while checking disabled plan: $*" >&2
                return 46
                ;;
        esac
    }

    if ( ensure_plan_selected ) >/dev/null 2>&1; then
        echo "disabled matching plan was accepted" >&2
        unset -f api
        rm -f "$marker"
        exit 1
    fi
    unset -f api

    if grep -q '^create-plan:' "$marker"; then
        echo "disabled matching plan triggered a duplicate create request" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    rm -f "$marker"
}

expect_disabled_existing_image_is_reenabled() {
    reset_smoke_state
    local image_response_id="11111111-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    local enable_marker
    enable_marker="$(mktemp)"

    api() {
        case "$1:$2" in
            "GET:/api/admin/images")
                printf '[{"id":"%s","name":"Debian 12","file_name":"%s","enabled":false}]' "$image_response_id" "$IMAGE_FILE"
                ;;
            "POST:/api/admin/images/${image_response_id}/enabled")
                [ "${3:-}" = '{"enabled":true}' ] || {
                    echo "unexpected image enable payload: ${3:-}" >&2
                    return 45
                }
                printf '1' > "$enable_marker"
                printf '{"id":"%s","name":"Debian 12","file_name":"%s","enabled":true}' "$image_response_id" "$IMAGE_FILE"
                ;;
            "POST:/api/admin/images")
                echo "disabled existing image should be enabled, not recreated" >&2
                return 46
                ;;
            *)
                echo "unexpected api call while ensuring image: $*" >&2
                return 47
                ;;
        esac
    }

    ensure_image_registered
    unset -f api

    [ "$(cat "$enable_marker")" = "1" ] || {
        echo "disabled existing image was not re-enabled" >&2
        rm -f "$enable_marker"
        exit 1
    }
    rm -f "$enable_marker"
}

expect_disabled_existing_image_rejects_invalid_image_id_before_enable() {
    reset_smoke_state
    local marker
    marker="$(mktemp)"

    api() {
        case "$1:$2" in
            "GET:/api/admin/images")
                echo "list-images" >> "$marker"
                printf '[{"id":"../../images","name":"Debian 12","file_name":"%s","enabled":false}]' "$IMAGE_FILE"
                ;;
            "POST:/api/admin/images/../../images/enabled")
                echo "enable-image:${3:-}" >> "$marker"
                printf '{"id":"../../images","name":"Debian 12","file_name":"%s","enabled":true}' "$IMAGE_FILE"
                ;;
            *)
                echo "unexpected api call while checking invalid image id: $*" >&2
                return 47
                ;;
        esac
    }

    local output
    if output="$(ensure_image_registered 2>&1)"; then
        echo "disabled image with invalid id reached enable endpoint" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        unset -f api
        exit 1
    fi
    unset -f api

    case "$output" in
        *"image catalog response id must be a UUID"*) ;;
        *)
            echo "invalid image id failure did not explain the rejected response field" >&2
            printf '%s\n' "$output" >&2
            cat "$marker" >&2
            rm -f "$marker"
            exit 1
            ;;
    esac

    if grep -q '^enable-image:' "$marker"; then
        echo "invalid image id was used in the enable-image URL" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    rm -f "$marker"
}

expect_image_enable_response_must_be_enabled() {
    reset_smoke_state
    local image_response_id="11111111-aaaa-aaaa-aaaa-aaaaaaaaaaaa"

    api() {
        case "$1:$2" in
            "GET:/api/admin/images")
                printf '[{"id":"%s","name":"Debian 12","file_name":"%s","enabled":false}]' "$image_response_id" "$IMAGE_FILE"
                ;;
            "POST:/api/admin/images/${image_response_id}/enabled")
                printf '{"id":"%s","name":"Debian 12","file_name":"%s","enabled":false}' "$image_response_id" "$IMAGE_FILE"
                ;;
            *)
                echo "unexpected api call while checking image enable response: $*" >&2
                return 48
                ;;
        esac
    }

    if ( ensure_image_registered ) >/dev/null 2>&1; then
        echo "disabled image enable response with enabled=false was accepted" >&2
        unset -f api
        exit 1
    fi
    unset -f api
}

expect_precheck_only_skips_admin_token_and_admin_api() {
    reset_smoke_state
    make_host_paths
    PRECHECK_ONLY="1"
    ADMIN_TOKEN=""
    NODE_ID=""
    local marker
    marker="$(mktemp)"

    validate_host_tools() {
        echo "host-tools" >> "$marker"
    }
    validate_agent_config() {
        echo "agent-config" >> "$marker"
    }
    validate_agent_doctor() {
        echo "agent-doctor" >> "$marker"
    }
    systemctl() {
        if [ "$#" -eq 3 ] && [ "$1" = "is-active" ] && [ "$2" = "--quiet" ] && [ "$3" = "vps-agent.service" ]; then
            echo "agent-service" >> "$marker"
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ReadWritePaths" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s %s\n' "${AGENT_CONFIG_PATH%/*}" "$DATA_DIR"
            return 0
        fi
        if [ "$#" -eq 12 ] && [ "$1" = "show" ] && [ "${12}" = "vps-agent.service" ]; then
            printf '%s\n' \
                "NoNewPrivileges=yes" \
                "MemoryDenyWriteExecute=yes" \
                "PrivateTmp=yes" \
                "ProtectClock=yes" \
                "ProtectHome=yes" \
                "ProtectHostname=yes" \
                "ProtectSystem=strict" \
                "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK" \
                "RestrictSUIDSGID=yes" \
                "UMask=0077"
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=Environment" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "RUST_LOG=vps_agent=info VPS_AGENT_CONFIG=${AGENT_CONFIG_PATH} PATH=${SAFE_SYSTEMD_PATH}"
            return 0
        fi
        if [ "$#" -eq 4 ] && [ "$1" = "show" ] && [ "$2" = "--property=ExecStart" ] && [ "$3" = "--value" ] && [ "$4" = "vps-agent.service" ]; then
            printf '%s\n' "{ path=${AGENT_BINARY_PATH} ; argv[]=${AGENT_BINARY_PATH} ; ignore_errors=no ; start_time=[n/a] ; stop_time=[n/a] ; pid=0 ; code=(null) ; status=0/0 }"
            return 0
        fi
        if is_extra_hardening_show_call "$@"; then
            print_default_extra_hardening_properties
            return 0
        fi
        echo "unexpected systemctl call in precheck-only mode: $*" >&2
        return 44
    }
    validate_host_paths() {
        echo "host-paths" >> "$marker"
    }
    validate_base_image_format() {
        echo "base-image-format" >> "$marker"
    }
    curl() {
        for arg in "$@"; do
            if [ "$arg" = "${MASTER_URL%/}/healthz" ]; then
                echo "healthz" >> "$marker"
                return 0
            fi
        done
        echo "unexpected curl call in precheck-only mode: $*" >&2
        return 44
    }
    api() {
        echo "admin API must not be called in precheck-only mode" >&2
        return 45
    }

    local output
    if ! output="$(main 2>&1)"; then
        echo "precheck-only mode failed: $output" >&2
        cleanup_host_paths
        rm -f "$marker"
        unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl api systemctl
        set_default_systemctl_active
        exit 1
    fi

    unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl api systemctl
    set_default_systemctl_active

    case "$output" in
        *'"precheck_only": true'*|*"\"precheck_only\":  true"*) ;;
        *)
            echo "precheck-only output did not report precheck_only=true" >&2
            printf '%s\n' "$output" >&2
            cleanup_host_paths
            rm -f "$marker"
            exit 1
            ;;
    esac

    if [ "$(grep -c '^host-tools$' "$marker")" -ne 1 ] ||
        [ "$(grep -c '^agent-config$' "$marker")" -ne 1 ] ||
        [ "$(grep -c '^agent-doctor$' "$marker")" -ne 1 ] ||
        [ "$(grep -c '^agent-service$' "$marker")" -ne 1 ] ||
        [ "$(grep -c '^host-paths$' "$marker")" -ne 1 ] ||
        [ "$(grep -c '^base-image-format$' "$marker")" -ne 1 ] ||
        [ "$(grep -c '^healthz$' "$marker")" -ne 1 ]; then
        echo "precheck-only mode did not run the expected checks exactly once" >&2
        cat "$marker" >&2
        cleanup_host_paths
        rm -f "$marker"
        exit 1
    fi

    cleanup_host_paths
    rm -f "$marker"
}

expect_precheck_success_reports_non_secret_diagnostics() {
    reset_smoke_state
    ADMIN_TOKEN="admin-token-that-must-not-be-printed"
    NODE_ID="11111111-2222-3333-4444-555555555555"
    MASTER_CA_CERT_PATH="/etc/ssl/certs/master-ca.pem"
    AGENT_BINARY_SHA256="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    AGENT_BINARY_SHA256_VERIFIED="1"
    CURL_TIMEOUT_SECONDS="19"
    TIMEOUT_SECONDS="31"
    POLL_SECONDS="7"
    CLOUD_INIT_ISO_TOOL="genisoimage"
    BASE_IMAGE_FORMAT="qcow2"

    local output
    output="$(print_precheck_success)"

    [ "$(printf '%s' "$output" | json_get precheck_only)" = "True" ] || {
        echo "precheck output did not report precheck_only=true" >&2
        exit 1
    }
    [ "$(printf '%s' "$output" | json_get host_preflight)" = "ok" ] || {
        echo "precheck output did not report host_preflight=ok" >&2
        exit 1
    }
    [ "$(printf '%s' "$output" | json_get master_health_verified)" = "True" ] || {
        echo "precheck output did not confirm master health verification" >&2
        exit 1
    }
    [ "$(printf '%s' "$output" | json_get agent_config_registered)" = "True" ] || {
        echo "precheck output did not confirm registered agent config" >&2
        exit 1
    }
    [ "$(printf '%s' "$output" | json_get agent_binary_sha256_verified)" = "True" ] || {
        echo "precheck output did not confirm installed agent binary hash verification" >&2
        exit 1
    }
    [ "$(printf '%s' "$output" | json_get agent_binary_sha256)" = "$AGENT_BINARY_SHA256" ] || {
        echo "precheck output did not include the verified installed agent binary hash" >&2
        exit 1
    }
    [ "$(printf '%s' "$output" | json_get master_url)" = "$MASTER_URL" ] || {
        echo "precheck output did not include validated master_url" >&2
        exit 1
    }
    [ "$(printf '%s' "$output" | json_get data_dir)" = "$DATA_DIR" ] || {
        echo "precheck output did not include data_dir" >&2
        exit 1
    }
    [ "$(printf '%s' "$output" | json_get image_dir)" = "$IMAGE_DIR" ] || {
        echo "precheck output did not include image_dir" >&2
        exit 1
    }
    [ "$(printf '%s' "$output" | json_get image_file)" = "$IMAGE_FILE" ] || {
        echo "precheck output did not include image_file" >&2
        exit 1
    }
    [ "$(printf '%s' "$output" | json_get ca_cert_configured)" = "True" ] || {
        echo "precheck output did not report configured CA certificate" >&2
        exit 1
    }
    [ "$(printf '%s' "$output" | json_get curl_timeout_seconds)" = "$CURL_TIMEOUT_SECONDS" ] || {
        echo "precheck output did not include curl timeout seconds" >&2
        exit 1
    }
    [ "$(printf '%s' "$output" | json_get timeout_seconds)" = "$TIMEOUT_SECONDS" ] || {
        echo "precheck output did not include task timeout seconds" >&2
        exit 1
    }
    [ "$(printf '%s' "$output" | json_get poll_seconds)" = "$POLL_SECONDS" ] || {
        echo "precheck output did not include poll seconds" >&2
        exit 1
    }
    [ "$(printf '%s' "$output" | json_get cloud_init_iso_tool)" = "$CLOUD_INIT_ISO_TOOL" ] || {
        echo "precheck output did not include cloud-init ISO tool" >&2
        exit 1
    }
    [ "$(printf '%s' "$output" | json_get libvirt_network_name)" = "$LIBVIRT_NETWORK_NAME" ] || {
        echo "precheck output did not include libvirt network name" >&2
        exit 1
    }
    [ "$(printf '%s' "$output" | json_get libvirt_bridge_name)" = "$LIBVIRT_BRIDGE_NAME" ] || {
        echo "precheck output did not include libvirt bridge name" >&2
        exit 1
    }
    [ "$(printf '%s' "$output" | json_get base_image_format)" = "$BASE_IMAGE_FORMAT" ] || {
        echo "precheck output did not include base image format" >&2
        exit 1
    }

    case "$output" in
        *"$ADMIN_TOKEN"*|*"$NODE_ID"*|*"$MASTER_CA_CERT_PATH"*)
            echo "precheck output leaked a secret or host-local trust path" >&2
            exit 1
            ;;
    esac
    CLOUD_INIT_ISO_TOOL=""
    BASE_IMAGE_FORMAT=""
}

expect_precheck_health_uses_bounded_curl_timeout() {
    reset_smoke_state
    make_host_paths
    PRECHECK_ONLY="1"
    ADMIN_TOKEN=""
    NODE_ID=""
    CURL_TIMEOUT_SECONDS="19"
    local disables_curl_config=0
    local connect_timeout_seen=0
    local max_time_seen=0
    local proto_seen=0

    validate_host_tools() {
        return 0
    }
    validate_agent_config() {
        return 0
    }
    validate_agent_doctor() {
        return 0
    }
    validate_host_paths() {
        return 0
    }
    validate_base_image_format() {
        return 0
    }
    curl() {
        local previous=""
        local health_seen=0
        if [ "${1:-}" = "-q" ]; then
            disables_curl_config=1
        fi
        for arg in "$@"; do
            if [ "$previous" = "--connect-timeout" ] && [ "$arg" = "$CURL_TIMEOUT_SECONDS" ]; then
                connect_timeout_seen=1
            fi
            if [ "$previous" = "--max-time" ] && [ "$arg" = "$CURL_TIMEOUT_SECONDS" ]; then
                max_time_seen=1
            fi
            if [ "$previous" = "--proto" ] && [ "$arg" = "=https" ]; then
                proto_seen=1
            fi
            if [ "$arg" = "${MASTER_URL%/}/healthz" ]; then
                health_seen=1
            fi
            previous="$arg"
        done
        [ "$health_seen" = "1" ] || {
            echo "precheck health curl did not target /healthz" >&2
            return 44
        }
    }

    main >/dev/null
    unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl
    cleanup_host_paths

    if [ "$disables_curl_config" != "1" ]; then
        echo "precheck health curl call did not pass -q before other arguments" >&2
        exit 1
    fi
    if [ "$connect_timeout_seen:$max_time_seen" != "1:1" ]; then
        echo "precheck health curl call did not include bounded timeout arguments" >&2
        exit 1
    fi
    if [ "$proto_seen" != "1" ]; then
        echo "precheck health curl call did not restrict protocols to HTTPS" >&2
        exit 1
    fi
}

expect_precheck_health_keeps_https_proto_when_allow_http_flag_is_set_for_https_url() {
    reset_smoke_state
    make_host_paths
    PRECHECK_ONLY="1"
    ADMIN_TOKEN=""
    NODE_ID=""
    MASTER_URL="https://panel.example.com"
    ALLOW_HTTP="1"
    local proto_arg=""

    validate_host_tools() {
        return 0
    }
    validate_agent_config() {
        return 0
    }
    validate_agent_doctor() {
        return 0
    }
    validate_host_paths() {
        return 0
    }
    validate_base_image_format() {
        return 0
    }
    curl() {
        local previous=""
        local health_seen=0
        for arg in "$@"; do
            if [ "$previous" = "--proto" ]; then
                proto_arg="$arg"
            fi
            if [ "$arg" = "${MASTER_URL%/}/healthz" ]; then
                health_seen=1
            fi
            previous="$arg"
        done
        [ "$health_seen" = "1" ] || {
            echo "precheck health curl did not target /healthz" >&2
            return 44
        }
    }

    main >/dev/null
    unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl
    cleanup_host_paths

    if [ "$proto_arg" != "=https" ]; then
        echo "precheck health curl broadened protocol allow-list for an HTTPS master URL: $proto_arg" >&2
        exit 1
    fi
}

expect_precheck_health_uses_configured_ca_certificate() {
    reset_smoke_state
    make_host_paths
    make_ca_cert_path
    PRECHECK_ONLY="1"
    ADMIN_TOKEN=""
    NODE_ID=""
    local cacert_seen=0

    validate_host_tools() {
        return 0
    }
    validate_agent_config() {
        return 0
    }
    validate_agent_doctor() {
        return 0
    }
    validate_host_paths() {
        return 0
    }
    validate_base_image_format() {
        return 0
    }
    curl() {
        local previous=""
        for arg in "$@"; do
            if [ "$previous" = "--cacert" ] && [ "$arg" = "$MASTER_CA_CERT_PATH" ]; then
                cacert_seen=1
            fi
            previous="$arg"
        done
    }

    main >/dev/null
    unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl
    cleanup_host_paths

    if [ "$cacert_seen" != "1" ]; then
        echo "precheck health curl call did not use configured CA certificate" >&2
        cleanup_ca_cert_path
        exit 1
    fi
    cleanup_ca_cert_path
}

expect_full_smoke_checks_node_ready_before_catalog_mutation() {
    reset_smoke_state
    local marker
    marker="$(mktemp)"

    validate_host_tools() {
        echo "host-tools" >> "$marker"
    }
    validate_agent_config() {
        echo "agent-config" >> "$marker"
    }
    validate_agent_doctor() {
        echo "agent-doctor" >> "$marker"
    }
    validate_host_paths() {
        echo "host-paths" >> "$marker"
    }
    validate_base_image_format() {
        echo "base-image-format" >> "$marker"
    }
    curl() {
        for arg in "$@"; do
            if [ "$arg" = "${MASTER_URL%/}/healthz" ]; then
                echo "healthz" >> "$marker"
                return 0
            fi
        done
        echo "unexpected curl call in node-ready ordering test: $*" >&2
        return 44
    }
    api() {
        case "$1:$2" in
            "GET:/api/admin/nodes")
                echo "node-ready-api" >> "$marker"
                node_ready_list_json
                ;;
            *)
                echo "unexpected api call in node-ready ordering test: $*" >&2
                return 45
                ;;
        esac
    }
    ensure_image_registered() {
        echo "image-registered" >> "$marker"
        fail "image registration intentionally stopped after node-ready ordering check"
    }

    if output="$(main 2>&1)"; then
        echo "node-ready ordering test expected the image registration stub to stop main" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl \
            ensure_image_registered
        restore_api
        exit 1
    fi

    unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl \
        ensure_image_registered
    restore_api

    node_line="$(grep -n '^node-ready-api$' "$marker" | head -n1 | cut -d: -f1 || true)"
    image_line="$(grep -n '^image-registered$' "$marker" | head -n1 | cut -d: -f1 || true)"
    if [ -z "$node_line" ] || [ -z "$image_line" ] || [ "$node_line" -ge "$image_line" ]; then
        echo "full smoke did not verify node readiness before catalog mutation" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    rm -f "$marker"
}

expect_full_smoke_stops_when_ip_pool_selection_fails() {
    reset_smoke_state
    IP_POOL_CIDR="192.0.2.0/29"
    IP_POOL_GATEWAY="192.0.2.1"
    local marker
    marker="$(mktemp)"
    local original_ensure_ip_pool_selected
    local original_ensure_plan_selected
    original_ensure_ip_pool_selected="$(declare -f ensure_ip_pool_selected)"
    original_ensure_plan_selected="$(declare -f ensure_plan_selected)"
    stub_node_ready

    validate_host_tools() {
        echo "host-tools" >> "$marker"
    }
    validate_agent_config() {
        echo "agent-config" >> "$marker"
    }
    validate_agent_doctor() {
        echo "agent-doctor" >> "$marker"
    }
    validate_host_paths() {
        echo "host-paths" >> "$marker"
    }
    validate_base_image_format() {
        echo "base-image-format" >> "$marker"
    }
    curl() {
        for arg in "$@"; do
            if [ "$arg" = "${MASTER_URL%/}/healthz" ]; then
                echo "healthz" >> "$marker"
                return 0
            fi
        done
        echo "unexpected curl call in IP pool failure smoke test: $*" >&2
        return 44
    }
    ensure_image_registered() {
        echo "image-registered" >> "$marker"
    }
    ensure_ip_pool_selected() {
        echo "ip-pool-failed" >> "$marker"
        return 46
    }
    ensure_plan_selected() {
        echo "plan-selected" >> "$marker"
    }
    api() {
        case "$1:$2" in
            "POST:/api/admin/tasks/create-vm")
                echo "create-task" >> "$marker"
                return 47
                ;;
            *)
                echo "unexpected api call in IP pool failure smoke test: $*" >&2
                return 48
                ;;
        esac
    }

    local output
    if output="$(main 2>&1)"; then
        echo "smoke path succeeded after IP pool selection failed" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl \
            ensure_image_registered api
        eval "$original_ensure_ip_pool_selected"
        eval "$original_ensure_plan_selected"
        restore_api
        exit 1
    fi

    unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl \
        ensure_image_registered api
    eval "$original_ensure_ip_pool_selected"
    eval "$original_ensure_plan_selected"
    restore_api

    if grep -Eq '^(plan-selected|create-task)$' "$marker"; then
        echo "IP pool selection failure did not stop before later catalog or task work" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    rm -f "$marker"
}

expect_create_response_rejects_invalid_vm_id_before_host_actions() {
    reset_smoke_state
    local create_task_id="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    local delete_task_id="cccccccc-cccc-cccc-cccc-cccccccccccc"
    local marker
    marker="$(mktemp)"
    stub_node_ready

    validate_host_tools() {
        echo "host-tools" >> "$marker"
    }
    validate_agent_config() {
        echo "agent-config" >> "$marker"
    }
    validate_agent_doctor() {
        echo "agent-doctor" >> "$marker"
    }
    validate_host_paths() {
        echo "host-paths" >> "$marker"
    }
    validate_base_image_format() {
        echo "base-image-format" >> "$marker"
    }
    curl() {
        for arg in "$@"; do
            if [ "$arg" = "${MASTER_URL%/}/healthz" ]; then
                echo "healthz" >> "$marker"
                return 0
            fi
        done
        echo "unexpected curl call in invalid VM id smoke test: $*" >&2
        return 44
    }
    ensure_image_registered() {
        echo "image-registered" >> "$marker"
    }
    api() {
        case "$1:$2" in
            "POST:/api/admin/tasks/create-vm")
                echo "create-task" >> "$marker"
                printf '{"id":"%s","kind":{"vm_id":"../../host"}}' "$create_task_id"
                ;;
            "POST:/api/admin/tasks/delete-vm")
                echo "delete-task:${3:-}" >> "$marker"
                printf '{"id":"%s"}' "$delete_task_id"
                ;;
            *)
                echo "unexpected api call in invalid VM id smoke test: $*" >&2
                return 45
                ;;
        esac
    }
    wait_for_task() {
        echo "wait:$1" >> "$marker"
    }
    verify_created_vm_on_host() {
        echo "verify-created:$1" >> "$marker"
    }
    verify_deleted_vm_on_host() {
        echo "verify-deleted:$1" >> "$marker"
    }

    local output
    if output="$(main 2>&1)"; then
        echo "smoke path accepted an invalid create response vm_id" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl \
            ensure_image_registered api wait_for_task verify_created_vm_on_host \
            verify_deleted_vm_on_host
        exit 1
    fi

    unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl \
        ensure_image_registered api wait_for_task verify_created_vm_on_host \
        verify_deleted_vm_on_host

    case "$output" in
        *"create response vm_id must be a UUID"*) ;;
        *)
            echo "invalid VM id failure did not explain the rejected response field" >&2
            printf '%s\n' "$output" >&2
            cat "$marker" >&2
            rm -f "$marker"
            exit 1
            ;;
    esac

    if grep -Eq '^(wait|verify|delete)' "$marker"; then
        echo "invalid create response vm_id reached task wait, host verification, or cleanup" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    rm -f "$marker"
}

expect_create_response_rejects_invalid_task_id_before_polling() {
    reset_smoke_state
    local vm_id="11111111-2222-3333-4444-555555555555"
    local delete_task_id="cccccccc-cccc-cccc-cccc-cccccccccccc"
    local marker
    marker="$(mktemp)"
    stub_node_ready

    validate_host_tools() {
        echo "host-tools" >> "$marker"
    }
    validate_agent_config() {
        echo "agent-config" >> "$marker"
    }
    validate_agent_doctor() {
        echo "agent-doctor" >> "$marker"
    }
    validate_host_paths() {
        echo "host-paths" >> "$marker"
    }
    validate_base_image_format() {
        echo "base-image-format" >> "$marker"
    }
    curl() {
        for arg in "$@"; do
            if [ "$arg" = "${MASTER_URL%/}/healthz" ]; then
                echo "healthz" >> "$marker"
                return 0
            fi
        done
        echo "unexpected curl call in invalid task id smoke test: $*" >&2
        return 44
    }
    ensure_image_registered() {
        echo "image-registered" >> "$marker"
    }
    api() {
        case "$1:$2" in
            "POST:/api/admin/tasks/create-vm")
                echo "create-task" >> "$marker"
                printf '{"id":"../../tasks","kind":{"vm_id":"%s"}}' "$vm_id"
                ;;
            "POST:/api/admin/tasks/delete-vm")
                echo "delete-task:${3:-}" >> "$marker"
                printf '{"id":"%s"}' "$delete_task_id"
                ;;
            *)
                echo "unexpected api call in invalid task id smoke test: $*" >&2
                return 45
                ;;
        esac
    }
    wait_for_task() {
        echo "wait:$1" >> "$marker"
    }
    verify_created_vm_on_host() {
        echo "verify-created:$1" >> "$marker"
    }
    verify_deleted_vm_on_host() {
        echo "verify-deleted:$1" >> "$marker"
    }

    local output
    if output="$(main 2>&1)"; then
        echo "smoke path accepted an invalid create response task id" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl \
            ensure_image_registered api wait_for_task verify_created_vm_on_host \
            verify_deleted_vm_on_host
        exit 1
    fi

    unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl \
        ensure_image_registered api wait_for_task verify_created_vm_on_host \
        verify_deleted_vm_on_host

    case "$output" in
        *"create response task id must be a UUID"*) ;;
        *)
            echo "invalid task id failure did not explain the rejected response field" >&2
            printf '%s\n' "$output" >&2
            cat "$marker" >&2
            rm -f "$marker"
            exit 1
            ;;
    esac

    if grep -Eq '^(wait|verify|delete)' "$marker"; then
        echo "invalid create response task id reached polling, host verification, or cleanup" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    rm -f "$marker"
}

expect_create_response_requires_selected_plan_id_before_polling() {
    reset_smoke_state
    PLAN_ID="99999999-aaaa-bbbb-cccc-dddddddddddd"
    local vm_id="11111111-2222-3333-4444-555555555555"
    local create_response_task_id="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    local delete_response_task_id="cccccccc-cccc-cccc-cccc-cccccccccccc"
    local marker
    marker="$(mktemp)"
    stub_node_ready

    validate_host_tools() {
        echo "host-tools" >> "$marker"
    }
    validate_agent_config() {
        echo "agent-config" >> "$marker"
    }
    validate_agent_doctor() {
        echo "agent-doctor" >> "$marker"
    }
    validate_host_paths() {
        echo "host-paths" >> "$marker"
    }
    validate_base_image_format() {
        echo "base-image-format" >> "$marker"
    }
    curl() {
        for arg in "$@"; do
            if [ "$arg" = "${MASTER_URL%/}/healthz" ]; then
                echo "healthz" >> "$marker"
                return 0
            fi
        done
        echo "unexpected curl call in missing plan id smoke test: $*" >&2
        return 44
    }
    ensure_image_registered() {
        echo "image-registered" >> "$marker"
    }
    api() {
        case "$1:$2" in
            "POST:/api/admin/tasks/create-vm")
                echo "create-task" >> "$marker"
                printf '{"id":"%s","kind":{"vm_id":"%s"}}' "$create_response_task_id" "$vm_id"
                ;;
            "POST:/api/admin/tasks/delete-vm")
                echo "delete-task:${3:-}" >> "$marker"
                printf '{"id":"%s"}' "$delete_response_task_id"
                ;;
            *)
                echo "unexpected api call in missing plan id smoke test: $*" >&2
                return 45
                ;;
        esac
    }
    wait_for_task() {
        echo "wait:$1" >> "$marker"
    }
    verify_created_vm_on_host() {
        echo "verify-created:$1" >> "$marker"
    }
    verify_deleted_vm_on_host() {
        echo "verify-deleted:$1" >> "$marker"
    }

    local output
    if output="$(main 2>&1)"; then
        echo "smoke path accepted a create response without selected plan_id" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl \
            ensure_image_registered api wait_for_task verify_created_vm_on_host \
            verify_deleted_vm_on_host
        exit 1
    fi

    unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl \
        ensure_image_registered api wait_for_task verify_created_vm_on_host \
        verify_deleted_vm_on_host

    case "$output" in
        *"create response plan_id did not match selected PLAN_ID"*) ;;
        *)
            echo "missing plan id failure did not explain the rejected response field" >&2
            printf '%s\n' "$output" >&2
            cat "$marker" >&2
            rm -f "$marker"
            exit 1
            ;;
    esac

    if grep -Eq '^(wait|verify|delete)' "$marker"; then
        echo "missing selected plan_id reached polling, host verification, or cleanup" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    rm -f "$marker"
}

expect_create_verification_failure_attempts_cleanup() {
    reset_smoke_state
    local vm_id="11111111-2222-3333-4444-555555555555"
    local create_response_task_id="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    local delete_response_task_id="cccccccc-cccc-cccc-cccc-cccccccccccc"
    local marker
    marker="$(mktemp)"
    stub_node_ready

    validate_host_tools() {
        echo "host-tools" >> "$marker"
    }
    validate_agent_config() {
        echo "agent-config" >> "$marker"
    }
    validate_agent_doctor() {
        echo "agent-doctor" >> "$marker"
    }
    validate_host_paths() {
        echo "host-paths" >> "$marker"
    }
    validate_base_image_format() {
        echo "base-image-format" >> "$marker"
    }
    curl() {
        for arg in "$@"; do
            if [ "$arg" = "${MASTER_URL%/}/healthz" ]; then
                echo "healthz" >> "$marker"
                return 0
            fi
        done
        echo "unexpected curl call in cleanup-on-create-verification-failure test: $*" >&2
        return 44
    }
    ensure_image_registered() {
        echo "image-registered" >> "$marker"
    }
    api() {
        case "$1:$2" in
            "POST:/api/admin/tasks/create-vm")
                echo "create-task" >> "$marker"
                printf '{"id":"%s","kind":{"vm_id":"%s"}}' "$create_response_task_id" "$vm_id"
                ;;
            "GET:/api/admin/tasks/${create_response_task_id}/logs")
                echo "create-logs" >> "$marker"
                task_started_logs_json "$create_response_task_id"
                ;;
            "POST:/api/admin/tasks/delete-vm")
                echo "delete-task:${3:-}" >> "$marker"
                printf '{"id":"%s","kind":{"vm_id":"%s"}}' "$delete_response_task_id" "$vm_id"
                ;;
            *)
                echo "unexpected api call in cleanup-on-create-verification-failure test: $*" >&2
                return 45
                ;;
        esac
    }
    wait_for_task() {
        echo "wait:$1" >> "$marker"
    }
    verify_created_vm_on_host() {
        echo "verify-created:$1" >> "$marker"
        return 46
    }
    verify_deleted_vm_on_host() {
        echo "verify-deleted:$1" >> "$marker"
    }

    local output
    if output="$(main 2>&1)"; then
        echo "smoke path succeeded after created VM host verification failed" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl \
            ensure_image_registered api wait_for_task verify_created_vm_on_host \
            verify_deleted_vm_on_host
        exit 1
    fi

    unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl \
        ensure_image_registered api wait_for_task verify_created_vm_on_host \
        verify_deleted_vm_on_host

    case "$output" in
        *"$ADMIN_TOKEN"*)
            echo "cleanup-on-failure output leaked admin token" >&2
            printf '%s\n' "$output" >&2
            rm -f "$marker"
            exit 1
            ;;
    esac

    if ! grep -q "^delete-task:" "$marker" ||
        ! grep -q "^wait:${delete_response_task_id}$" "$marker" ||
        ! grep -q "^verify-deleted:${vm_id}$" "$marker"; then
        echo "create verification failure did not attempt cleanup" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    if grep '^delete-task:' "$marker" | grep -vq "\"vm_id\":\"$vm_id\""; then
        echo "cleanup payload did not include the created vm_id" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    rm -f "$marker"
}

expect_create_success_requires_task_start_log_and_attempts_cleanup() {
    reset_smoke_state
    local vm_id="11111111-2222-3333-4444-555555555555"
    local create_response_task_id="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    local delete_response_task_id="cccccccc-cccc-cccc-cccc-cccccccccccc"
    local marker
    marker="$(mktemp)"
    stub_node_ready

    validate_host_tools() {
        echo "host-tools" >> "$marker"
    }
    validate_agent_config() {
        echo "agent-config" >> "$marker"
    }
    validate_agent_doctor() {
        echo "agent-doctor" >> "$marker"
    }
    validate_host_paths() {
        echo "host-paths" >> "$marker"
    }
    validate_base_image_format() {
        echo "base-image-format" >> "$marker"
    }
    curl() {
        for arg in "$@"; do
            if [ "$arg" = "${MASTER_URL%/}/healthz" ]; then
                echo "healthz" >> "$marker"
                return 0
            fi
        done
        echo "unexpected curl call in missing task log smoke test: $*" >&2
        return 44
    }
    ensure_image_registered() {
        echo "image-registered" >> "$marker"
    }
    api() {
        case "$1:$2" in
            "POST:/api/admin/tasks/create-vm")
                echo "create-task" >> "$marker"
                printf '{"id":"%s","kind":{"vm_id":"%s"}}' "$create_response_task_id" "$vm_id"
                ;;
            "GET:/api/admin/tasks/${create_response_task_id}/logs")
                echo "create-logs" >> "$marker"
                printf '[]'
                ;;
            "POST:/api/admin/tasks/delete-vm")
                echo "delete-task:${3:-}" >> "$marker"
                printf '{"id":"%s","kind":{"vm_id":"%s"}}' "$delete_response_task_id" "$vm_id"
                ;;
            *)
                echo "unexpected api call in missing task log smoke test: $*" >&2
                return 45
                ;;
        esac
    }
    wait_for_task() {
        echo "wait:$1" >> "$marker"
    }
    verify_created_vm_on_host() {
        echo "verify-created:$1" >> "$marker"
    }
    verify_deleted_vm_on_host() {
        echo "verify-deleted:$1" >> "$marker"
    }

    local output
    if output="$(main 2>&1)"; then
        echo "smoke path accepted create success without readable task start log" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl \
            ensure_image_registered api wait_for_task verify_created_vm_on_host \
            verify_deleted_vm_on_host
        exit 1
    fi

    unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl \
        ensure_image_registered api wait_for_task verify_created_vm_on_host \
        verify_deleted_vm_on_host

    case "$output" in
        *"create task logs did not include task executor started"*) ;;
        *)
            echo "missing task log failure did not explain the rejected response field" >&2
            printf '%s\n' "$output" >&2
            cat "$marker" >&2
            rm -f "$marker"
            exit 1
            ;;
    esac

    if ! grep -q '^create-logs$' "$marker" ||
        ! grep -q "^delete-task:" "$marker" ||
        ! grep -q "^wait:${delete_response_task_id}$" "$marker" ||
        ! grep -q "^verify-deleted:${vm_id}$" "$marker"; then
        echo "missing task log failure did not check logs and attempt cleanup" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    if grep -q '^verify-created:' "$marker"; then
        echo "missing task log failure reached host create verification" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    rm -f "$marker"
}

expect_task_start_log_parser_requires_task_and_node_match() {
    reset_smoke_state
    local task_id="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    local other_task_id="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    local other_node_id="99999999-9999-9999-9999-999999999999"

    if ! task_started_logs_json "$task_id" | json_task_logs_include_task_started "$task_id" "$NODE_ID"; then
        echo "task start log parser rejected the matching task/node log" >&2
        exit 1
    fi

    if task_started_logs_json "$other_task_id" | json_task_logs_include_task_started "$task_id" "$NODE_ID"; then
        echo "task start log parser accepted a log row for another task" >&2
        exit 1
    fi

    if printf '[{"id":1,"task_id":"%s","node_id":"%s","message":"task executor started","created_at":"2026-05-23T00:00:00Z"}]' \
        "$task_id" "$other_node_id" |
        json_task_logs_include_task_started "$task_id" "$NODE_ID"; then
        echo "task start log parser accepted a log row for another node" >&2
        exit 1
    fi
}

expect_full_lifecycle_required_validates_flags() {
    reset_smoke_state
    FULL_LIFECYCLE_REQUIRED="1"
    REINSTALL_AFTER_CREATE="1"
    POWER_CYCLE_AFTER_CREATE="1"
    CLEANUP="1"
    AGENT_BINARY_SHA256="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    validate_args

    expect_invalid eval "FULL_LIFECYCLE_REQUIRED='1'; REINSTALL_AFTER_CREATE='1'; POWER_CYCLE_AFTER_CREATE='1'; CLEANUP='1'; AGENT_BINARY_SHA256=''"
    expect_invalid eval "FULL_LIFECYCLE_REQUIRED='1'; REINSTALL_AFTER_CREATE='0'; POWER_CYCLE_AFTER_CREATE='1'; CLEANUP='1'"
    expect_invalid eval "FULL_LIFECYCLE_REQUIRED='1'; REINSTALL_AFTER_CREATE='1'; POWER_CYCLE_AFTER_CREATE='0'; CLEANUP='1'"
    expect_invalid eval "FULL_LIFECYCLE_REQUIRED='1'; REINSTALL_AFTER_CREATE='1'; POWER_CYCLE_AFTER_CREATE='1'; CLEANUP='0'"
    expect_invalid eval "FULL_LIFECYCLE_REQUIRED='1'; REINSTALL_AFTER_CREATE='1'; POWER_CYCLE_AFTER_CREATE='1'; CLEANUP='1'; PRECHECK_ONLY='1'"
    expect_invalid eval "FULL_LIFECYCLE_REQUIRED='1'; REINSTALL_AFTER_CREATE='1'; POWER_CYCLE_AFTER_CREATE='1'; CLEANUP='1'; AGENT_BINARY_SHA256='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'; ALLOW_HTTP='1'; MASTER_URL='http://127.0.0.1:8080'"
}

expect_full_lifecycle_required_rejects_unverified_agent_binary_hash() {
    reset_smoke_state
    FULL_LIFECYCLE_REQUIRED="1"
    REINSTALL_AFTER_CREATE="1"
    POWER_CYCLE_AFTER_CREATE="1"
    CLEANUP="1"
    AGENT_BINARY_SHA256="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    AGENT_BINARY_SHA256_VERIFIED="0"
    local marker
    marker="$(mktemp)"

    validate_agent_config() {
        echo "agent-config" >> "$marker"
    }
    validate_agent_doctor() {
        echo "agent-doctor" >> "$marker"
    }
    validate_host_tools() {
        echo "host-tools" >> "$marker"
    }

    local output
    if output="$(main 2>&1)"; then
        echo "full-lifecycle smoke accepted an unverified agent binary hash" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        unset -f validate_agent_config validate_agent_doctor validate_host_tools
        exit 1
    fi
    unset -f validate_agent_config validate_agent_doctor validate_host_tools

    case "$output" in
        *"FULL_LIFECYCLE_REQUIRED requires verified agent binary SHA-256"*) ;;
        *)
            echo "full-lifecycle smoke did not explain the missing hash verification" >&2
            printf '%s\n' "$output" >&2
            cat "$marker" >&2
            rm -f "$marker"
            exit 1
            ;;
    esac
    if grep -q '^host-tools$' "$marker"; then
        echo "full-lifecycle smoke reached host checks before proving agent binary hash verification" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    rm -f "$marker"
}

expect_smoke_audit_logs_valid() {
    reset_smoke_state
    local create_task_id="11111111-1111-1111-1111-111111111111"
    local vm_id="22222222-2222-2222-2222-222222222222"
    api() {
        case "$1:$2" in
            "GET:/api/admin/audit-logs") smoke_audit_logs_json "$create_task_id" "$vm_id" ;;
            *)
                echo "unexpected api call in audit log success test: $*" >&2
                return 45
                ;;
        esac
    }

    verify_smoke_audit_logs "$vm_id" "$create_task_id" "" "" "" "" ""
    restore_api
}

expect_smoke_audit_logs_reject_missing_status_update() {
    reset_smoke_state
    local create_task_id="11111111-1111-1111-1111-111111111111"
    local vm_id="22222222-2222-2222-2222-222222222222"
    api() {
        case "$1:$2" in
            "GET:/api/admin/audit-logs") smoke_audit_logs_json "$create_task_id" "$vm_id" "0" ;;
            *)
                echo "unexpected api call in audit log failure test: $*" >&2
                return 45
                ;;
        esac
    }

    if ( verify_smoke_audit_logs "$vm_id" "$create_task_id" "" "" "" "" "" ) >/dev/null 2>&1; then
        echo "smoke audit verification accepted missing task.status_update" >&2
        restore_api
        exit 1
    fi

    restore_api
}

expect_action_response_rejects_mismatched_vm_id_before_polling() {
    reset_smoke_state
    local vm_id="11111111-2222-3333-4444-555555555555"
    local other_vm_id="99999999-2222-3333-4444-555555555555"
    local stop_response_task_id="dddddddd-dddd-dddd-dddd-dddddddddddd"
    local marker
    marker="$(mktemp)"

    api() {
        case "$1:$2" in
            "POST:/api/admin/tasks/stop-vm")
                echo "stop-task:${3:-}" >> "$marker"
                printf '{"id":"%s","kind":{"vm_id":"%s"}}' "$stop_response_task_id" "$other_vm_id"
                ;;
            *)
                echo "unexpected api call in mismatched action response test: $*" >&2
                return 45
                ;;
        esac
    }
    wait_for_task() {
        echo "wait:$1" >> "$marker"
    }

    local output
    if output="$(queue_vm_action_task stop-vm "$vm_id" 2>&1 >/dev/null)"; then
        echo "action task accepted a response for a different vm_id" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        unset -f api wait_for_task
        exit 1
    fi

    unset -f api wait_for_task

    case "$output" in
        *"stop-vm response vm_id did not match requested VM"*) ;;
        *)
            echo "mismatched action response failure did not explain the rejected VM id" >&2
            printf '%s\n' "$output" >&2
            cat "$marker" >&2
            rm -f "$marker"
            exit 1
            ;;
    esac

    if grep -q '^wait:' "$marker"; then
        echo "mismatched action response reached task polling" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    rm -f "$marker"
}

expect_power_action_queue_failure_attempts_cleanup() {
    reset_smoke_state
    POWER_CYCLE_AFTER_CREATE="1"
    local vm_id="11111111-2222-3333-4444-555555555555"
    local other_vm_id="99999999-2222-3333-4444-555555555555"
    local create_response_task_id="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    local stop_response_task_id="dddddddd-dddd-dddd-dddd-dddddddddddd"
    local delete_response_task_id="cccccccc-cccc-cccc-cccc-cccccccccccc"
    local marker
    marker="$(mktemp)"
    stub_node_ready

    validate_host_tools() {
        echo "host-tools" >> "$marker"
    }
    validate_agent_config() {
        echo "agent-config" >> "$marker"
    }
    validate_agent_doctor() {
        echo "agent-doctor" >> "$marker"
    }
    validate_host_paths() {
        echo "host-paths" >> "$marker"
    }
    validate_base_image_format() {
        echo "base-image-format" >> "$marker"
    }
    curl() {
        for arg in "$@"; do
            if [ "$arg" = "${MASTER_URL%/}/healthz" ]; then
                echo "healthz" >> "$marker"
                return 0
            fi
        done
        echo "unexpected curl call in power-action-queue-failure test: $*" >&2
        return 44
    }
    ensure_image_registered() {
        echo "image-registered" >> "$marker"
    }
    api() {
        case "$1:$2" in
            "POST:/api/admin/tasks/create-vm")
                echo "create-task" >> "$marker"
                printf '{"id":"%s","kind":{"vm_id":"%s"}}' "$create_response_task_id" "$vm_id"
                ;;
            "GET:/api/admin/tasks/${create_response_task_id}/logs")
                echo "create-logs" >> "$marker"
                task_started_logs_json "$create_response_task_id"
                ;;
            "POST:/api/admin/tasks/stop-vm")
                echo "stop-task:${3:-}" >> "$marker"
                printf '{"id":"%s","kind":{"vm_id":"%s"}}' "$stop_response_task_id" "$other_vm_id"
                ;;
            "POST:/api/admin/tasks/delete-vm")
                echo "delete-task:${3:-}" >> "$marker"
                printf '{"id":"%s","kind":{"vm_id":"%s"}}' "$delete_response_task_id" "$vm_id"
                ;;
            *)
                echo "unexpected api call in power-action-queue-failure test: $*" >&2
                return 45
                ;;
        esac
    }
    wait_for_task() {
        echo "wait:$1" >> "$marker"
    }
    verify_created_vm_on_host() {
        echo "verify-created:$1" >> "$marker"
    }
    verify_stopped_vm_on_host() {
        echo "verify-stopped:$1" >> "$marker"
    }
    verify_deleted_vm_on_host() {
        echo "verify-deleted:$1" >> "$marker"
    }

    local output
    if output="$(main 2>&1)"; then
        echo "power-cycle smoke path succeeded after action queue failure" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl \
            ensure_image_registered api wait_for_task verify_created_vm_on_host \
            verify_stopped_vm_on_host verify_deleted_vm_on_host
        exit 1
    fi

    unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl \
        ensure_image_registered api wait_for_task verify_created_vm_on_host \
        verify_stopped_vm_on_host verify_deleted_vm_on_host

    case "$output" in
        *"$ADMIN_TOKEN"*)
            echo "power action cleanup output leaked admin token" >&2
            printf '%s\n' "$output" >&2
            rm -f "$marker"
            exit 1
            ;;
    esac

    if ! grep -q "^stop-task:" "$marker" ||
        ! grep -q "^delete-task:" "$marker" ||
        ! grep -q "^wait:${delete_response_task_id}$" "$marker" ||
        ! grep -q "^verify-deleted:${vm_id}$" "$marker"; then
        echo "power action queue failure did not attempt cleanup" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    if grep '^delete-task:' "$marker" | grep -vq "\"vm_id\":\"$vm_id\""; then
        echo "cleanup payload did not include the created vm_id" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    rm -f "$marker"
}

expect_reinstall_after_create_posts_reinstall_and_verifies_host() {
    reset_smoke_state
    REINSTALL_AFTER_CREATE="1"
    local vm_id="11111111-2222-3333-4444-555555555555"
    local create_response_task_id="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    local reinstall_response_task_id="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    local delete_response_task_id="cccccccc-cccc-cccc-cccc-cccccccccccc"
    local marker
    marker="$(mktemp)"
    stub_node_ready

    validate_host_tools() {
        echo "host-tools" >> "$marker"
    }
    validate_agent_config() {
        echo "agent-config" >> "$marker"
    }
    validate_agent_doctor() {
        echo "agent-doctor" >> "$marker"
    }
    validate_host_paths() {
        echo "host-paths" >> "$marker"
    }
    validate_base_image_format() {
        echo "base-image-format" >> "$marker"
    }
    curl() {
        for arg in "$@"; do
            if [ "$arg" = "${MASTER_URL%/}/healthz" ]; then
                echo "healthz" >> "$marker"
                return 0
            fi
        done
        echo "unexpected curl call in reinstall smoke test: $*" >&2
        return 44
    }
    ensure_image_registered() {
        echo "image-registered" >> "$marker"
    }
    api() {
        case "$1:$2" in
            "POST:/api/admin/tasks/create-vm")
                echo "create-task" >> "$marker"
                printf '{"id":"%s","kind":{"vm_id":"%s"}}' "$create_response_task_id" "$vm_id"
                ;;
            "GET:/api/admin/tasks/${create_response_task_id}/logs")
                echo "create-logs" >> "$marker"
                task_started_logs_json "$create_response_task_id"
                ;;
            "POST:/api/admin/tasks/reinstall-vm")
                echo "reinstall-task:${3:-}" >> "$marker"
                printf '{"id":"%s","kind":{"vm_id":"%s"}}' "$reinstall_response_task_id" "$vm_id"
                ;;
            "GET:/api/admin/tasks/${reinstall_response_task_id}/logs")
                echo "reinstall-logs" >> "$marker"
                task_started_logs_json "$reinstall_response_task_id"
                ;;
            "POST:/api/admin/tasks/delete-vm")
                echo "delete-task:${3:-}" >> "$marker"
                printf '{"id":"%s","kind":{"vm_id":"%s"}}' "$delete_response_task_id" "$vm_id"
                ;;
            "GET:/api/admin/tasks/${delete_response_task_id}/logs")
                echo "delete-logs" >> "$marker"
                task_started_logs_json "$delete_response_task_id"
                ;;
            "GET:/api/admin/audit-logs")
                echo "audit-logs" >> "$marker"
                smoke_audit_logs_json "$create_response_task_id" "$vm_id" "1" \
                    "task.reinstall_vm" "$reinstall_response_task_id" "reinstall_vm" \
                    "task.delete_vm" "$delete_response_task_id" "delete_vm"
                ;;
            *)
                echo "unexpected api call in reinstall smoke test: $*" >&2
                return 45
                ;;
        esac
    }
    wait_for_task() {
        echo "wait:$1" >> "$marker"
    }
    verify_created_vm_on_host() {
        echo "verify-created:$1" >> "$marker"
    }
    verify_deleted_vm_on_host() {
        echo "verify-deleted:$1" >> "$marker"
    }

    local output
    if ! output="$(main 2>&1)"; then
        echo "reinstall smoke path failed: $output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl \
            ensure_image_registered api wait_for_task verify_created_vm_on_host \
            verify_deleted_vm_on_host
        exit 1
    fi

    unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl \
        ensure_image_registered api wait_for_task verify_created_vm_on_host \
        verify_deleted_vm_on_host

    [ "$(printf '%s' "$output" | json_get reinstall_task_id)" = "$reinstall_response_task_id" ] || {
        echo "smoke output did not include reinstall_task_id" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    }
    [ "$(printf '%s' "$output" | json_get task_logs_verified)" = "True" ] || {
        echo "smoke output did not confirm task log verification" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    }
    [ "$(printf '%s' "$output" | json_get audit_logs_verified)" = "True" ] || {
        echo "smoke output did not confirm audit log verification" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    }
    [ "$(printf '%s' "$output" | json_get lifecycle_coverage.create_vm)" = "True" ] &&
        [ "$(printf '%s' "$output" | json_get lifecycle_coverage.delete_vm)" = "True" ] &&
        [ "$(printf '%s' "$output" | json_get lifecycle_coverage.reinstall_vm)" = "True" ] &&
        [ "$(printf '%s' "$output" | json_get lifecycle_coverage.power_cycle)" = "False" ] || {
        echo "smoke output did not report reinstall lifecycle coverage" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    }

    if [ "$(grep -c '^verify-created:' "$marker")" -ne 2 ] ||
        ! grep -q "^wait:${reinstall_response_task_id}$" "$marker" ||
        ! grep -q '^reinstall-task:' "$marker" ||
        ! grep -q '^audit-logs$' "$marker"; then
        echo "reinstall smoke path did not wait and verify as expected" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    if grep '^reinstall-task:' "$marker" | grep -vq "\"vm_id\":\"$vm_id\""; then
        echo "reinstall payload did not include the created vm_id" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    rm -f "$marker"
}

expect_power_cycle_after_create_posts_actions_and_verifies_host() {
    reset_smoke_state
    POWER_CYCLE_AFTER_CREATE="1"
    local vm_id="11111111-2222-3333-4444-555555555555"
    local create_response_task_id="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    local stop_response_task_id="dddddddd-dddd-dddd-dddd-dddddddddddd"
    local start_response_task_id="eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
    local reboot_response_task_id="ffffffff-ffff-ffff-ffff-ffffffffffff"
    local delete_response_task_id="cccccccc-cccc-cccc-cccc-cccccccccccc"
    local marker
    marker="$(mktemp)"
    stub_node_ready

    validate_host_tools() {
        echo "host-tools" >> "$marker"
    }
    validate_agent_config() {
        echo "agent-config" >> "$marker"
    }
    validate_agent_doctor() {
        echo "agent-doctor" >> "$marker"
    }
    validate_host_paths() {
        echo "host-paths" >> "$marker"
    }
    validate_base_image_format() {
        echo "base-image-format" >> "$marker"
    }
    curl() {
        for arg in "$@"; do
            if [ "$arg" = "${MASTER_URL%/}/healthz" ]; then
                echo "healthz" >> "$marker"
                return 0
            fi
        done
        echo "unexpected curl call in power-cycle smoke test: $*" >&2
        return 44
    }
    ensure_image_registered() {
        echo "image-registered" >> "$marker"
    }
    api() {
        case "$1:$2" in
            "POST:/api/admin/tasks/create-vm")
                echo "create-task" >> "$marker"
                printf '{"id":"%s","kind":{"vm_id":"%s"}}' "$create_response_task_id" "$vm_id"
                ;;
            "GET:/api/admin/tasks/${create_response_task_id}/logs")
                echo "create-logs" >> "$marker"
                task_started_logs_json "$create_response_task_id"
                ;;
            "POST:/api/admin/tasks/stop-vm")
                echo "stop-task:${3:-}" >> "$marker"
                printf '{"id":"%s","kind":{"vm_id":"%s"}}' "$stop_response_task_id" "$vm_id"
                ;;
            "GET:/api/admin/tasks/${stop_response_task_id}/logs")
                echo "stop-logs" >> "$marker"
                task_started_logs_json "$stop_response_task_id"
                ;;
            "POST:/api/admin/tasks/start-vm")
                echo "start-task:${3:-}" >> "$marker"
                printf '{"id":"%s","kind":{"vm_id":"%s"}}' "$start_response_task_id" "$vm_id"
                ;;
            "GET:/api/admin/tasks/${start_response_task_id}/logs")
                echo "start-logs" >> "$marker"
                task_started_logs_json "$start_response_task_id"
                ;;
            "POST:/api/admin/tasks/reboot-vm")
                echo "reboot-task:${3:-}" >> "$marker"
                printf '{"id":"%s","kind":{"vm_id":"%s"}}' "$reboot_response_task_id" "$vm_id"
                ;;
            "GET:/api/admin/tasks/${reboot_response_task_id}/logs")
                echo "reboot-logs" >> "$marker"
                task_started_logs_json "$reboot_response_task_id"
                ;;
            "POST:/api/admin/tasks/delete-vm")
                echo "delete-task:${3:-}" >> "$marker"
                printf '{"id":"%s","kind":{"vm_id":"%s"}}' "$delete_response_task_id" "$vm_id"
                ;;
            "GET:/api/admin/tasks/${delete_response_task_id}/logs")
                echo "delete-logs" >> "$marker"
                task_started_logs_json "$delete_response_task_id"
                ;;
            "GET:/api/admin/audit-logs")
                echo "audit-logs" >> "$marker"
                smoke_audit_logs_json "$create_response_task_id" "$vm_id" "1" \
                    "task.stop_vm" "$stop_response_task_id" "stop_vm" \
                    "task.start_vm" "$start_response_task_id" "start_vm" \
                    "task.reboot_vm" "$reboot_response_task_id" "reboot_vm" \
                    "task.delete_vm" "$delete_response_task_id" "delete_vm"
                ;;
            *)
                echo "unexpected api call in power-cycle smoke test: $*" >&2
                return 45
                ;;
        esac
    }
    wait_for_task() {
        echo "wait:$1" >> "$marker"
    }
    verify_created_vm_on_host() {
        echo "verify-running:$1" >> "$marker"
    }
    verify_stopped_vm_on_host() {
        echo "verify-stopped:$1" >> "$marker"
    }
    verify_deleted_vm_on_host() {
        echo "verify-deleted:$1" >> "$marker"
    }

    local output
    if ! output="$(main 2>&1)"; then
        echo "power-cycle smoke path failed: $output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl \
            ensure_image_registered api wait_for_task verify_created_vm_on_host \
            verify_stopped_vm_on_host verify_deleted_vm_on_host
        exit 1
    fi

    unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl \
        ensure_image_registered api wait_for_task verify_created_vm_on_host \
        verify_stopped_vm_on_host verify_deleted_vm_on_host

    [ "$(printf '%s' "$output" | json_get stop_task_id)" = "$stop_response_task_id" ] || {
        echo "smoke output did not include stop_task_id" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    }
    [ "$(printf '%s' "$output" | json_get start_task_id)" = "$start_response_task_id" ] || {
        echo "smoke output did not include start_task_id" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    }
    [ "$(printf '%s' "$output" | json_get reboot_task_id)" = "$reboot_response_task_id" ] || {
        echo "smoke output did not include reboot_task_id" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    }
    [ "$(printf '%s' "$output" | json_get task_logs_verified)" = "True" ] || {
        echo "smoke output did not confirm task log verification" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    }
    [ "$(printf '%s' "$output" | json_get audit_logs_verified)" = "True" ] || {
        echo "smoke output did not confirm audit log verification" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    }
    [ "$(printf '%s' "$output" | json_get lifecycle_coverage.create_vm)" = "True" ] &&
        [ "$(printf '%s' "$output" | json_get lifecycle_coverage.delete_vm)" = "True" ] &&
        [ "$(printf '%s' "$output" | json_get lifecycle_coverage.reinstall_vm)" = "False" ] &&
        [ "$(printf '%s' "$output" | json_get lifecycle_coverage.power_cycle)" = "True" ] || {
        echo "smoke output did not report power-cycle lifecycle coverage" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    }

    if [ "$(grep -c '^verify-running:' "$marker")" -ne 3 ] ||
        [ "$(grep -c '^verify-stopped:' "$marker")" -ne 1 ] ||
        ! grep -q "^wait:${stop_response_task_id}$" "$marker" ||
        ! grep -q "^wait:${start_response_task_id}$" "$marker" ||
        ! grep -q "^wait:${reboot_response_task_id}$" "$marker" ||
        ! grep -q '^audit-logs$' "$marker"; then
        echo "power-cycle smoke path did not wait and verify as expected" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    for action in stop start reboot; do
        if grep "^${action}-task:" "$marker" | grep -vq "\"vm_id\":\"$vm_id\""; then
            echo "${action} payload did not include the created vm_id" >&2
            cat "$marker" >&2
            rm -f "$marker"
            exit 1
        fi
    done

    rm -f "$marker"
}

expect_full_lifecycle_required_runs_all_lifecycle_actions() {
    reset_smoke_state
    REINSTALL_AFTER_CREATE="1"
    POWER_CYCLE_AFTER_CREATE="1"
    FULL_LIFECYCLE_REQUIRED="1"
    IP_POOL_ID="99999999-aaaa-bbbb-cccc-dddddddddddd"
    AGENT_BINARY_SHA256="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    local vm_id="11111111-2222-3333-4444-555555555555"
    local create_response_task_id="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    local reinstall_response_task_id="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    local stop_response_task_id="dddddddd-dddd-dddd-dddd-dddddddddddd"
    local start_response_task_id="eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
    local reboot_response_task_id="ffffffff-ffff-ffff-ffff-ffffffffffff"
    local delete_response_task_id="cccccccc-cccc-cccc-cccc-cccccccccccc"
    local assigned_ip="192.0.2.2"
    local assigned_ip_prefix="29"
    local assigned_gateway_ip="192.0.2.1"
    local marker
    marker="$(mktemp)"
    stub_node_ready

    validate_host_tools() {
        echo "host-tools" >> "$marker"
    }
    validate_agent_config() {
        echo "agent-config" >> "$marker"
    }
    validate_agent_doctor() {
        AGENT_BINARY_SHA256_VERIFIED="1"
        echo "agent-doctor" >> "$marker"
    }
    validate_host_paths() {
        echo "host-paths" >> "$marker"
    }
    validate_base_image_format() {
        BASE_IMAGE_FORMAT="qcow2"
        echo "base-image-format" >> "$marker"
    }
    curl() {
        for arg in "$@"; do
            if [ "$arg" = "${MASTER_URL%/}/healthz" ]; then
                echo "healthz" >> "$marker"
                return 0
            fi
        done
        echo "unexpected curl call in full-lifecycle smoke test: $*" >&2
        return 44
    }
    ensure_image_registered() {
        echo "image-registered" >> "$marker"
    }
    api() {
        case "$1:$2" in
            "POST:/api/admin/tasks/create-vm")
                echo "create-task" >> "$marker"
                printf '{"id":"%s","kind":{"vm_id":"%s","assigned_ip":"%s","assigned_ip_prefix":%s,"assigned_gateway_ip":"%s"}}' \
                    "$create_response_task_id" "$vm_id" "$assigned_ip" "$assigned_ip_prefix" "$assigned_gateway_ip"
                ;;
            "GET:/api/admin/tasks/${create_response_task_id}/logs")
                echo "create-logs" >> "$marker"
                task_started_logs_json "$create_response_task_id"
                ;;
            "POST:/api/admin/tasks/reinstall-vm")
                echo "reinstall-task:${3:-}" >> "$marker"
                printf '{"id":"%s","kind":{"vm_id":"%s"}}' "$reinstall_response_task_id" "$vm_id"
                ;;
            "GET:/api/admin/tasks/${reinstall_response_task_id}/logs")
                echo "reinstall-logs" >> "$marker"
                task_started_logs_json "$reinstall_response_task_id"
                ;;
            "POST:/api/admin/tasks/stop-vm")
                echo "stop-task:${3:-}" >> "$marker"
                printf '{"id":"%s","kind":{"vm_id":"%s"}}' "$stop_response_task_id" "$vm_id"
                ;;
            "GET:/api/admin/tasks/${stop_response_task_id}/logs")
                echo "stop-logs" >> "$marker"
                task_started_logs_json "$stop_response_task_id"
                ;;
            "POST:/api/admin/tasks/start-vm")
                echo "start-task:${3:-}" >> "$marker"
                printf '{"id":"%s","kind":{"vm_id":"%s"}}' "$start_response_task_id" "$vm_id"
                ;;
            "GET:/api/admin/tasks/${start_response_task_id}/logs")
                echo "start-logs" >> "$marker"
                task_started_logs_json "$start_response_task_id"
                ;;
            "POST:/api/admin/tasks/reboot-vm")
                echo "reboot-task:${3:-}" >> "$marker"
                printf '{"id":"%s","kind":{"vm_id":"%s"}}' "$reboot_response_task_id" "$vm_id"
                ;;
            "GET:/api/admin/tasks/${reboot_response_task_id}/logs")
                echo "reboot-logs" >> "$marker"
                task_started_logs_json "$reboot_response_task_id"
                ;;
            "POST:/api/admin/tasks/delete-vm")
                echo "delete-task:${3:-}" >> "$marker"
                printf '{"id":"%s","kind":{"vm_id":"%s"}}' "$delete_response_task_id" "$vm_id"
                ;;
            "GET:/api/admin/tasks/${delete_response_task_id}/logs")
                echo "delete-logs" >> "$marker"
                task_started_logs_json "$delete_response_task_id"
                ;;
            "GET:/api/admin/audit-logs")
                echo "audit-logs" >> "$marker"
                smoke_audit_logs_json "$create_response_task_id" "$vm_id" "1" \
                    "task.reinstall_vm" "$reinstall_response_task_id" "reinstall_vm" \
                    "task.stop_vm" "$stop_response_task_id" "stop_vm" \
                    "task.start_vm" "$start_response_task_id" "start_vm" \
                    "task.reboot_vm" "$reboot_response_task_id" "reboot_vm" \
                    "task.delete_vm" "$delete_response_task_id" "delete_vm"
                ;;
            *)
                echo "unexpected api call in full-lifecycle smoke test: $*" >&2
                return 45
                ;;
        esac
    }
    wait_for_task() {
        echo "wait:$1" >> "$marker"
    }
    verify_created_vm_on_host() {
        echo "verify-running:$1" >> "$marker"
    }
    verify_stopped_vm_on_host() {
        echo "verify-stopped:$1" >> "$marker"
    }
    verify_deleted_vm_on_host() {
        echo "verify-deleted:$1" >> "$marker"
    }

    local output
    if ! output="$(main 2>&1)"; then
        echo "full-lifecycle smoke path failed: $output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl \
            ensure_image_registered api wait_for_task verify_created_vm_on_host \
            verify_stopped_vm_on_host verify_deleted_vm_on_host
        exit 1
    fi

    unset -f validate_host_tools validate_agent_config validate_agent_doctor validate_host_paths validate_base_image_format curl \
        ensure_image_registered api wait_for_task verify_created_vm_on_host \
        verify_stopped_vm_on_host verify_deleted_vm_on_host

    [ "$(printf '%s' "$output" | json_get full_lifecycle_required)" = "True" ] &&
        [ "$(printf '%s' "$output" | json_get agent_config_registered)" = "True" ] &&
        [ "$(printf '%s' "$output" | json_get host_preflight_verified)" = "True" ] &&
        [ "$(printf '%s' "$output" | json_get master_health_verified)" = "True" ] &&
        [ "$(printf '%s' "$output" | json_get master_url)" = "$MASTER_URL" ] &&
        [ "$(printf '%s' "$output" | json_get allow_http)" = "False" ] &&
        [ "$(printf '%s' "$output" | json_get ca_cert_configured)" = "False" ] &&
        [ "$(printf '%s' "$output" | json_get curl_timeout_seconds)" = "$CURL_TIMEOUT_SECONDS" ] &&
        [ "$(printf '%s' "$output" | json_get node_ready_verified)" = "True" ] &&
        [ "$(printf '%s' "$output" | json_get agent_binary_sha256_verified)" = "True" ] &&
        [ "$(printf '%s' "$output" | json_get agent_binary_sha256)" = "$AGENT_BINARY_SHA256" ] &&
        [ "$(printf '%s' "$output" | json_get node_id)" = "$NODE_ID" ] &&
        [ "$(printf '%s' "$output" | json_get image_file)" = "$IMAGE_FILE" ] &&
        [ "$(printf '%s' "$output" | json_get image_name)" = "$IMAGE_NAME" ] &&
        [ "$(printf '%s' "$output" | json_get data_dir)" = "$DATA_DIR" ] &&
        [ "$(printf '%s' "$output" | json_get image_dir)" = "$IMAGE_DIR" ] &&
        [ "$(printf '%s' "$output" | json_get libvirt_network_name)" = "$LIBVIRT_NETWORK_NAME" ] &&
        [ "$(printf '%s' "$output" | json_get libvirt_bridge_name)" = "$LIBVIRT_BRIDGE_NAME" ] &&
        [ "$(printf '%s' "$output" | json_get base_image_format)" = "qcow2" ] &&
        [ "$(printf '%s' "$output" | json_get cpu_cores)" = "$CPU_CORES" ] &&
        [ "$(printf '%s' "$output" | json_get memory_mb)" = "$MEMORY_MB" ] &&
        [ "$(printf '%s' "$output" | json_get disk_gb)" = "$DISK_GB" ] &&
        [ "$(printf '%s' "$output" | json_get assigned_ip)" = "$assigned_ip" ] &&
        [ "$(printf '%s' "$output" | json_get assigned_ip_prefix)" = "$assigned_ip_prefix" ] &&
        [ "$(printf '%s' "$output" | json_get assigned_gateway_ip)" = "$assigned_gateway_ip" ] &&
        [ "$(printf '%s' "$output" | json_get lifecycle_coverage.create_vm)" = "True" ] &&
        [ "$(printf '%s' "$output" | json_get lifecycle_coverage.delete_vm)" = "True" ] &&
        [ "$(printf '%s' "$output" | json_get lifecycle_coverage.reinstall_vm)" = "True" ] &&
        [ "$(printf '%s' "$output" | json_get lifecycle_coverage.power_cycle)" = "True" ] || {
        echo "full-lifecycle smoke output did not prove required lifecycle coverage and non-secret run context" >&2
        printf '%s\n' "$output" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    }

    if [ "$(grep -c '^verify-running:' "$marker")" -ne 4 ] ||
        [ "$(grep -c '^verify-stopped:' "$marker")" -ne 1 ] ||
        ! grep -q '^audit-logs$' "$marker"; then
        echo "full-lifecycle smoke path did not verify every lifecycle state" >&2
        cat "$marker" >&2
        rm -f "$marker"
        exit 1
    fi

    rm -f "$marker"
}

expect_help_includes_final_acceptance_command

expect_valid true
expect_valid eval "MASTER_URL='http://127.0.0.1:8080'; ALLOW_HTTP='1'"
expect_valid eval "MASTER_URL='http://localhost:8080'; ALLOW_HTTP='1'"
expect_invalid eval "MASTER_URL='http://panel.example.com'; ALLOW_HTTP='1'"

for unsafe_url in \
    "http://127.0.0.1:8080" \
    "https://user:secret@panel.example.com" \
    "https://panel.example.com?token=secret" \
    "https://panel.example.com/#fragment" \
    "https://panel.example.com/." \
    "https://panel.example.com/.." \
    "https://panel.example.com/install/../api" \
    "https://panel.example.com/install/%2e%2e/api" \
    "https://panel.example.com/install/%2E/api" \
    "https://panel.example.com/install%2f..%2fapi" \
    "https://panel.example.com/install%5c..%5capi" \
    "https://panel.example.com/install%0aapi" \
    "https://panel.example.com/install%7fapi" \
    "https://panel.example.com/space here" \
    "https://panel.example.com/\\path" \
    "https://panel.example.com/\`cmd\`" \
    "https://:8443" \
    "https://[::1" \
    "https://[::1]extra" \
    "https://2001:db8::1" \
    "https://panel.example.com:abc" \
    "https://panel.example.com:0" \
    "https://panel.example.com:65536" \
    "https://panel.example.com:99999" \
    "https://panel%0a.example.com" \
    "https://panel%7f.example.com" \
    "https://panel%2f.example.com" \
    "https://panel%5c.example.com" \
    "https://"
do
    expect_invalid eval "MASTER_URL='$unsafe_url'"
done

expect_invalid eval "MASTER_URL='http://localhost:abc'; ALLOW_HTTP='1'"
expect_invalid eval "MASTER_URL='http://localhost:0'; ALLOW_HTTP='1'"
expect_invalid eval "MASTER_URL='http://localhost:65536'; ALLOW_HTTP='1'"
expect_invalid eval "MASTER_URL=\$'https://panel.example.com/\\ahealth'"

for unsafe_data_dir in \
    "/" \
    "relative" \
    "/var/lib/vps-agent/../host"
do
    expect_invalid eval "DATA_DIR='$unsafe_data_dir'"
done

expect_invalid eval "DATA_DIR='/var/lib/vps-agent'; IMAGE_DIR='/tmp/vps-agent-images'"
expect_valid eval "DATA_DIR='/var/lib/vps-agent'; IMAGE_DIR='/var/lib/vps-agent/images'"
expect_invalid eval "DATA_DIR=\$'/var/lib/vps-agent\\a'; IMAGE_DIR=\$'/var/lib/vps-agent\\a/images'"

for unsafe_value in \
    "CPU_CORES=0" \
    "CPU_CORES=33" \
    "CPU_CORES=999999999999999999999999" \
    "MEMORY_MB=127" \
    "DISK_GB=0" \
    "TIMEOUT_SECONDS=0" \
    "TIMEOUT_SECONDS=999999999999999999999999" \
    "POLL_SECONDS=0" \
    "TIMEOUT_SECONDS=10; POLL_SECONDS=11" \
    "CURL_TIMEOUT_SECONDS=0" \
    "CURL_TIMEOUT_SECONDS=3601" \
    "CLEANUP=2" \
    "ALLOW_HTTP=2" \
    "FULL_LIFECYCLE_REQUIRED=2" \
    "REINSTALL_AFTER_CREATE=2" \
    "POWER_CYCLE_AFTER_CREATE=2" \
    "NODE_ID=not-a-uuid" \
    "NODE_ID=zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz" \
    "IP_POOL_ID=not-a-uuid" \
    "IP_POOL_ID=zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz" \
    "IP_POOL_ID=99999999-aaaa-bbbb-cccc-dddddddddddd; IP_POOL_CIDR=192.0.2.0/29; IP_POOL_GATEWAY=192.0.2.1" \
    "IP_POOL_NAME='bad pool'" \
    "IP_POOL_NAME='bad/pool'" \
    "IP_POOL_CIDR=192.0.2.0" \
    "IP_POOL_CIDR=192.0.2.0/31; IP_POOL_GATEWAY=192.0.2.1" \
    "IP_POOL_CIDR=192.0.2.0/29" \
    "IP_POOL_GATEWAY=192.0.2.1" \
    "IP_POOL_CIDR=192.0.2.0/29; IP_POOL_GATEWAY=198.51.100.1" \
    "PLAN_ID=not-a-uuid" \
    "PLAN_ID=zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz" \
    "PLAN_ID=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee; PLAN_SLUG=kvm-smoke-plan" \
    "PLAN_SLUG='bad plan'" \
    "PLAN_SLUG='bad/plan'" \
    "PLAN_SLUG=kvm-smoke-plan; PLAN_NAME=''" \
    "PLAN_SLUG=kvm-smoke-plan; PLAN_NAME='bad/plan'" \
    "VM_NAME='bad name'" \
    "SSH_PUBLIC_KEY='-----BEGIN OPENSSH PRIVATE KEY-----'" \
    "SSH_PUBLIC_KEY='ssh-ed25519 short'" \
    "SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb bad;comment'" \
    "SSH_PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb bad\$comment'" \
    "IMAGE_NAME='bad/name'" \
    "IMAGE_NAME='bad.name'" \
    "LIBVIRT_NETWORK_NAME='default;reboot'" \
    "LIBVIRT_BRIDGE_NAME='../virbr0'" \
    "IMAGE_FILE='../debian.qcow2'" \
    "IMAGE_FILE='debian.'" \
    "AGENT_CONFIG_PATH='relative.toml'" \
    "AGENT_CONFIG_PATH='/etc/vps-agent/../agent.toml'" \
    "AGENT_CONFIG_PATH='/etc/vps-agent/agent bad.toml'" \
    "AGENT_BINARY_PATH='relative/vps-agent'" \
    "AGENT_BINARY_PATH='/usr/local/bin/../vps-agent'" \
    "AGENT_BINARY_PATH='/usr/local/bin/vps agent'" \
    "AGENT_BINARY_SHA256_PATH='relative/agent.sha256'" \
    "AGENT_BINARY_SHA256_PATH='/etc/vps-agent/../agent.sha256'" \
    "AGENT_BINARY_SHA256_PATH='/etc/vps-agent/agent hash.sha256'"
do
    expect_invalid eval "$unsafe_value"
done

expect_valid eval "AGENT_BINARY_SHA256='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'"
expect_invalid eval "AGENT_BINARY_SHA256='not-a-sha256'"
expect_invalid eval "AGENT_BINARY_SHA256='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg'"
expect_full_lifecycle_loads_persisted_agent_binary_sha256
expect_persisted_agent_binary_sha256_file_rejects_invalid_digest
expect_persisted_agent_binary_sha256_file_rejects_loose_permissions
expect_persisted_agent_binary_sha256_file_rejects_symlink

for unsafe_admin_token in \
    "bad token" \
    "bad\"token" \
    "bad\\token" \
    "bad\`token"
do
    expect_invalid eval "ADMIN_TOKEN='$unsafe_admin_token'"
done
expect_invalid eval "ADMIN_TOKEN=\$'bad\\atoken'"
expect_invalid eval "ADMIN_TOKEN='$(printf 'a%.0s' {1..257})'"

expect_host_valid true
expect_host_invalid eval "rm -f \"\${IMAGE_DIR}/\${IMAGE_FILE}\""
expect_host_invalid eval "mv \"\$DATA_DIR\" \"\${HOST_TMP_DIR}/real-data\"; ln -s \"real-data\" \"\$DATA_DIR\""
expect_host_invalid eval "mv \"\$IMAGE_DIR\" \"\${DATA_DIR}/real-images\"; ln -s \"real-images\" \"\$IMAGE_DIR\""
expect_host_invalid eval "mv \"\${IMAGE_DIR}/\${IMAGE_FILE}\" \"\${IMAGE_DIR}/real-\${IMAGE_FILE}\"; ln -s \"real-\${IMAGE_FILE}\" \"\${IMAGE_DIR}/\${IMAGE_FILE}\""
expect_host_invalid eval "chmod 0755 \"\$DATA_DIR\""
expect_host_invalid eval "chmod 0755 \"\$IMAGE_DIR\""
expect_host_invalid eval "chmod 0770 \"\$DATA_DIR\""
expect_host_invalid eval "chmod 0770 \"\$IMAGE_DIR\""
expect_host_invalid eval "chmod 0660 \"\${IMAGE_DIR}/\${IMAGE_FILE}\""

expect_ca_cert_valid true
expect_ca_cert_invalid eval "rm -f \"\$MASTER_CA_CERT_PATH\""
expect_ca_cert_invalid eval "chmod 0660 \"\$MASTER_CA_CERT_PATH\""
expect_ca_cert_invalid eval "mv \"\$MASTER_CA_CERT_PATH\" \"\${CA_TMP_DIR}/master-ca-real.pem\"; ln -s \"master-ca-real.pem\" \"\$MASTER_CA_CERT_PATH\""
expect_invalid eval "MASTER_CA_CERT_PATH='relative.pem'"
expect_invalid eval "MASTER_CA_CERT_PATH='/etc/ssl/certs/../master-ca.pem'"
expect_invalid eval "MASTER_CA_CERT_PATH='/etc/ssl/certs/master ca.pem'"
expect_invalid eval "MASTER_CA_CERT_PATH=\$'/etc/ssl/certs/master\\a.pem'"

expect_agent_config_valid true
expect_agent_config_valid eval "PRECHECK_ONLY='1'; NODE_ID=''"
expect_agent_config_invalid eval "chmod 0640 \"\$AGENT_CONFIG_PATH\""
expect_agent_config_invalid eval "mv \"\$AGENT_CONFIG_PATH\" \"\${AGENT_TMP_DIR}/agent-real.toml\"; ln -s \"agent-real.toml\" \"\$AGENT_CONFIG_PATH\""
expect_agent_config_invalid eval "sed -i 's/mode = \"libvirt\"/mode = \"mock\"/' \"\$AGENT_CONFIG_PATH\""
expect_agent_config_invalid eval "sed -i 's#data_dir = \"/var/lib/vps-agent\"#data_dir = \"/srv/vps-agent\"#' \"\$AGENT_CONFIG_PATH\""
expect_agent_config_invalid eval "sed -i 's#image_dir = \"/var/lib/vps-agent/images\"#image_dir = \"/srv/vps-agent/images\"#' \"\$AGENT_CONFIG_PATH\""
expect_agent_config_invalid eval "sed -i 's/network_name = \"default\"/network_name = \"public\"/' \"\$AGENT_CONFIG_PATH\""
expect_agent_config_invalid eval "sed -i 's/bridge_name = \"virbr0\"/bridge_name = \"br0\"/' \"\$AGENT_CONFIG_PATH\""
expect_agent_config_invalid eval "sed -i 's/node_id = \"00000000-0000-0000-0000-000000000000\"/node_id = \"11111111-1111-1111-1111-111111111111\"/' \"\$AGENT_CONFIG_PATH\""
expect_agent_config_invalid eval "sed -i '/^credential = /d' \"\$AGENT_CONFIG_PATH\""
expect_agent_config_invalid eval "sed -i 's/credential = \"ag_test-credential.1\"/credential = \"bt_still-bootstrap.1\"/' \"\$AGENT_CONFIG_PATH\""
expect_agent_config_invalid eval "sed -i '/^\\[executor\\]/i bootstrap_token = \"bt_still-bootstrap.1\"' \"\$AGENT_CONFIG_PATH\""
expect_agent_config_invalid eval "rm -f \"\$AGENT_CONFIG_PATH\""
expect_agent_doctor_valid true
expect_agent_doctor_invalid eval "chmod 0640 \"\$AGENT_BINARY_PATH\""
expect_agent_doctor_invalid eval "rm -f \"\$AGENT_BINARY_PATH\"; mkdir \"\$AGENT_BINARY_PATH\""
expect_agent_doctor_invalid eval "printf '%s\n' '#!/usr/bin/env bash' 'echo doctor did not finish' > \"\$AGENT_BINARY_PATH\"; chmod 0750 \"\$AGENT_BINARY_PATH\""
expect_agent_doctor_invalid eval "rm -f \"\$AGENT_BINARY_PATH\""
expect_agent_doctor_valid set_agent_binary_sha256
expect_agent_doctor_rejects_mismatched_binary_sha256
expect_agent_doctor_records_verified_sha256
expect_agent_doctor_hides_failed_output
expect_agent_service_valid
expect_agent_service_invalid_when_inactive
expect_agent_service_hides_failed_output
expect_agent_service_rejects_missing_writable_data_dir
expect_agent_service_rejects_missing_no_new_privileges
expect_agent_service_rejects_missing_memory_deny_write_execute
expect_agent_service_rejects_missing_restrict_address_families
expect_agent_service_rejects_missing_clock_hostname_protection
expect_agent_service_rejects_missing_restrict_suid_sgid
expect_agent_service_rejects_nonempty_capability_bounding_set
expect_agent_service_rejects_nonempty_ambient_capabilities
expect_agent_service_rejects_missing_kernel_tunable_protection
expect_agent_service_rejects_missing_native_syscall_architecture
expect_agent_service_rejects_wrong_config_environment
expect_agent_service_rejects_duplicate_config_environment
expect_agent_service_rejects_missing_safe_path_environment
expect_agent_service_rejects_duplicate_safe_path_environment
expect_agent_service_rejects_wrong_exec_start
expect_agent_service_rejects_wrong_exec_start_path_even_with_matching_argv
expect_agent_service_rejects_extra_exec_start_arguments
expect_node_ready_valid
expect_node_ready_rejects_missing_node
expect_node_ready_rejects_unregistered_node
expect_node_ready_rejects_unschedulable_node
expect_node_ready_rejects_unavailable_libvirt_status
expect_node_ready_rejects_stale_heartbeat

verify_domain_running_state " running "
if ( verify_domain_running_state "shut off" ) >/dev/null 2>&1; then
    echo "expected stopped domain state validation failure" >&2
    exit 1
fi
if ( verify_domain_running_state "paused" ) >/dev/null 2>&1; then
    echo "expected paused domain state validation failure" >&2
    exit 1
fi
expect_api_hides_admin_token_from_curl_args
expect_api_hides_admin_token_from_trace_output
expect_api_uses_bounded_curl_timeouts
expect_api_keeps_https_proto_when_allow_http_flag_is_set_for_https_url
expect_api_uses_configured_ca_certificate
expect_api_keeps_ca_certificate_path_as_single_argument
expect_cleanup_failure_reports_manual_state
expect_cleanup_rejects_invalid_delete_task_id_before_polling
expect_cleanup_rejects_malformed_delete_response_without_parser_details
expect_wait_for_task_rejects_invalid_task_id_before_api_call
expect_wait_for_task_rejects_unknown_status_without_polling_until_timeout
expect_wait_for_task_rejects_mismatched_response_id_before_accepting_status
expect_wait_for_task_rejects_missing_status_without_polling_until_timeout
expect_wait_for_task_redacts_and_bounds_failed_task_logs
expect_poll_sleep_caps_to_remaining_timeout
expect_created_vm_verification_hides_failed_dominfo_output
expect_created_vm_verification_hides_failed_domstate_output
expect_deleted_vm_verification_hides_ambiguous_dominfo_output
expect_created_vm_verification_rejects_symlink_artifacts
expect_created_vm_verification_rejects_mismatched_domain_metadata
expect_created_vm_verification_rejects_non_qcow2_managed_disk
expect_managed_disk_format_verification_accepts_qcow2_json
expect_created_vm_verification_requires_cloud_init_artifacts
expect_created_vm_verification_rejects_stale_cloud_init_metadata
expect_created_vm_verification_rejects_swapped_domain_disk_devices
expect_created_vm_verification_rejects_oversized_domain_metadata
expect_created_vm_verification_requires_network_config_for_ipam_metadata
expect_wsl_kernel_rejected_before_host_tool_checks
expect_host_tool_preflight_checks_kvm_qemu_and_cloud_init
expect_host_tool_preflight_hides_failed_virsh_version_output
expect_host_tool_preflight_hides_failed_qemu_img_version_output
expect_libvirt_network_preflight_requires_active_network
expect_libvirt_network_preflight_requires_expected_bridge
expect_libvirt_network_preflight_hides_failed_virsh_output
expect_base_image_format_preflight_requires_qcow2
expect_base_image_format_preflight_hides_failed_qemu_img_info_output
expect_base_image_format_preflight_records_qcow2
expect_cloud_init_tool_rejects_broken_candidates
expect_cloud_init_tool_records_cloud_localds_when_available
expect_cloud_init_tool_falls_back_when_cloud_localds_is_broken
expect_payload_builders_use_validated_shell_state
expect_create_payload_includes_optional_ssh_public_key
expect_create_payload_includes_optional_ip_pool_id
expect_create_payload_includes_optional_plan_id
expect_ip_pool_cidr_reuses_existing_matching_pool
expect_ip_pool_cidr_creates_pool_when_missing
expect_ip_pool_create_response_must_match_request
expect_plan_slug_reuses_existing_enabled_matching_plan
expect_plan_slug_creates_plan_when_missing
expect_plan_create_response_must_match_request
expect_disabled_matching_plan_is_rejected_without_create
expect_disabled_existing_image_is_reenabled
expect_disabled_existing_image_rejects_invalid_image_id_before_enable
expect_image_enable_response_must_be_enabled
expect_precheck_only_skips_admin_token_and_admin_api
expect_precheck_success_reports_non_secret_diagnostics
expect_precheck_health_uses_bounded_curl_timeout
expect_precheck_health_keeps_https_proto_when_allow_http_flag_is_set_for_https_url
expect_precheck_health_uses_configured_ca_certificate
expect_full_smoke_checks_node_ready_before_catalog_mutation
expect_full_smoke_stops_when_ip_pool_selection_fails
expect_create_response_rejects_invalid_vm_id_before_host_actions
expect_create_response_rejects_invalid_task_id_before_polling
expect_create_response_requires_selected_plan_id_before_polling
expect_create_verification_failure_attempts_cleanup
expect_create_success_requires_task_start_log_and_attempts_cleanup
expect_task_start_log_parser_requires_task_and_node_match
expect_full_lifecycle_required_validates_flags
expect_full_lifecycle_required_rejects_unverified_agent_binary_hash
expect_smoke_audit_logs_valid
expect_smoke_audit_logs_reject_missing_status_update
expect_action_response_rejects_mismatched_vm_id_before_polling
expect_power_action_queue_failure_attempts_cleanup
expect_reinstall_after_create_posts_reinstall_and_verifies_host
expect_power_cycle_after_create_posts_actions_and_verifies_host
expect_full_lifecycle_required_runs_all_lifecycle_actions

echo "kvm-host-smoke validation tests passed"
