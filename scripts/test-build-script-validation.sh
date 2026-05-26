#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_scripts=(
    "$repo_root/scripts/build-agent-binary.ps1"
    "$repo_root/scripts/build-docker-images.ps1"
)

if [[ ! -f "$repo_root/scripts/build-agent-binary.sh" ]]; then
    echo "build-agent-binary.sh is missing" >&2
    exit 1
fi

for build_script in "$repo_root"/scripts/build-*.ps1; do
    is_covered=0
    for covered_script in "${build_scripts[@]}"; do
        if [[ "$build_script" == "$covered_script" ]]; then
            is_covered=1
            break
        fi
    done
    if [[ "$is_covered" -ne 1 ]]; then
        echo "$(basename "$build_script") is missing from build script validation" >&2
        exit 1
    fi
done

for build_script in "${build_scripts[@]}"; do
    script_name="$(basename "$build_script")"

    if grep -Eq '\b(bash|sh)\s+-c\b' "$build_script"; then
        echo "$script_name must not use bash -c or sh -c command strings" >&2
        exit 1
    fi

    if grep -Eq '&&|\|\|' "$build_script"; then
        echo "$script_name must not chain build steps through shell operators" >&2
        exit 1
    fi
done

for project_dir in "$repo_root/agent" "$repo_root/master" "$repo_root/shared" "$repo_root/frontend"; do
    while IFS= read -r option_like_file; do
        echo "unexpected option-looking file in project root: $option_like_file" >&2
        exit 1
    done < <(find "$project_dir" -maxdepth 1 -type f -name '--*' -print)
done

if ! grep -Eq 'Get-FileHash.+SHA256|SHA256.+Get-FileHash' "$repo_root/scripts/build-agent-binary.ps1"; then
    echo "build-agent-binary.ps1 must compute a SHA-256 for the exported agent binary" >&2
    exit 1
fi

if ! grep -Eq 'agent_sha256' "$repo_root/scripts/build-agent-binary.ps1"; then
    echo "build-agent-binary.ps1 must include agent_sha256 in its JSON output" >&2
    exit 1
fi

if grep -Eq '\b(bash|sh)\s+-c\b' "$repo_root/scripts/build-agent-binary.sh"; then
    echo "build-agent-binary.sh must not use bash -c or sh -c command strings" >&2
    exit 1
fi

if grep -Eq '&&|\|\|' "$repo_root/scripts/build-agent-binary.sh"; then
    echo "build-agent-binary.sh must not chain build steps through shell operators" >&2
    exit 1
fi

required_agent_binary_sh_markers=(
    "cargo build --release -p vps-agent --bin vps-agent"
    "CARGO_TARGET_DIR=/target"
    "install -m 0755 /target/release/vps-agent /out/vps-agent"
    "sha256sum"
    "agent_sha256"
)

for marker in "${required_agent_binary_sh_markers[@]}"; do
    if ! grep -Fq "$marker" "$repo_root/scripts/build-agent-binary.sh"; then
        echo "build-agent-binary.sh is missing expected marker: $marker" >&2
        exit 1
    fi
done

if grep -RIn --include='*.rs' '^#!\[allow(dead_code)\]' "$repo_root/agent/src" "$repo_root/master/src" "$repo_root/shared/src"; then
    echo "Rust crates must not hide dead code with crate-wide allow(dead_code)" >&2
    exit 1
fi

echo "build script validation tests passed"
