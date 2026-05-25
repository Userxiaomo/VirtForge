#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

fake_scanner="$tmp_dir/fake-security-scanner.sh"
args_file="$tmp_dir/scanner-args.txt"

cat > "$fake_scanner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$SECURITY_SCANNER_ARGS_FILE"
printf '%s\n' '{"files_scanned":44,"passed":true,"counts":{},"findings":[]}'
EOF
chmod 0750 "$fake_scanner"

flint_repo="$tmp_dir/repo-with-flint"
mkdir -p "$flint_repo/scripts" "$flint_repo/flint"
cp "$repo_root/scripts/security-scan.sh" "$flint_repo/scripts/security-scan.sh"
chmod 0750 "$flint_repo/scripts/security-scan.sh"

if SECURITY_SCANNER="$fake_scanner" \
    SECURITY_SCANNER_ARGS_FILE="$args_file" \
    bash "$flint_repo/scripts/security-scan.sh" --json >/dev/null 2>&1; then
    echo "security-scan wrapper accepted a vendored flint source tree" >&2
    exit 1
fi

SECURITY_SCANNER="$fake_scanner" \
SECURITY_SCANNER_ARGS_FILE="$args_file" \
    bash "$repo_root/scripts/security-scan.sh" --json >/dev/null

require_arg() {
    local expected="$1"
    grep -Fxq -- "$expected" "$args_file" || {
        echo "security-scan wrapper did not pass expected argument: $expected" >&2
        printf '%s\n' "actual args:" >&2
        cat "$args_file" >&2
        exit 1
    }
}

require_arg "$repo_root"
require_arg "--json"
require_arg "--exclude"
require_arg ".next"
require_arg "target"
require_arg "node_modules"

fake_js_scanner="$tmp_dir/security_scanner.js"
fake_node="$tmp_dir/node"
node_args_file="$tmp_dir/node-args.txt"
printf '%s\n' '// fake scanner' > "$fake_js_scanner"
cat > "$fake_node" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$SECURITY_SCANNER_NODE_ARGS_FILE"
printf '%s\n' '{"files_scanned":44,"passed":true,"counts":{},"findings":[]}'
EOF
chmod 0750 "$fake_node"

SECURITY_SCANNER="$fake_js_scanner" \
SECURITY_SCANNER_NODE="$fake_node" \
SECURITY_SCANNER_NODE_ARGS_FILE="$node_args_file" \
    bash "$repo_root/scripts/security-scan.sh" --json >/dev/null

grep -Fxq -- "$fake_js_scanner" "$node_args_file" || {
    echo "security-scan wrapper did not invoke the configured JS runtime with the scanner path" >&2
    cat "$node_args_file" >&2
    exit 1
}
grep -Fxq -- "--json" "$node_args_file" || {
    echo "security-scan wrapper did not forward scanner arguments through the configured JS runtime" >&2
    cat "$node_args_file" >&2
    exit 1
}

fake_node_exe="$tmp_dir/node.exe"
node_exe_args_file="$tmp_dir/node-exe-args.txt"
repo_scanner="$repo_root/.tmp-security-scanner.js"
trap 'rm -rf "$tmp_dir"; rm -f "$repo_scanner"' EXIT

cat > "$fake_node_exe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$SECURITY_SCANNER_NODE_EXE_ARGS_FILE"
printf '%s\n' '{"files_scanned":44,"passed":true,"counts":{},"findings":[]}'
EOF
chmod 0750 "$fake_node_exe"

printf '%s\n' '// fake scanner' > "$repo_scanner"

SECURITY_SCANNER="$repo_scanner" \
SECURITY_SCANNER_NODE="$fake_node_exe" \
SECURITY_SCANNER_NODE_EXE_ARGS_FILE="$node_exe_args_file" \
    bash "$repo_root/scripts/security-scan.sh" --json >/dev/null

first_arg="$(sed -n '1p' "$node_exe_args_file")"
second_arg="$(sed -n '2p' "$node_exe_args_file")"
case "$first_arg" in
    [A-Za-z]:\\*) ;;
    *)
        echo "security-scan wrapper did not convert the scanner path for node.exe" >&2
        cat "$node_exe_args_file" >&2
        exit 1
        ;;
