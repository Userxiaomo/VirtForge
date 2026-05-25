#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$repo_root/docs/DESIGN.md" "$repo_root/docs/INSTALL.md" "$repo_root/docs/SECURITY.md" "$repo_root/master/src/http/mod.rs" "$repo_root/master/src/tasks/mod.rs" "$repo_root/scripts/test-docs-validation.sh" <<'PY'
from pathlib import Path
import re
import sys

design = Path(sys.argv[1])
install = Path(sys.argv[2])
security = Path(sys.argv[3])
router = Path(sys.argv[4])
tasks_source = Path(sys.argv[5])
validator = Path(sys.argv[6])
text = design.read_text(encoding="utf-8")
install_text = install.read_text(encoding="utf-8")
security_text = security.read_text(encoding="utf-8")
router_text = router.read_text(encoding="utf-8")
tasks_text = tasks_source.read_text(encoding="utf-8")

required_method_extractor = "extract_" + "route_methods"
if required_method_extractor not in validator.read_text(encoding="utf-8"):
    print(
        f"{validator}: docs validation must compare documented HTTP methods with master/src/http/mod.rs",
        file=sys.stderr,
    )
    sys.exit(1)


def extract_route_calls(source):
    calls = []
    search_from = 0
    while True:
        start = source.find(".route(", search_from)
        if start == -1:
            return calls

        open_paren = source.find("(", start)
        depth = 0
        in_string = False
        escaped = False
        for index in range(open_paren, len(source)):
            char = source[index]
            if in_string:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == '"':
                    in_string = False
                continue

            if char == '"':
                in_string = True
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    calls.append(source[open_paren + 1 : index])
                    search_from = index + 1
                    break
        else:
            print("master/src/http/mod.rs: unterminated .route(...) declaration", file=sys.stderr)
            sys.exit(1)


def extract_route_methods(source):
    route_methods = {}
    for call in extract_route_calls(source):
        path_match = re.search(r'"([^"]+)"', call)
        if not path_match:
            continue

        path = path_match.group(1)
        handler_expression = call[path_match.end() :]
        methods = {
            method.upper()
            for method in re.findall(
                r"\b(get|post|put|patch|delete)\s*\(",
                handler_expression,
            )
        }
        if not methods:
            print(f"master/src/http/mod.rs: no HTTP method extracted for route {path}", file=sys.stderr)
            sys.exit(1)
        route_methods[path] = methods
    return route_methods


def extract_function_body(source, name):
    match = re.search(rf"\basync\s+fn\s+{re.escape(name)}\b", source)
    if not match:
        print(f"master/src/http/mod.rs: function {name} was not found", file=sys.stderr)
        sys.exit(1)

    open_brace = source.find("{", match.end())
    if open_brace == -1:
        print(f"master/src/http/mod.rs: function {name} has no body", file=sys.stderr)
        sys.exit(1)

    depth = 0
    in_string = False
    in_line_comment = False
    in_block_comment = False
    escaped = False
    for index in range(open_brace, len(source)):
        char = source[index]
        next_char = source[index + 1] if index + 1 < len(source) else ""

        if in_line_comment:
            if char == "\n":
                in_line_comment = False
            continue

        if in_block_comment:
            if char == "*" and next_char == "/":
                in_block_comment = False
            continue

        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue

        if char == "/" and next_char == "/":
            in_line_comment = True
            continue
        if char == "/" and next_char == "*":
            in_block_comment = True
            continue
        if char == '"':
            in_string = True
            continue
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[open_brace : index + 1]

    print(f"master/src/http/mod.rs: function {name} body was not closed", file=sys.stderr)
    sys.exit(1)


