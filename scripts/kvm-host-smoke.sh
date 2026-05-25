#!/usr/bin/env bash
set -euo pipefail

MASTER_URL="${MASTER_URL:-}"
MASTER_CA_CERT_PATH="${MASTER_CA_CERT_PATH:-}"
ADMIN_TOKEN="${ADMIN_TOKEN:-}"
NODE_ID="${NODE_ID:-}"
IMAGE_FILE="${IMAGE_FILE:-}"
IMAGE_NAME="${IMAGE_NAME:-KVM Smoke Image}"
IP_POOL_ID="${IP_POOL_ID:-}"
IP_POOL_NAME="${IP_POOL_NAME:-kvm-smoke-pool}"
IP_POOL_CIDR="${IP_POOL_CIDR:-}"
IP_POOL_GATEWAY="${IP_POOL_GATEWAY:-}"
PLAN_ID="${PLAN_ID:-}"
PLAN_NAME="${PLAN_NAME:-KVM Smoke Plan}"
PLAN_SLUG="${PLAN_SLUG:-}"
VM_NAME="${VM_NAME:-kvm-smoke-$(date +%s)}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
LIBVIRT_NETWORK_NAME="${LIBVIRT_NETWORK_NAME:-default}"
LIBVIRT_BRIDGE_NAME="${LIBVIRT_BRIDGE_NAME:-virbr0}"
CPU_CORES="${CPU_CORES:-1}"
MEMORY_MB="${MEMORY_MB:-512}"
DISK_GB="${DISK_GB:-10}"
DATA_DIR="${DATA_DIR:-/var/lib/vps-agent}"
IMAGE_DIR="${IMAGE_DIR:-${DATA_DIR}/images}"
AGENT_CONFIG_PATH="${AGENT_CONFIG_PATH:-/etc/vps-agent/agent.toml}"
AGENT_BINARY_PATH="${AGENT_BINARY_PATH:-/usr/local/bin/vps-agent}"
AGENT_BINARY_SHA256="${AGENT_BINARY_SHA256:-}"
AGENT_BINARY_SHA256_PATH="${AGENT_BINARY_SHA256_PATH:-${AGENT_CONFIG_PATH%/*}/agent.sha256}"
AGENT_BINARY_SHA256_VERIFIED="${AGENT_BINARY_SHA256_VERIFIED:-0}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-900}"
POLL_SECONDS="${POLL_SECONDS:-5}"
CURL_TIMEOUT_SECONDS="${CURL_TIMEOUT_SECONDS:-30}"
CLEANUP="${CLEANUP:-1}"
ALLOW_HTTP="${ALLOW_HTTP:-0}"
PRECHECK_ONLY="${PRECHECK_ONLY:-0}"
REINSTALL_AFTER_CREATE="${REINSTALL_AFTER_CREATE:-0}"
POWER_CYCLE_AFTER_CREATE="${POWER_CYCLE_AFTER_CREATE:-0}"
FULL_LIFECYCLE_REQUIRED="${FULL_LIFECYCLE_REQUIRED:-0}"
SAFE_SYSTEMD_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

usage() {
    cat <<'EOF'
Run this on a real Linux KVM host after the agent is installed, registered,
and configured with executor.mode = "libvirt".

Required environment:
  MASTER_URL=https://panel.example.com
  ADMIN_TOKEN=<admin-secret>
  NODE_ID=<registered-node-uuid>
  IMAGE_FILE=debian-12.qcow2

Optional environment:
  MASTER_CA_CERT_PATH=/etc/ssl/certs/master-ca.pem
  IMAGE_NAME="Debian 12"
  IP_POOL_ID=<existing-ip-pool-uuid>
  IP_POOL_NAME=kvm-smoke-pool
  IP_POOL_CIDR=192.0.2.0/29
  IP_POOL_GATEWAY=192.0.2.1
  PLAN_ID=<existing-enabled-plan-uuid>
  PLAN_NAME="KVM Smoke Plan"
  PLAN_SLUG=kvm-smoke-plan
  VM_NAME=kvm-smoke-<timestamp>
  SSH_PUBLIC_KEY="ssh-ed25519 AAAA... operator@example"
  LIBVIRT_NETWORK_NAME=default
  LIBVIRT_BRIDGE_NAME=virbr0
  CPU_CORES=1
  MEMORY_MB=512
  DISK_GB=10
  DATA_DIR=/var/lib/vps-agent
  IMAGE_DIR=/var/lib/vps-agent/images
  AGENT_CONFIG_PATH=/etc/vps-agent/agent.toml
  AGENT_BINARY_PATH=/usr/local/bin/vps-agent
  AGENT_BINARY_SHA256=<expected-installed-agent-sha256>
  AGENT_BINARY_SHA256_PATH=/etc/vps-agent/agent.sha256
  TIMEOUT_SECONDS=900
  POLL_SECONDS=5
  CURL_TIMEOUT_SECONDS=30
  CLEANUP=1
  ALLOW_HTTP=0
  PRECHECK_ONLY=0
  REINSTALL_AFTER_CREATE=0
  POWER_CYCLE_AFTER_CREATE=0
  FULL_LIFECYCLE_REQUIRED=0

The script registers IMAGE_FILE in the master image catalog if needed, queues a
real create_vm task, waits for the agent to complete it, verifies the libvirt
domain and managed files on this host, optionally queues reinstall_vm when
REINSTALL_AFTER_CREATE=1, optionally queues stop_vm/start_vm/reboot_vm when
POWER_CYCLE_AFTER_CREATE=1, verifies the host after each step, then queues
delete_vm when CLEANUP=1. Before it mutates the master catalog or queues tasks,
full mode reads GET /api/admin/nodes with ADMIN_TOKEN and requires NODE_ID to
be online, schedulable, registered, heartbeating within the last two hours, and
reporting libvirt_status=available.
Set PRECHECK_ONLY=1 to validate the master health endpoint, host tools, KVM
device, local agent config, active vps-agent systemd service, and base image
path without requiring ADMIN_TOKEN or queueing tasks.
Set FULL_LIFECYCLE_REQUIRED=1 for final acceptance runs; it requires
ALLOW_HTTP=0, AGENT_BINARY_SHA256 or a verified hash at AGENT_BINARY_SHA256_PATH,
REINSTALL_AFTER_CREATE=1, POWER_CYCLE_AFTER_CREATE=1, CLEANUP=1, and
PRECHECK_ONLY=0 before the script starts host or master checks.

Final acceptance command:
  export MASTER_URL=https://panel.example.com
  export ADMIN_TOKEN=<admin-secret>
  export NODE_ID=<registered-node-uuid>
  export IMAGE_FILE=debian-12.qcow2
  export AGENT_BINARY_SHA256=<expected-installed-agent-sha256>
  export ALLOW_HTTP=0
  export CLEANUP=1
  export PRECHECK_ONLY=0
  export REINSTALL_AFTER_CREATE=1
  export POWER_CYCLE_AFTER_CREATE=1
  export FULL_LIFECYCLE_REQUIRED=1
  sudo -E bash scripts/kvm-host-smoke.sh
EOF
}

fail() {
    echo "kvm-host-smoke: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

require_env() {
    [ -n "${!1}" ] || fail "$1 is required"
}

contains_ascii_control_chars() {
    case "$1" in
        *[[:cntrl:]]*) return 0 ;;
        *) return 1 ;;
    esac
}

contains_url_unsafe_chars() {
    case "$1" in
        *"'"*|*\"*|*\\*|*'`'*|*" "*) return 0 ;;
        *) contains_ascii_control_chars "$1" ;;
    esac
}

contains_path_unsafe_chars() {
    case "$1" in
        *"'"*|*\"*|*\\*|*'`'*|*" "*) return 0 ;;
        *) contains_ascii_control_chars "$1" ;;
    esac
}

contains_header_unsafe_chars() {
    case "$1" in
        *"'"*|*\"*|*\\*|*'`'*|*" "*) return 0 ;;
        *) contains_ascii_control_chars "$1" ;;
    esac
}

validate_admin_token() {
    [ -n "$ADMIN_TOKEN" ] || fail "ADMIN_TOKEN is required"
    if [ "${#ADMIN_TOKEN}" -gt 256 ]; then
        fail "ADMIN_TOKEN must be 256 characters or shorter"
    fi
    if contains_header_unsafe_chars "$ADMIN_TOKEN"; then
        fail "ADMIN_TOKEN contains unsupported characters"
    fi
}

validate_url_port() {
    port="$1"

    [ -n "$port" ] || fail "MASTER_URL port must not be empty"
    case "$port" in
        *[!0-9]*) fail "MASTER_URL port must be numeric" ;;
    esac
    if [ "${#port}" -gt 5 ] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        fail "MASTER_URL port must be between 1 and 65535"
    fi
}

validate_url_authority() {
    authority="$1"

    lower_authority="$(printf '%s' "$authority" | tr 'A-F' 'a-f')"
    case "$lower_authority" in
        *%2f*|*%5c*) fail "MASTER_URL must not include encoded path separators" ;;
    esac
    case "$lower_authority" in
        *%00*|*%01*|*%02*|*%03*|*%04*|*%05*|*%06*|*%07*|\
        *%08*|*%09*|*%0a*|*%0b*|*%0c*|*%0d*|*%0e*|*%0f*|\
        *%10*|*%11*|*%12*|*%13*|*%14*|*%15*|*%16*|*%17*|\
        *%18*|*%19*|*%1a*|*%1b*|*%1c*|*%1d*|*%1e*|*%1f*|\
        *%7f*) fail "MASTER_URL must not include percent-encoded control characters" ;;
    esac

    case "$authority" in
        \[*)
            case "$authority" in
                \[*\]*) ;;
                *) fail "MASTER_URL has malformed bracketed host" ;;
            esac
            host="${authority#\[}"
            host="${host%%]*}"
            [ -n "$host" ] || fail "MASTER_URL must include a host"
            after_bracket="${authority#*\]}"
            case "$after_bracket" in
                "") ;;
                :*) validate_url_port "${after_bracket#:}" ;;
                *) fail "MASTER_URL has malformed bracketed host" ;;
            esac
            ;;
        *)
            case "$authority" in
                *"["*|*"]"*) fail "MASTER_URL has malformed bracketed host" ;;
                *:*:*) fail "MASTER_URL IPv6 hosts must be bracketed" ;;
            esac
            host="${authority%%:*}"
            [ -n "$host" ] || fail "MASTER_URL must include a host"
            case "$authority" in
                *:*) validate_url_port "${authority##*:}" ;;
            esac
            ;;
    esac
}

validate_url_path_segments() {
    path="$1"

    lower_path="$(printf '%s' "$path" | tr 'A-F' 'a-f')"
    case "$lower_path" in
        *%2f*|*%5c*) fail "MASTER_URL must not include encoded path separators" ;;
    esac
    case "$lower_path" in
        *%00*|*%01*|*%02*|*%03*|*%04*|*%05*|*%06*|*%07*|\
        *%08*|*%09*|*%0a*|*%0b*|*%0c*|*%0d*|*%0e*|*%0f*|\
        *%10*|*%11*|*%12*|*%13*|*%14*|*%15*|*%16*|*%17*|\
        *%18*|*%19*|*%1a*|*%1b*|*%1c*|*%1d*|*%1e*|*%1f*|\
        *%7f*) fail "MASTER_URL must not include percent-encoded control characters" ;;
    esac

    remaining="$path"
    while :; do
        segment="${remaining%%/*}"
        normalized="${segment//%2e/.}"
        normalized="${normalized//%2E/.}"
        case "$normalized" in
            .|..) fail "MASTER_URL must not include dot path segments" ;;
        esac
        [ "$remaining" != "$segment" ] || break
        remaining="${remaining#*/}"
    done
}

validate_master_url() {
    [ -n "$MASTER_URL" ] || fail "MASTER_URL is required"
    if contains_url_unsafe_chars "$MASTER_URL"; then
        fail "MASTER_URL contains unsupported characters"
    fi

    is_http=0
    case "$MASTER_URL" in
        https://*) ;;
        http://*)
            [ "$ALLOW_HTTP" = "1" ] || fail "MASTER_URL must use https://"
            is_http=1
            ;;
        *) fail "MASTER_URL must start with https://" ;;
    esac

    if [ "$ALLOW_HTTP" = "1" ]; then
        remainder="${MASTER_URL#http://}"
        if [ "$remainder" = "$MASTER_URL" ]; then
            remainder="${MASTER_URL#https://}"
        fi
    else
        remainder="${MASTER_URL#https://}"
    fi

    case "$remainder" in
        ""|/*) fail "MASTER_URL must include a host" ;;
    esac
    case "$remainder" in
        *\?*|*#*) fail "MASTER_URL must not include query strings or fragments" ;;
    esac
    case "$remainder" in
        */*) validate_url_path_segments "${remainder#*/}" ;;
    esac

    authority="${remainder%%/*}"
    [ -n "$authority" ] || fail "MASTER_URL must include a host"
    case "$authority" in
        *@*) fail "MASTER_URL must not include username or password" ;;
    esac
    validate_url_authority "$authority"
    if [ "$is_http" = "1" ]; then
        case "$authority" in
            localhost|localhost:*|127.0.0.1|127.0.0.1:*|\[::1\]|\[::1\]:*) ;;
            *) fail "ALLOW_HTTP only supports loopback hosts" ;;
        esac
    fi
}

