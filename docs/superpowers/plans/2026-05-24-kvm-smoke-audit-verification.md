# KVM Smoke Audit Verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the real-host KVM smoke run prove that master audit logs exist for each VM task it executes.

**Architecture:** Add one bounded audit verification helper to `scripts/kvm-host-smoke.sh` that queries `GET /api/admin/audit-logs` once near the end of a successful run and validates task-scoped audit entries by action, task ID, VM ID, and task kind. Extend `scripts/test-kvm-host-smoke-validation.sh` with red/green coverage using the existing stubbed `api` pattern.

**Tech Stack:** Bash, Python JSON parsing, existing master admin audit API.

---

### Task 1: Red Audit Validation Tests

**Files:**
- Modify: `scripts/test-kvm-host-smoke-validation.sh`

- [x] **Step 1: Add a success fixture**

Create a test helper that stubs `api GET /api/admin/audit-logs` with entries for `task.create_vm`, `task.assigned`, `task.status_update`, and `task.log.append` for a known task/VM/node.

- [x] **Step 2: Add a missing-entry failure fixture**

Add a test that omits `task.status_update` and expects the new audit verifier to fail before accepting the smoke result.

- [x] **Step 3: Run validation and confirm red**

Run:

```bash
bash scripts/test-kvm-host-smoke-validation.sh
```

Expected: failure because `verify_smoke_audit_logs` is not implemented yet.

### Task 2: Implement Smoke Audit Verification

**Files:**
- Modify: `scripts/kvm-host-smoke.sh`
- Modify: `scripts/test-kvm-host-smoke-validation.sh`

- [x] **Step 1: Add parser helper**

Add a Python-backed helper that reads audit JSON from stdin and checks task action entries without printing raw JSON.

- [x] **Step 2: Add `verify_smoke_audit_logs`**

Validate:

```text
task.create_vm       create task id       create_vm
task.assigned        create task id       create_vm
task.status_update   create task id       create_vm
task.log.append      create task id
```

Also validate optional reinstall, stop, start, reboot, and cleanup delete task IDs when those phases run.

- [x] **Step 3: Wire verification into `main`**

Call the audit verifier after the successful task/log/host verification path and before printing final JSON.

- [x] **Step 4: Run validation and confirm green**

Run:

```bash
bash scripts/test-kvm-host-smoke-validation.sh
```

Expected: `kvm-host-smoke validation tests passed`.

### Task 3: Docs and Gates

**Files:**
- Modify: `docs/SECURITY.md`
- Modify: `docs/INSTALL.md`

- [x] **Step 1: Document audit verification**

State that full real-host smoke verifies task-scoped audit entries for create/action/delete task lifecycle events and suppresses raw audit JSON on failure.

- [x] **Step 2: Run final checks**

Run:

```bash
bash scripts/test-kvm-host-smoke-validation.sh
bash scripts/test-docs-validation.sh
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
cd frontend && npm run test && npm run lint && npm run typecheck && npm run build
```

Expected: all local checks pass. Real KVM host completion remains unproven until the full smoke script runs on a real host.
