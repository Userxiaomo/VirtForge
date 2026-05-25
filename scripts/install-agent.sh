#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="/etc/vps-agent"
CONFIG_PATH="${CONFIG_DIR}/agent.toml"
AGENT_SHA256_PATH="${CONFIG_DIR}/agent.sha256"
DATA_DIR="/var/lib/vps-agent"
IMAGE_DIR="${DATA_DIR}/images"
SERVICE_PATH="/etc/systemd/system/vps-agent.service"
BINARY_PATH="/usr/local/bin/vps-agent"
EXECUTOR_MODE="libvirt"
NETWORK_NAME="default"
BRIDGE_NAME="virbr0"
AGENT_URL=""
AGENT_SHA256=""
MASTER_URL=""
NODE_ID=""
BOOTSTRAP_TOKEN=""
CA_CERT_PATH=""
CLIENT_IDENTITY_PATH=""
SKIP_DEPS=0
SKIP_DOCTOR=0
NO_START=0
AGENT_DOWNLOAD_CONNECT_TIMEOUT_SECONDS=30
AGENT_DOWNLOAD_MAX_TIME_SECONDS=300

usage() {
    cat <<'EOF'
Usage:
  install-agent.sh --master-url https://panel.example.com \
    --node-id <uuid> \
    --bootstrap-token <one-time-token> \
    [--agent-url https://panel.example.com/downloads/vps-agent] \
    [--agent-sha256 <expected-sha256-hex>] \
    [--ca-cert-path /etc/ssl/certs/master-ca.pem] \
    [--client-identity-path /etc/vps-agent/client-identity.pem] \
    [--executor-mode libvirt|mock] \
    [--data-dir /var/lib/vps-agent] \
    [--image-dir /var/lib/vps-agent/images] \
    [--network-name default] \
    [--bridge-name virbr0] \
    [--skip-deps] [--skip-doctor] [--no-start]

The bootstrap token is written once to /etc/vps-agent/agent.toml.
The agent removes it after successful registration and persists its long-term credential.
EOF
}

fail() {
    echo "install-agent: $*" >&2
    exit 1
}

contains_toml_unsafe_chars() {
    case "$1" in
        *[[:cntrl:]]*) return 0 ;;
        *\"*|*$'\n'*|*$'\r'*) return 0 ;;
        *) return 1 ;;
    esac
}

contains_url_unsafe_chars() {
    case "$1" in
        *[[:cntrl:]]*) return 0 ;;
        *"'"*|*\"*|*\\*|*'`'*|*$'\n'*|*$'\r'*|*$'\t'*|*" "*) return 0 ;;
        *) return 1 ;;
    esac
}

validate_toml_string() {
    name="$1"
    value="$2"
    if contains_toml_unsafe_chars "$value"; then
        fail "$name contains unsupported characters"
    fi
}

validate_bootstrap_token() {
    case "$BOOTSTRAP_TOKEN" in
        ""|*[!A-Za-z0-9._-]*)
            fail "--bootstrap-token may only contain ASCII letters, numbers, dots, dashes or underscores"
            ;;
    esac
    if [ "${#BOOTSTRAP_TOKEN}" -gt 256 ]; then
        fail "--bootstrap-token must be 256 characters or shorter"
    fi
}

contains_path_unsafe_chars() {
    case "$1" in
        *[[:cntrl:]]*) return 0 ;;
        *"'"*|*\"*|*\\*|*'`'*|*$'\n'*|*$'\r'*|*$'\t'*|*" "*) return 0 ;;
        *) return 1 ;;
    esac
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
        /) fail "$name must point to a file, not the filesystem root" ;;
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