validate_controlled_dir() {
    name="$1"
    value="$2"

    [ -n "$value" ] || fail "$name must not be empty"
    if contains_path_unsafe_chars "$value"; then
        fail "$name contains unsupported characters"
    fi

    case "$value" in
        /) fail "$name must not be the filesystem root" ;;
        /*) ;;
        *) fail "$name must be an absolute Linux path" ;;
    esac

    case "$value" in
        */../*|*/..) fail "$name must not contain parent directory traversal" ;;
    esac
}

validate_linux_file_path() {
    name="$1"
    value="$2"

    [ -n "$value" ] || return 0
    if contains_path_unsafe_chars "$value"; then
        fail "$name contains unsupported characters"
    fi

    case "$value" in
        /) fail "$name must not be the filesystem root" ;;
        /*) ;;
        *) fail "$name must be an absolute Linux path" ;;
    esac

    case "$value" in
        */../*|*/..) fail "$name must not contain parent directory traversal" ;;
    esac
}

validate_child_dir() {
    child_name="$1"
    child="$2"
    parent_name="$3"
    parent="$4"

    case "$child" in
        "$parent"/*) ;;
        *) fail "$child_name must be under $parent_name" ;;
    esac
}

validate_safe_file_name() {
    name="$1"
    value="$2"
    case "$value" in
        ""|.*|*.|*/*|*\\*|*..*|*[!A-Za-z0-9._-]*)
            fail "$name must be a safe file name"
            ;;
    esac
}

validate_uuid() {
    name="$1"
    value="$2"
    if [[ ! "$value" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
        fail "$name must be a UUID"
    fi
}

validate_vm_name() {
    case "$VM_NAME" in
        ""|*[!A-Za-z0-9_-]*)
            fail "VM_NAME must be 1-64 chars and only contain ASCII letters, numbers, dashes or underscores"
            ;;
    esac
    if [ "${#VM_NAME}" -gt 64 ]; then
        fail "VM_NAME must be 64 characters or shorter"
    fi
}

validate_libvirt_identifier() {
    name="$1"
    value="$2"

    case "$value" in
        ""|*[!A-Za-z0-9._-]*)
            fail "$name must be 1-64 ASCII letters, numbers, dots, dashes or underscores"
            ;;
    esac
    if [ "${#value}" -gt 64 ]; then
        fail "$name must be 64 characters or shorter"
    fi
}

validate_image_name() {
    if [[ ! "$IMAGE_NAME" =~ ^[A-Za-z0-9_\ -]{1,80}$ ]]; then
        fail "IMAGE_NAME must be 1-80 chars and only contain ASCII letters, numbers, spaces, dashes or underscores"
    fi
}

validate_ip_pool_name() {
    case "$IP_POOL_NAME" in
        ""|*[!A-Za-z0-9._-]*)
            fail "IP_POOL_NAME must be 1-80 chars and only contain ASCII letters, numbers, dots, dashes or underscores"
            ;;
    esac
    if [ "${#IP_POOL_NAME}" -gt 80 ]; then
        fail "IP_POOL_NAME must be 80 characters or shorter"
    fi
}

validate_ip_pool_config() {
    if [ -n "$IP_POOL_ID" ] && { [ -n "$IP_POOL_CIDR" ] || [ -n "$IP_POOL_GATEWAY" ]; }; then
        fail "set either IP_POOL_ID or IP_POOL_CIDR/IP_POOL_GATEWAY, not both"
    fi
    if [ -z "$IP_POOL_CIDR" ] && [ -z "$IP_POOL_GATEWAY" ]; then
        return
    fi
    [ -n "$IP_POOL_CIDR" ] || fail "IP_POOL_CIDR is required when IP_POOL_GATEWAY is set"
    [ -n "$IP_POOL_GATEWAY" ] || fail "IP_POOL_GATEWAY is required when IP_POOL_CIDR is set"
    validate_ip_pool_name

    normalized_cidr="$(python3 - "$IP_POOL_CIDR" "$IP_POOL_GATEWAY" <<'PY'
import ipaddress
import sys

cidr_text, gateway_text = sys.argv[1:3]


def fail(message):
    print(f"kvm-host-smoke: {message}", file=sys.stderr)
    sys.exit(1)


try:
    network = ipaddress.IPv4Network(cidr_text, strict=False)
    gateway = ipaddress.IPv4Address(gateway_text)
except ValueError:
    fail("IP_POOL_CIDR and IP_POOL_GATEWAY must be valid IPv4 values")

if network.prefixlen < 16 or network.prefixlen > 30:
    fail("IP_POOL_CIDR must use a /16 through /30 prefix")
if gateway not in network or gateway == network.network_address or gateway == network.broadcast_address:
    fail("IP_POOL_GATEWAY must be a usable host address inside IP_POOL_CIDR")

print(str(network))
PY
)" || return 1
    IP_POOL_CIDR="$normalized_cidr"
}

validate_plan_name() {
    if [[ ! "$PLAN_NAME" =~ ^[-A-Za-z0-9_\ ]{1,80}$ ]]; then
        fail "PLAN_NAME must be 1-80 chars and only contain ASCII letters, numbers, spaces, dashes or underscores"
    fi
}

validate_plan_slug() {
    if [[ ! "$PLAN_SLUG" =~ ^[-A-Za-z0-9_]{1,80}$ ]]; then
        fail "PLAN_SLUG must be 1-80 chars and only contain ASCII letters, numbers, dashes or underscores"
    fi
}

validate_plan_config() {
    if [ -n "$PLAN_ID" ] && [ -n "$PLAN_SLUG" ]; then
        fail "set either PLAN_ID or PLAN_SLUG, not both"
    fi
    if [ -n "$PLAN_ID" ]; then
        validate_uuid "PLAN_ID" "$PLAN_ID"
    fi
    if [ -z "$PLAN_SLUG" ]; then
        return
    fi
    validate_plan_slug
    validate_plan_name
}

validate_ssh_public_key() {
    [ -n "$SSH_PUBLIC_KEY" ] || return 0

    case "$SSH_PUBLIC_KEY" in
        *$'\n'*|*$'\r'*|*$'\t'*|*"'"*|*\"*|*\\*|*'`'*)
            fail "SSH_PUBLIC_KEY must be a single OpenSSH public key without quotes, backslashes or control characters"
            ;;
    esac

    read -r key_kind key_body key_comment key_extra <<< "$SSH_PUBLIC_KEY"
    [ -n "${key_kind:-}" ] || fail "SSH_PUBLIC_KEY must include a key type"
    [ -n "${key_body:-}" ] || fail "SSH_PUBLIC_KEY must include a base64 key body"
    [ -z "${key_extra:-}" ] || fail "SSH_PUBLIC_KEY must contain at most type, body and one comment"

    case "$key_kind" in
        ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) ;;
        *) fail "SSH_PUBLIC_KEY uses an unsupported key type" ;;
    esac

    if [ "${#key_body}" -lt 32 ] || [ "${#key_body}" -gt 900 ]; then
        fail "SSH_PUBLIC_KEY body length is outside the accepted range"
    fi
    case "$key_body" in
        *[!A-Za-z0-9+/=]*) fail "SSH_PUBLIC_KEY body must be base64-like text" ;;
    esac

    if [ -n "${key_comment:-}" ]; then
        if [ "${#key_comment}" -gt 128 ]; then
            fail "SSH_PUBLIC_KEY comment must be 128 characters or shorter"
        fi
        case "$key_comment" in
            *[![:graph:]]*) fail "SSH_PUBLIC_KEY comment must be printable ASCII without spaces" ;;
        esac
        case "$key_comment" in
            *'$'*|*';'*|*'|'*|*'&'*|*'<'*|*'>'*|*'('*|*')'*|*'{'*|*'}'*|*'['*|*']'*|*'*'*|*'?'*|*'!'*|*'#'*)
                fail "SSH_PUBLIC_KEY comment must not contain shell metacharacters"
                ;;
        esac
    fi
}

validate_integer_range() {
    name="$1"
    value="$2"
    min="$3"
    max="$4"

    case "$value" in
        ""|*[!0-9]*) fail "$name must be an integer" ;;
    esac

    normalized="$value"
    while [ "${#normalized}" -gt 1 ]; do
        case "$normalized" in
            0*) normalized="${normalized#0}" ;;
            *) break ;;
        esac
    done

    if [ "${#normalized}" -lt "${#min}" ] ||
        { [ "${#normalized}" -eq "${#min}" ] && [ "$normalized" \< "$min" ]; } ||
        [ "${#normalized}" -gt "${#max}" ] ||
        { [ "${#normalized}" -eq "${#max}" ] && [ "$normalized" \> "$max" ]; }; then
        fail "$name must be between $min and $max"
    fi
}

validate_binary_flag() {
    name="$1"
    value="$2"
    case "$value" in
        0|1) ;;
        *) fail "$name must be 0 or 1" ;;
    esac
}

validate_optional_sha256() {
    name="$1"
    value="$2"

    [ -n "$value" ] || return 0
    case "$value" in
        ????????????????????????????????????????????????????????????????) ;;
        *) fail "$name must be a 64-character SHA-256 hex digest" ;;
    esac
    case "$value" in
        *[!A-Fa-f0-9]*) fail "$name must be a 64-character SHA-256 hex digest" ;;
    esac
}

