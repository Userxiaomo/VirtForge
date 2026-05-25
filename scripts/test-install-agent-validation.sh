#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Load installer functions without executing main.
source <(sed '/^main "\$@"/d' "$repo_root/scripts/install-agent.sh")

bash "$repo_root/scripts/install-agent.sh" --help >/dev/null

require_service_hardening() {
    service_file="$1"
    python3 - "$service_file" <<'PY'
from pathlib import Path
import sys

service_file = Path(sys.argv[1])
text = service_file.read_text(encoding="utf-8")
required_lines = [
    "Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "NoNewPrivileges=true",
    "PrivateTmp=true",
    "ProtectHome=true",
    "ProtectSystem=strict",
    "ReadWritePaths=/etc/vps-agent /var/lib/vps-agent",
    "ProtectClock=true",
    "ProtectHostname=true",
    "ProtectKernelTunables=true",
    "ProtectKernelModules=true",
    "ProtectControlGroups=true",
    "LockPersonality=true",
    "RestrictRealtime=true",
    "MemoryDenyWriteExecute=true",
    "RestrictSUIDSGID=true",
    "CapabilityBoundingSet=",
    "AmbientCapabilities=",
    "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK",
    "SystemCallArchitectures=native",
    "UMask=0077",
]
missing = [line for line in required_lines if line not in text]
if missing:
    print(f"{service_file}: missing systemd hardening directives: {', '.join(missing)}", file=sys.stderr)
    sys.exit(1)
PY
}

require_installer_service_hardening() {
    installer_file="$1"
    python3 - "$installer_file" <<'PY'
from pathlib import Path
import sys

installer_file = Path(sys.argv[1])
text = installer_file.read_text(encoding="utf-8")
required_snippets = [
    "Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    "NoNewPrivileges=true",
    "PrivateTmp=true",
    "ProtectHome=true",
    "ProtectSystem=strict",
    "ReadWritePaths=$CONFIG_DIR $DATA_DIR",
    "ProtectClock=true",
    "ProtectHostname=true",
    "ProtectKernelTunables=true",
    "ProtectKernelModules=true",
    "ProtectControlGroups=true",
    "LockPersonality=true",
    "RestrictRealtime=true",
    "MemoryDenyWriteExecute=true",
    "RestrictSUIDSGID=true",
    "CapabilityBoundingSet=",
    "AmbientCapabilities=",
    "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK",
    "SystemCallArchitectures=native",
    "UMask=0077",
]
missing = [snippet for snippet in required_snippets if snippet not in text]
if missing:
    print(f"{installer_file}: generated service is missing hardening snippets: {', '.join(missing)}", file=sys.stderr)
    sys.exit(1)
PY
}

require_installer_service_atomic_write() {
    installer_file="$1"
    python3 - "$installer_file" <<'PY'
from pathlib import Path
import sys

installer_file = Path(sys.argv[1])
text = installer_file.read_text(encoding="utf-8")
if 'cat > "$SERVICE_PATH"' in text:
    print(f"{installer_file}: write_service must not redirect directly to SERVICE_PATH", file=sys.stderr)
    sys.exit(1)
required_snippets = [
    'tmp_service="$(mktemp "${service_dir}/.vps-agent.service.XXXXXX")"',
    'validate_service_path_before_write\n        mv -fT "$tmp_service" "$SERVICE_PATH"',
    'mv -fT "$tmp_service" "$SERVICE_PATH"',
]
missing = [snippet for snippet in required_snippets if snippet not in text]
if missing:
    print(f"{installer_file}: write_service must use same-directory temp file and atomic rename: {', '.join(missing)}", file=sys.stderr)
    sys.exit(1)
PY
}

require_installer_config_atomic_write() {
    installer_file="$1"
    python3 - "$installer_file" <<'PY'
from pathlib import Path
import sys

installer_file = Path(sys.argv[1])
text = installer_file.read_text(encoding="utf-8")
if 'cat > "$CONFIG_PATH"' in text:
    print(f"{installer_file}: write_config must not redirect directly to CONFIG_PATH", file=sys.stderr)
    sys.exit(1)
required_snippets = [
    'tmp_config="$(mktemp "${CONFIG_DIR}/.agent.toml.XXXXXX")"',
    'mv -fT "$tmp_config" "$CONFIG_PATH"',
]
missing = [snippet for snippet in required_snippets if snippet not in text]
if missing:
    print(f"{installer_file}: write_config must use same-directory temp file and no-target-directory atomic rename: {', '.join(missing)}", file=sys.stderr)
    sys.exit(1)
PY
}

require_installer_binary_atomic_install() {
    installer_file="$1"
    python3 - "$installer_file" <<'PY'
from pathlib import Path
import sys

installer_file = Path(sys.argv[1])
text = installer_file.read_text(encoding="utf-8")
forbidden_snippet = 'install -m 0755 "$tmp_binary" "$BINARY_PATH"'
if forbidden_snippet in text:
    print(f"{installer_file}: download_agent must not install directly to BINARY_PATH", file=sys.stderr)
    sys.exit(1)
required_snippets = [
    'tmp_install="$(mktemp "${binary_dir}/.vps-agent.XXXXXX")"',
    'install -m 0755 "$tmp_binary" "$tmp_install"',
    'validate_binary_directory_before_install\n    validate_binary_path_before_install\n    mv -fT "$tmp_install" "$BINARY_PATH"',
]
missing = [snippet for snippet in required_snippets if snippet not in text]
if missing:
    print(f"{installer_file}: download_agent must stage the binary in the target directory and atomically rename it: {', '.join(missing)}", file=sys.stderr)
    sys.exit(1)
PY
}

reset_installer_state() {
    CONFIG_DIR="/etc/vps-agent"
    CONFIG_PATH="${CONFIG_DIR}/agent.toml"
    DATA_DIR="/var/lib/vps-agent"
    IMAGE_DIR="${DATA_DIR}/images"
    SERVICE_PATH="/etc/systemd/system/vps-agent.service"
    BINARY_PATH="/usr/local/bin/vps-agent"
    AGENT_SHA256_PATH="${CONFIG_DIR}/agent.sha256"
    MASTER_URL="https://panel.example.com"
    AGENT_URL=""
    NODE_ID="00000000-0000-0000-0000-000000000000"
    BOOTSTRAP_TOKEN="bootstrap-token"
    AGENT_SHA256=""
    CA_CERT_PATH=""
    CLIENT_IDENTITY_PATH=""
    EXECUTOR_MODE="mock"
    NETWORK_NAME="default"
    BRIDGE_NAME="virbr0"
}

expect_valid() {
    reset_installer_state
    "$@"
    validate_args
}

expect_invalid() {
    reset_installer_state
    "$@"
    if ( validate_args ) >/dev/null 2>&1; then
        echo "expected validation failure: $*" >&2
        exit 1
    fi
}