def require_transactional_create_vm_persistence(source):
    checks = {
        "create_vm_task": [
            r"state\.pool\.begin\(\)\.await\?",
            r"plans::apply_to_create_vm_in_tx\(",
            r"ipam::reserve_next_for_vm_in_tx\(",
            r"tasks::create_in_tx\(",
            r"ipam::attach_task_in_tx\(",
            r"vms::create_from_request_in_tx\(",
            r"audit::write_in_tx\(",
            r"\btx\.commit\(\)\.await\?",
        ],
        "retry_task": [
            r"state\.pool\.begin\(\)\.await\?",
            r"ipam::reserve_next_for_vm_in_tx\(",
            r"tasks::create_in_tx\(",
            r"ipam::attach_task_in_tx\(",
            r"vms::apply_retry_created_in_tx\(",
            r"audit::write_in_tx\(",
            r"\btx\.commit\(\)\.await\?",
        ],
    }

    forbidden = {
        "create_vm_task": [
            r"plans::apply_to_create_vm\(&state\.pool",
            r"ipam::reserve_next_for_vm\(&state\.pool",
            r"tasks::create\(&state\.pool",
            r"ipam::attach_task\(&state\.pool",
            r"vms::create_from_request\(&state\.pool",
            r"audit::write\(\s*&state\.pool",
        ],
        "retry_task": [
            r"ipam::reserve_next_for_vm\(&state\.pool",
            r"tasks::create\(&state\.pool",
            r"ipam::attach_task\(&state\.pool",
            r"vms::apply_retry_created\(&state\.pool",
            r"audit::write\(\s*&state\.pool",
        ],
    }

    for name, required_patterns in checks.items():
        body = extract_function_body(source, name)
        missing = [
            pattern for pattern in required_patterns if not re.search(pattern, body)
        ]
        if missing:
            print(
                f"master/src/http/mod.rs: {name} must persist create-VM task state through one transaction; missing: {', '.join(missing)}",
                file=sys.stderr,
            )
            sys.exit(1)

        present_forbidden = [
            pattern for pattern in forbidden[name] if re.search(pattern, body)
        ]
        if present_forbidden:
            print(
                f"master/src/http/mod.rs: {name} still uses pool-scoped persistence inside create-VM commit path: {', '.join(present_forbidden)}",
                file=sys.stderr,
            )
            sys.exit(1)


def require_transactional_bootstrap_token_creation(source):
    wrapper_body = extract_function_body(source, "create_bootstrap_token")
    inner_body = extract_function_body(source, "create_bootstrap_token_inner")
    required_inner_patterns = [
        r"state\.pool\.begin\(\)\.await\?",
        r"nodes::create_bootstrap_token_in_tx\(",
        r"audit::write_in_tx\(",
        r"\btx\.commit\(\)\.await\?",
    ]
    missing = [
        pattern for pattern in required_inner_patterns if not re.search(pattern, inner_body)
    ]
    required_wrapper_patterns = [
        r"one_time_secret_json_response\(response\)",
        r"no_store_error_response\(error\)",
    ]
    missing.extend(
        pattern for pattern in required_wrapper_patterns if not re.search(pattern, wrapper_body)
    )
    if missing:
        print(
            f"master/src/http/mod.rs: create_bootstrap_token must insert token hash, write audit, and return the one-time install command through one transaction; missing: {', '.join(missing)}",
            file=sys.stderr,
        )
        sys.exit(1)

    forbidden_patterns = [
        r"nodes::create_bootstrap_token\(\s*&state\.pool",
        r"audit::write\(\s*&state\.pool",
    ]
    present_forbidden = [
        pattern
        for pattern in forbidden_patterns
        if re.search(pattern, wrapper_body) or re.search(pattern, inner_body)
    ]
    if present_forbidden:
        print(
            f"master/src/http/mod.rs: create_bootstrap_token still uses pool-scoped token/audit persistence: {', '.join(present_forbidden)}",
            file=sys.stderr,
        )
        sys.exit(1)