load_agent_binary_sha256_from_file() {
    [ -z "$AGENT_BINARY_SHA256" ] || {
        AGENT_BINARY_SHA256="$(printf '%s' "$AGENT_BINARY_SHA256" | tr 'A-F' 'a-f')"
        return 0
    }
    [ -e "$AGENT_BINARY_SHA256_PATH" ] || return 0

    [ ! -L "$AGENT_BINARY_SHA256_PATH" ] || fail "AGENT_BINARY_SHA256_PATH must not be a symlink"
    [ -f "$AGENT_BINARY_SHA256_PATH" ] || fail "AGENT_BINARY_SHA256_PATH must be a regular file"
    require_command stat

    mode="$(stat -c '%a' "$AGENT_BINARY_SHA256_PATH")" || fail "unable to read AGENT_BINARY_SHA256_PATH permissions"
    case "$mode" in
        ""|*[!0-7]*) fail "unable to parse AGENT_BINARY_SHA256_PATH permissions" ;;
    esac
    if [ $((8#$mode & 022)) -ne 0 ]; then
        fail "AGENT_BINARY_SHA256_PATH must not be writable by group or other"
    fi

    AGENT_BINARY_SHA256="$(cat "$AGENT_BINARY_SHA256_PATH")" || fail "unable to read AGENT_BINARY_SHA256_PATH"
    case "$AGENT_BINARY_SHA256" in
        *$'\n'*|*$'\r'*) fail "AGENT_BINARY_SHA256_PATH must contain exactly one SHA-256 digest" ;;
    esac
    validate_optional_sha256 "AGENT_BINARY_SHA256_PATH" "$AGENT_BINARY_SHA256"
    AGENT_BINARY_SHA256="$(printf '%s' "$AGENT_BINARY_SHA256" | tr 'A-F' 'a-f')"
}

validate_args() {
    require_env MASTER_URL
    require_env IMAGE_FILE

    validate_binary_flag "ALLOW_HTTP" "$ALLOW_HTTP"
    validate_binary_flag "CLEANUP" "$CLEANUP"
    validate_binary_flag "PRECHECK_ONLY" "$PRECHECK_ONLY"
    validate_binary_flag "REINSTALL_AFTER_CREATE" "$REINSTALL_AFTER_CREATE"
    validate_binary_flag "POWER_CYCLE_AFTER_CREATE" "$POWER_CYCLE_AFTER_CREATE"
    validate_binary_flag "FULL_LIFECYCLE_REQUIRED" "$FULL_LIFECYCLE_REQUIRED"
    validate_linux_file_path "AGENT_BINARY_SHA256_PATH" "$AGENT_BINARY_SHA256_PATH"
    load_agent_binary_sha256_from_file
    validate_optional_sha256 "AGENT_BINARY_SHA256" "$AGENT_BINARY_SHA256"
    validate_full_lifecycle_requirement
    validate_master_url
    validate_linux_file_path "MASTER_CA_CERT_PATH" "$MASTER_CA_CERT_PATH"
    validate_linux_file_path "AGENT_CONFIG_PATH" "$AGENT_CONFIG_PATH"
    validate_linux_file_path "AGENT_BINARY_PATH" "$AGENT_BINARY_PATH"

    if [ "$PRECHECK_ONLY" = "0" ]; then
        require_env NODE_ID

        validate_admin_token
        validate_uuid "NODE_ID" "$NODE_ID"
    fi

    if [ -n "$IP_POOL_ID" ]; then
        validate_uuid "IP_POOL_ID" "$IP_POOL_ID"
    fi
    validate_ip_pool_name
    validate_ip_pool_config || return 1
    validate_plan_config

    validate_safe_file_name "IMAGE_FILE" "$IMAGE_FILE"
    validate_image_name
    validate_vm_name
    validate_libvirt_identifier "LIBVIRT_NETWORK_NAME" "$LIBVIRT_NETWORK_NAME"
    validate_libvirt_identifier "LIBVIRT_BRIDGE_NAME" "$LIBVIRT_BRIDGE_NAME"
    validate_ssh_public_key
    validate_integer_range "CPU_CORES" "$CPU_CORES" 1 32
    validate_integer_range "MEMORY_MB" "$MEMORY_MB" 128 262144
    validate_integer_range "DISK_GB" "$DISK_GB" 1 4096
    validate_integer_range "TIMEOUT_SECONDS" "$TIMEOUT_SECONDS" 1 86400
    validate_integer_range "POLL_SECONDS" "$POLL_SECONDS" 1 3600
    if [ "$POLL_SECONDS" -gt "$TIMEOUT_SECONDS" ]; then
        fail "POLL_SECONDS must be less than or equal to TIMEOUT_SECONDS"
    fi
    validate_integer_range "CURL_TIMEOUT_SECONDS" "$CURL_TIMEOUT_SECONDS" 1 3600
    validate_controlled_dir "DATA_DIR" "$DATA_DIR"
    validate_controlled_dir "IMAGE_DIR" "$IMAGE_DIR"
    validate_child_dir "IMAGE_DIR" "$IMAGE_DIR" "DATA_DIR" "$DATA_DIR"
}

validate_full_lifecycle_requirement() {
    [ "$FULL_LIFECYCLE_REQUIRED" = "1" ] || return 0
    [ "$PRECHECK_ONLY" = "0" ] || fail "FULL_LIFECYCLE_REQUIRED cannot be used with PRECHECK_ONLY=1"
    [ "$ALLOW_HTTP" = "0" ] || fail "FULL_LIFECYCLE_REQUIRED requires ALLOW_HTTP=0"
    [ "$CLEANUP" = "1" ] || fail "FULL_LIFECYCLE_REQUIRED requires CLEANUP=1"
    [ "$REINSTALL_AFTER_CREATE" = "1" ] || fail "FULL_LIFECYCLE_REQUIRED requires REINSTALL_AFTER_CREATE=1"
    [ "$POWER_CYCLE_AFTER_CREATE" = "1" ] || fail "FULL_LIFECYCLE_REQUIRED requires POWER_CYCLE_AFTER_CREATE=1"
    [ -n "$AGENT_BINARY_SHA256" ] || fail "FULL_LIFECYCLE_REQUIRED requires AGENT_BINARY_SHA256 or AGENT_BINARY_SHA256_PATH"
}

validate_full_lifecycle_agent_binary_verified() {
    [ "$FULL_LIFECYCLE_REQUIRED" = "1" ] || return 0
    [ "$AGENT_BINARY_SHA256_VERIFIED" = "1" ] ||
        fail "FULL_LIFECYCLE_REQUIRED requires verified agent binary SHA-256"
}

validate_ca_cert_path() {
    [ -n "$MASTER_CA_CERT_PATH" ] || return 0
    python3 - "$MASTER_CA_CERT_PATH" <<'PY'
from pathlib import Path
import stat
import sys

path = Path(sys.argv[1])


def fail(message):
    print(f"kvm-host-smoke: {message}", file=sys.stderr)
    sys.exit(1)


try:
    if path.is_symlink():
        fail(f"MASTER_CA_CERT_PATH must not be a symlink: {path}")
    real = path.resolve(strict=True)
except FileNotFoundError:
    fail(f"MASTER_CA_CERT_PATH does not exist: {path}")
except OSError as exc:
    fail(f"MASTER_CA_CERT_PATH cannot be resolved: {exc}")

if not real.is_file():
    fail(f"MASTER_CA_CERT_PATH is not a regular file: {path}")

mode = real.stat().st_mode
if mode & 0o022:
    fail(f"MASTER_CA_CERT_PATH must not be group/world writable: {path}")
PY
}

validate_agent_config() {
    require_command python3
    python3 - "$AGENT_CONFIG_PATH" "$NODE_ID" "$DATA_DIR" "$IMAGE_DIR" "$LIBVIRT_NETWORK_NAME" "$LIBVIRT_BRIDGE_NAME" "$PRECHECK_ONLY" <<'PY'
from pathlib import Path
import re
import stat
import sys

path = Path(sys.argv[1])
expected_node_id = sys.argv[2]
expected_data_dir = sys.argv[3]
expected_image_dir = sys.argv[4]
expected_network_name = sys.argv[5]
expected_bridge_name = sys.argv[6]
precheck_only = sys.argv[7] == "1"

UUID_RE = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)
AGENT_CREDENTIAL_RE = re.compile(r"^ag_[A-Za-z0-9._-]{1,253}$")
SECTION_RE = re.compile(r"^\[([A-Za-z_][A-Za-z0-9_]*)\]$")
ASSIGNMENT_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"([^"\n]*)"\s*$')


def fail(message):
    print(f"kvm-host-smoke: {message}", file=sys.stderr)
    sys.exit(1)


def strip_comment(line):
    in_quote = False
    escaped = False
    result = []
    for ch in line:
        if escaped:
            result.append(ch)
            escaped = False
            continue
        if ch == "\\" and in_quote:
            result.append(ch)
            escaped = True
            continue
        if ch == '"':
            in_quote = not in_quote
            result.append(ch)
            continue
        if ch == "#" and not in_quote:
            break
        result.append(ch)
    return "".join(result).strip()


try:
    if path.is_symlink():
        fail(f"AGENT_CONFIG_PATH must not be a symlink: {path}")
    real = path.resolve(strict=True)
except FileNotFoundError:
    fail(f"AGENT_CONFIG_PATH does not exist: {path}")
except OSError as exc:
    fail(f"AGENT_CONFIG_PATH cannot be resolved: {exc}")

if not real.is_file():
    fail(f"AGENT_CONFIG_PATH is not a regular file: {path}")

mode = real.stat().st_mode & 0o777
if mode & (stat.S_IRWXG | stat.S_IRWXO):
    fail(f"AGENT_CONFIG_PATH must be 0600 or stricter: {path} has mode {mode:o}")

try:
    text = real.read_text(encoding="utf-8")
except UnicodeDecodeError:
    fail("agent config is not UTF-8")
except OSError as exc:
    fail(f"agent config cannot be read: {exc}")

values = {}
section = ""
for raw_line in text.splitlines():
    line = strip_comment(raw_line)
    if not line:
        continue
    section_match = SECTION_RE.match(line)
    if section_match:
        section = section_match.group(1)
        continue
    assignment_match = ASSIGNMENT_RE.match(line)
    if assignment_match:
        values[(section, assignment_match.group(1))] = assignment_match.group(2)

config_node_id = values.get(("", "node_id"))
if not isinstance(config_node_id, str) or not UUID_RE.match(config_node_id):
    fail("agent config node_id must be a UUID")
if not precheck_only and config_node_id != expected_node_id:
    fail("agent config node_id must match NODE_ID")

credential = values.get(("", "credential"))
if not isinstance(credential, str) or not AGENT_CREDENTIAL_RE.match(credential):
    fail("agent config credential must be present after registration")

if ("", "bootstrap_token") in values:
    fail("agent config must not contain bootstrap_token after registration")

expected_values = {
    ("", "data_dir"): (expected_data_dir, "agent config data_dir must match DATA_DIR"),
    ("executor", "mode"): ("libvirt", "agent config executor.mode must be libvirt"),
    ("executor", "image_dir"): (
        expected_image_dir,
        "agent config executor.image_dir must match IMAGE_DIR",
    ),
    ("executor", "network_name"): (
        expected_network_name,
        "agent config executor.network_name must match LIBVIRT_NETWORK_NAME",
    ),
    ("executor", "bridge_name"): (
        expected_bridge_name,
        "agent config executor.bridge_name must match LIBVIRT_BRIDGE_NAME",
    ),
}

for key, (expected, message) in expected_values.items():
    if values.get(key) != expected:
        fail(message)
PY
}

validate_agent_doctor() {
    require_command python3
    python3 - "$AGENT_BINARY_PATH" <<'PY'
from pathlib import Path
import stat
import sys

path = Path(sys.argv[1])


def fail(message):
    print(f"kvm-host-smoke: {message}", file=sys.stderr)
    sys.exit(1)


try:
    if path.is_symlink():
        fail(f"AGENT_BINARY_PATH must not be a symlink: {path}")
    real = path.resolve(strict=True)
except FileNotFoundError:
    fail(f"AGENT_BINARY_PATH does not exist: {path}")
except OSError as exc:
    fail(f"AGENT_BINARY_PATH cannot be resolved: {exc}")

if not real.is_file():
    fail(f"AGENT_BINARY_PATH is not a regular file: {path}")

mode = real.stat().st_mode & 0o777
if mode & (stat.S_IWGRP | stat.S_IWOTH):
    fail(f"AGENT_BINARY_PATH must not be group/world writable: {path} has mode {mode:o}")
if mode & (stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH) == 0:
    fail(f"AGENT_BINARY_PATH must be executable: {path} has mode {mode:o}")
PY

    if [ -n "$AGENT_BINARY_SHA256" ]; then
        require_command sha256sum
        expected_sha256="$(printf '%s' "$AGENT_BINARY_SHA256" | tr 'A-F' 'a-f')"
        actual_sha256_line="$(sha256sum "$AGENT_BINARY_PATH")"
        actual_sha256="${actual_sha256_line%% *}"
        if [ "$actual_sha256" != "$expected_sha256" ]; then
            fail "installed agent binary SHA-256 did not match AGENT_BINARY_SHA256"
        fi
        AGENT_BINARY_SHA256_VERIFIED=1
    fi

    local doctor_output
    if ! doctor_output="$(VPS_AGENT_CONFIG="$AGENT_CONFIG_PATH" "$AGENT_BINARY_PATH" doctor 2>&1)"; then
        fail "vps-agent doctor failed; rerun it manually with VPS_AGENT_CONFIG=${AGENT_CONFIG_PATH}"
    fi
    case "$doctor_output" in
        *"vps-agent doctor: ok"*) ;;
        *) fail "vps-agent doctor did not report ok" ;;
    esac
}

validate_agent_service() {
    require_command systemctl
    if ! systemctl is-active --quiet vps-agent.service >/dev/null 2>&1; then
        fail "vps-agent systemd service is not active; run systemctl status vps-agent.service on the host"
    fi

    local read_write_paths
    if ! read_write_paths="$(systemctl show --property=ReadWritePaths --value vps-agent.service 2>/dev/null)"; then
        fail "unable to read vps-agent systemd writable paths; run systemctl show --property=ReadWritePaths vps-agent.service on the host"
    fi

    local config_dir
    config_dir="${AGENT_CONFIG_PATH%/*}"
    python3 - "$read_write_paths" "$config_dir" "$DATA_DIR" <<'PY' || return 1
import sys

read_write_paths = set(sys.argv[1].split())
expected = [
    ("AGENT_CONFIG_PATH directory", sys.argv[2]),
    ("DATA_DIR", sys.argv[3]),
]

for label, path in expected:
    if path not in read_write_paths:
        print(
            f"kvm-host-smoke: vps-agent systemd ReadWritePaths must include {label}: {path}",
            file=sys.stderr,
        )
        sys.exit(1)
PY

    local hardening_properties
    if ! hardening_properties="$(
        systemctl show \
            --property=NoNewPrivileges \
            --property=MemoryDenyWriteExecute \
            --property=PrivateTmp \
            --property=ProtectClock \
            --property=ProtectHome \
            --property=ProtectHostname \
            --property=ProtectSystem \
            --property=RestrictAddressFamilies \
            --property=RestrictSUIDSGID \
            --property=UMask \
            vps-agent.service 2>/dev/null
    )"; then
        fail "unable to read vps-agent systemd hardening properties; run systemctl show vps-agent.service on the host"
    fi

    python3 - "$hardening_properties" <<'PY' || return 1
import sys

properties = {}
for line in sys.argv[1].splitlines():
    if "=" not in line:
        continue
    name, value = line.split("=", 1)
    properties[name] = value

expected = {
    "NoNewPrivileges": "yes",
    "MemoryDenyWriteExecute": "yes",
    "PrivateTmp": "yes",
    "ProtectClock": "yes",
    "ProtectHome": "yes",
    "ProtectHostname": "yes",
    "ProtectSystem": "strict",
    "RestrictSUIDSGID": "yes",
    "UMask": "0077",
}

for name, value in expected.items():
    if properties.get(name) != value:
        print(
            f"kvm-host-smoke: vps-agent systemd {name} must be {value}",
            file=sys.stderr,
        )
        sys.exit(1)

expected_address_families = {"AF_UNIX", "AF_INET", "AF_INET6", "AF_NETLINK"}
actual_address_families = set(properties.get("RestrictAddressFamilies", "").split())
if actual_address_families != expected_address_families:
    print(
        "kvm-host-smoke: vps-agent systemd RestrictAddressFamilies must be "
        + " ".join(sorted(expected_address_families)),
        file=sys.stderr,
    )
    sys.exit(1)
PY

    local extra_hardening_properties
    if ! extra_hardening_properties="$(
        systemctl show \
            --property=ProtectKernelTunables \
            --property=ProtectKernelModules \
            --property=ProtectControlGroups \
            --property=LockPersonality \
            --property=RestrictRealtime \
            --property=CapabilityBoundingSet \
            --property=AmbientCapabilities \
            --property=SystemCallArchitectures \
            vps-agent.service 2>/dev/null
    )"; then
        fail "unable to read vps-agent systemd extended hardening properties; run systemctl show vps-agent.service on the host"
    fi

    python3 - "$extra_hardening_properties" <<'PY' || return 1