expect_parse_invalid() {
    reset_installer_state
    local output
    if output="$(parse_args "$@" 2>&1)"; then
        echo "expected parse failure: $*" >&2
        exit 1
    fi
    case "$output" in
        install-agent:*) ;;
        *)
            echo "parse failure did not use installer error format: $*" >&2
            printf '%s\n' "$output" >&2
            exit 1
            ;;
    esac
}

make_identity_file() {
    IDENTITY_FILE="$(mktemp)"
    printf '%s\n' "-----BEGIN PRIVATE KEY-----" "smoke" "-----END PRIVATE KEY-----" > "$IDENTITY_FILE"
}

cleanup_identity_file() {
    if [ -n "${IDENTITY_FILE:-}" ]; then
        rm -f "$IDENTITY_FILE"
        IDENTITY_FILE=""
    fi
}

expect_identity_valid() {
    reset_installer_state
    make_identity_file
    chmod 0600 "$IDENTITY_FILE"
    CLIENT_IDENTITY_PATH="$IDENTITY_FILE"
    validate_args
    cleanup_identity_file
}

expect_identity_invalid() {
    reset_installer_state
    make_identity_file
    chmod 0644 "$IDENTITY_FILE"
    CLIENT_IDENTITY_PATH="$IDENTITY_FILE"
    if ( validate_args ) >/dev/null 2>&1; then
        echo "expected client identity permission validation failure" >&2
        cleanup_identity_file
        exit 1
    fi
    cleanup_identity_file
}

expect_identity_unowned_invalid() {
    reset_installer_state
    make_identity_file
    chmod 0600 "$IDENTITY_FILE"
    CLIENT_IDENTITY_PATH="$IDENTITY_FILE"
    local other_uid
    other_uid=$(($(id -u) + 1))

    stat() {
        if [ "$#" -eq 3 ] && [ "$1" = "-c" ] && [ "$2" = "%u" ] && [ "$3" = "$CLIENT_IDENTITY_PATH" ]; then
            printf '%s\n' "$other_uid"
            return 0
        fi
        command stat "$@"
    }

    if ( validate_args ) >/dev/null 2>&1; then
        echo "expected client identity owner validation failure" >&2
        unset -f stat
        cleanup_identity_file
        exit 1
    fi
    unset -f stat
    cleanup_identity_file
}

expect_identity_symlink_invalid() {
    reset_installer_state
    local tls_tmp_dir
    tls_tmp_dir="$(mktemp -d)"
    local identity_target="${tls_tmp_dir}/client-identity.pem"
    local identity_link="${tls_tmp_dir}/client-identity-link.pem"
    printf '%s\n' "-----BEGIN PRIVATE KEY-----" "smoke" "-----END PRIVATE KEY-----" > "$identity_target"
    chmod 0600 "$identity_target"
    ln -s "$identity_target" "$identity_link"
    CLIENT_IDENTITY_PATH="$identity_link"

    if ( validate_args ) >/dev/null 2>&1; then
        echo "expected client identity symlink validation failure" >&2
        rm -rf "$tls_tmp_dir"
        exit 1
    fi
    rm -rf "$tls_tmp_dir"
}

expect_tls_path_invalid() {
    reset_installer_state
    local tls_tmp_dir
    tls_tmp_dir="$(mktemp -d)"
    local tls_file="${tls_tmp_dir}/bad path.pem"
    printf '%s\n' "-----BEGIN CERTIFICATE-----" "smoke" "-----END CERTIFICATE-----" > "$tls_file"
    chmod 0600 "$tls_file"
    "$@" "$tls_file"
    if ( validate_args ) >/dev/null 2>&1; then
        echo "expected TLS path validation failure" >&2
        rm -rf "$tls_tmp_dir"
        exit 1
    fi
    rm -rf "$tls_tmp_dir"
}

set_ca_cert_path() {
    CA_CERT_PATH="$1"
}

set_client_identity_path() {
    CLIENT_IDENTITY_PATH="$1"
}

set_master_url_control_char() {
    MASTER_URL=$'https://panel.example.com/\001bad'
}

set_data_dir_control_char() {
    DATA_DIR=$'/var/lib/vps-agent\001bad'
    IMAGE_DIR="${DATA_DIR}/images"
}

expect_ca_cert_permission_invalid() {
    reset_installer_state
    local tls_tmp_dir
    tls_tmp_dir="$(mktemp -d)"
    CA_CERT_PATH="${tls_tmp_dir}/master-ca.pem"
    printf '%s\n' "-----BEGIN CERTIFICATE-----" "smoke" "-----END CERTIFICATE-----" > "$CA_CERT_PATH"
    chmod 0660 "$CA_CERT_PATH"
    if ( validate_args ) >/dev/null 2>&1; then
        echo "expected CA certificate writable permission validation failure" >&2
        rm -rf "$tls_tmp_dir"
        exit 1
    fi
    chmod 0644 "$CA_CERT_PATH"
    validate_args
    rm -rf "$tls_tmp_dir"
}

expect_ca_cert_symlink_invalid() {
    reset_installer_state
    local tls_tmp_dir
    tls_tmp_dir="$(mktemp -d)"
    local ca_target="${tls_tmp_dir}/master-ca.pem"
    local ca_link="${tls_tmp_dir}/master-ca-link.pem"
    printf '%s\n' "-----BEGIN CERTIFICATE-----" "smoke" "-----END CERTIFICATE-----" > "$ca_target"
    chmod 0644 "$ca_target"
    ln -s "$ca_target" "$ca_link"
    CA_CERT_PATH="$ca_link"

    local output
    if output="$(validate_args 2>&1)"; then
        echo "expected CA certificate symlink validation failure" >&2
        rm -rf "$tls_tmp_dir"
        exit 1
    fi
    case "$output" in
        *"symlink"*) ;;
        *)
            echo "CA certificate symlink validation did not report symlink" >&2
            printf '%s\n' "$output" >&2
            rm -rf "$tls_tmp_dir"
            exit 1
            ;;
    esac
    rm -rf "$tls_tmp_dir"
}

expect_checksum_valid() {
    reset_installer_state
    local artifact
    artifact="$(mktemp)"
    printf 'agent-binary' > "$artifact"
    AGENT_SHA256="$(sha256sum "$artifact" | awk '{print $1}')"
    validate_args
    verify_agent_checksum "$artifact"
    rm -f "$artifact"
}

expect_checksum_invalid() {
    reset_installer_state
    local artifact
    artifact="$(mktemp)"
    printf 'agent-binary' > "$artifact"
    AGENT_SHA256="$(printf 'different-binary' | sha256sum | awk '{print $1}')"
    validate_args
    if ( verify_agent_checksum "$artifact" ) >/dev/null 2>&1; then
        echo "expected agent checksum verification failure" >&2
        rm -f "$artifact"
        exit 1
    fi
    rm -f "$artifact"
}