def require_transactional_node_creation(source):
    body = extract_function_body(source, "create_node")
    required_patterns = [
        r"state\.pool\.begin\(\)\.await\?",
        r"nodes::create_in_tx\(",
        r"audit::write_in_tx\(",
        r"\btx\.commit\(\)\.await\?",
    ]
    missing = [pattern for pattern in required_patterns if not re.search(pattern, body)]
    if missing:
        print(
            f"master/src/http/mod.rs: create_node must insert the node row and write node.create audit through one transaction; missing: {', '.join(missing)}",
            file=sys.stderr,
        )
        sys.exit(1)

    forbidden_patterns = [
        r"nodes::create\(\s*&state\.pool",
        r"audit::write\(\s*&state\.pool",
    ]
    present_forbidden = [
        pattern for pattern in forbidden_patterns if re.search(pattern, body)
    ]
    if present_forbidden:
        print(
            f"master/src/http/mod.rs: create_node still uses pool-scoped node/audit persistence: {', '.join(present_forbidden)}",
            file=sys.stderr,
        )
        sys.exit(1)


def require_transactional_node_scheduling_update(source):
    body = extract_function_body(source, "update_node_scheduling")
    required_patterns = [
        r"state\.pool\.begin\(\)\.await\?",
        r"nodes::update_scheduling_in_tx\(",
        r"audit::write_in_tx\(",
        r"\btx\.commit\(\)\.await\?",
    ]
    missing = [pattern for pattern in required_patterns if not re.search(pattern, body)]
    if missing:
        print(
            f"master/src/http/mod.rs: update_node_scheduling must update scheduling and write node.scheduling_update audit through one transaction; missing: {', '.join(missing)}",
            file=sys.stderr,
        )
        sys.exit(1)

    forbidden_patterns = [
        r"nodes::update_scheduling\(\s*&state\.pool",
        r"audit::write\(\s*&state\.pool",
    ]
    present_forbidden = [
        pattern for pattern in forbidden_patterns if re.search(pattern, body)
    ]
    if present_forbidden:
        print(
            f"master/src/http/mod.rs: update_node_scheduling still uses pool-scoped scheduling/audit persistence: {', '.join(present_forbidden)}",
            file=sys.stderr,
        )
        sys.exit(1)


def require_task_scheduling_row_locks(source):
    required_markers = [
        "const NODE_TASK_ADMISSION_FOR_UPDATE_SQL",
        "const CLAIM_NEXT_FOR_NODE_SQL",
        "FOR UPDATE OF n",
        "FOR UPDATE OF t SKIP LOCKED",
    ]
    missing = [marker for marker in required_markers if marker not in source]
    if missing:
        print(
            f"master/src/tasks/mod.rs: task admission and claim must lock node scheduling rows; missing: {', '.join(missing)}",
            file=sys.stderr,
        )
        sys.exit(1)


def require_transactional_plan_creation(source):
    body = extract_function_body(source, "create_plan")
    required_patterns = [
        r"state\.pool\.begin\(\)\.await\?",
        r"plans::create_in_tx\(",
        r"audit::write_in_tx\(",
        r"\btx\.commit\(\)\.await\?",
    ]
    missing = [pattern for pattern in required_patterns if not re.search(pattern, body)]
    if missing:
        print(
            f"master/src/http/mod.rs: create_plan must insert the commercial plan row and write plan.create audit through one transaction; missing: {', '.join(missing)}",
            file=sys.stderr,
        )
        sys.exit(1)

    forbidden_patterns = [
        r"plans::create\(\s*&state\.pool",
        r"audit::write\(\s*&state\.pool",
    ]
    present_forbidden = [
        pattern for pattern in forbidden_patterns if re.search(pattern, body)
    ]
    if present_forbidden:
        print(
            f"master/src/http/mod.rs: create_plan still uses pool-scoped plan/audit persistence: {', '.join(present_forbidden)}",
            file=sys.stderr,
        )
        sys.exit(1)