validate_https_base_url() {
    name="$1"
    value="$2"

    [ -n "$value" ] || fail "$name must not be empty"
    if contains_url_unsafe_chars "$value"; then
        fail "$name contains unsupported characters"
    fi

    case "$value" in
        https://*) ;;
        *) fail "$name must start with https://" ;;
    esac

    remainder="${value#https://}"
    case "$remainder" in
        ""|/*) fail "$name must include a host" ;;
    esac
    case "$remainder" in
        *\?*|*#*) fail "$name must not include query strings or fragments" ;;
    esac

    authority="${remainder%%/*}"
    [ -n "$authority" ] || fail "$name must include a host"
    case "$authority" in
        *@*) fail "$name must not include username or password" ;;
    esac
    validate_url_authority "$name" "$authority"
    case "$remainder" in
        */*) validate_url_path_segments "$name" "${remainder#*/}" ;;
    esac
}

validate_url_path_segments() {
    name="$1"
    path="$2"

    lower_path="$(printf '%s' "$path" | tr 'A-F' 'a-f')"
    case "$lower_path" in
        *%2f*|*%5c*) fail "$name must not include encoded path separators" ;;
    esac
    case "$lower_path" in
        *%00*|*%01*|*%02*|*%03*|*%04*|*%05*|*%06*|*%07*|\
        *%08*|*%09*|*%0a*|*%0b*|*%0c*|*%0d*|*%0e*|*%0f*|\
        *%10*|*%11*|*%12*|*%13*|*%14*|*%15*|*%16*|*%17*|\
        *%18*|*%19*|*%1a*|*%1b*|*%1c*|*%1d*|*%1e*|*%1f*|\
        *%7f*) fail "$name must not include percent-encoded control characters" ;;
    esac

    remaining="$path"
    while :; do
        segment="${remaining%%/*}"
        normalized="${segment//%2e/.}"
        normalized="${normalized//%2E/.}"
        case "$normalized" in
            .|..) fail "$name must not include dot path segments" ;;
        esac
        [ "$remaining" != "$segment" ] || break
        remaining="${remaining#*/}"
    done
}

validate_url_port() {
    name="$1"
    port="$2"

    [ -n "$port" ] || fail "$name port must not be empty"
    case "$port" in
        *[!0-9]*) fail "$name port must be numeric" ;;
    esac
    if [ "${#port}" -gt 5 ] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        fail "$name port must be between 1 and 65535"
    fi
}

validate_url_authority() {
    name="$1"
    authority="$2"

    lower_authority="$(printf '%s' "$authority" | tr 'A-F' 'a-f')"
    case "$lower_authority" in
        *%2f*|*%5c*) fail "$name must not include encoded path separators" ;;
    esac
    case "$lower_authority" in
        *%00*|*%01*|*%02*|*%03*|*%04*|*%05*|*%06*|*%07*|\
        *%08*|*%09*|*%0a*|*%0b*|*%0c*|*%0d*|*%0e*|*%0f*|\
        *%10*|*%11*|*%12*|*%13*|*%14*|*%15*|*%16*|*%17*|\
        *%18*|*%19*|*%1a*|*%1b*|*%1c*|*%1d*|*%1e*|*%1f*|\
        *%7f*) fail "$name must not include percent-encoded control characters" ;;
    esac

    case "$authority" in
        \[*)
            case "$authority" in
                \[*\]*) ;;
                *) fail "$name must include a valid bracketed IPv6 host" ;;
            esac
            host="${authority#\[}"
            host="${host%%]*}"
            [ -n "$host" ] || fail "$name must include a host"
            after_bracket="${authority#*\]}"
            case "$after_bracket" in
                "") ;;
                :*) validate_url_port "$name" "${after_bracket#:}" ;;
                *) fail "$name must include a valid bracketed IPv6 host" ;;
            esac
            ;;
        *)
            case "$authority" in
                *"["*|*"]"*) fail "$name must include a valid bracketed IPv6 host" ;;
                *:*:*) fail "$name IPv6 hosts must be bracketed" ;;
            esac
            host="${authority%%:*}"
            [ -n "$host" ] || fail "$name must include a host"
            case "$authority" in
                *:*) validate_url_port "$name" "${authority##*:}" ;;
            esac
            ;;
    esac
}