import sys

properties = {}
for line in sys.argv[1].splitlines():
    if "=" not in line:
        continue
    name, value = line.split("=", 1)
    properties[name] = value

expected = {
    "ProtectKernelTunables": "yes",
    "ProtectKernelModules": "yes",
    "ProtectControlGroups": "yes",
    "LockPersonality": "yes",
    "RestrictRealtime": "yes",
    "CapabilityBoundingSet": "",
    "AmbientCapabilities": "",
    "SystemCallArchitectures": "native",
}

for name, value in expected.items():
    if properties.get(name) != value:
        print(
            f"kvm-host-smoke: vps-agent systemd {name} must be {value}",
            file=sys.stderr,
        )
        sys.exit(1)
PY

    local service_environment
    if ! service_environment="$(systemctl show --property=Environment --value vps-agent.service 2>/dev/null)"; then
        fail "unable to read vps-agent systemd environment; run systemctl show --property=Environment vps-agent.service on the host"
    fi

    python3 - "$service_environment" "$AGENT_CONFIG_PATH" "$SAFE_SYSTEMD_PATH" <<'PY' || return 1
import shlex
import sys

environment = sys.argv[1]
expected_config = sys.argv[2]
expected_path = sys.argv[3]
expected_token = f"VPS_AGENT_CONFIG={expected_config}"
expected_path_token = f"PATH={expected_path}"

try:
    tokens = shlex.split(environment)
except ValueError:
    tokens = environment.split()

config_tokens = [token for token in tokens if token.startswith("VPS_AGENT_CONFIG=")]
path_tokens = [token for token in tokens if token.startswith("PATH=")]

if config_tokens != [expected_token]:
    print(
        f"kvm-host-smoke: vps-agent systemd Environment must contain exactly one {expected_token}",
        file=sys.stderr,
    )
    sys.exit(1)

if path_tokens != [expected_path_token]:
    print(
        f"kvm-host-smoke: vps-agent systemd Environment must contain exactly one {expected_path_token}",
        file=sys.stderr,
    )
    sys.exit(1)
PY

    local service_exec_start
    if ! service_exec_start="$(systemctl show --property=ExecStart --value vps-agent.service 2>/dev/null)"; then
        fail "unable to read vps-agent systemd ExecStart; run systemctl show --property=ExecStart vps-agent.service on the host"
    fi

    python3 - "$service_exec_start" "$AGENT_BINARY_PATH" <<'PY' || return 1
import re
import sys

exec_start = sys.argv[1]
expected_binary = sys.argv[2]

paths = re.findall(r"(?:^|[ {;])path=([^ ;]+)", exec_start)
argv = re.findall(r"(?:^|[ {;])argv\[\]=([^ ;]+)", exec_start)

if paths != [expected_binary]:
    print(
        f"kvm-host-smoke: vps-agent systemd ExecStart must use AGENT_BINARY_PATH: {expected_binary}",
        file=sys.stderr,
    )
    sys.exit(1)

if argv != [expected_binary]:
    print(
        f"kvm-host-smoke: vps-agent systemd ExecStart argv must contain only AGENT_BINARY_PATH: {expected_binary}",
        file=sys.stderr,
    )
    sys.exit(1)
PY
}

validate_host_paths() {
    require_command python3
    python3 - "$DATA_DIR" "$IMAGE_DIR" "$IMAGE_FILE" <<'PY'
from pathlib import Path
import stat
import sys

data_dir = Path(sys.argv[1])
image_dir = Path(sys.argv[2])
image_file = sys.argv[3]
base_image = image_dir / image_file


def fail(message):
    print(f"kvm-host-smoke: {message}", file=sys.stderr)
    sys.exit(1)


def resolve_existing(path, label):
    try:
        return path.resolve(strict=True)
    except FileNotFoundError:
        fail(f"{label} does not exist: {path}")
    except OSError as exc:
        fail(f"{label} cannot be resolved: {exc}")


def is_relative_to(child, parent):
    try:
        child.relative_to(parent)
        return True
    except ValueError:
        return False


def reject_group_or_world_writable(path, label):
    mode = path.stat().st_mode
    if mode & (stat.S_IWGRP | stat.S_IWOTH):
        fail(f"{label} must not be group/world writable: {path}")


def reject_loose_managed_directory(path, label):
    mode = path.stat().st_mode
    if mode & (stat.S_IWGRP | stat.S_IRWXO):
        fail(f"{label} permissions are too open: {path}")


if data_dir.is_symlink():
    fail(f"DATA_DIR must not be a symlink: {data_dir}")
if not data_dir.is_dir():
    fail(f"DATA_DIR is not a directory: {data_dir}")
if image_dir.is_symlink():
    fail(f"IMAGE_DIR must not be a symlink: {image_dir}")
if not image_dir.is_dir():
    fail(f"IMAGE_DIR is not a directory: {image_dir}")
if base_image.is_symlink():
    fail(f"base image must not be a symlink: {base_image}")
if not base_image.is_file():
    fail(f"base image is not a regular file: {base_image}")

data_real = resolve_existing(data_dir, "DATA_DIR")
image_real = resolve_existing(image_dir, "IMAGE_DIR")
base_real = resolve_existing(base_image, "base image")

if image_real == data_real or not is_relative_to(image_real, data_real):
    fail(f"IMAGE_DIR resolves outside DATA_DIR: {image_dir}")
if not is_relative_to(base_real, image_real):
    fail(f"base image resolves outside IMAGE_DIR: {base_image}")
if not is_relative_to(base_real, data_real):
    fail(f"base image resolves outside DATA_DIR: {base_image}")

reject_loose_managed_directory(data_real, "DATA_DIR")
reject_loose_managed_directory(image_real, "IMAGE_DIR")
reject_group_or_world_writable(base_real, "base image")
PY
}

validate_base_image_format() {
    qemu_info="$(qemu-img info --output=json "${IMAGE_DIR}/${IMAGE_FILE}" 2>/dev/null)" \
        || fail "qemu-img cannot read base image: ${IMAGE_FILE}"
    BASE_IMAGE_FORMAT="$(printf '%s' "$qemu_info" | python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
except json.JSONDecodeError as exc:
    print(f"kvm-host-smoke: qemu-img returned invalid JSON: {exc}", file=sys.stderr)
    sys.exit(1)

fmt = data.get("format")
if not isinstance(fmt, str) or not fmt:
    print("kvm-host-smoke: qemu-img output did not include image format", file=sys.stderr)
    sys.exit(1)

print(fmt)
')"
    [ "$BASE_IMAGE_FORMAT" = "qcow2" ] || fail "base image must be qcow2, got ${BASE_IMAGE_FORMAT}"
}

validate_not_wsl_host() {
    os_release_path="${1:-/proc/sys/kernel/osrelease}"
    [ -r "$os_release_path" ] || return 0

    os_release="$(cat "$os_release_path")" || return 0
    os_release_lc="$(printf '%s' "$os_release" | tr '[:upper:]' '[:lower:]')"
    case "$os_release_lc" in
        *microsoft*|*wsl*)
            fail "real Linux KVM host required; WSL is not supported for libvirt smoke tests"
            ;;
    esac
}

validate_kvm_device() {
    [ -e /dev/kvm ] || fail "/dev/kvm is required"
    [ -c /dev/kvm ] || fail "/dev/kvm must be a character device"
}

validate_cloud_init_tool() {
    if command -v cloud-localds >/dev/null 2>&1; then
        if cloud-localds --help >/dev/null 2>&1; then
            CLOUD_INIT_ISO_TOOL="cloud-localds"
            return
        fi
    fi
    if command -v genisoimage >/dev/null 2>&1; then
        if genisoimage --version >/dev/null 2>&1; then
            CLOUD_INIT_ISO_TOOL="genisoimage"
            return
        fi
    fi
    fail "a runnable cloud-localds or genisoimage is required"
}

libvirt_network_is_active() {
    awk -F: '
        tolower($1) == "active" {
            value = $2
            gsub(/^[ \t]+|[ \t]+$/, "", value)
            if (tolower(value) == "yes") {
                found = 1
            }
        }
        END { exit found ? 0 : 1 }
    '
}

libvirt_network_uses_bridge() {
    expected_bridge="$1"
    awk -F: -v expected_bridge="$expected_bridge" '
        tolower($1) == "bridge" {
            value = $2
            gsub(/^[ \t]+|[ \t]+$/, "", value)
            if (value == expected_bridge) {
                found = 1
            }
        }
        END { exit found ? 0 : 1 }
    '
}

validate_libvirt_network() {
    validate_libvirt_identifier "LIBVIRT_NETWORK_NAME" "$LIBVIRT_NETWORK_NAME"
    validate_libvirt_identifier "LIBVIRT_BRIDGE_NAME" "$LIBVIRT_BRIDGE_NAME"
    network_info="$(virsh --connect qemu:///system net-info "$LIBVIRT_NETWORK_NAME" 2>/dev/null)" \
        || fail "unable to read libvirt network ${LIBVIRT_NETWORK_NAME}"
    if ! printf '%s\n' "$network_info" | libvirt_network_is_active; then
        fail "libvirt network ${LIBVIRT_NETWORK_NAME} is not active"
    fi
    if ! printf '%s\n' "$network_info" | libvirt_network_uses_bridge "$LIBVIRT_BRIDGE_NAME"; then
        fail "libvirt network ${LIBVIRT_NETWORK_NAME} is not using bridge ${LIBVIRT_BRIDGE_NAME}"
    fi
}

validate_host_tools() {
    validate_not_wsl_host
    require_command curl
    require_command python3
    require_command virsh
    require_command qemu-img
    validate_kvm_device
    virsh --connect qemu:///system version >/dev/null 2>&1 \
        || fail "virsh qemu:///system is unavailable"
    validate_libvirt_network
    qemu-img --version >/dev/null 2>&1 \
        || fail "qemu-img is unavailable"
    validate_cloud_init_tool
}

api() {
    method="$1"
    path="$2"
    body="${3:-}"
    url="${MASTER_URL%/}${path}"
    local -a tls_args=()
    local -a proto_args=()
    if [ -n "$MASTER_CA_CERT_PATH" ]; then
        tls_args=(--cacert "$MASTER_CA_CERT_PATH")
    fi
    curl_proto_args proto_args

    if [ -n "$body" ]; then
        curl -q -fsS \
            "${proto_args[@]}" \
            --connect-timeout "$CURL_TIMEOUT_SECONDS" \
            --max-time "$CURL_TIMEOUT_SECONDS" \
            "${tls_args[@]}" \
            --config <(admin_curl_config) \
            -X "$method" \
            -H "Content-Type: application/json" \
            --data "$body" \
            "$url"
    else
        curl -q -fsS \
            "${proto_args[@]}" \
            --connect-timeout "$CURL_TIMEOUT_SECONDS" \
            --max-time "$CURL_TIMEOUT_SECONDS" \
            "${tls_args[@]}" \
            --config <(admin_curl_config) \
            -X "$method" \
            "$url"
    fi
}

curl_proto_args() {
    local -n out_ref="$1"
    case "$MASTER_URL" in
        http://*) out_ref=(--proto "=http,https") ;;
        *) out_ref=(--proto "=https") ;;
    esac
}

admin_curl_config() {
    local restore_xtrace=0
    case "$-" in
        *x*)
            restore_xtrace=1
            set +x
            ;;
    esac

    printf 'header = "Authorization: Bearer %s"\n' "$ADMIN_TOKEN"

    if [ "$restore_xtrace" = "1" ]; then
        set -x
    fi
}

redact_diagnostic_output() {
    ADMIN_TOKEN_TO_REDACT="${ADMIN_TOKEN:-}" python3 -c '
import os
import re
import sys

MAX_INPUT_BYTES = 64 * 1024
MAX_OUTPUT_CHARS = 8 * 1024

raw = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
input_truncated = len(raw) > MAX_INPUT_BYTES
if input_truncated:
    raw = raw[:MAX_INPUT_BYTES]

text = raw.decode("utf-8", errors="replace")

admin_token = os.environ.get("ADMIN_TOKEN_TO_REDACT", "")
if admin_token:
    text = text.replace(admin_token, "[REDACTED]")

text = re.sub(
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----",
    "[REDACTED PRIVATE KEY]",
    text,
    flags=re.IGNORECASE | re.DOTALL,
)
text = re.sub(
    r"([a-z][a-z0-9+.-]*://)[^/\s:@\\]+:[^@\s/\\]+@",
    r"\1[REDACTED]@",
    text,
    flags=re.IGNORECASE,
)
text = re.sub(
    r"\b(authorization\s*[:=]\s*(?:bearer|basic)?\s*)[^\s\"'\''},\\]+",
    r"\1[REDACTED]",
    text,
    flags=re.IGNORECASE,
)
text = re.sub(
    r"\b(x-agent-(?:credential|signature)\s*[:=]\s*)[^\s\"'\''},\\]+",
    r"\1[REDACTED]",
    text,
    flags=re.IGNORECASE,
)
text = re.sub(
    r"\b([a-z0-9_.-]*(?:token|credential|password|secret|private_key|signature)[a-z0-9_.-]*\s*[:=]\s*)[^\s\"'\''},\\]+",
    r"\1[REDACTED]",
    text,
    flags=re.IGNORECASE,
)
text = re.sub(
    r"^\s*((?:set-)?cookie\s*[:=]).*$",
    r"\1 [REDACTED]",
    text,
    flags=re.IGNORECASE | re.MULTILINE,
)

if admin_token:
    text = text.replace(admin_token, "[REDACTED]")

output_truncated = input_truncated or len(text) > MAX_OUTPUT_CHARS
if len(text) > MAX_OUTPUT_CHARS:
    text = text[:MAX_OUTPUT_CHARS]

sys.stdout.write(text)
if output_truncated:
    if text and not text.endswith("\n"):
        sys.stdout.write("\n")
    sys.stdout.write("...[truncated]\n")
'
}

