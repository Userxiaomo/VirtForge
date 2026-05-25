#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

reject_vendored_flint_source() {
    if [ -e "$repo_root/flint" ]; then
        echo "security-scan: remove copied flint source; keep Flint as an external reference only" >&2
        exit 1
    fi
}

find_default_scanner() {
    for candidate in \
        "${HOME:-}/.codex/skills/ccg/tools/verify-security/scripts/security_scanner.js" \
        "${HOME:-}/.agents/skills/ccg/tools/verify-security/scripts/security_scanner.js"
    do
        if [ -n "$candidate" ] && [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    windows_home="$(windows_user_profile_wsl_path || true)"
    if [ -n "$windows_home" ]; then
        for candidate in \
            "$windows_home/.codex/skills/ccg/tools/verify-security/scripts/security_scanner.js" \
            "$windows_home/.agents/skills/ccg/tools/verify-security/scripts/security_scanner.js"
        do
            if [ -f "$candidate" ]; then
                printf '%s\n' "$candidate"
                return 0
            fi
        done
    fi
    return 1
}

windows_user_profile_wsl_path() {
    if ! command -v cmd.exe >/dev/null 2>&1 || ! command -v wslpath >/dev/null 2>&1; then
        return 1
    fi

    windows_profile="$(
        cmd.exe /C echo %USERPROFILE% 2>/dev/null |
            tr -d '\r' |
            sed -n '1p'
    )"
    if [ -z "$windows_profile" ] || [ "$windows_profile" = "%USERPROFILE%" ]; then
        return 1
    fi

    wslpath -u "$windows_profile"
}

find_node_runtime() {
    if [ -n "${SECURITY_SCANNER_NODE:-}" ]; then
        printf '%s\n' "$SECURITY_SCANNER_NODE"
        return 0
    fi
    if command -v node >/dev/null 2>&1; then
        command -v node
        return 0
    fi
    if command -v node.exe >/dev/null 2>&1; then
        command -v node.exe
        return 0
    fi
    return 1
}

convert_wsl_path_for_windows_node() {
    path="$1"
    if [[ "$path" != /mnt/* ]]; then
        printf '%s\n' "$path"
        return 0
    fi
    if command -v wslpath >/dev/null 2>&1; then
        wslpath -w "$path"
        return 0
    fi
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$path"
        return 0
    fi
    echo "security-scan: wslpath or cygpath is required to use node.exe with WSL paths" >&2
    return 1
}

scanner="${SECURITY_SCANNER:-}"
if [ -z "$scanner" ]; then
    scanner="$(find_default_scanner || true)"
fi

if [ -z "$scanner" ] || [ ! -f "$scanner" ]; then
    echo "security-scan: set SECURITY_SCANNER to verify-security/scripts/security_scanner.js" >&2
    exit 1
fi

scanner_args=(
    "$repo_root"
    "$@"
    --exclude .next
    --exclude target
    --exclude node_modules
)

run_scanner() {
    case "$scanner" in
        *.js)
            node_runtime="$(find_node_runtime || true)"
            if [ -z "$node_runtime" ]; then
                echo "security-scan: node is required for $scanner" >&2
                exit 1
            fi
            runtime_scanner="$scanner"
            if [ "$(basename "$node_runtime")" = "node.exe" ]; then
                runtime_scanner="$(convert_wsl_path_for_windows_node "$scanner")"
                scanner_args[0]="$(convert_wsl_path_for_windows_node "$repo_root")"
            fi
            "$node_runtime" "$runtime_scanner" "${scanner_args[@]}"
            ;;
        *)
            "$scanner" "${scanner_args[@]}"
            ;;
    esac
}

validate_nonzero_json_scan() {
    output="$1"
    python3 -c '
import json
import sys

try:
    payload = json.loads(sys.stdin.read())
except json.JSONDecodeError:
    print("security-scan: scanner did not return valid JSON", file=sys.stderr)
    sys.exit(1)

files_scanned = payload.get("files_scanned")
if not isinstance(files_scanned, int) or files_scanned <= 0:
    print("security-scan: scanner must report files_scanned as a positive integer", file=sys.stderr)
    sys.exit(1)

if payload.get("passed") is not True:
    print("security-scan: scanner JSON must report passed as true", file=sys.stderr)
    sys.exit(1)
' <<EOF
$output
EOF
}

reject_vendored_flint_source

case " $* " in
    *" --json "*)
        set +e
        scan_output="$(run_scanner)"
        scanner_status=$?
        set -e
        printf '%s\n' "$scan_output"
        validate_nonzero_json_scan "$scan_output"
        exit "$scanner_status"
        ;;
esac

run_scanner