validate_libvirt_identifier() {
    name="$1"
    value="$2"
    case "$value" in
        "") fail "$name must not be empty" ;;
    esac
    if [ "${#value}" -gt 64 ]; then
        fail "$name must be 64 characters or shorter"
    fi
    case "$value" in
        *[!A-Za-z0-9._-]*) fail "$name may only contain ASCII letters, numbers, dots, dashes or underscores" ;;
    esac
}

validate_secret_file_permissions() {
    name="$1"
    path="$2"

    [ -n "$path" ] || return 0
    [ ! -L "$path" ] || fail "$name must not be a symlink"
    command -v stat >/dev/null 2>&1 || fail "stat is required to validate $name permissions"
    mode="$(stat -c '%a' "$path")" || fail "unable to read $name permissions"
    case "$mode" in
        ""|*[!0-7]*) fail "unable to parse $name permissions" ;;
    esac
    if [ $((8#$mode & 077)) -ne 0 ]; then
        fail "$name must not be readable, writable or executable by group or other"
    fi
    owner_uid="$(stat -c '%u' "$path")" || fail "unable to read $name owner"
    installer_uid="$(id -u)" || fail "unable to read installer uid"
    case "$owner_uid" in
        ""|*[!0-9]*) fail "unable to parse $name owner" ;;
    esac
    case "$installer_uid" in
        ""|*[!0-9]*) fail "unable to parse installer uid" ;;
    esac
    if [ "$owner_uid" != "$installer_uid" ]; then
        fail "$name must be owned by the installer user"
    fi
}