expect_write_agent_sha256_file_persists_normalized_hash() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    CONFIG_DIR="${tmp_dir}/etc/vps-agent"
    CONFIG_PATH="${CONFIG_DIR}/agent.toml"
    AGENT_SHA256_PATH="${CONFIG_DIR}/agent.sha256"
    AGENT_SHA256="ABCDEFabcdef0123456789abcdef0123456789abcdef0123456789abcdef0123"

    validate_args
    write_agent_sha256_file

    if [ "$(cat "$AGENT_SHA256_PATH")" != "$(printf '%s' "$AGENT_SHA256" | tr 'A-F' 'a-f')" ]; then
        echo "installer did not persist the normalized agent SHA-256" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    if [ "$(stat -c '%a' "$AGENT_SHA256_PATH")" != "644" ]; then
        echo "installer did not write the agent SHA-256 file with safe non-secret permissions" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi

    rm -rf "$tmp_dir"
}

expect_write_agent_sha256_file_clears_stale_hash_when_unverified() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    CONFIG_DIR="${tmp_dir}/etc/vps-agent"
    CONFIG_PATH="${CONFIG_DIR}/agent.toml"
    AGENT_SHA256_PATH="${CONFIG_DIR}/agent.sha256"
    mkdir -p "$CONFIG_DIR"
    chmod 0700 "$CONFIG_DIR"
    printf '%s\n' "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" > "$AGENT_SHA256_PATH"
    chmod 0644 "$AGENT_SHA256_PATH"

    validate_args
    write_agent_sha256_file

    if [ -e "$AGENT_SHA256_PATH" ]; then
        echo "installer left a stale agent SHA-256 proof after an unverified install" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi

    rm -rf "$tmp_dir"
}

expect_write_agent_sha256_file_rejects_symlinked_hash_path() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    CONFIG_DIR="${tmp_dir}/etc/vps-agent"
    CONFIG_PATH="${CONFIG_DIR}/agent.toml"
    AGENT_SHA256_PATH="${CONFIG_DIR}/agent.sha256"
    AGENT_SHA256="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    mkdir -p "$CONFIG_DIR"
    chmod 0700 "$CONFIG_DIR"
    local target="${tmp_dir}/outside-hash"
    printf 'sentinel' > "$target"
    ln -s "$target" "$AGENT_SHA256_PATH"

    validate_args
    if ( write_agent_sha256_file ) >/dev/null 2>&1; then
        echo "installer accepted a symlinked agent SHA-256 path" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    if [ "$(cat "$target")" != "sentinel" ]; then
        echo "installer modified a symlink target while writing agent SHA-256 proof" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi

    rm -rf "$tmp_dir"
}

expect_write_agent_sha256_file_rejects_config_dir_symlink_swapped_during_create() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    CONFIG_DIR="${tmp_dir}/etc/vps-agent"
    CONFIG_PATH="${CONFIG_DIR}/agent.toml"
    AGENT_SHA256_PATH="${CONFIG_DIR}/agent.sha256"
    AGENT_SHA256="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    local outside_config_dir="${tmp_dir}/outside-config"
    install() {
        if [ "$#" -eq 4 ] && [ "$1" = "-d" ] && [ "$2" = "-m" ] && [ "$3" = "0700" ] && [ "$4" = "$CONFIG_DIR" ]; then
            mkdir -p "$(dirname "$CONFIG_DIR")" "$outside_config_dir"
            ln -s "$outside_config_dir" "$CONFIG_DIR"
            return 0
        fi
        command install "$@"
    }

    validate_args
    if ( write_agent_sha256_file ) >/dev/null 2>&1; then
        echo "expected write_agent_sha256_file to reject a config directory symlink swapped in during create" >&2
        unset -f install
        rm -rf "$tmp_dir"
        exit 1
    fi
    unset -f install

    if [ -e "${outside_config_dir}/agent.sha256" ]; then
        echo "write_agent_sha256_file wrote the SHA-256 proof through a swapped config directory symlink" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi

    rm -rf "$tmp_dir"
}

expect_write_agent_sha256_file_rejects_hash_path_symlink_swapped_after_atomic_rename() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    CONFIG_DIR="${tmp_dir}/etc/vps-agent"
    CONFIG_PATH="${CONFIG_DIR}/agent.toml"
    AGENT_SHA256_PATH="${CONFIG_DIR}/agent.sha256"
    AGENT_SHA256="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    local target="${tmp_dir}/outside-hash"
    mkdir -p "$CONFIG_DIR"
    chmod 0700 "$CONFIG_DIR"
    printf 'sentinel' > "$target"
    chmod 0600 "$target"

    mktemp() {
        printf '%s/.agent.sha256.atomic' "$CONFIG_DIR"
    }
    mv() {
        if [ "$#" -eq 3 ] && [ "$1" = "-fT" ] && [ "$2" = "${CONFIG_DIR}/.agent.sha256.atomic" ] && [ "$3" = "$AGENT_SHA256_PATH" ]; then
            command mv "$@"
            rm -f "$AGENT_SHA256_PATH"
            ln -s "$target" "$AGENT_SHA256_PATH"
            return 0
        fi
        command mv "$@"
    }

    validate_args
    if ( write_agent_sha256_file ) >/dev/null 2>&1; then
        echo "expected write_agent_sha256_file to reject a hash path symlink swapped after atomic rename" >&2
        unset -f mktemp mv
        rm -rf "$tmp_dir"
        exit 1
    fi
    unset -f mktemp mv

    if [ "$(cat "$target")" != "sentinel" ] || [ "$(stat -c '%a' "$target")" != "600" ]; then
        echo "write_agent_sha256_file modified the symlink target after atomic rename" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi

    rm -rf "$tmp_dir"
}

expect_write_agent_sha256_file_rejects_loose_hash_path_swapped_after_atomic_rename() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    CONFIG_DIR="${tmp_dir}/etc/vps-agent"
    CONFIG_PATH="${CONFIG_DIR}/agent.toml"
    AGENT_SHA256_PATH="${CONFIG_DIR}/agent.sha256"
    AGENT_SHA256="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    mkdir -p "$CONFIG_DIR"
    chmod 0700 "$CONFIG_DIR"

    mktemp() {
        printf '%s/.agent.sha256.atomic' "$CONFIG_DIR"
    }
    mv() {
        if [ "$#" -eq 3 ] && [ "$1" = "-fT" ] && [ "$2" = "${CONFIG_DIR}/.agent.sha256.atomic" ] && [ "$3" = "$AGENT_SHA256_PATH" ]; then
            command mv "$@"
            printf 'attacker-controlled-proof\n' > "$AGENT_SHA256_PATH"
            chmod 0666 "$AGENT_SHA256_PATH"
            return 0
        fi
        command mv "$@"
    }

    validate_args
    if ( write_agent_sha256_file ) >/dev/null 2>&1; then
        echo "expected write_agent_sha256_file to reject a loose hash path swapped after atomic rename" >&2
        unset -f mktemp mv
        rm -rf "$tmp_dir"
        exit 1
    fi
    unset -f mktemp mv

    rm -rf "$tmp_dir"
}