esac
case "$second_arg" in
    [A-Za-z]:\\*) ;;
    *)
        echo "security-scan wrapper did not convert the scan root for node.exe" >&2
        cat "$node_exe_args_file" >&2
        exit 1
        ;;
esac

zero_scanner="$tmp_dir/zero-security-scanner.sh"
cat > "$zero_scanner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '{"files_scanned":0,"passed":true,"counts":{},"findings":[]}'
EOF
chmod 0750 "$zero_scanner"

if SECURITY_SCANNER="$zero_scanner" bash "$repo_root/scripts/security-scan.sh" --json >/dev/null 2>&1; then
    echo "security-scan wrapper accepted a zero-file JSON scan result" >&2
    exit 1
fi

missing_count_scanner="$tmp_dir/missing-count-security-scanner.sh"
cat > "$missing_count_scanner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '{"passed":true,"counts":{},"findings":[]}'
EOF
chmod 0750 "$missing_count_scanner"

if SECURITY_SCANNER="$missing_count_scanner" bash "$repo_root/scripts/security-scan.sh" --json >/dev/null 2>&1; then
    echo "security-scan wrapper accepted JSON without a positive files_scanned count" >&2
    exit 1
fi

failed_passed_scanner="$tmp_dir/failed-passed-security-scanner.sh"
cat > "$failed_passed_scanner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '{"files_scanned":44,"passed":false,"counts":{"critical":1},"findings":[]}'
EOF
chmod 0750 "$failed_passed_scanner"

if SECURITY_SCANNER="$failed_passed_scanner" bash "$repo_root/scripts/security-scan.sh" --json >/dev/null 2>&1; then
    echo "security-scan wrapper accepted JSON where passed was not true" >&2
    exit 1
fi

invalid_json_scanner="$tmp_dir/invalid-json-security-scanner.sh"
cat > "$invalid_json_scanner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'security scanner produced text instead of json'
EOF
chmod 0750 "$invalid_json_scanner"

if SECURITY_SCANNER="$invalid_json_scanner" bash "$repo_root/scripts/security-scan.sh" --json >/dev/null 2>&1; then
    echo "security-scan wrapper accepted invalid JSON in --json mode" >&2
    exit 1
fi

fake_windows_home="$tmp_dir/windows-home"
default_scanner="$fake_windows_home/.codex/skills/ccg/tools/verify-security/scripts/security_scanner.js"
mkdir -p "$(dirname "$default_scanner")"
printf '%s\n' '// fake discovered scanner' > "$default_scanner"

fake_cmd="$tmp_dir/cmd.exe"
cat > "$fake_cmd" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\r\n' 'C:\\Users\\Smoke'
EOF
chmod 0750 "$fake_cmd"

fake_wslpath="$tmp_dir/wslpath"
cat > "$fake_wslpath" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [ "\$1" != "-u" ] || [ "\$2" != 'C:\\Users\\Smoke' ]; then
    echo "unexpected wslpath arguments: \$*" >&2
    exit 1
fi
printf '%s\n' '$fake_windows_home'
EOF
chmod 0750 "$fake_wslpath"

default_node_args_file="$tmp_dir/default-node-args.txt"
fake_default_node="$tmp_dir/node"
cat > "$fake_default_node" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$SECURITY_SCANNER_DEFAULT_NODE_ARGS_FILE"
printf '%s\n' '{"files_scanned":44,"passed":true,"counts":{},"findings":[]}'
EOF
chmod 0750 "$fake_default_node"

HOME="$tmp_dir/no-default-scanner-home" \
PATH="$tmp_dir:$PATH" \
SECURITY_SCANNER_DEFAULT_NODE_ARGS_FILE="$default_node_args_file" \
    bash "$repo_root/scripts/security-scan.sh" --json >/dev/null

grep -Fxq -- "$default_scanner" "$default_node_args_file" || {
    echo "security-scan wrapper did not discover the Windows Codex scanner from WSL" >&2
    cat "$default_node_args_file" >&2
    exit 1
}

echo "security-scan wrapper validation tests passed"