def require_transactional_plan_enabled_update(source):
    body = extract_function_body(source, "update_plan_enabled")
    required_patterns = [
        r"state\.pool\.begin\(\)\.await\?",
        r"plans::set_enabled_in_tx\(",
        r"audit::write_in_tx\(",
        r"\btx\.commit\(\)\.await\?",
    ]
    missing = [pattern for pattern in required_patterns if not re.search(pattern, body)]
    if missing:
        print(
            f"master/src/http/mod.rs: update_plan_enabled must update the commercial plan enabled flag and write plan.enabled_update audit through one transaction; missing: {', '.join(missing)}",
            file=sys.stderr,
        )
        sys.exit(1)

    forbidden_patterns = [
        r"plans::set_enabled\(\s*&state\.pool",
        r"audit::write\(\s*&state\.pool",
    ]
    present_forbidden = [
        pattern for pattern in forbidden_patterns if re.search(pattern, body)
    ]
    if present_forbidden:
        print(
            f"master/src/http/mod.rs: update_plan_enabled still uses pool-scoped plan-enabled/audit persistence: {', '.join(present_forbidden)}",
            file=sys.stderr,
        )
        sys.exit(1)


def require_transactional_image_creation(source):
    body = extract_function_body(source, "create_image")
    required_patterns = [
        r"state\.pool\.begin\(\)\.await\?",
        r"images::create_in_tx\(",
        r"audit::write_in_tx\(",
        r"\btx\.commit\(\)\.await\?",
    ]
    missing = [pattern for pattern in required_patterns if not re.search(pattern, body)]
    if missing:
        print(
            f"master/src/http/mod.rs: create_image must insert the image catalog row and write image.create audit through one transaction; missing: {', '.join(missing)}",
            file=sys.stderr,
        )
        sys.exit(1)

    forbidden_patterns = [
        r"images::create\(\s*&state\.pool",
        r"audit::write\(\s*&state\.pool",
    ]
    present_forbidden = [
        pattern for pattern in forbidden_patterns if re.search(pattern, body)
    ]
    if present_forbidden:
        print(
            f"master/src/http/mod.rs: create_image still uses pool-scoped image/audit persistence: {', '.join(present_forbidden)}",
            file=sys.stderr,
        )
        sys.exit(1)


def require_transactional_image_enabled_update(source):
    body = extract_function_body(source, "update_image_enabled")
    required_patterns = [
        r"state\.pool\.begin\(\)\.await\?",
        r"images::set_enabled_in_tx\(",
        r"audit::write_in_tx\(",
        r"\btx\.commit\(\)\.await\?",
    ]
    missing = [pattern for pattern in required_patterns if not re.search(pattern, body)]
    if missing:
        print(
            f"master/src/http/mod.rs: update_image_enabled must update the image enabled flag and write image.enabled_update audit through one transaction; missing: {', '.join(missing)}",
            file=sys.stderr,
        )
        sys.exit(1)

    forbidden_patterns = [
        r"images::set_enabled\(\s*&state\.pool",
        r"audit::write\(\s*&state\.pool",
    ]
    present_forbidden = [
        pattern for pattern in forbidden_patterns if re.search(pattern, body)
    ]
    if present_forbidden:
        print(
            f"master/src/http/mod.rs: update_image_enabled still uses pool-scoped image-enabled/audit persistence: {', '.join(present_forbidden)}",
            file=sys.stderr,
        )
        sys.exit(1)


def require_transactional_ip_pool_creation(source):
    body = extract_function_body(source, "create_ip_pool")
    required_patterns = [
        r"state\.pool\.begin\(\)\.await\?",
        r"ipam::create_in_tx\(",
        r"audit::write_in_tx\(",
        r"\btx\.commit\(\)\.await\?",
    ]
    missing = [pattern for pattern in required_patterns if not re.search(pattern, body)]
    if missing:
        print(
            f"master/src/http/mod.rs: create_ip_pool must insert the IP pool row and write ip_pool.create audit through one transaction; missing: {', '.join(missing)}",
            file=sys.stderr,
        )
        sys.exit(1)

    forbidden_patterns = [
        r"ipam::create\(\s*&state\.pool",
        r"audit::write\(\s*&state\.pool",
    ]
    present_forbidden = [
        pattern for pattern in forbidden_patterns if re.search(pattern, body)
    ]
    if present_forbidden:
        print(
            f"master/src/http/mod.rs: create_ip_pool still uses pool-scoped IP pool/audit persistence: {', '.join(present_forbidden)}",
            file=sys.stderr,
        )
        sys.exit(1)