expect_download_agent_uses_configured_ca_certificate() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    CA_CERT_PATH="${tmp_dir}/master-ca.pem"
    BINARY_PATH="${tmp_dir}/vps-agent"
    printf '%s\n' "-----BEGIN CERTIFICATE-----" "smoke" "-----END CERTIFICATE-----" > "$CA_CERT_PATH"
    chmod 0640 "$CA_CERT_PATH"
    validate_args

    local cacert_seen=0
    curl() {
        local previous=""
        local output_path=""
        for arg in "$@"; do
            if [ "$previous" = "--cacert" ] && [ "$arg" = "$CA_CERT_PATH" ]; then
                cacert_seen=1
            fi
            if [ "$previous" = "-o" ]; then
                output_path="$arg"
            fi
            previous="$arg"
        done
        [ -n "$output_path" ] || {
            echo "curl did not receive output path" >&2
            return 42
        }
        printf 'agent-binary' > "$output_path"
    }

    download_agent
    unset -f curl

    if [ "$cacert_seen" != "1" ]; then
        echo "agent download did not use configured CA certificate" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    [ -x "$BINARY_PATH" ] || {
        echo "agent binary was not installed" >&2
        rm -rf "$tmp_dir"
        exit 1
    }
    rm -rf "$tmp_dir"
}

expect_download_agent_uses_https_only_non_redirecting_curl() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    BINARY_PATH="${tmp_dir}/vps-agent"
    validate_args

    local disables_curl_config=0
    local proto_seen=0
    local redirect_seen=0
    curl() {
        local previous=""
        local output_path=""
        if [ "${1:-}" = "-q" ]; then
            disables_curl_config=1
        fi
        for arg in "$@"; do
            if { [ "$previous" = "--proto" ] || [ "$previous" = "--proto-redir" ]; } && [ "$arg" = "=https" ]; then
                proto_seen=1
            fi
            case "$arg" in
                -L|--location|--location-trusted|-[!-]*L*) redirect_seen=1 ;;
            esac
            if [ "$previous" = "-o" ]; then
                output_path="$arg"
            fi
            previous="$arg"
        done
        [ -n "$output_path" ] || {
            echo "curl did not receive output path" >&2
            return 42
        }
        printf 'agent-binary' > "$output_path"
    }

    download_agent
    unset -f curl

    if [ "$disables_curl_config" != "1" ]; then
        echo "agent download curl did not pass -q before other arguments" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    if [ "$proto_seen" != "1" ]; then
        echo "agent download curl did not constrain protocol to HTTPS" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    if [ "$redirect_seen" != "0" ]; then
        echo "agent download curl followed redirects" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    rm -rf "$tmp_dir"
}

expect_download_agent_uses_bounded_curl_timeouts() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    BINARY_PATH="${tmp_dir}/vps-agent"
    validate_args

    local connect_timeout=""
    local max_time=""
    curl() {
        local previous=""
        local output_path=""
        for arg in "$@"; do
            if [ "$previous" = "--connect-timeout" ]; then
                connect_timeout="$arg"
            fi
            if [ "$previous" = "--max-time" ]; then
                max_time="$arg"
            fi
            if [ "$previous" = "-o" ]; then
                output_path="$arg"
            fi
            previous="$arg"
        done
        [ -n "$output_path" ] || {
            echo "curl did not receive output path" >&2
            return 42
        }
        printf 'agent-binary' > "$output_path"
    }

    download_agent
    unset -f curl

    case "$connect_timeout" in
        ""|*[!0-9]*)
            echo "agent download curl did not use a numeric --connect-timeout" >&2
            rm -rf "$tmp_dir"
            exit 1
            ;;
    esac
    case "$max_time" in
        ""|*[!0-9]*)
            echo "agent download curl did not use a numeric --max-time" >&2
            rm -rf "$tmp_dir"
            exit 1
            ;;
    esac
    if [ "$connect_timeout" -lt 1 ] || [ "$connect_timeout" -gt "$max_time" ] || [ "$max_time" -gt 3600 ]; then
        echo "agent download curl timeouts are outside the expected bounded range" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    rm -rf "$tmp_dir"
}

expect_download_agent_rejects_symlinked_binary_path_before_curl() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    BINARY_PATH="${tmp_dir}/vps-agent"
    local target="${tmp_dir}/outside-target"
    printf 'sentinel' > "$target"
    ln -s "$target" "$BINARY_PATH"
    validate_args

    local curl_seen=0
    curl() {
        curl_seen=1
        return 42
    }

    if ( download_agent ) >/dev/null 2>&1; then
        echo "expected download_agent to reject a symlinked binary path" >&2
        unset -f curl
        rm -rf "$tmp_dir"
        exit 1
    fi
    unset -f curl

    if [ "$curl_seen" != "0" ]; then
        echo "download_agent called curl before rejecting a symlinked binary path" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    if [ "$(cat "$target")" != "sentinel" ]; then
        echo "download_agent modified the symlink target before failing" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    rm -rf "$tmp_dir"
}

expect_download_agent_rejects_partial_binary_after_curl_failure() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    BINARY_PATH="${tmp_dir}/vps-agent"
    validate_args

    curl() {
        local previous=""
        local output_path=""
        for arg in "$@"; do
            if [ "$previous" = "-o" ]; then
                output_path="$arg"
            fi
            previous="$arg"
        done
        [ -n "$output_path" ] || {
            echo "curl did not receive output path" >&2
            return 42
        }
        printf 'partial-agent-binary' > "$output_path"
        printf '%s\n' 'bootstrap_token=curl_should_not_leak' >&2
        printf '%s\n' 'password=curl_password_should_not_leak'
        return 42
    }

    local output
    if output="$(download_agent 2>&1)"; then
        echo "download_agent installed a partial binary after curl failure" >&2
        unset -f curl
        rm -rf "$tmp_dir"
        exit 1
    fi
    unset -f curl

    case "$output" in
        *curl_should_not_leak*|*curl_password_should_not_leak*)
            echo "download_agent leaked failed curl output" >&2
            printf '%s\n' "$output" >&2
            rm -rf "$tmp_dir"
            exit 1
            ;;
    esac
    case "$output" in
        *"agent download failed"*) ;;
        *)
            echo "download_agent did not return a safe curl failure message" >&2
            printf '%s\n' "$output" >&2
            rm -rf "$tmp_dir"
            exit 1
            ;;
    esac

    if [ -e "$BINARY_PATH" ]; then
        echo "download_agent left a final binary after curl failure" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi

    rm -rf "$tmp_dir"
}