print_failed_task_logs() {
    task_id="$1"
    api GET "/api/admin/tasks/${task_id}/logs" 2>/dev/null | redact_diagnostic_output >&2 || true
}

json_get() {
    path="$1"
    python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    for part in sys.argv[1].split("."):
        if isinstance(data, list):
            data = data[int(part)]
        else:
            data = data[part]
except (json.JSONDecodeError, KeyError, IndexError, ValueError, TypeError):
    sys.exit(1)
if data is None:
    sys.exit(1)
print(data)
' "$path"
}

json_get_uuid() {
    label="$1"
    path="$2"
    value="$(json_get "$path")"
    validate_uuid "$label" "$value"
    printf '%s' "$value"
}

verify_task_response_vm_id() {
    label="$1"
    task_json="$2"
    expected_vm_id="$3"

    response_vm_id="$(printf '%s' "$task_json" | json_get_uuid "${label} vm_id" kind.vm_id)"
    [ "$response_vm_id" = "$expected_vm_id" ] || fail "${label} vm_id did not match requested VM"
}

json_task_logs_include_task_started() {
    expected_task_id="$1"
    expected_node_id="$2"
    python3 -c '
import json
import sys

expected_task_id = sys.argv[1]
expected_node_id = sys.argv[2]

try:
    logs = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)

if not isinstance(logs, list):
    sys.exit(1)

for log in logs:
    if (
        isinstance(log, dict)
        and log.get("task_id") == expected_task_id
        and log.get("node_id") == expected_node_id
        and log.get("message") == "task executor started"
    ):
        sys.exit(0)

sys.exit(1)
' "$expected_task_id" "$expected_node_id"
}

verify_task_start_log() {
    task_id="$1"
    label="$2"

    validate_uuid "${label} task id" "$task_id"
    if ! logs_json="$(api GET "/api/admin/tasks/${task_id}/logs")"; then
        echo "kvm-host-smoke: ${label} task logs did not include task executor started" >&2
        return 1
    fi
    if ! printf '%s' "$logs_json" | json_task_logs_include_task_started "$task_id" "$NODE_ID"; then
        echo "kvm-host-smoke: ${label} task logs did not include task executor started" >&2
        return 1
    fi
}

json_audit_logs_cover_smoke_tasks() {
    node_id="$1"
    vm_id="$2"
    create_task_id="$3"
    reinstall_task_id="${4:-}"
    stop_task_id="${5:-}"
    start_task_id="${6:-}"
    reboot_task_id="${7:-}"
    delete_task_id="${8:-}"

    python3 -c '
import json
import sys

node_id, vm_id, create_task_id, reinstall_task_id, stop_task_id, start_task_id, reboot_task_id, delete_task_id = sys.argv[1:9]

try:
    logs = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(1)

if not isinstance(logs, list):
    sys.exit(1)

task_specs = [
    ("task.create_vm", create_task_id, "create_vm"),
    ("task.reinstall_vm", reinstall_task_id, "reinstall_vm"),
    ("task.stop_vm", stop_task_id, "stop_vm"),
    ("task.start_vm", start_task_id, "start_vm"),
    ("task.reboot_vm", reboot_task_id, "reboot_vm"),
    ("task.delete_vm", delete_task_id, "delete_vm"),
]
task_specs = [spec for spec in task_specs if spec[1]]


def detail(log):
    value = log.get("detail") if isinstance(log, dict) else None
    return value if isinstance(value, dict) else {}


def has_task_detail(action, task_id, task_kind, status=None):
    for log in logs:
        if not isinstance(log, dict):
            continue
        log_detail = detail(log)
        if (
            log.get("action") == action
            and log.get("node_id") == node_id
            and log.get("task_id") == task_id
            and log_detail.get("task_kind") == task_kind
            and log_detail.get("vm_id") == vm_id
            and (status is None or log_detail.get("status") == status)
        ):
            return True
    return False


def has_task_log_append(task_id):
    for log in logs:
        if not isinstance(log, dict):
            continue
        log_detail = detail(log)
        message_bytes = log_detail.get("message_bytes")
        if (
            log.get("action") == "task.log.append"
            and log.get("node_id") == node_id
            and log.get("task_id") == task_id
            and isinstance(message_bytes, int)
            and message_bytes > 0
        ):
            return True
    return False


for admin_action, task_id, task_kind in task_specs:
    if not has_task_detail(admin_action, task_id, task_kind):
        sys.exit(1)
    if not has_task_detail("task.assigned", task_id, task_kind):
        sys.exit(1)
    if not has_task_detail("task.status_update", task_id, task_kind, "succeeded"):
        sys.exit(1)
    if not has_task_log_append(task_id):
        sys.exit(1)
' "$node_id" "$vm_id" "$create_task_id" "$reinstall_task_id" "$stop_task_id" "$start_task_id" "$reboot_task_id" "$delete_task_id"
}

verify_smoke_audit_logs() {
    vm_id="$1"
    create_task_id="$2"
    reinstall_task_id="${3:-}"
    stop_task_id="${4:-}"
    start_task_id="${5:-}"
    reboot_task_id="${6:-}"
    delete_task_id="${7:-}"

    validate_uuid "audit vm id" "$vm_id"
    validate_uuid "audit create task id" "$create_task_id"
    [ -z "$reinstall_task_id" ] || validate_uuid "audit reinstall task id" "$reinstall_task_id"
    [ -z "$stop_task_id" ] || validate_uuid "audit stop task id" "$stop_task_id"
    [ -z "$start_task_id" ] || validate_uuid "audit start task id" "$start_task_id"
    [ -z "$reboot_task_id" ] || validate_uuid "audit reboot task id" "$reboot_task_id"
    [ -z "$delete_task_id" ] || validate_uuid "audit delete task id" "$delete_task_id"

    if ! audit_logs_json="$(api GET "/api/admin/audit-logs")"; then
        echo "kvm-host-smoke: unable to read audit logs for smoke verification" >&2
        return 1
    fi
    if ! printf '%s' "$audit_logs_json" |
        json_audit_logs_cover_smoke_tasks \
            "$NODE_ID" \
            "$vm_id" \
            "$create_task_id" \
            "$reinstall_task_id" \
            "$stop_task_id" \
            "$start_task_id" \
            "$reboot_task_id" \
            "$delete_task_id"; then
        echo "kvm-host-smoke: audit logs did not include the expected task lifecycle entries" >&2
        return 1
    fi
}

verify_create_response_plan_id() {
    task_json="$1"

    [ -n "$PLAN_ID" ] || return 0
    if ! response_plan_id="$(printf '%s' "$task_json" | json_get_uuid "create response plan_id" kind.plan_id 2>/dev/null)"; then
        fail "create response plan_id did not match selected PLAN_ID"
    fi
    [ "$response_plan_id" = "$PLAN_ID" ] || fail "create response plan_id did not match selected PLAN_ID"
}

json_image_record_for_file() {
    file_name="$1"
    python3 -c '
import json, sys
file_name = sys.argv[1]
for image in json.load(sys.stdin):
    if image.get("file_name") == file_name:
        print("{}\t{}".format(image["id"], str(image.get("enabled") is True).lower()))
        sys.exit(0)
sys.exit(1)
' "$file_name"
}

make_image_payload() {
    IMAGE_NAME="$IMAGE_NAME" IMAGE_FILE="$IMAGE_FILE" python3 -c '
import json, os
print(json.dumps({
    "name": os.environ["IMAGE_NAME"],
    "file_name": os.environ["IMAGE_FILE"],
    "enabled": True,
}, separators=(",", ":")))
'
}

make_ip_pool_payload() {
    IP_POOL_NAME="$IP_POOL_NAME" IP_POOL_CIDR="$IP_POOL_CIDR" IP_POOL_GATEWAY="$IP_POOL_GATEWAY" python3 -c '
import json, os
print(json.dumps({
    "name": os.environ["IP_POOL_NAME"],
    "cidr": os.environ["IP_POOL_CIDR"],
    "gateway_ip": os.environ["IP_POOL_GATEWAY"],
}, separators=(",", ":")))
'
}

make_plan_payload() {
    PLAN_NAME="$PLAN_NAME" PLAN_SLUG="$PLAN_SLUG" CPU_CORES="$CPU_CORES" MEMORY_MB="$MEMORY_MB" DISK_GB="$DISK_GB" python3 -c '
import json, os
print(json.dumps({
    "name": os.environ["PLAN_NAME"],
    "slug": os.environ["PLAN_SLUG"],
    "cpu_cores": int(os.environ["CPU_CORES"]),
    "memory_mb": int(os.environ["MEMORY_MB"]),
    "disk_gb": int(os.environ["DISK_GB"]),
    "enabled": True,
}, separators=(",", ":")))
'
}

verify_image_enabled_response() {
    image_json="$1"
    image_file="$2"

    response_file_name="$(printf '%s' "$image_json" | json_get file_name)"
    [ "$response_file_name" = "$image_file" ] || fail "image API returned unexpected file_name: $response_file_name"

    response_enabled="$(printf '%s' "$image_json" | json_get enabled)"
    [ "$response_enabled" = "True" ] || fail "image API did not return enabled=true for $image_file"
}

json_ip_pool_record_for_network() {
    cidr="$1"
    gateway_ip="$2"
    python3 -c '
import json, sys
cidr, gateway_ip = sys.argv[1:3]
for pool in json.load(sys.stdin):
    if pool.get("cidr") == cidr and pool.get("gateway_ip") == gateway_ip:
        print(pool["id"])
        sys.exit(0)
sys.exit(1)
' "$cidr" "$gateway_ip"
}

json_plan_record_for_slug() {
    slug="$1"
    python3 -c '
import json, sys
slug = sys.argv[1]
for plan in json.load(sys.stdin):
    if plan.get("slug") == slug:
        print("{}\t{}\t{}\t{}\t{}".format(
            plan["id"],
            str(plan.get("enabled") is True).lower(),
            plan.get("cpu_cores"),
            plan.get("memory_mb"),
            plan.get("disk_gb"),
        ))
        sys.exit(0)
sys.exit(1)
' "$slug"
}

verify_ip_pool_response() {
    pool_json="$1"

    response_cidr="$(printf '%s' "$pool_json" | json_get cidr)"
    [ "$response_cidr" = "$IP_POOL_CIDR" ] || fail "IP pool API returned unexpected cidr: $response_cidr"

    response_gateway="$(printf '%s' "$pool_json" | json_get gateway_ip)"
    [ "$response_gateway" = "$IP_POOL_GATEWAY" ] || fail "IP pool API returned unexpected gateway_ip: $response_gateway"
}

verify_plan_response() {
    plan_json="$1"

    response_slug="$(printf '%s' "$plan_json" | json_get slug)"
    [ "$response_slug" = "$PLAN_SLUG" ] || fail "plan API returned unexpected slug: $response_slug"

    response_cpu_cores="$(printf '%s' "$plan_json" | json_get cpu_cores)"
    [ "$response_cpu_cores" = "$CPU_CORES" ] || fail "plan API returned unexpected cpu_cores: $response_cpu_cores"

    response_memory_mb="$(printf '%s' "$plan_json" | json_get memory_mb)"
    [ "$response_memory_mb" = "$MEMORY_MB" ] || fail "plan API returned unexpected memory_mb: $response_memory_mb"

    response_disk_gb="$(printf '%s' "$plan_json" | json_get disk_gb)"
    [ "$response_disk_gb" = "$DISK_GB" ] || fail "plan API returned unexpected disk_gb: $response_disk_gb"

    response_enabled="$(printf '%s' "$plan_json" | json_get enabled)"
    [ "$response_enabled" = "True" ] || fail "plan API did not return enabled=true for $PLAN_SLUG"
}

make_create_vm_payload() {
    NODE_ID="$NODE_ID" IP_POOL_ID="$IP_POOL_ID" PLAN_ID="$PLAN_ID" VM_NAME="$VM_NAME" IMAGE_FILE="$IMAGE_FILE" SSH_PUBLIC_KEY="$SSH_PUBLIC_KEY" CPU_CORES="$CPU_CORES" MEMORY_MB="$MEMORY_MB" DISK_GB="$DISK_GB" python3 -c '
import json, os
vm = {
    "node_id": os.environ["NODE_ID"],
    "name": os.environ["VM_NAME"],
    "image": os.environ["IMAGE_FILE"],
    "cpu_cores": int(os.environ["CPU_CORES"]),
    "memory_mb": int(os.environ["MEMORY_MB"]),
    "disk_gb": int(os.environ["DISK_GB"]),
}
if os.environ.get("IP_POOL_ID"):
    vm["ip_pool_id"] = os.environ["IP_POOL_ID"]
if os.environ.get("PLAN_ID"):
    vm["plan_id"] = os.environ["PLAN_ID"]
if os.environ.get("SSH_PUBLIC_KEY"):
    vm["ssh_public_key"] = os.environ["SSH_PUBLIC_KEY"]
print(json.dumps({"vm": vm}, separators=(",", ":")))
'
}