def require_transactional_agent_heartbeat_persistence(source):
    body = extract_function_body(source, "agent_heartbeat")
    required_patterns = [
        r"state\.pool\.begin\(\)\.await\?",
        r"nodes::record_heartbeat_in_tx\(",
        r"audit::write_in_tx\(",
        r"\btx\.commit\(\)\.await\?",
    ]
    missing = [pattern for pattern in required_patterns if not re.search(pattern, body)]
    if missing:
        print(
            f"master/src/http/mod.rs: agent_heartbeat must persist node telemetry and agent.heartbeat audit through one transaction; missing: {', '.join(missing)}",
            file=sys.stderr,
        )
        sys.exit(1)

    forbidden_patterns = [
        r"nodes::record_heartbeat\(\s*&state\.pool",
        r"audit::write\(\s*&state\.pool",
    ]
    present_forbidden = [
        pattern for pattern in forbidden_patterns if re.search(pattern, body)
    ]
    if present_forbidden:
        print(
            f"master/src/http/mod.rs: agent_heartbeat still uses pool-scoped telemetry/audit persistence: {', '.join(present_forbidden)}",
            file=sys.stderr,
        )
        sys.exit(1)


def require_transactional_agent_status_persistence(source):
    body = extract_function_body(source, "agent_update_task_status")
    required_patterns = [
        r"state\.pool\.begin\(\)\.await\?",
        r"tasks::update_status_in_tx\(",
        r"vms::apply_task_status_in_tx\(",
        r"audit::write_in_tx\(",
        r"tasks::append_failure_log_in_tx\(",
        r"\btx\.commit\(\)\.await\?",
    ]
    missing = [pattern for pattern in required_patterns if not re.search(pattern, body)]
    if missing:
        print(
            f"master/src/http/mod.rs: agent_update_task_status must persist task status, VM lifecycle, audit, and failure summary through one transaction; missing: {', '.join(missing)}",
            file=sys.stderr,
        )
        sys.exit(1)


def require_transactional_agent_registration_persistence(source):
    wrapper_body = extract_function_body(source, "register_agent")
    inner_body = extract_function_body(source, "register_agent_inner")
    required_inner_patterns = [
        r"state\.pool\.begin\(\)\.await\?",
        r"nodes::register_agent_in_tx\(",
        r"audit::write_in_tx\(",
        r"\btx\.commit\(\)\.await\?",
    ]
    missing = [pattern for pattern in required_inner_patterns if not re.search(pattern, inner_body)]
    required_wrapper_patterns = [
        r"one_time_secret_json_response\(response\)",
        r"no_store_error_response\(error\)",
    ]
    missing.extend(
        pattern for pattern in required_wrapper_patterns if not re.search(pattern, wrapper_body)
    )
    if missing:
        print(
            f"master/src/http/mod.rs: register_agent must consume bootstrap token, store credential hash, write audit, and return the one-time credential through one transaction; missing: {', '.join(missing)}",
            file=sys.stderr,
        )
        sys.exit(1)

    forbidden_patterns = [
        r"nodes::register_agent\(\s*&state\.pool",
        r"audit::write\(\s*&state\.pool",
    ]
    present_forbidden = [
        pattern
        for pattern in forbidden_patterns
        if re.search(pattern, wrapper_body) or re.search(pattern, inner_body)
    ]
    if present_forbidden:
        print(
            f"master/src/http/mod.rs: register_agent still uses pool-scoped registration/audit persistence: {', '.join(present_forbidden)}",
            file=sys.stderr,
        )
        sys.exit(1)