expect_download_agent_rejects_symlink_swapped_during_download() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    BINARY_PATH="${tmp_dir}/vps-agent"
    local target="${tmp_dir}/outside-target"
    printf 'sentinel' > "$target"
    validate_args

    curl() {
        local previous=""
        local output_path=""
        for arg in "$@"; do
            if [ "$previous" = "-o" ]; then
                output_path="$arg"
            fi
            previous="$arg"
        done
        [ -n "$output_path" ] || {
            echo "curl did not receive output path" >&2
            return 42
        }
        ln -s "$target" "$BINARY_PATH"
        printf 'agent-binary' > "$output_path"
    }

    if ( download_agent ) >/dev/null 2>&1; then
        echo "expected download_agent to reject a symlink swapped in during download" >&2
        unset -f curl
        rm -rf "$tmp_dir"
        exit 1
    fi
    unset -f curl

    if [ "$(cat "$target")" != "sentinel" ]; then
        echo "download_agent followed a symlink swapped in during download" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    if [ ! -L "$BINARY_PATH" ]; then
        echo "download_agent did not leave the swapped symlink untouched after failing" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    rm -rf "$tmp_dir"
}

expect_download_agent_rejects_binary_dir_symlink_swapped_before_rename() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local binary_dir="${tmp_dir}/bin"
    local original_binary_dir="${tmp_dir}/bin-original"
    local outside_binary_dir="${tmp_dir}/outside-bin"
    mkdir -p "$binary_dir" "$outside_binary_dir"
    BINARY_PATH="${binary_dir}/vps-agent"
    validate_args

    curl() {
        local previous=""
        local output_path=""
        for arg in "$@"; do
            if [ "$previous" = "-o" ]; then
                output_path="$arg"
            fi
            previous="$arg"
        done
        [ -n "$output_path" ] || {
            echo "curl did not receive output path" >&2
            return 42
        }
        printf 'agent-binary' > "$output_path"
    }

    install() {
        local destination="${!#}"
        command install "$@"
        case "$destination" in
            "${binary_dir}"/.vps-agent.*)
                mv "$binary_dir" "$original_binary_dir"
                ln -s "$outside_binary_dir" "$binary_dir"
                printf 'attacker-controlled-binary' > "${outside_binary_dir}/$(basename "$destination")"
                chmod 0755 "${outside_binary_dir}/$(basename "$destination")"
                ;;
        esac
    }

    if ( download_agent ) >/dev/null 2>&1; then
        echo "expected download_agent to reject a binary directory symlink swapped in before rename" >&2
        unset -f curl install
        rm -rf "$tmp_dir"
        exit 1
    fi
    unset -f curl install

    if [ -e "${outside_binary_dir}/vps-agent" ]; then
        echo "download_agent wrote the final binary through a swapped binary directory symlink" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    rm -rf "$tmp_dir"
}

expect_write_config_rejects_symlinked_config_path() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    CONFIG_DIR="${tmp_dir}/etc/vps-agent"
    CONFIG_PATH="${CONFIG_DIR}/agent.toml"
    DATA_DIR="${tmp_dir}/var/lib/vps-agent"
    IMAGE_DIR="${DATA_DIR}/images"
    mkdir -p "$CONFIG_DIR"
    chmod 0700 "$CONFIG_DIR"
    local target="${tmp_dir}/outside-target"
    printf 'sentinel' > "$target"
    ln -s "$target" "$CONFIG_PATH"

    validate_args
    if ( write_config ) >/dev/null 2>&1; then
        echo "expected write_config to reject symlinked config path" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    if [ "$(cat "$target")" != "sentinel" ]; then
        echo "write_config modified the symlink target before failing" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    rm -rf "$tmp_dir"
}

expect_write_config_rejects_loose_existing_config_path() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    CONFIG_DIR="${tmp_dir}/etc/vps-agent"
    CONFIG_PATH="${CONFIG_DIR}/agent.toml"
    DATA_DIR="${tmp_dir}/var/lib/vps-agent"
    IMAGE_DIR="${DATA_DIR}/images"
    mkdir -p "$CONFIG_DIR"
    chmod 0700 "$CONFIG_DIR"
    printf 'sentinel' > "$CONFIG_PATH"
    chmod 0644 "$CONFIG_PATH"

    validate_args
    if ( write_config ) >/dev/null 2>&1; then
        echo "expected write_config to reject loose existing config path" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    if [ "$(cat "$CONFIG_PATH")" != "sentinel" ]; then
        echo "write_config modified the loose config before failing" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    rm -rf "$tmp_dir"
}

expect_write_config_rejects_unowned_existing_config_path() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    CONFIG_DIR="${tmp_dir}/etc/vps-agent"
    CONFIG_PATH="${CONFIG_DIR}/agent.toml"
    DATA_DIR="${tmp_dir}/var/lib/vps-agent"
    IMAGE_DIR="${DATA_DIR}/images"
    mkdir -p "$CONFIG_DIR"
    chmod 0700 "$CONFIG_DIR"
    printf 'sentinel' > "$CONFIG_PATH"
    chmod 0600 "$CONFIG_PATH"
    local other_uid
    other_uid=$(($(id -u) + 1))

    stat() {
        if [ "$#" -eq 3 ] && [ "$1" = "-c" ] && [ "$2" = "%u" ] && [ "$3" = "$CONFIG_PATH" ]; then
            printf '%s\n' "$other_uid"
            return 0
        fi
        command stat "$@"
    }

    validate_args
    if ( write_config ) >/dev/null 2>&1; then
        echo "expected write_config to reject unowned existing config path" >&2
        unset -f stat
        rm -rf "$tmp_dir"
        exit 1
    fi
    unset -f stat

    if [ "$(cat "$CONFIG_PATH")" != "sentinel" ]; then
        echo "write_config modified the unowned existing config before failing" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    rm -rf "$tmp_dir"
}

expect_write_config_uses_atomic_rename_for_agent_config() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    CONFIG_DIR="${tmp_dir}/etc/vps-agent"
    CONFIG_PATH="${CONFIG_DIR}/agent.toml"
    DATA_DIR="${tmp_dir}/var/lib/vps-agent"
    IMAGE_DIR="${DATA_DIR}/images"
    mkdir -p "$CONFIG_DIR"
    chmod 0700 "$CONFIG_DIR"

    local mktemp_marker="${tmp_dir}/mktemp-seen"
    local mv_marker="${tmp_dir}/mv-seen"
    mktemp() {
        printf '1' > "$mktemp_marker"
        printf '%s/.agent.toml.atomic' "$CONFIG_DIR"
    }
    mv() {
        printf '1' > "$mv_marker"
        command mv "$@"
    }

    validate_args
    write_config

    unset -f mktemp mv

    if [ ! -f "$mktemp_marker" ]; then
        echo "write_config did not create a temporary config file" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    if [ ! -f "$mv_marker" ]; then
        echo "write_config did not atomically rename the temporary config" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    if [ ! -f "$CONFIG_PATH" ]; then
        echo "write_config did not create the final agent config" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    if [ -e "${CONFIG_DIR}/.agent.toml.atomic" ]; then
        echo "write_config left the temporary config behind" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    if ! grep -q '^bootstrap_token = "bootstrap-token"$' "$CONFIG_PATH"; then
        echo "write_config did not persist the bootstrap token in the final config" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi

    rm -rf "$tmp_dir"
}

