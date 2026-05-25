# KVM Smoke Service Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the real-host KVM smoke harness verify the same vps-agent systemd sandbox properties that the unit file and security docs promise.

**Architecture:** Keep the check inside `scripts/kvm-host-smoke.sh` because it already owns real-host preflight before master mutations. Extend the existing shell validation tests in `scripts/test-kvm-host-smoke-validation.sh` with failing cases for missing sandbox properties, then update the script and docs.

**Tech Stack:** Bash, Python snippets, systemd `systemctl show`, existing docs validation scripts.

---

### Task 1: Add Red Smoke-Validation Coverage

**Files:**
- Modify: `scripts/test-kvm-host-smoke-validation.sh`

- [x] **Step 1: Add failing tests for missing active systemd sandbox properties**

Add tests that stub `systemctl show` with a weakened service state and assert `validate_agent_service` rejects it:

```bash
expect_agent_service_rejects_missing_capability_bounding_set
expect_agent_service_rejects_missing_ambient_capabilities
expect_agent_service_rejects_missing_kernel_tunable_protection
expect_agent_service_rejects_missing_native_syscall_architecture
```

- [x] **Step 2: Run validation to prove the new checks are red**

Run:

```bash
bash scripts/test-kvm-host-smoke-validation.sh
```

Expected: failure because the smoke script does not yet request or validate those systemd properties.

### Task 2: Extend Host Smoke Service Validation

**Files:**
- Modify: `scripts/kvm-host-smoke.sh`
- Modify: `scripts/test-kvm-host-smoke-validation.sh`

- [x] **Step 1: Request all documented hardening properties**

Add `--property=ProtectKernelTunables`, `--property=ProtectKernelModules`, `--property=ProtectControlGroups`, `--property=LockPersonality`, `--property=RestrictRealtime`, `--property=CapabilityBoundingSet`, `--property=AmbientCapabilities`, and `--property=SystemCallArchitectures` to the existing `systemctl show` call.

- [x] **Step 2: Validate exact expected values**

Update the Python `expected` map so the smoke script fails unless the active service reports:

```text
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
LockPersonality=yes
RestrictRealtime=yes
CapabilityBoundingSet=
AmbientCapabilities=
SystemCallArchitectures=native
```

- [x] **Step 3: Update the test stubs**

Every test stub for the hardening `systemctl show` call must match the new argument count and include the extra expected properties, except the specific negative test that omits or changes one property.

- [x] **Step 4: Run validation and expect green**

Run:

```bash
bash scripts/test-kvm-host-smoke-validation.sh
```

Expected: `kvm-host-smoke validation tests passed`.

### Task 3: Document and Verify

**Files:**
- Modify: `docs/SECURITY.md`
- Modify: `docs/INSTALL.md`

- [x] **Step 1: Update docs**

Record that the real-host smoke harness checks the full active sandbox property set, including empty capability sets and native syscall architecture.

- [x] **Step 2: Run final checks**

Run:

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cd frontend && npm run test && npm run lint && npm run typecheck && npm run build
cd .. && bash scripts/test-kvm-host-smoke-validation.sh && bash scripts/test-docs-validation.sh
```

Expected: all checks pass. If a real KVM host is unavailable, do not claim final goal completion.