def require_transactional_agent_log_persistence(source):
    body = extract_function_body(source, "agent_append_task_log")
    required_patterns = [
        r"state\.pool\.begin\(\)\.await\?",
        r"tasks::append_log_in_tx\(",
        r"audit::write_in_tx\(",
        r"\btx\.commit\(\)\.await\?",
    ]
    missing = [pattern for pattern in required_patterns if not re.search(pattern, body)]
    if missing:
        print(
            f"master/src/http/mod.rs: agent_append_task_log must persist task log and audit through one transaction; missing: {', '.join(missing)}",
            file=sys.stderr,
        )
        sys.exit(1)

    forbidden_patterns = [
        r"tasks::append_log\(\s*&state\.pool",
        r"audit::write\(\s*&state\.pool",
    ]
    present_forbidden = [
        pattern for pattern in forbidden_patterns if re.search(pattern, body)
    ]
    if present_forbidden:
        print(
            f"master/src/http/mod.rs: agent_append_task_log still uses pool-scoped log/audit persistence: {', '.join(present_forbidden)}",
            file=sys.stderr,
        )
        sys.exit(1)


def require_transactional_agent_poll_task_persistence(source):
    body = extract_function_body(source, "agent_poll_task")
    required_patterns = [
        r"state\.pool\.begin\(\)\.await\?",
        r"tasks::claim_next_for_node_in_tx\(",
        r"audit::write_in_tx\(",
        r"\btx\.commit\(\)\.await\?",
    ]
    missing = [pattern for pattern in required_patterns if not re.search(pattern, body)]
    if missing:
        print(
            f"master/src/http/mod.rs: agent_poll_task must persist task assignment and audit through one transaction; missing: {', '.join(missing)}",
            file=sys.stderr,
        )
        sys.exit(1)

    forbidden_patterns = [
        r"tasks::claim_next_for_node\(\s*&state\.pool",
        r"audit::write\(\s*&state\.pool",
    ]
    present_forbidden = [
        pattern for pattern in forbidden_patterns if re.search(pattern, body)
    ]
    if present_forbidden:
        print(
            f"master/src/http/mod.rs: agent_poll_task still uses pool-scoped assignment/audit persistence: {', '.join(present_forbidden)}",
            file=sys.stderr,
        )
        sys.exit(1)


def require_transactional_admin_task_persistence(source):
    checks = {
        "reinstall_vm_task": [
            r"state\.pool\.begin\(\)\.await\?",
            r"tasks::create_in_tx\(",
            r"vms::apply_task_status_in_tx\(",
            r"audit::write_in_tx\(",
            r"\btx\.commit\(\)\.await\?",
        ],
        "create_vm_action_task": [
            r"state\.pool\.begin\(\)\.await\?",
            r"tasks::create_in_tx\(",
            r"vms::apply_task_status_in_tx\(",
            r"audit::write_in_tx\(",
            r"\btx\.commit\(\)\.await\?",
        ],
        "cancel_task": [
            r"state\.pool\.begin\(\)\.await\?",
            r"tasks::cancel_in_tx\(",
            r"vms::apply_task_status_in_tx\(",
            r"audit::write_in_tx\(",
            r"\btx\.commit\(\)\.await\?",
        ],
    }

    forbidden = {
        "reinstall_vm_task": [
            r"tasks::create\(&state\.pool",
            r"vms::apply_task_status\(&state\.pool",
            r"audit::write\(\s*&state\.pool",
        ],
        "create_vm_action_task": [
            r"tasks::create\(&state\.pool",
            r"vms::apply_task_status\(&state\.pool",
            r"audit::write\(\s*&state\.pool",
        ],
        "cancel_task": [
            r"tasks::cancel\(&state\.pool",
            r"vms::apply_task_status\(&state\.pool",
            r"audit::write\(\s*&state\.pool",
        ],
    }

    for name, required_patterns in checks.items():
        body = extract_function_body(source, name)
        missing = [
            pattern for pattern in required_patterns if not re.search(pattern, body)
        ]
        if missing:
            print(
                f"master/src/http/mod.rs: {name} must persist admin task state, VM lifecycle, and audit through one transaction; missing: {', '.join(missing)}",
                file=sys.stderr,
            )
            sys.exit(1)

        present_forbidden = [
            pattern for pattern in forbidden[name] if re.search(pattern, body)
        ]
        if present_forbidden:
            print(
                f"master/src/http/mod.rs: {name} still uses pool-scoped admin task persistence: {', '.join(present_forbidden)}",
                file=sys.stderr,
            )
            sys.exit(1)

    forbidden_patterns = [
        r"tasks::update_status\(&state\.pool",
        r"vms::apply_task_status\(&state\.pool",
        r"audit::write\(\s*&state\.pool",
        r"tasks::append_failure_log\(&state\.pool",
    ]
    present_forbidden = [
        pattern for pattern in forbidden_patterns if re.search(pattern, body)
    ]
    if present_forbidden:
        print(
            f"master/src/http/mod.rs: agent_update_task_status still uses pool-scoped status persistence: {', '.join(present_forbidden)}",
            file=sys.stderr,
        )
        sys.exit(1)