expect_write_config_rejects_config_path_symlink_swapped_after_atomic_rename() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    CONFIG_DIR="${tmp_dir}/etc/vps-agent"
    CONFIG_PATH="${CONFIG_DIR}/agent.toml"
    AGENT_SHA256_PATH="${CONFIG_DIR}/agent.sha256"
    DATA_DIR="${tmp_dir}/var/lib/vps-agent"
    IMAGE_DIR="${DATA_DIR}/images"
    BOOTSTRAP_TOKEN="bootstrap-token"

    local target="${tmp_dir}/outside-config"
    mkdir -p "$CONFIG_DIR"
    chmod 0700 "$CONFIG_DIR"
    printf 'sentinel' > "$target"
    chmod 0644 "$target"

    mktemp() {
        printf '%s/.agent.toml.atomic' "$CONFIG_DIR"
    }
    mv() {
        if [ "$#" -eq 3 ] && [ "$1" = "-fT" ] && [ "$2" = "${CONFIG_DIR}/.agent.toml.atomic" ] && [ "$3" = "$CONFIG_PATH" ]; then
            command mv "$@"
            rm -f "$CONFIG_PATH"
            ln -s "$target" "$CONFIG_PATH"
            return 0
        fi
        command mv "$@"
    }

    validate_args
    if ( write_config ) >/dev/null 2>&1; then
        echo "expected write_config to reject a config path symlink swapped after atomic rename" >&2
        unset -f mv
        rm -rf "$tmp_dir"
        exit 1
    fi
    unset -f mv

    if [ "$(cat "$target")" != "sentinel" ]; then
        echo "write_config chmodded the symlink target after atomic rename" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi

    unset -f mktemp mv

    rm -rf "$tmp_dir"
}

expect_write_config_rejects_symlinked_managed_dirs() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    CONFIG_DIR="${tmp_dir}/etc/vps-agent"
    CONFIG_PATH="${CONFIG_DIR}/agent.toml"
    DATA_DIR="${tmp_dir}/var/lib/vps-agent"
    IMAGE_DIR="${DATA_DIR}/images"

    local outside_config_dir="${tmp_dir}/outside-config"
    mkdir -p "$(dirname "$CONFIG_DIR")"
    mkdir -p "$outside_config_dir"
    ln -s "$outside_config_dir" "$CONFIG_DIR"
    validate_args
    if ( write_config ) >/dev/null 2>&1; then
        echo "expected write_config to reject a symlinked config directory" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    if [ -e "${outside_config_dir}/agent.toml" ]; then
        echo "write_config wrote agent.toml through a symlinked config directory" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi

    rm -f "$CONFIG_DIR"
    mkdir -p "$CONFIG_DIR"
    chmod 0700 "$CONFIG_DIR"
    local outside_data_dir="${tmp_dir}/outside-data"
    mkdir -p "$(dirname "$DATA_DIR")"
    mkdir -p "$outside_data_dir"
    ln -s "$outside_data_dir" "$DATA_DIR"
    if ( write_config ) >/dev/null 2>&1; then
        echo "expected write_config to reject a symlinked data directory" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    if [ -e "${outside_data_dir}/images" ]; then
        echo "write_config created image storage through a symlinked data directory" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi

    rm -f "$DATA_DIR"
    mkdir -p "$DATA_DIR"
    chmod 0750 "$DATA_DIR"
    local outside_image_dir="${tmp_dir}/outside-images"
    mkdir -p "$outside_image_dir"
    ln -s "$outside_image_dir" "$IMAGE_DIR"
    EXECUTOR_MODE="libvirt"
    validate_args
    if [ "$EXECUTOR_MODE" != "libvirt" ]; then
        echo "test setup expected libvirt executor mode" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    if [ ! -L "$IMAGE_DIR" ]; then
        echo "test setup failed to create a symlinked image directory" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    if ( write_config ) >/dev/null 2>&1; then
        echo "expected write_config to reject a symlinked image directory" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi

    rm -rf "$tmp_dir"
}

expect_write_config_rejects_config_dir_symlink_swapped_during_create() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    CONFIG_DIR="${tmp_dir}/etc/vps-agent"
    CONFIG_PATH="${CONFIG_DIR}/agent.toml"
    DATA_DIR="${tmp_dir}/var/lib/vps-agent"
    IMAGE_DIR="${DATA_DIR}/images"

    local outside_config_dir="${tmp_dir}/outside-config"
    install() {
        if [ "$#" -eq 4 ] && [ "$1" = "-d" ] && [ "$2" = "-m" ] && [ "$3" = "0700" ] && [ "$4" = "$CONFIG_DIR" ]; then
            mkdir -p "$(dirname "$CONFIG_DIR")" "$outside_config_dir"
            ln -s "$outside_config_dir" "$CONFIG_DIR"
            return 0
        fi
        command install "$@"
    }

    validate_args
    if ( write_config ) >/dev/null 2>&1; then
        echo "expected write_config to reject a config directory symlink swapped in during create" >&2
        unset -f install
        rm -rf "$tmp_dir"
        exit 1
    fi
    unset -f install

    if [ -e "${outside_config_dir}/agent.toml" ]; then
        echo "write_config wrote agent.toml through a swapped config directory symlink" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    rm -rf "$tmp_dir"
}

expect_write_config_rejects_loose_managed_dirs() {
    local case_name
    for case_name in config data image; do
        reset_installer_state
        local tmp_dir
        tmp_dir="$(mktemp -d)"

        CONFIG_DIR="${tmp_dir}/etc/vps-agent"
        CONFIG_PATH="${CONFIG_DIR}/agent.toml"
        DATA_DIR="${tmp_dir}/var/lib/vps-agent"
        IMAGE_DIR="${DATA_DIR}/images"
        EXECUTOR_MODE="libvirt"

        mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$IMAGE_DIR"
        chmod 0700 "$CONFIG_DIR"
        chmod 0750 "$DATA_DIR" "$IMAGE_DIR"

        case "$case_name" in
            config) chmod 0777 "$CONFIG_DIR" ;;
            data) chmod 0777 "$DATA_DIR" ;;
            image) chmod 0777 "$IMAGE_DIR" ;;
        esac

        validate_args
        if ( write_config ) >/dev/null 2>&1; then
            echo "expected write_config to reject loose existing ${case_name} directory permissions" >&2
            rm -rf "$tmp_dir"
            exit 1
        fi

        if [ -e "$CONFIG_PATH" ]; then
            echo "write_config created agent.toml after accepting loose ${case_name} directory permissions" >&2
            rm -rf "$tmp_dir"
            exit 1
        fi

        rm -rf "$tmp_dir"
    done
}