validate_trust_anchor_file_permissions() {
    name="$1"
    path="$2"

    [ -n "$path" ] || return 0
    [ ! -L "$path" ] || fail "$name must not be a symlink"
    command -v stat >/dev/null 2>&1 || fail "stat is required to validate $name permissions"
    mode="$(stat -c '%a' "$path")" || fail "unable to read $name permissions"
    case "$mode" in
        ""|*[!0-7]*) fail "unable to parse $name permissions" ;;
    esac
    if [ $((8#$mode & 022)) -ne 0 ]; then
        fail "$name must not be writable by group or other"
    fi
}

validate_config_path_before_write() {
    [ ! -L "$CONFIG_PATH" ] || fail "$CONFIG_PATH must not be a symlink"
    if [ -e "$CONFIG_PATH" ] && [ ! -f "$CONFIG_PATH" ]; then
        fail "$CONFIG_PATH must be a regular file"
    fi
    if [ -e "$CONFIG_PATH" ]; then
        validate_secret_file_permissions "existing agent config" "$CONFIG_PATH"
    fi
}

validate_agent_sha256_path_before_write() {
    [ ! -L "$AGENT_SHA256_PATH" ] || fail "$AGENT_SHA256_PATH must not be a symlink"
    if [ -e "$AGENT_SHA256_PATH" ] && [ ! -f "$AGENT_SHA256_PATH" ]; then
        fail "$AGENT_SHA256_PATH must be a regular file"
    fi
    if [ -e "$AGENT_SHA256_PATH" ]; then
        validate_trust_anchor_file_permissions "agent SHA-256 proof" "$AGENT_SHA256_PATH"
    fi
}

validate_managed_directory_before_write() {
    name="$1"
    path="$2"

    [ ! -L "$path" ] || fail "$name must not be a symlink"
    if [ -e "$path" ] && [ ! -d "$path" ]; then
        fail "$name must be a directory"
    fi
}

validate_existing_directory_permissions() {
    name="$1"
    path="$2"
    forbidden_mask="$3"

    [ -e "$path" ] || return 0
    command -v stat >/dev/null 2>&1 || fail "stat is required to validate $name permissions"
    mode="$(stat -c '%a' "$path")" || fail "unable to read $name permissions"
    case "$mode" in
        ""|*[!0-7]*) fail "unable to parse $name permissions" ;;
    esac
    if [ $((8#$mode & 8#$forbidden_mask)) -ne 0 ]; then
        fail "$name permissions are too open"
    fi
    owner_uid="$(stat -c '%u' "$path")" || fail "unable to read $name owner"
    installer_uid="$(id -u)" || fail "unable to read installer uid"
    case "$owner_uid" in
        ""|*[!0-9]*) fail "unable to parse $name owner" ;;
    esac
    case "$installer_uid" in
        ""|*[!0-9]*) fail "unable to parse installer uid" ;;
    esac
    if [ "$owner_uid" != "$installer_uid" ]; then
        fail "$name must be owned by the installer user"
    fi
}

validate_managed_directories_before_write() {
    validate_managed_directory_before_write "config directory" "$CONFIG_DIR"
    validate_managed_directory_before_write "data directory" "$DATA_DIR"
    validate_existing_directory_permissions "config directory" "$CONFIG_DIR" 077
    validate_existing_directory_permissions "data directory" "$DATA_DIR" 027
    if [ "$EXECUTOR_MODE" = "libvirt" ]; then
        validate_managed_directory_before_write "image directory" "$IMAGE_DIR"
        validate_existing_directory_permissions "image directory" "$IMAGE_DIR" 027
    fi
}

validate_binary_path_before_install() {
    [ ! -L "$BINARY_PATH" ] || fail "$BINARY_PATH must not be a symlink"
    if [ -e "$BINARY_PATH" ] && [ ! -f "$BINARY_PATH" ]; then
        fail "$BINARY_PATH must be a regular file"
    fi
}

validate_binary_directory_before_install() {
    binary_dir="$(dirname "$BINARY_PATH")"
    [ ! -L "$binary_dir" ] || fail "agent binary directory must not be a symlink"
    if [ ! -d "$binary_dir" ]; then
        fail "agent binary directory must be a directory"
    fi
}

validate_service_path_before_write() {
    [ ! -L "$SERVICE_PATH" ] || fail "$SERVICE_PATH must not be a symlink"
    if [ -e "$SERVICE_PATH" ] && [ ! -f "$SERVICE_PATH" ]; then
        fail "$SERVICE_PATH must be a regular file"
    fi
}

validate_service_directory_before_write() {
    service_dir="$(dirname "$SERVICE_PATH")"
    [ ! -L "$service_dir" ] || fail "systemd service directory must not be a symlink"
    if [ -e "$service_dir" ] && [ ! -d "$service_dir" ]; then
        fail "systemd service directory must be a directory"
    fi
    validate_existing_directory_permissions "systemd service directory" "$service_dir" 022
}

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        fail "this installer must run as root"
    fi
}

ARG_VALUE=""
require_option_value() {
    name="$1"
    value="${2:-}"

    [ -n "$value" ] || fail "$name requires a value"
    case "$value" in
        --*) fail "$name requires a value" ;;
    esac

    ARG_VALUE="$value"
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --master-url)
                require_option_value "$1" "${2:-}"
                MASTER_URL="$ARG_VALUE"
                shift 2
                ;;
            --node-id)
                require_option_value "$1" "${2:-}"
                NODE_ID="$ARG_VALUE"
                shift 2
                ;;
            --bootstrap-token)
                require_option_value "$1" "${2:-}"
                BOOTSTRAP_TOKEN="$ARG_VALUE"
                shift 2
                ;;
            --agent-url)
                require_option_value "$1" "${2:-}"
                AGENT_URL="$ARG_VALUE"
                shift 2
                ;;
            --agent-sha256)
                require_option_value "$1" "${2:-}"
                AGENT_SHA256="$ARG_VALUE"
                shift 2
                ;;
            --ca-cert-path)
                require_option_value "$1" "${2:-}"
                CA_CERT_PATH="$ARG_VALUE"
                shift 2
                ;;
            --client-identity-path)
                require_option_value "$1" "${2:-}"
                CLIENT_IDENTITY_PATH="$ARG_VALUE"
                shift 2
                ;;
            --executor-mode)
                require_option_value "$1" "${2:-}"
                EXECUTOR_MODE="$ARG_VALUE"
                shift 2
                ;;
            --data-dir)
                require_option_value "$1" "${2:-}"
                DATA_DIR="$ARG_VALUE"
                IMAGE_DIR="${DATA_DIR}/images"
                shift 2
                ;;
            --image-dir)
                require_option_value "$1" "${2:-}"
                IMAGE_DIR="$ARG_VALUE"
                shift 2
                ;;
            --network-name)
                require_option_value "$1" "${2:-}"
                NETWORK_NAME="$ARG_VALUE"
                shift 2
                ;;
            --bridge-name)
                require_option_value "$1" "${2:-}"
                BRIDGE_NAME="$ARG_VALUE"
                shift 2
                ;;
            --skip-deps)
                SKIP_DEPS=1
                shift
                ;;
            --skip-doctor)
                SKIP_DOCTOR=1
                shift
                ;;
            --no-start)
                NO_START=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                fail "unknown argument: $1"
                ;;
        esac
    done
}