stale_phrases = [
    "当前阶段只建立清晰骨架，不实现完整业务闭环",
    "权限角色占位",
    "节点模型占位",
    "任务模型占位",
    "审计模型占位",
    "心跳 payload 占位",
    "后续镜像和 IP 池边界",
    "后续执行层边界",
    "后续页面",
    "第二阶段再实现 PostgreSQL",
]

found = [phrase for phrase in stale_phrases if phrase in text]
if found:
    print(
        f"{design}: stale first-stage placeholder wording remains: {', '.join(found)}",
        file=sys.stderr,
    )
    sys.exit(1)

required_current_markers = [
    "当前实现已经覆盖 master MVP、agent MVP、frontend MVP、libvirt 执行层和部署闭环脚本",
    "master 当前包含",
    "agent 当前包含",
    "frontend 当前覆盖",
]

missing = [marker for marker in required_current_markers if marker not in text]
if missing:
    print(
        f"{design}: missing current-state design markers: {', '.join(missing)}",
        file=sys.stderr,
    )
    sys.exit(1)

stale_install_phrases = [
    "Runs agent registration against master.",
    "Persists the long-term credential to `/etc/vps-agent/agent.toml`.",
    "Clears the bootstrap token from the local config.",
]

found_install_stale = [phrase for phrase in stale_install_phrases if phrase in install_text]
if found_install_stale:
    print(
        f"{install}: stale installer flow wording makes agent-owned registration look like installer behavior: {', '.join(found_install_stale)}",
        file=sys.stderr,
    )
    sys.exit(1)

stale_security_phrases = [
    "task payload 来自认证通道，后续可增加请求签名",
    "如果后续实现请求签名",
]

found_security_stale = [phrase for phrase in stale_security_phrases if phrase in security_text]
if found_security_stale:
    print(
        f"{security}: stale agent request-signing wording remains after HMAC signing was implemented: {', '.join(found_security_stale)}",
        file=sys.stderr,
    )
    sys.exit(1)

required_security_markers = [
    "After registration, agent requests are HMAC-signed",
    "nonce table rejects replay",
    "The HMAC key is the long-term agent credential",
    "Admin session creation applies the `admin:session` bucket before parsing the login JSON",
    "This keeps repeated malformed browser login payloads inside the same login throttling boundary",
    "Admin mutation endpoints that accept JSON payloads authenticate the bearer token and consume the authenticated admin rate-limit buckets before parsing the mutation JSON",
    "Repeated malformed mutation payloads from a valid admin token therefore stay inside the same admin throttling boundary",
    "Master applies the global agent rate-limit bucket before parsing signed-agent JSON",
    "Well-formed requests then also consume the node-specific bucket",
    "Agent registration applies the global `agent-register:all` bucket before parsing the registration JSON",
    "Well-formed registration attempts then also consume a secret-derived bucket scoped by node ID and bootstrap token",
    "Short secret-shaped values of eight characters or fewer must use the fixed hint `***` instead of a suffix hint",
    "Master configuration has a custom `Debug` implementation",
    "prints fixed `[REDACTED]` placeholders for `MASTER_ADMIN_TOKEN_HASH` and `MASTER_READONLY_TOKEN_HASH`",
    "Agent configuration also has a custom `Debug` implementation",
    "redacts URL userinfo in `master_base_url` and relies on the shared redacted secret wrappers",
    "The shared bootstrap-token response also has a custom `Debug` implementation",
    "prints only a fixed `[REDACTED INSTALL COMMAND]` placeholder for `install_command`",
    "`install_command` is also treated as a sensitive field by the master and agent redactors",
    "the whole value is replaced with `[REDACTED]` instead of trying to parse individual shell arguments",
    "The agent registration endpoint uses the same no-store response boundary for the long-term `credential`",
]