make_vm_action_payload() {
    vm_id="$1"
    NODE_ID="$NODE_ID" VM_ID="$vm_id" python3 -c '
import json, os
print(json.dumps({
    "node_id": os.environ["NODE_ID"],
    "vm_id": os.environ["VM_ID"],
}, separators=(",", ":")))
'
}

poll_sleep_seconds() {
    configured_poll="$1"
    remaining_timeout="$2"

    if [ "$remaining_timeout" -lt "$configured_poll" ]; then
        printf '%s' "$remaining_timeout"
    else
        printf '%s' "$configured_poll"
    fi
}

wait_for_task() {
    task_id="$1"
    validate_uuid "task id" "$task_id"
    deadline=$((SECONDS + TIMEOUT_SECONDS))
    while [ "$SECONDS" -lt "$deadline" ]; do
        task_json="$(api GET "/api/admin/tasks/${task_id}")"
        if ! response_task_id="$(printf '%s' "$task_json" | json_get_uuid "task polling response id" id 2>/dev/null)"; then
            fail "task polling response did not include a valid id"
        fi
        [ "$response_task_id" = "$task_id" ] || fail "task polling response id did not match requested task"
        if ! status="$(printf '%s' "$task_json" | json_get status 2>/dev/null)"; then
            fail "task polling response did not include a status"
        fi
        case "$status" in
            succeeded)
                printf '%s' "$task_json"
                return 0
                ;;
            failed|canceled)
                echo "kvm-host-smoke: task ${task_id} ended as ${status}" >&2
                print_failed_task_logs "$task_id"
                return 1
                ;;
            pending|assigned|running)
                ;;
            *)
                fail "task ${task_id} returned unexpected task status"
                ;;
        esac
        remaining_timeout=$((deadline - SECONDS))
        [ "$remaining_timeout" -gt 0 ] || break
        sleep "$(poll_sleep_seconds "$POLL_SECONDS" "$remaining_timeout")"
    done
    fail "task ${task_id} did not finish within ${TIMEOUT_SECONDS}s"
}

ensure_node_ready() {
    nodes_json="$(api GET "/api/admin/nodes")"
    NODES_JSON="$nodes_json" python3 - "$NODE_ID" <<'PY'
import json
import os
import sys
from datetime import datetime, timedelta, timezone

expected_node_id = sys.argv[1]
STALE_AFTER = timedelta(seconds=2 * 60 * 60)


def fail(message):
    print(f"kvm-host-smoke: {message}", file=sys.stderr)
    sys.exit(1)


def parse_utc_timestamp(value):
    try:
        normalized = value.replace("Z", "+00:00")
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        fail("NODE_ID heartbeat timestamp is not valid")
    if parsed.tzinfo is None:
        fail("NODE_ID heartbeat timestamp is not UTC")
    return parsed.astimezone(timezone.utc)


try:
    nodes = json.loads(os.environ["NODES_JSON"])
except json.JSONDecodeError:
    fail("node list response was not valid JSON")

if not isinstance(nodes, list):
    fail("node list response was not an array")

target = None
for node in nodes:
    if isinstance(node, dict) and node.get("id") == expected_node_id:
        target = node
        break

if target is None:
    fail("NODE_ID was not found in master node list")
if target.get("status") != "online":
    fail("NODE_ID is not online in master")
if target.get("scheduling_enabled") is not True:
    fail("NODE_ID scheduling is disabled in master")
if not isinstance(target.get("agent_version"), str) or not target["agent_version"]:
    fail("NODE_ID has not completed agent registration in master")
if not isinstance(target.get("last_seen_at"), str) or not target["last_seen_at"]:
    fail("NODE_ID has not reported heartbeat in master")
last_seen_at = parse_utc_timestamp(target["last_seen_at"])
if datetime.now(timezone.utc) - last_seen_at > STALE_AFTER:
    fail("NODE_ID heartbeat is stale in master")
if target.get("libvirt_status") != "available":
    fail("NODE_ID libvirt_status is not available in master")
PY
}

ensure_image_registered() {
    images_json="$(api GET "/api/admin/images")"
    image_record="$(printf '%s' "$images_json" | json_image_record_for_file "$IMAGE_FILE" || true)"
    if [ -n "$image_record" ]; then
        image_id="${image_record%%	*}"
        validate_uuid "image catalog response id" "$image_id"
        image_enabled="${image_record#*	}"
        if [ "$image_enabled" = "true" ]; then
            return
        fi
        image_json="$(api POST "/api/admin/images/${image_id}/enabled" '{"enabled":true}')"
        verify_image_enabled_response "$image_json" "$IMAGE_FILE"
        return
    fi
    image_json="$(api POST /api/admin/images "$(make_image_payload)")"
    verify_image_enabled_response "$image_json" "$IMAGE_FILE"
}

ensure_ip_pool_selected() {
    [ -z "$IP_POOL_ID" ] || return 0
    [ -n "$IP_POOL_CIDR" ] || return 0

    pools_json="$(api GET "/api/admin/ip-pools")"
    pool_id="$(printf '%s' "$pools_json" | json_ip_pool_record_for_network "$IP_POOL_CIDR" "$IP_POOL_GATEWAY" || true)"
    if [ -n "$pool_id" ]; then
        validate_uuid "IP pool response id" "$pool_id"
        IP_POOL_ID="$pool_id"
        return
    fi

    pool_json="$(api POST /api/admin/ip-pools "$(make_ip_pool_payload)")"
    pool_id="$(printf '%s' "$pool_json" | json_get_uuid "IP pool create response id" id)"
    verify_ip_pool_response "$pool_json"
    IP_POOL_ID="$pool_id"
}

ensure_plan_selected() {
    [ -z "$PLAN_ID" ] || return 0
    [ -n "$PLAN_SLUG" ] || return 0

    plans_json="$(api GET "/api/admin/plans")"
    plan_record="$(printf '%s' "$plans_json" | json_plan_record_for_slug "$PLAN_SLUG" || true)"
    if [ -n "$plan_record" ]; then
        plan_id="${plan_record%%	*}"
        validate_uuid "plan catalog response id" "$plan_id"
        remaining="${plan_record#*	}"
        plan_enabled="${remaining%%	*}"
        remaining="${remaining#*	}"
        plan_cpu_cores="${remaining%%	*}"
        remaining="${remaining#*	}"
        plan_memory_mb="${remaining%%	*}"
        plan_disk_gb="${remaining#*	}"

        [ "$plan_cpu_cores" = "$CPU_CORES" ] || fail "PLAN_SLUG exists with different cpu_cores"
        [ "$plan_memory_mb" = "$MEMORY_MB" ] || fail "PLAN_SLUG exists with different memory_mb"
        [ "$plan_disk_gb" = "$DISK_GB" ] || fail "PLAN_SLUG exists with different disk_gb"
        [ "$plan_enabled" = "true" ] || fail "PLAN_SLUG matches a disabled plan"

        PLAN_ID="$plan_id"
        return
    fi

    plan_json="$(api POST /api/admin/plans "$(make_plan_payload)")"
    plan_id="$(printf '%s' "$plan_json" | json_get_uuid "plan create response id" id)"
    verify_plan_response "$plan_json"
    PLAN_ID="$plan_id"
}

verify_created_vm_on_host() {
    vm_id="$1"
    assigned_ip="${2:-}"
    assigned_ip_prefix="${3:-}"
    assigned_gateway_ip="${4:-}"
    domain="vps-${vm_id}"
    vm_dir="${DATA_DIR}/vms/${vm_id}"

    require_libvirt_domain "$domain"
    domain_state="$(read_libvirt_domain_state "$domain")"
    verify_domain_running_state "$domain_state"
    require_real_directory "$vm_dir" "managed VM directory"
    require_real_file "${vm_dir}/disk.qcow2" "managed VM disk"
    require_real_file "${vm_dir}/seed.iso" "managed VM seed ISO"
    require_real_file "${vm_dir}/domain.xml" "managed VM domain XML"
    require_real_file "${vm_dir}/user-data" "managed VM cloud-init user-data"
    require_real_file "${vm_dir}/meta-data" "managed VM cloud-init meta-data"
    verify_cloud_init_artifacts_on_host \
        "$vm_id" \
        "${vm_dir}/user-data" \
        "${vm_dir}/meta-data" || return 1
    verify_network_config_on_host \
        "${vm_dir}/network-config" \
        "$assigned_ip" \
        "$assigned_ip_prefix" \
        "$assigned_gateway_ip" || return 1
    verify_domain_metadata_on_host \
        "$vm_id" \
        "${vm_dir}/domain.xml" \
        "${vm_dir}/disk.qcow2" \
        "${vm_dir}/seed.iso" || return 1
    require_qcow2_image "${vm_dir}/disk.qcow2" "managed VM disk" || return 1
}

verify_domain_running_state() {
    state="$(printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ "$state" = "running" ] || fail "domain is not running after create: $state"
}

verify_domain_stopped_state() {
    state="$(printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ "$state" = "shut off" ] || fail "domain is not shut off after stop: $state"
}

wait_for_domain_state() {
    domain="$1"
    expected_state="$2"
    deadline=$((SECONDS + TIMEOUT_SECONDS))
    while [ "$SECONDS" -lt "$deadline" ]; do
        domain_state="$(read_libvirt_domain_state "$domain")"
        state="$(printf '%s' "$domain_state" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        if [ "$state" = "$expected_state" ]; then
            printf '%s' "$domain_state"
            return 0
        fi
        remaining_timeout=$((deadline - SECONDS))
        [ "$remaining_timeout" -gt 0 ] || break
        sleep "$(poll_sleep_seconds "$POLL_SECONDS" "$remaining_timeout")"
    done
    fail "domain ${domain} did not reach state ${expected_state} within ${TIMEOUT_SECONDS}s"
}

verify_stopped_vm_on_host() {
    vm_id="$1"
    assigned_ip="${2:-}"
    assigned_ip_prefix="${3:-}"
    assigned_gateway_ip="${4:-}"
    domain="vps-${vm_id}"
    vm_dir="${DATA_DIR}/vms/${vm_id}"

    require_libvirt_domain "$domain"
    domain_state="$(wait_for_domain_state "$domain" "shut off")"
    verify_domain_stopped_state "$domain_state"
    require_real_directory "$vm_dir" "managed VM directory"
    require_real_file "${vm_dir}/disk.qcow2" "managed VM disk"
    require_real_file "${vm_dir}/seed.iso" "managed VM seed ISO"
    require_real_file "${vm_dir}/domain.xml" "managed VM domain XML"
    require_real_file "${vm_dir}/user-data" "managed VM cloud-init user-data"
    require_real_file "${vm_dir}/meta-data" "managed VM cloud-init meta-data"
    verify_cloud_init_artifacts_on_host \
        "$vm_id" \
        "${vm_dir}/user-data" \
        "${vm_dir}/meta-data" || return 1
    verify_network_config_on_host \
        "${vm_dir}/network-config" \
        "$assigned_ip" \
        "$assigned_ip_prefix" \
        "$assigned_gateway_ip" || return 1
    verify_domain_metadata_on_host \
        "$vm_id" \
        "${vm_dir}/domain.xml" \
        "${vm_dir}/disk.qcow2" \
        "${vm_dir}/seed.iso" || return 1
    require_qcow2_image "${vm_dir}/disk.qcow2" "managed VM disk" || return 1
}

require_libvirt_domain() {
    domain="$1"
    virsh --connect qemu:///system dominfo "$domain" >/dev/null 2>&1 \
        || fail "libvirt domain ${domain} is unavailable"
}

read_libvirt_domain_state() {
    domain="$1"
    virsh --connect qemu:///system domstate "$domain" 2>/dev/null \
        || fail "unable to read libvirt domain state for ${domain}"
}

is_libvirt_domain_missing_output() {
    output="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$output" in
        *"domain not found"*|*"failed to get domain"*|*"no domain with matching name"*)
            return 0
            ;;
    esac
    return 1
}

require_libvirt_domain_absent() {
    domain="$1"
    if output="$(virsh --connect qemu:///system dominfo "$domain" 2>&1)"; then
        fail "domain still exists after delete: $domain"
    fi
    is_libvirt_domain_missing_output "$output" \
        || fail "unable to confirm libvirt domain ${domain} is absent"
}

require_real_directory() {
    path="$1"
    label="$2"

    [ -d "$path" ] || fail "$label missing: $path"
    [ ! -L "$path" ] || fail "$label must not be a symlink: $path"
}

require_real_file() {
    path="$1"
    label="$2"

    [ -f "$path" ] || fail "$label missing: $path"
    [ ! -L "$path" ] || fail "$label must not be a symlink: $path"
}

require_qcow2_image() {
    path="$1"
    label="$2"

    qemu_info="$(qemu-img info --force-share --output=json "$path" 2>/dev/null)" \
        || fail "qemu-img cannot read ${label}: ${path}"
    image_format="$(printf '%s' "$qemu_info" | python3 -c '
import json
import sys

label = sys.argv[1]

try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    print(f"kvm-host-smoke: qemu-img returned invalid JSON for {label}", file=sys.stderr)
    sys.exit(1)

fmt = data.get("format")
if not isinstance(fmt, str) or not fmt:
    print(f"kvm-host-smoke: qemu-img output did not include {label} image format", file=sys.stderr)
    sys.exit(1)

print(fmt)
' "$label")"
    [ "$image_format" = "qcow2" ] || fail "${label} must be qcow2, got ${image_format}"
}