expect_write_config_rejects_unowned_managed_dirs() {
    local case_name
    for case_name in config data image; do
        reset_installer_state
        local tmp_dir
        tmp_dir="$(mktemp -d)"

        CONFIG_DIR="${tmp_dir}/etc/vps-agent"
        CONFIG_PATH="${CONFIG_DIR}/agent.toml"
        DATA_DIR="${tmp_dir}/var/lib/vps-agent"
        IMAGE_DIR="${DATA_DIR}/images"
        EXECUTOR_MODE="libvirt"

        mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$IMAGE_DIR"
        chmod 0700 "$CONFIG_DIR"
        chmod 0750 "$DATA_DIR" "$IMAGE_DIR"

        local unowned_path
        case "$case_name" in
            config) unowned_path="$CONFIG_DIR" ;;
            data) unowned_path="$DATA_DIR" ;;
            image) unowned_path="$IMAGE_DIR" ;;
        esac
        local other_uid
        other_uid=$(($(id -u) + 1))

        stat() {
            if [ "$#" -eq 3 ] && [ "$1" = "-c" ] && [ "$2" = "%u" ] && [ "$3" = "$unowned_path" ]; then
                printf '%s\n' "$other_uid"
                return 0
            fi
            command stat "$@"
        }

        validate_args
        if ( write_config ) >/dev/null 2>&1; then
            echo "expected write_config to reject unowned existing ${case_name} directory" >&2
            unset -f stat
            rm -rf "$tmp_dir"
            exit 1
        fi
        unset -f stat

        if [ -e "$CONFIG_PATH" ]; then
            echo "write_config created agent.toml after accepting unowned existing ${case_name} directory" >&2
            rm -rf "$tmp_dir"
            exit 1
        fi

        rm -rf "$tmp_dir"
    done
}

expect_write_service_rejects_symlinked_service_path() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    SERVICE_PATH="${tmp_dir}/vps-agent.service"
    local target="${tmp_dir}/outside-target"
    printf 'sentinel' > "$target"
    ln -s "$target" "$SERVICE_PATH"

    systemctl() {
        :
    }

    if ( write_service ) >/dev/null 2>&1; then
        echo "expected write_service to reject a symlinked service path" >&2
        unset -f systemctl
        rm -rf "$tmp_dir"
        exit 1
    fi
    unset -f systemctl

    if [ "$(cat "$target")" != "sentinel" ]; then
        echo "write_service modified the symlink target before failing" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    rm -rf "$tmp_dir"
}

expect_write_service_rejects_loose_service_directory_permissions() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local service_dir="${tmp_dir}/system"
    SERVICE_PATH="${service_dir}/vps-agent.service"
    mkdir -p "$service_dir"
    chmod 0777 "$service_dir"

    systemctl() {
        :
    }

    if ( write_service ) >/dev/null 2>&1; then
        echo "expected write_service to reject loose service directory permissions" >&2
        unset -f systemctl
        rm -rf "$tmp_dir"
        exit 1
    fi
    unset -f systemctl

    if [ -e "$SERVICE_PATH" ]; then
        echo "write_service created a unit after accepting loose service directory permissions" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    rm -rf "$tmp_dir"
}

expect_write_service_rejects_unowned_service_directory() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local service_dir="${tmp_dir}/system"
    SERVICE_PATH="${service_dir}/vps-agent.service"
    mkdir -p "$service_dir"
    chmod 0755 "$service_dir"
    local other_uid
    other_uid=$(($(id -u) + 1))

    systemctl() {
        :
    }
    stat() {
        if [ "$#" -eq 3 ] && [ "$1" = "-c" ] && [ "$2" = "%u" ] && [ "$3" = "$service_dir" ]; then
            printf '%s\n' "$other_uid"
            return 0
        fi
        command stat "$@"
    }

    if ( write_service ) >/dev/null 2>&1; then
        echo "expected write_service to reject unowned service directory" >&2
        unset -f stat systemctl
        rm -rf "$tmp_dir"
        exit 1
    fi
    unset -f stat systemctl

    if [ -e "$SERVICE_PATH" ]; then
        echo "write_service created a unit after accepting unowned service directory" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    rm -rf "$tmp_dir"
}

expect_write_service_rejects_service_dir_symlink_swapped_before_rename() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local service_dir="${tmp_dir}/system"
    local outside_service_dir="${tmp_dir}/outside-system"
    SERVICE_PATH="${service_dir}/vps-agent.service"

    systemctl() {
        :
    }
    mktemp() {
        mkdir -p "$outside_service_dir"
        ln -s "$outside_service_dir" "$service_dir"
        command mktemp "$@"
    }

    if ( write_service ) >/dev/null 2>&1; then
        echo "expected write_service to reject a service directory symlink swapped in before rename" >&2
        unset -f mktemp systemctl
        rm -rf "$tmp_dir"
        exit 1
    fi
    unset -f mktemp systemctl

    if [ -e "${outside_service_dir}/vps-agent.service" ]; then
        echo "write_service wrote the unit through a swapped service directory symlink" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    rm -rf "$tmp_dir"
}

expect_write_service_rejects_service_path_symlink_swapped_before_rename() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    SERVICE_PATH="${tmp_dir}/vps-agent.service"
    local target="${tmp_dir}/outside-target"
    printf 'sentinel' > "$target"

    systemctl() {
        :
    }
    chmod() {
        if [ "$#" -eq 2 ] && [ "$1" = "0644" ]; then
            ln -s "$target" "$SERVICE_PATH"
        fi
        command chmod "$@"
    }

    if ( write_service ) >/dev/null 2>&1; then
        echo "expected write_service to reject a service path symlink swapped in before rename" >&2
        unset -f chmod systemctl
        rm -rf "$tmp_dir"
        exit 1
    fi
    unset -f chmod systemctl

    if [ "$(cat "$target")" != "sentinel" ]; then
        echo "write_service modified the swapped service path symlink target" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi
    rm -rf "$tmp_dir"
}

expect_run_doctor_hides_failed_output() {
    reset_installer_state
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    CONFIG_PATH="${tmp_dir}/agent.toml"
    BINARY_PATH="${tmp_dir}/vps-agent"

    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'printf "%s\n" "bootstrap_token=doctor_should_not_leak" >&2'
        printf '%s\n' 'printf "%s\n" "password=doctor_password_should_not_leak"'
        printf '%s\n' 'exit 47'
    } > "$BINARY_PATH"
    chmod 0750 "$BINARY_PATH"

    local output
    if output="$(run_doctor 2>&1)"; then
        echo "failed doctor passed installer pre-start check" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi

    case "$output" in
        *doctor_should_not_leak*|*doctor_password_should_not_leak*)
            echo "installer leaked failed doctor output" >&2
            printf '%s\n' "$output" >&2
            rm -rf "$tmp_dir"
            exit 1
            ;;
    esac

    case "$output" in
        *"vps-agent doctor failed; rerun it manually with VPS_AGENT_CONFIG=${CONFIG_PATH}"*) ;;
        *)
            echo "installer doctor failure did not return a safe rerun hint" >&2
            printf '%s\n' "$output" >&2
            rm -rf "$tmp_dir"
            exit 1
            ;;
    esac

    rm -rf "$tmp_dir"
}