missing_security_markers = [
    marker for marker in required_security_markers if marker not in security_text
]
if missing_security_markers:
    print(
        f"{security}: missing current agent request-signing boundary wording: {', '.join(missing_security_markers)}",
        file=sys.stderr,
    )
    sys.exit(1)

required_install_markers = [
    "Starts the systemd service so the agent can register on first start.",
    "The installer does not call the",
    "registration endpoint itself",
    "After successful registration, the agent receives a",
    "long-term `credential`, saves it to the same config file, and removes the",
    "bootstrap token.",
]

missing_install_markers = [
    marker for marker in required_install_markers if marker not in install_text
]
if missing_install_markers:
    print(
        f"{install}: missing installer/agent registration boundary wording: {', '.join(missing_install_markers)}",
        file=sys.stderr,
    )
    sys.exit(1)

implemented_route_methods = extract_route_methods(router_text)
if not implemented_route_methods:
    print(f"{router}: no axum routes were extracted for documentation validation", file=sys.stderr)
    sys.exit(1)
require_transactional_create_vm_persistence(router_text)
require_transactional_node_creation(router_text)
require_transactional_node_scheduling_update(router_text)
require_task_scheduling_row_locks(tasks_text)
require_transactional_plan_creation(router_text)
require_transactional_plan_enabled_update(router_text)
require_transactional_image_creation(router_text)
require_transactional_image_enabled_update(router_text)
require_transactional_ip_pool_creation(router_text)
require_transactional_bootstrap_token_creation(router_text)
require_transactional_agent_registration_persistence(router_text)
require_transactional_agent_heartbeat_persistence(router_text)
require_transactional_agent_status_persistence(router_text)
require_transactional_agent_log_persistence(router_text)
require_transactional_agent_poll_task_persistence(router_text)
require_transactional_admin_task_persistence(router_text)

missing_routes = [route for route in sorted(implemented_route_methods) if route not in text]
if missing_routes:
    print(
        f"{design}: missing implemented API route documentation from {router}: {', '.join(missing_routes)}",
        file=sys.stderr,
    )
    sys.exit(1)

method_order = ["GET", "POST", "PUT", "PATCH", "DELETE"]
missing_method_routes = []
for route, methods in sorted(implemented_route_methods.items()):
    ordered_methods = [method for method in method_order if method in methods]
    combined_marker = f"{'/'.join(ordered_methods)} {route}"
    if len(ordered_methods) > 1 and combined_marker in text:
        continue

    for method in ordered_methods:
        method_marker = f"{method} {route}"
        if method_marker not in text:
            missing_method_routes.append(method_marker)

if missing_method_routes:
    print(
        f"{design}: missing implemented API method documentation from {router}: {', '.join(missing_method_routes)}",
        file=sys.stderr,
    )
    sys.exit(1)

expected_service_path = "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
stale_service_path = "PATH=/usr/local/sbin:/usr/local/bin:/sbin:/usr/bin:/sbin:/bin"
for doc, doc_text in ((design, text), (install, install_text), (security, security_text)):
    if stale_service_path in doc_text:
        print(
            f"{doc}: documented vps-agent service PATH is missing /usr/sbin",
            file=sys.stderr,
        )
        sys.exit(1)
    if expected_service_path not in doc_text:
        print(
            f"{doc}: missing documented vps-agent service PATH {expected_service_path}",
            file=sys.stderr,
        )
        sys.exit(1)
PY

echo "docs validation tests passed"