validate_args() {
    [ -n "$MASTER_URL" ] || fail "--master-url is required"
    [ -n "$NODE_ID" ] || fail "--node-id is required"
    [ -n "$BOOTSTRAP_TOKEN" ] || fail "--bootstrap-token is required"

    validate_toml_string "--master-url" "$MASTER_URL"
    validate_toml_string "--node-id" "$NODE_ID"
    validate_toml_string "--bootstrap-token" "$BOOTSTRAP_TOKEN"
    validate_bootstrap_token
    validate_toml_string "--data-dir" "$DATA_DIR"
    validate_toml_string "--image-dir" "$IMAGE_DIR"
    validate_controlled_dir "--data-dir" "$DATA_DIR"

    if [[ ! "$NODE_ID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
        fail "--node-id must be a UUID"
    fi

    validate_https_base_url "--master-url" "$MASTER_URL"

    case "$EXECUTOR_MODE" in
        libvirt|mock) ;;
        *) fail "--executor-mode must be libvirt or mock" ;;
    esac

    if [ -z "$AGENT_URL" ]; then
        AGENT_URL="${MASTER_URL%/}/downloads/vps-agent"
    fi
    validate_toml_string "--agent-url" "$AGENT_URL"

    validate_https_base_url "--agent-url" "$AGENT_URL"
    if [ -n "$AGENT_SHA256" ]; then
        case "$AGENT_SHA256" in
            ????????????????????????????????????????????????????????????????) ;;
            *) fail "--agent-sha256 must be a 64-character SHA-256 hex digest" ;;
        esac
        case "$AGENT_SHA256" in
            *[!A-Fa-f0-9]*) fail "--agent-sha256 must be a 64-character SHA-256 hex digest" ;;
        esac
    fi

    validate_linux_file_path "--ca-cert-path" "$CA_CERT_PATH"
    validate_linux_file_path "--client-identity-path" "$CLIENT_IDENTITY_PATH"
    if [ -n "$CA_CERT_PATH" ] && [ ! -f "$CA_CERT_PATH" ]; then
        fail "--ca-cert-path must point to an existing PEM file"
    fi
    if [ -n "$CLIENT_IDENTITY_PATH" ] && [ ! -f "$CLIENT_IDENTITY_PATH" ]; then
        fail "--client-identity-path must point to an existing PEM file"
    fi
    validate_trust_anchor_file_permissions "--ca-cert-path" "$CA_CERT_PATH"
    validate_secret_file_permissions "--client-identity-path" "$CLIENT_IDENTITY_PATH"
    if [ "$EXECUTOR_MODE" = "libvirt" ]; then
        validate_controlled_dir "--image-dir" "$IMAGE_DIR"
        validate_child_dir "--image-dir" "$IMAGE_DIR" "--data-dir" "$DATA_DIR"
        validate_libvirt_identifier "--network-name" "$NETWORK_NAME"
        validate_libvirt_identifier "--bridge-name" "$BRIDGE_NAME"
    fi
}

verify_agent_checksum() {
    artifact_path="$1"

    if [ -z "$AGENT_SHA256" ]; then
        return 0
    fi
    command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required when --agent-sha256 is set"

    expected="$(printf '%s' "$AGENT_SHA256" | tr 'A-F' 'a-f')"
    actual="$(sha256sum "$artifact_path" | awk '{print $1}')"
    if [ "$actual" != "$expected" ]; then
        fail "downloaded agent binary SHA-256 did not match --agent-sha256"
    fi
}