expect_enable_service_hides_failed_systemctl_output() {
    local failing_step
    for failing_step in daemon-reload enable restart; do
        reset_installer_state
        NO_START=0

        systemctl() {
            printf '%s\n' "bootstrap_token=systemctl_${1}_should_not_leak" >&2
            printf '%s\n' "password=systemctl_${1}_password_should_not_leak"
            if [ "$1" = "$failing_step" ]; then
                return 41
            fi
            return 0
        }

        local output
        if output="$(enable_service 2>&1)"; then
            echo "failed systemctl ${failing_step} passed installer service setup" >&2
            unset -f systemctl
            exit 1
        fi

        case "$output" in
            *systemctl_*_should_not_leak*|*systemctl_*_password_should_not_leak*)
                echo "installer leaked failed systemctl output for ${failing_step}" >&2
                printf '%s\n' "$output" >&2
                unset -f systemctl
                exit 1
                ;;
        esac

        case "$output" in
            *"systemctl ${failing_step} failed"*) ;;
            *)
                echo "installer systemctl failure did not return a safe message for ${failing_step}" >&2
                printf '%s\n' "$output" >&2
                unset -f systemctl
                exit 1
                ;;
        esac

        unset -f systemctl
    done
}

expect_valid true

for unsafe_url in \
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
    "https://" \
    "https://:8443" \
    "https://panel.example.com:0" \
    "https://panel.example.com:65536" \
    "https://panel.example.com:99999" \
    "https://panel%0a.example.com" \
    "https://panel%7f.example.com" \
    "https://panel%2f.example.com" \
    "https://panel%5c.example.com" \
    "https://[::1"
do
    expect_invalid eval "MASTER_URL='$unsafe_url'"
done

for unsafe_url in \
    "https://user:secret@downloads.example.com/vps-agent" \
    "https://downloads.example.com/vps-agent?token=secret" \
    "https://downloads.example.com/vps-agent#fragment" \
    "https://downloads.example.com/." \
    "https://downloads.example.com/.." \
    "https://downloads.example.com/releases/../vps-agent" \
    "https://downloads.example.com/releases/%2e%2e/vps-agent" \
    "https://downloads.example.com/releases/%2E/vps-agent" \
    "https://downloads.example.com/releases%2f..%2fvps-agent" \
    "https://downloads.example.com/releases%5c..%5cvps-agent" \
    "https://downloads.example.com/releases%0avps-agent" \
    "https://downloads.example.com/releases%7fvps-agent" \
    "https://downloads.example.com/bad path/vps-agent" \
    "https://downloads.example.com/\\vps-agent" \
    "https://downloads.example.com/\`cmd\`" \
    "https://:8443/vps-agent" \
    "https://downloads.example.com:0/vps-agent" \
    "https://downloads.example.com:65536/vps-agent" \
    "https://downloads.example.com:99999/vps-agent" \
    "https://downloads%0a.example.com/vps-agent" \
    "https://downloads%7f.example.com/vps-agent" \
    "https://downloads%2f.example.com/vps-agent" \
    "https://downloads%5c.example.com/vps-agent" \
    "https://[::1/vps-agent"
do
    expect_invalid eval "AGENT_URL='$unsafe_url'"
done

for unsafe_data_dir in \
    "/" \
    "relative" \
    "/var/lib/vps-agent/../host"
do
    expect_invalid eval "DATA_DIR='$unsafe_data_dir'"
done

expect_invalid eval "EXECUTOR_MODE='libvirt'; DATA_DIR='/var/lib/vps-agent'; IMAGE_DIR='/tmp/vps-agent-images'"

expect_valid eval "EXECUTOR_MODE='libvirt'; DATA_DIR='/var/lib/vps-agent'; IMAGE_DIR='/var/lib/vps-agent/images'"
expect_valid eval "AGENT_SHA256='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'"
expect_invalid eval "NODE_ID='zzzzzzzz-zzzz-zzzz-zzzz-zzzzzzzzzzzz'"
expect_invalid eval "AGENT_SHA256='not-a-sha256'"
expect_invalid eval "BOOTSTRAP_TOKEN='bad token'"
expect_invalid eval "BOOTSTRAP_TOKEN='bad\\token'"
expect_invalid eval "BOOTSTRAP_TOKEN='bad/token'"
expect_invalid set_master_url_control_char
expect_invalid set_data_dir_control_char
expect_parse_invalid --master-url
expect_parse_invalid --master-url --node-id 00000000-0000-0000-0000-000000000000
expect_parse_invalid --bootstrap-token --agent-url https://downloads.example.com/vps-agent
expect_identity_valid
expect_identity_invalid
expect_identity_unowned_invalid
expect_identity_symlink_invalid
expect_tls_path_invalid set_ca_cert_path
expect_tls_path_invalid set_client_identity_path
expect_ca_cert_permission_invalid
expect_ca_cert_symlink_invalid
expect_checksum_valid
expect_checksum_invalid
expect_write_agent_sha256_file_persists_normalized_hash
expect_write_agent_sha256_file_clears_stale_hash_when_unverified
expect_write_agent_sha256_file_rejects_symlinked_hash_path
expect_write_agent_sha256_file_rejects_config_dir_symlink_swapped_during_create
expect_write_agent_sha256_file_rejects_hash_path_symlink_swapped_after_atomic_rename
expect_write_agent_sha256_file_rejects_loose_hash_path_swapped_after_atomic_rename
expect_download_agent_uses_configured_ca_certificate
expect_download_agent_uses_https_only_non_redirecting_curl
expect_download_agent_uses_bounded_curl_timeouts
expect_download_agent_rejects_symlinked_binary_path_before_curl
expect_download_agent_rejects_partial_binary_after_curl_failure
expect_download_agent_rejects_symlink_swapped_during_download
expect_download_agent_rejects_binary_dir_symlink_swapped_before_rename
    expect_write_config_rejects_symlinked_config_path
    expect_write_config_rejects_loose_existing_config_path
    expect_write_config_rejects_unowned_existing_config_path
    expect_write_config_uses_atomic_rename_for_agent_config
    expect_write_config_rejects_config_path_symlink_swapped_after_atomic_rename
    expect_write_config_rejects_symlinked_managed_dirs
    expect_write_config_rejects_config_dir_symlink_swapped_during_create
    expect_write_config_rejects_loose_managed_dirs
    expect_write_config_rejects_unowned_managed_dirs
expect_write_service_rejects_symlinked_service_path
expect_write_service_rejects_loose_service_directory_permissions
expect_write_service_rejects_unowned_service_directory
expect_write_service_rejects_service_dir_symlink_swapped_before_rename
expect_write_service_rejects_service_path_symlink_swapped_before_rename
expect_run_doctor_hides_failed_output
expect_enable_service_hides_failed_systemctl_output
require_service_hardening "$repo_root/agent/deploy/vps-agent.service"
require_installer_service_hardening "$repo_root/scripts/install-agent.sh"
require_installer_service_atomic_write "$repo_root/scripts/install-agent.sh"
require_installer_config_atomic_write "$repo_root/scripts/install-agent.sh"
require_installer_binary_atomic_install "$repo_root/scripts/install-agent.sh"

echo "install-agent validation tests passed"