verify_cloud_init_artifacts_on_host() {
    vm_id="$1"
    user_data_path="$2"
    meta_data_path="$3"

    python3 - "$vm_id" "$VM_NAME" "$user_data_path" "$meta_data_path" <<'PY'
from pathlib import Path
import sys

MAX_CLOUD_INIT_BYTES = 64 * 1024
vm_id, vm_name, user_data_text_path, meta_data_text_path = sys.argv[1:5]
user_data_path = Path(user_data_text_path)
meta_data_path = Path(meta_data_text_path)


def fail(message):
    print(f"kvm-host-smoke: {message}", file=sys.stderr)
    sys.exit(1)


def read_bounded_text(path, label):
    try:
        size = path.stat().st_size
    except OSError as exc:
        fail(f"{label} cannot be read: {exc}")
    if size > MAX_CLOUD_INIT_BYTES:
        fail(f"{label} is too large: {path}")
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        fail(f"{label} is not UTF-8: {exc}")
    except OSError as exc:
        fail(f"{label} cannot be read: {exc}")
    if any((ord(ch) < 32 and ch not in "\n\r\t") or ord(ch) == 127 for ch in text):
        fail(f"{label} contains unsupported control characters")
    return text


user_data = read_bounded_text(user_data_path, "managed VM cloud-init user-data")
meta_data = read_bounded_text(meta_data_path, "managed VM cloud-init meta-data")

user_lines = {line.strip() for line in user_data.splitlines()}
for required in ["#cloud-config", "ssh_pwauth: false", "disable_root: true"]:
    if required not in user_lines:
        fail(f"managed VM cloud-init user-data is missing {required}")

meta_values = {}
for line in meta_data.splitlines():
    if ":" not in line:
        continue
    key, value = line.split(":", 1)
    meta_values[key.strip()] = value.strip()

if meta_values.get("instance-id") != vm_id:
    fail("managed VM cloud-init meta-data instance-id mismatch")
if meta_values.get("local-hostname") != vm_name:
    fail("managed VM cloud-init meta-data hostname mismatch")
PY
}

validate_task_network_metadata() {
    assigned_ip="$1"
    assigned_ip_prefix="$2"
    assigned_gateway_ip="$3"
    present_count=0
    [ -n "$assigned_ip" ] && present_count=$((present_count + 1))
    [ -n "$assigned_ip_prefix" ] && present_count=$((present_count + 1))
    [ -n "$assigned_gateway_ip" ] && present_count=$((present_count + 1))

    if [ "$present_count" -eq 0 ]; then
        [ -z "$IP_POOL_ID" ] || fail "create response did not include assigned IP metadata for IP_POOL_ID"
        return
    fi
    [ "$present_count" -eq 3 ] || fail "create response contained partial assigned IP metadata"

    python3 - "$assigned_ip" "$assigned_ip_prefix" "$assigned_gateway_ip" <<'PY'
import ipaddress
import sys

assigned_ip_text, prefix_text, gateway_ip_text = sys.argv[1:4]


def fail(message):
    print(f"kvm-host-smoke: {message}", file=sys.stderr)
    sys.exit(1)


try:
    assigned_ip = ipaddress.IPv4Address(assigned_ip_text)
    gateway_ip = ipaddress.IPv4Address(gateway_ip_text)
    prefix = int(prefix_text)
except ValueError:
    fail("create response assigned IP metadata is malformed")

if prefix < 16 or prefix > 30:
    fail("create response assigned IP prefix is outside /16 through /30")
if assigned_ip == gateway_ip:
    fail("create response assigned IP must differ from gateway")

network = ipaddress.IPv4Network(f"{assigned_ip}/{prefix}", strict=False)
if gateway_ip not in network:
    fail("create response assigned gateway is outside the assigned IP network")
PY
}

verify_network_config_on_host() {
    network_config_path="$1"
    assigned_ip="$2"
    assigned_ip_prefix="$3"
    assigned_gateway_ip="$4"

    validate_task_network_metadata "$assigned_ip" "$assigned_ip_prefix" "$assigned_gateway_ip"
    if [ -z "$assigned_ip" ]; then
        [ ! -e "$network_config_path" ] && [ ! -L "$network_config_path" ] ||
            fail "managed VM network-config exists without assigned IP metadata: $network_config_path"
        return
    fi

    require_real_file "$network_config_path" "managed VM network-config"
    python3 - "$network_config_path" "$assigned_ip" "$assigned_ip_prefix" "$assigned_gateway_ip" <<'PY'
from pathlib import Path
import ipaddress
import sys

MAX_NETWORK_CONFIG_BYTES = 64 * 1024
path = Path(sys.argv[1])
assigned_ip_text, prefix_text, gateway_ip_text = sys.argv[2:5]


def fail(message):
    print(f"kvm-host-smoke: {message}", file=sys.stderr)
    sys.exit(1)


try:
    assigned_ip = ipaddress.IPv4Address(assigned_ip_text)
    gateway_ip = ipaddress.IPv4Address(gateway_ip_text)
    prefix = int(prefix_text)
except ValueError:
    fail("assigned IP metadata is malformed before network-config verification")

if prefix < 16 or prefix > 30:
    fail("assigned IP prefix is outside /16 through /30 before network-config verification")
network = ipaddress.IPv4Network(f"{assigned_ip}/{prefix}", strict=False)
if assigned_ip == gateway_ip or gateway_ip not in network:
    fail("assigned IP metadata is inconsistent before network-config verification")

try:
    size = path.stat().st_size
except OSError as exc:
    fail(f"managed VM network-config cannot be read: {exc}")
if size > MAX_NETWORK_CONFIG_BYTES:
    fail(f"managed VM network-config is too large: {path}")

try:
    text = path.read_text(encoding="utf-8")
except UnicodeDecodeError as exc:
    fail(f"managed VM network-config is not UTF-8: {exc}")
except OSError as exc:
    fail(f"managed VM network-config cannot be read: {exc}")

if any((ord(ch) < 32 and ch not in "\n\r\t") or ord(ch) == 127 for ch in text):
    fail("managed VM network-config contains unsupported control characters")

lines = [line.strip() for line in text.splitlines()]
required_lines = {
    "version: 2",
    "dhcp4: false",
    f"- {assigned_ip}/{prefix}",
    "to: default",
    f"via: {gateway_ip}",
}
missing = sorted(required_lines.difference(lines))
if missing:
    fail(f"managed VM network-config is missing expected static IPv4 fields: {', '.join(missing)}")
PY
}

verify_domain_metadata_on_host() {
    vm_id="$1"
    domain_xml="$2"
    disk_path="$3"
    seed_path="$4"

    python3 - "$vm_id" "$domain_xml" "$disk_path" "$seed_path" <<'PY'
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

MAX_DOMAIN_XML_BYTES = 1024 * 1024
vm_id = sys.argv[1]
domain_xml = Path(sys.argv[2])
disk_path = sys.argv[3]
seed_path = sys.argv[4]
expected_name = f"vps-{vm_id}"


def fail(message):
    print(f"kvm-host-smoke: {message}", file=sys.stderr)
    sys.exit(1)


try:
    domain_xml_size = domain_xml.stat().st_size
except OSError as exc:
    fail(f"managed VM domain XML metadata cannot be read: {exc}")
if domain_xml_size > MAX_DOMAIN_XML_BYTES:
    fail(f"managed VM domain XML metadata is too large: {domain_xml}")

try:
    root = ET.parse(domain_xml).getroot()
except ET.ParseError as exc:
    fail(f"managed VM domain XML is malformed: {exc}")
except OSError as exc:
    fail(f"managed VM domain XML cannot be read: {exc}")

if root.tag != "domain":
    fail("managed VM domain XML root is not <domain>")

name = root.findtext("name")
uuid = root.findtext("uuid")
if name != expected_name:
    fail(f"managed VM domain XML name mismatch: expected {expected_name}")
if uuid != vm_id:
    fail(f"managed VM domain XML UUID mismatch: expected {vm_id}")

devices = root.find("devices")
if devices is None:
    fail("managed VM domain XML has no <devices> section")


def disk_source_files(device):
    paths = []
    for disk in devices.findall("disk"):
        if disk.attrib.get("device") != device:
            continue
        source = disk.find("source")
        if source is not None and source.attrib.get("file"):
            paths.append(source.attrib["file"])
    return paths


if disk_source_files("disk") != [disk_path]:
    fail("managed VM domain XML disk device does not reference the managed disk")
if disk_source_files("cdrom") != [seed_path]:
    fail("managed VM domain XML cdrom device does not reference the managed seed ISO")
PY
}

verify_deleted_vm_on_host() {
    vm_id="$1"
    domain="vps-${vm_id}"
    vm_dir="${DATA_DIR}/vms/${vm_id}"

    require_libvirt_domain_absent "$domain"
    [ ! -e "$vm_dir" ] && [ ! -L "$vm_dir" ] || fail "managed VM directory still exists after delete: $vm_dir"
}

print_precheck_success() {
    ca_cert_configured=0
    if [ -n "$MASTER_CA_CERT_PATH" ]; then
        ca_cert_configured=1
    fi

    MASTER_URL="$MASTER_URL" \
        DATA_DIR="$DATA_DIR" \
        IMAGE_DIR="$IMAGE_DIR" \
        IMAGE_FILE="$IMAGE_FILE" \
        AGENT_BINARY_SHA256="$AGENT_BINARY_SHA256" \
        AGENT_BINARY_SHA256_VERIFIED="$AGENT_BINARY_SHA256_VERIFIED" \
        LIBVIRT_NETWORK_NAME="$LIBVIRT_NETWORK_NAME" \
        LIBVIRT_BRIDGE_NAME="$LIBVIRT_BRIDGE_NAME" \
        BASE_IMAGE_FORMAT="${BASE_IMAGE_FORMAT:-unknown}" \
        CA_CERT_CONFIGURED="$ca_cert_configured" \
        CLOUD_INIT_ISO_TOOL="${CLOUD_INIT_ISO_TOOL:-unknown}" \
        CURL_TIMEOUT_SECONDS="$CURL_TIMEOUT_SECONDS" \
        TIMEOUT_SECONDS="$TIMEOUT_SECONDS" \
        POLL_SECONDS="$POLL_SECONDS" \
        python3 -c '
import json
import os

result = {
    "precheck_only": True,
    "host_preflight": "ok",
    "agent_config_registered": True,
    "master_health_verified": True,
    "agent_binary_sha256_verified": os.environ["AGENT_BINARY_SHA256_VERIFIED"] == "1",
    "master_url": os.environ["MASTER_URL"],
    "data_dir": os.environ["DATA_DIR"],
    "image_dir": os.environ["IMAGE_DIR"],
    "image_file": os.environ["IMAGE_FILE"],
    "libvirt_network_name": os.environ["LIBVIRT_NETWORK_NAME"],
    "libvirt_bridge_name": os.environ["LIBVIRT_BRIDGE_NAME"],
    "base_image_format": os.environ["BASE_IMAGE_FORMAT"],
    "ca_cert_configured": os.environ["CA_CERT_CONFIGURED"] == "1",
    "cloud_init_iso_tool": os.environ["CLOUD_INIT_ISO_TOOL"],
    "curl_timeout_seconds": int(os.environ["CURL_TIMEOUT_SECONDS"]),
    "timeout_seconds": int(os.environ["TIMEOUT_SECONDS"]),
    "poll_seconds": int(os.environ["POLL_SECONDS"]),
}
if os.environ.get("AGENT_BINARY_SHA256"):
    result["agent_binary_sha256"] = os.environ["AGENT_BINARY_SHA256"].lower()
print(json.dumps(result, indent=2))
'
}

print_cleanup_failure_hint() {
    vm_id="$1"
    delete_task_id="$2"
    domain="vps-${vm_id}"
    vm_dir="${DATA_DIR}/vms/${vm_id}"

    {
        echo "kvm-host-smoke: cleanup did not complete; manual host inspection is required"
        echo "kvm-host-smoke: delete_task_id=${delete_task_id}"
        echo "kvm-host-smoke: domain=${domain}"
        echo "kvm-host-smoke: managed_dir=${vm_dir}"
    } >&2
}

cleanup_created_vm() {
    vm_id="$1"
    if ! delete_task_json="$(api POST /api/admin/tasks/delete-vm "$(make_vm_action_payload "$vm_id")")"; then
        print_cleanup_failure_hint "$vm_id" "unavailable"
        return 1
    fi
    if ! delete_task_id="$(printf '%s' "$delete_task_json" | json_get_uuid "delete response task id" id)"; then
        print_cleanup_failure_hint "$vm_id" "unavailable"
        return 1
    fi
    if ! verify_task_response_vm_id "delete response" "$delete_task_json" "$vm_id"; then
        print_cleanup_failure_hint "$vm_id" "$delete_task_id"
        return 1
    fi

    if ! wait_for_task "$delete_task_id" >/dev/null; then
        print_cleanup_failure_hint "$vm_id" "$delete_task_id"
        return 1
    fi

    if ! verify_deleted_vm_on_host "$vm_id"; then
        print_cleanup_failure_hint "$vm_id" "$delete_task_id"
        return 1
    fi

    printf '%s' "$delete_task_id"
}