install_dependencies() {
    if [ "$SKIP_DEPS" -eq 1 ]; then
        return
    fi

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y \
            ca-certificates \
            curl \
            qemu-kvm \
            libvirt-daemon-system \
            qemu-utils \
            cloud-image-utils
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y \
            ca-certificates \
            curl \
            qemu-kvm \
            libvirt \
            libvirt-daemon-kvm \
            qemu-img \
            genisoimage
    elif command -v yum >/dev/null 2>&1; then
        yum install -y \
            ca-certificates \
            curl \
            qemu-kvm \
            libvirt \
            qemu-img \
            genisoimage
    else
        fail "supported package manager not found; install KVM/libvirt/qemu-img/cloud-init ISO tools manually and rerun with --skip-deps"
    fi
}

download_agent() {
    validate_binary_path_before_install
    validate_binary_directory_before_install
    command -v curl >/dev/null 2>&1 || fail "curl is required"
    tmp_binary="$(mktemp)"
    tmp_install=""
    trap 'rm -f "$tmp_binary" "$tmp_install"' EXIT

    curl_args=(
        -q
        -fsS
        --proto '=https'
        --connect-timeout "$AGENT_DOWNLOAD_CONNECT_TIMEOUT_SECONDS"
        --max-time "$AGENT_DOWNLOAD_MAX_TIME_SECONDS"
    )
    if [ -n "$CA_CERT_PATH" ]; then
        curl_args+=(--cacert "$CA_CERT_PATH")
    fi

    if ! curl "${curl_args[@]}" "$AGENT_URL" -o "$tmp_binary" >/dev/null 2>&1; then
        fail "agent download failed"
    fi
    verify_agent_checksum "$tmp_binary"
    binary_dir="$(dirname "$BINARY_PATH")"
    validate_binary_directory_before_install
    tmp_install="$(mktemp "${binary_dir}/.vps-agent.XXXXXX")"
    install -m 0755 "$tmp_binary" "$tmp_install"
    validate_binary_directory_before_install
    validate_binary_path_before_install
    mv -fT "$tmp_install" "$BINARY_PATH"
}

write_config() {
    validate_managed_directories_before_write
    install -d -m 0700 "$CONFIG_DIR"
    install -d -m 0750 "$DATA_DIR"
    if [ "$EXECUTOR_MODE" = "libvirt" ]; then
        install -d -m 0750 "$IMAGE_DIR"
    fi

    validate_managed_directories_before_write
    validate_config_path_before_write

    (
        umask 077
        tmp_config="$(mktemp "${CONFIG_DIR}/.agent.toml.XXXXXX")"
        trap 'rm -f "$tmp_config"' EXIT

        ca_cert_config_line=""
        if [ -n "$CA_CERT_PATH" ]; then
            ca_cert_config_line="ca_cert_path = \"$CA_CERT_PATH\""
        fi
        client_identity_config_line=""
        if [ -n "$CLIENT_IDENTITY_PATH" ]; then
            client_identity_config_line="client_identity_path = \"$CLIENT_IDENTITY_PATH\""
        fi
        if [ "$EXECUTOR_MODE" = "mock" ]; then
            cat > "$tmp_config" <<EOF
master_base_url = "$MASTER_URL"
node_id = "$NODE_ID"
data_dir = "$DATA_DIR"
heartbeat_interval_seconds = 30
bootstrap_token = "$BOOTSTRAP_TOKEN"
$ca_cert_config_line
$client_identity_config_line

[executor]
mode = "mock"
EOF
        else
            cat > "$tmp_config" <<EOF
master_base_url = "$MASTER_URL"
node_id = "$NODE_ID"
data_dir = "$DATA_DIR"
heartbeat_interval_seconds = 30
bootstrap_token = "$BOOTSTRAP_TOKEN"
$ca_cert_config_line
$client_identity_config_line

[executor]
mode = "libvirt"
image_dir = "$IMAGE_DIR"
network_name = "$NETWORK_NAME"
bridge_name = "$BRIDGE_NAME"
EOF
        fi
        chmod 0600 "$tmp_config"
        mv -fT "$tmp_config" "$CONFIG_PATH"
        validate_config_path_before_write
        trap - EXIT
    )
}

