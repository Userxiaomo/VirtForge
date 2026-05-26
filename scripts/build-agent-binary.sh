#!/usr/bin/env bash
set -euo pipefail

output_path="dist/vps-agent"
build_network="host"
docker_platform="linux/amd64"

usage() {
    cat <<'EOF'
Usage:
  scripts/build-agent-binary.sh [--output-path dist/vps-agent] [--build-network host] [--docker-platform linux/amd64]

Builds the Linux vps-agent artifact in Docker, exports it to dist/vps-agent,
and prints JSON containing the artifact path and SHA-256.
EOF
}

fail() {
    echo "build-agent-binary: $*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --output-path)
            if [ "${2:-}" = "" ]; then
                fail "--output-path requires a value"
            fi
            output_path="$2"
            shift 2
            ;;
        --build-network)
            if [ "${2:-}" = "" ]; then
                fail "--build-network requires a value"
            fi
            build_network="$2"
            shift 2
            ;;
        --docker-platform)
            if [ "${2:-}" = "" ]; then
                fail "--docker-platform requires a value"
            fi
            docker_platform="$2"
            shift 2
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

repo_root_dir="$(dirname "${BASH_SOURCE[0]}")/.."
repo_root="$(cd "$repo_root_dir"; pwd -P)"
case "$output_path" in
    /*) resolved_output="$output_path" ;;
    *) resolved_output="$repo_root/$output_path" ;;
esac

output_dir="$(dirname "$resolved_output")"
output_file_name="$(basename "$resolved_output")"
if [ "$output_file_name" != "vps-agent" ]; then
    fail "--output-path must end with vps-agent"
fi

mkdir -p "$output_dir"
resolved_output_dir="$(cd "$output_dir"; pwd -P)"
resolved_output="$resolved_output_dir/$output_file_name"

target_dir="$(mktemp -d)"
cleanup() {
    rm -rf "$target_dir"
}
trap cleanup EXIT

docker info >/dev/null

docker run \
    --rm \
    --platform "$docker_platform" \
    --network "$build_network" \
    -v "$repo_root:/work" \
    -v "$target_dir:/target" \
    -w /work \
    -e CARGO_INCREMENTAL=0 \
    -e CARGO_TARGET_DIR=/target \
    rust:1.88-bookworm \
    cargo build --release -p vps-agent --bin vps-agent

docker run \
    --rm \
    --platform "$docker_platform" \
    -v "$target_dir:/target:ro" \
    -v "$resolved_output_dir:/out" \
    rust:1.88-bookworm \
    install -m 0755 /target/release/vps-agent /out/vps-agent

agent_sha256="$(sha256sum "$resolved_output" | awk '{print $1}')"

json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    printf '%s' "$value"
}

printf '{\n'
printf '  "agent_binary": "%s",\n' "$(json_escape "$resolved_output")"
printf '  "agent_sha256": "%s",\n' "$agent_sha256"
printf '  "build_network": "%s",\n' "$(json_escape "$build_network")"
printf '  "docker_platform": "%s"\n' "$(json_escape "$docker_platform")"
printf '}\n'