queue_vm_action_task() {
    action="$1"
    vm_id="$2"
    action_task_json="$(api POST "/api/admin/tasks/${action}" "$(make_vm_action_payload "$vm_id")")"
    action_task_id="$(printf '%s' "$action_task_json" | json_get_uuid "${action} response task id" id)" || return 1
    verify_task_response_vm_id "${action} response" "$action_task_json" "$vm_id"
    printf '%s' "$action_task_id"
}

cleanup_after_smoke_failure() {
    vm_id="$1"
    phase="$2"

    [ "$CLEANUP" = "1" ] || return 0
    echo "kvm-host-smoke: ${phase} failed; attempting cleanup for VM ${vm_id}" >&2
    cleanup_created_vm "$vm_id" >/dev/null || true
}

main() {
    if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
        usage
        exit 0
    fi

    validate_args || return 1

    validate_agent_config || return 1
    validate_agent_doctor || return 1
    validate_full_lifecycle_agent_binary_verified || return 1
    validate_host_tools || return 1
    validate_agent_service || return 1
    validate_ca_cert_path || return 1
    validate_host_paths || return 1
    validate_base_image_format || return 1
    local -a health_tls_args=()
    local -a health_proto_args=()
    if [ -n "$MASTER_CA_CERT_PATH" ]; then
        health_tls_args=(--cacert "$MASTER_CA_CERT_PATH")
    fi
    curl_proto_args health_proto_args
    curl -q -fsS \
        "${health_proto_args[@]}" \
        --connect-timeout "$CURL_TIMEOUT_SECONDS" \
        --max-time "$CURL_TIMEOUT_SECONDS" \
        "${health_tls_args[@]}" \
        "${MASTER_URL%/}/healthz" >/dev/null || return 1

    if [ "$PRECHECK_ONLY" = "1" ]; then
        print_precheck_success
        return
    fi

    ensure_node_ready || return 1
    ensure_image_registered || return 1
    ensure_ip_pool_selected || return 1
    ensure_plan_selected || return 1
    create_task_json="$(api POST /api/admin/tasks/create-vm "$(make_create_vm_payload)")" || return 1
    create_task_id="$(printf '%s' "$create_task_json" | json_get_uuid "create response task id" id)" || return 1
    vm_id="$(printf '%s' "$create_task_json" | json_get_uuid "create response vm_id" kind.vm_id)" || return 1
    verify_create_response_plan_id "$create_task_json" || return 1
    assigned_ip="$(printf '%s' "$create_task_json" | json_get kind.assigned_ip 2>/dev/null || true)"
    assigned_ip_prefix="$(printf '%s' "$create_task_json" | json_get kind.assigned_ip_prefix 2>/dev/null || true)"
    assigned_gateway_ip="$(printf '%s' "$create_task_json" | json_get kind.assigned_gateway_ip 2>/dev/null || true)"
    validate_task_network_metadata "$assigned_ip" "$assigned_ip_prefix" "$assigned_gateway_ip" || return 1

    if ! wait_for_task "$create_task_id" >/dev/null; then
        cleanup_after_smoke_failure "$vm_id" "create task"
        return 1
    fi
    if ! verify_task_start_log "$create_task_id" "create"; then
        cleanup_after_smoke_failure "$vm_id" "create task log verification"
        return 1
    fi
    if ! verify_created_vm_on_host "$vm_id" "$assigned_ip" "$assigned_ip_prefix" "$assigned_gateway_ip"; then
        cleanup_after_smoke_failure "$vm_id" "create host verification"
        return 1
    fi

    reinstall_task_id=""
    if [ "$REINSTALL_AFTER_CREATE" = "1" ]; then
        if ! reinstall_task_json="$(api POST /api/admin/tasks/reinstall-vm "$(make_vm_action_payload "$vm_id")")"; then
            cleanup_after_smoke_failure "$vm_id" "reinstall task queue"
            return 1
        fi
        if ! reinstall_task_id="$(printf '%s' "$reinstall_task_json" | json_get_uuid "reinstall response task id" id)"; then
            cleanup_after_smoke_failure "$vm_id" "reinstall task response"
            return 1
        fi
        if ! verify_task_response_vm_id "reinstall response" "$reinstall_task_json" "$vm_id"; then
            cleanup_after_smoke_failure "$vm_id" "reinstall task response"
            return 1
        fi
        if ! wait_for_task "$reinstall_task_id" >/dev/null; then
            cleanup_after_smoke_failure "$vm_id" "reinstall task"
            return 1
        fi
        if ! verify_task_start_log "$reinstall_task_id" "reinstall"; then
            cleanup_after_smoke_failure "$vm_id" "reinstall task log verification"
            return 1
        fi
        if ! verify_created_vm_on_host "$vm_id" "$assigned_ip" "$assigned_ip_prefix" "$assigned_gateway_ip"; then
            cleanup_after_smoke_failure "$vm_id" "reinstall host verification"
            return 1
        fi
    fi

    stop_task_id=""
    start_task_id=""
    reboot_task_id=""
    if [ "$POWER_CYCLE_AFTER_CREATE" = "1" ]; then
        if ! stop_task_id="$(queue_vm_action_task stop-vm "$vm_id")"; then
            cleanup_after_smoke_failure "$vm_id" "stop task queue"
            return 1
        fi
        if ! wait_for_task "$stop_task_id" >/dev/null; then
            cleanup_after_smoke_failure "$vm_id" "stop task"
            return 1
        fi
        if ! verify_task_start_log "$stop_task_id" "stop"; then
            cleanup_after_smoke_failure "$vm_id" "stop task log verification"
            return 1
        fi
        if ! verify_stopped_vm_on_host "$vm_id" "$assigned_ip" "$assigned_ip_prefix" "$assigned_gateway_ip"; then
            cleanup_after_smoke_failure "$vm_id" "stop host verification"
            return 1
        fi

        if ! start_task_id="$(queue_vm_action_task start-vm "$vm_id")"; then
            cleanup_after_smoke_failure "$vm_id" "start task queue"
            return 1
        fi
        if ! wait_for_task "$start_task_id" >/dev/null; then
            cleanup_after_smoke_failure "$vm_id" "start task"
            return 1
        fi
        if ! verify_task_start_log "$start_task_id" "start"; then
            cleanup_after_smoke_failure "$vm_id" "start task log verification"
            return 1
        fi
        if ! verify_created_vm_on_host "$vm_id" "$assigned_ip" "$assigned_ip_prefix" "$assigned_gateway_ip"; then
            cleanup_after_smoke_failure "$vm_id" "start host verification"
            return 1
        fi

        if ! reboot_task_id="$(queue_vm_action_task reboot-vm "$vm_id")"; then
            cleanup_after_smoke_failure "$vm_id" "reboot task queue"
            return 1
        fi
        if ! wait_for_task "$reboot_task_id" >/dev/null; then
            cleanup_after_smoke_failure "$vm_id" "reboot task"
            return 1
        fi
        if ! verify_task_start_log "$reboot_task_id" "reboot"; then
            cleanup_after_smoke_failure "$vm_id" "reboot task log verification"
            return 1
        fi
        if ! verify_created_vm_on_host "$vm_id" "$assigned_ip" "$assigned_ip_prefix" "$assigned_gateway_ip"; then
            cleanup_after_smoke_failure "$vm_id" "reboot host verification"
            return 1
        fi
    fi

    delete_task_id=""
    if [ "$CLEANUP" = "1" ]; then
        delete_task_id="$(cleanup_created_vm "$vm_id")" || return 1
        verify_task_start_log "$delete_task_id" "delete" || return 1
    fi

    verify_smoke_audit_logs \
        "$vm_id" \
        "$create_task_id" \
        "$reinstall_task_id" \
        "$stop_task_id" \
        "$start_task_id" \
        "$reboot_task_id" \
        "$delete_task_id" || return 1

    ca_cert_configured=0
    if [ -n "$MASTER_CA_CERT_PATH" ]; then
        ca_cert_configured=1
    fi

    VM_ID="$vm_id" NODE_ID="$NODE_ID" PLAN_ID="$PLAN_ID" CREATE_TASK_ID="$create_task_id" REINSTALL_TASK_ID="$reinstall_task_id" STOP_TASK_ID="$stop_task_id" START_TASK_ID="$start_task_id" REBOOT_TASK_ID="$reboot_task_id" DELETE_TASK_ID="$delete_task_id" CLEANUP="$CLEANUP" FULL_LIFECYCLE_REQUIRED="$FULL_LIFECYCLE_REQUIRED" MASTER_URL="$MASTER_URL" ALLOW_HTTP="$ALLOW_HTTP" CA_CERT_CONFIGURED="$ca_cert_configured" CURL_TIMEOUT_SECONDS="$CURL_TIMEOUT_SECONDS" IMAGE_FILE="$IMAGE_FILE" IMAGE_NAME="$IMAGE_NAME" AGENT_BINARY_SHA256="$AGENT_BINARY_SHA256" AGENT_BINARY_SHA256_VERIFIED="$AGENT_BINARY_SHA256_VERIFIED" DATA_DIR="$DATA_DIR" IMAGE_DIR="$IMAGE_DIR" LIBVIRT_NETWORK_NAME="$LIBVIRT_NETWORK_NAME" LIBVIRT_BRIDGE_NAME="$LIBVIRT_BRIDGE_NAME" BASE_IMAGE_FORMAT="${BASE_IMAGE_FORMAT:-unknown}" CPU_CORES="$CPU_CORES" MEMORY_MB="$MEMORY_MB" DISK_GB="$DISK_GB" ASSIGNED_IP="$assigned_ip" ASSIGNED_IP_PREFIX="$assigned_ip_prefix" ASSIGNED_GATEWAY_IP="$assigned_gateway_ip" python3 -c '
import json, os
result = {
    "vm_id": os.environ["VM_ID"],
    "node_id": os.environ["NODE_ID"],
    "create_task_id": os.environ["CREATE_TASK_ID"],
    "cleanup": os.environ["CLEANUP"],
    "full_lifecycle_required": os.environ["FULL_LIFECYCLE_REQUIRED"] == "1",
    "agent_config_registered": True,
    "host_preflight_verified": True,
    "master_health_verified": True,
    "master_url": os.environ["MASTER_URL"],
    "allow_http": os.environ["ALLOW_HTTP"] == "1",
    "ca_cert_configured": os.environ["CA_CERT_CONFIGURED"] == "1",
    "curl_timeout_seconds": int(os.environ["CURL_TIMEOUT_SECONDS"]),
    "node_ready_verified": True,
    "task_logs_verified": True,
    "audit_logs_verified": True,
    "agent_binary_sha256_verified": os.environ["AGENT_BINARY_SHA256_VERIFIED"] == "1",
    "image_file": os.environ["IMAGE_FILE"],
    "image_name": os.environ["IMAGE_NAME"],
    "data_dir": os.environ["DATA_DIR"],
    "image_dir": os.environ["IMAGE_DIR"],
    "libvirt_network_name": os.environ["LIBVIRT_NETWORK_NAME"],
    "libvirt_bridge_name": os.environ["LIBVIRT_BRIDGE_NAME"],
    "base_image_format": os.environ["BASE_IMAGE_FORMAT"],
    "cpu_cores": int(os.environ["CPU_CORES"]),
    "memory_mb": int(os.environ["MEMORY_MB"]),
    "disk_gb": int(os.environ["DISK_GB"]),
    "lifecycle_coverage": {
        "create_vm": True,
        "delete_vm": bool(os.environ.get("DELETE_TASK_ID")),
        "reinstall_vm": bool(os.environ.get("REINSTALL_TASK_ID")),
        "power_cycle": bool(
            os.environ.get("STOP_TASK_ID")
            and os.environ.get("START_TASK_ID")
            and os.environ.get("REBOOT_TASK_ID")
        ),
    },
}
if os.environ.get("AGENT_BINARY_SHA256"):
    result["agent_binary_sha256"] = os.environ["AGENT_BINARY_SHA256"].lower()
if os.environ.get("PLAN_ID"):
    result["plan_id"] = os.environ["PLAN_ID"]
if os.environ.get("ASSIGNED_IP"):
    result["assigned_ip"] = os.environ["ASSIGNED_IP"]
    result["assigned_ip_prefix"] = int(os.environ["ASSIGNED_IP_PREFIX"])
    result["assigned_gateway_ip"] = os.environ["ASSIGNED_GATEWAY_IP"]
if os.environ.get("REINSTALL_TASK_ID"):
    result["reinstall_task_id"] = os.environ["REINSTALL_TASK_ID"]
if os.environ.get("STOP_TASK_ID"):
    result["stop_task_id"] = os.environ["STOP_TASK_ID"]
if os.environ.get("START_TASK_ID"):
    result["start_task_id"] = os.environ["START_TASK_ID"]
if os.environ.get("REBOOT_TASK_ID"):
    result["reboot_task_id"] = os.environ["REBOOT_TASK_ID"]
if os.environ.get("DELETE_TASK_ID"):
    result["delete_task_id"] = os.environ["DELETE_TASK_ID"]
print(json.dumps(result, indent=2))
'
}

main "$@"