write_agent_sha256_file() {
    validate_managed_directory_before_write "config directory" "$CONFIG_DIR"
    validate_existing_directory_permissions "config directory" "$CONFIG_DIR" 077
    install -d -m 0700 "$CONFIG_DIR"
    validate_managed_directory_before_write "config directory" "$CONFIG_DIR"
    validate_existing_directory_permissions "config directory" "$CONFIG_DIR" 077
    validate_agent_sha256_path_before_write

    if [ -z "$AGENT_SHA256" ]; then
        rm -f "$AGENT_SHA256_PATH"
        return
    fi

    (
        tmp_sha256="$(mktemp "${CONFIG_DIR}/.agent.sha256.XXXXXX")"
        trap 'rm -f "$tmp_sha256"' EXIT
        printf '%s\n' "$(printf '%s' "$AGENT_SHA256" | tr 'A-F' 'a-f')" > "$tmp_sha256"
        chmod 0644 "$tmp_sha256"
        mv -fT "$tmp_sha256" "$AGENT_SHA256_PATH"
        validate_agent_sha256_path_before_write
        trap - EXIT
    )
}

write_service() {
    validate_service_path_before_write
    command -v systemctl >/dev/null 2>&1 || fail "systemd is required"
    service_dir="$(dirname "$SERVICE_PATH")"
    validate_service_directory_before_write

    (
        umask 077
        tmp_service="$(mktemp "${service_dir}/.vps-agent.service.XXXXXX")"
        trap 'rm -f "$tmp_service"' EXIT

        cat > "$tmp_service" <<EOF
[Unit]
Description=VPS Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
Environment=RUST_LOG=vps_agent=info
Environment=VPS_AGENT_CONFIG=$CONFIG_PATH
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=$BINARY_PATH
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$CONFIG_DIR $DATA_DIR
ProtectClock=true
ProtectHostname=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
LockPersonality=true
RestrictRealtime=true
MemoryDenyWriteExecute=true
RestrictSUIDSGID=true
CapabilityBoundingSet=
AmbientCapabilities=
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
SystemCallArchitectures=native
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
        chmod 0644 "$tmp_service"
        validate_service_directory_before_write
        validate_service_path_before_write
        mv -fT "$tmp_service" "$SERVICE_PATH"
        trap - EXIT
    )
}

run_doctor() {
    if [ "$SKIP_DOCTOR" -eq 1 ]; then
        return
    fi

    echo "install-agent: running vps-agent doctor before service start"
    if ! doctor_output="$(VPS_AGENT_CONFIG="$CONFIG_PATH" "$BINARY_PATH" doctor 2>&1)"; then
        fail "vps-agent doctor failed; rerun it manually with VPS_AGENT_CONFIG=${CONFIG_PATH} ${BINARY_PATH} doctor"
    fi
}

enable_service() {
    run_systemctl_step "daemon-reload" daemon-reload
    run_systemctl_step "enable" enable vps-agent.service
    if [ "$NO_START" -eq 0 ]; then
        run_systemctl_step "restart" restart vps-agent.service
    fi
}

run_systemctl_step() {
    local step="$1"
    shift

    if ! systemctl "$@" >/dev/null 2>&1; then
        fail "systemctl ${step} failed"
    fi
}

main() {
    parse_args "$@"
    require_root
    validate_args

    install_dependencies
    download_agent
    write_config
    write_agent_sha256_file
    write_service
    run_doctor
    enable_service

    echo "install-agent: vps-agent installed for node ${NODE_ID}"
    echo "install-agent: bootstrap token was written to ${CONFIG_PATH} and will be cleared by agent after registration"
}

main "$@"
