use chrono::{DateTime, Utc};
use serde_json::json;
use sqlx::{PgPool, Postgres, Row, Transaction};
use uuid::Uuid;
use vps_shared::{NodeId, TaskDto, TaskId, TaskKind, TaskLogDto, TaskStatus};

use crate::{http::ApiError, redaction};

const MAX_DIAGNOSTIC_MESSAGE_BYTES: usize = 4096;
const NODE_HEARTBEAT_STALE_AFTER_SECONDS: i64 = 2 * 60 * 60;

const NODE_TASK_ADMISSION_FOR_UPDATE_SQL: &str = r#"
        SELECT credential_hash, scheduling_enabled, status, agent_version, last_seen_at, libvirt_status
        FROM nodes n
        WHERE n.id = $1
        FOR UPDATE OF n
        "#;

const CLAIM_NEXT_FOR_NODE_SQL: &str = r#"
        WITH admitted_node AS (
            SELECT n.id
            FROM nodes n
            WHERE n.id = $1
                AND n.scheduling_enabled = true
            FOR UPDATE OF n
        ),
        next_task AS (
            SELECT t.id
            FROM tasks t
            JOIN admitted_node n ON n.id = t.node_id
            WHERE t.status = 'pending'
            ORDER BY t.created_at ASC
            LIMIT 1
            FOR UPDATE OF t SKIP LOCKED
        )
        UPDATE tasks t
        SET status = 'assigned', updated_at = now()
        FROM next_task
        WHERE t.id = next_task.id
        RETURNING t.id, t.node_id, t.kind, t.payload, t.status, t.error_message, t.created_at, t.updated_at
        "#;

pub async fn create_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    node_id: NodeId,
    kind: TaskKind,
) -> Result<TaskDto, ApiError> {
    ensure_node_accepts_task_in_tx(tx, node_id, &kind).await?;

    let id = Uuid::new_v4();
    let kind_name = kind_name(&kind);
    let payload = serde_json::to_value(&kind)?;

    let row = sqlx::query(
        r#"
        INSERT INTO tasks (id, node_id, kind, payload, status)
        VALUES ($1, $2, $3, $4, $5)
        RETURNING id, node_id, kind, payload, status, error_message, created_at, updated_at
        "#,
    )
    .bind(id)
    .bind(node_id.0)
    .bind(kind_name)
    .bind(payload)
    .bind(TaskStatus::Pending.as_str())
    .fetch_one(&mut **tx)
    .await?;

    task_from_row(row)
}

pub fn audit_detail(kind: &TaskKind) -> serde_json::Value {
    json!({
        "task_kind": kind_name(kind),
        "vm_id": task_vm_id(kind).map(|id| id.0),
    })
}

fn kind_name(kind: &TaskKind) -> &'static str {
    match kind {
        TaskKind::CreateVm(_) => "create_vm",
        TaskKind::StartVm { .. } => "start_vm",
        TaskKind::StopVm { .. } => "stop_vm",
        TaskKind::RebootVm { .. } => "reboot_vm",
        TaskKind::ReinstallVm { .. } => "reinstall_vm",
        TaskKind::DeleteVm { .. } => "delete_vm",
    }
}

fn task_vm_id(kind: &TaskKind) -> Option<vps_shared::VmId> {
    match kind {
        TaskKind::CreateVm(request) => request.vm_id,
        TaskKind::StartVm { vm_id }
        | TaskKind::StopVm { vm_id }
        | TaskKind::RebootVm { vm_id }
        | TaskKind::ReinstallVm { vm_id, .. }
        | TaskKind::DeleteVm { vm_id } => Some(*vm_id),
    }
}

#[derive(Clone, Copy)]
struct NodeTaskAdmission<'a> {
    credential_hash: Option<&'a str>,
    scheduling_enabled: bool,
    status: &'a str,
    agent_version: Option<&'a str>,
    last_seen_at: Option<DateTime<Utc>>,
    libvirt_status: &'a str,
}

async fn ensure_node_accepts_task_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    node_id: NodeId,
    kind: &TaskKind,
) -> Result<(), ApiError> {
    let row = sqlx::query(NODE_TASK_ADMISSION_FOR_UPDATE_SQL)
        .bind(node_id.0)
        .fetch_optional(&mut **tx)
        .await?
        .ok_or(ApiError::NotFound("node not found"))?;

    validate_node_task_admission_row(kind, row)
}

fn validate_node_task_admission_row(
    kind: &TaskKind,
    row: sqlx::postgres::PgRow,
) -> Result<(), ApiError> {
    let credential_hash: Option<String> = row.try_get("credential_hash")?;
    let scheduling_enabled: bool = row.try_get("scheduling_enabled")?;
    let status: String = row.try_get("status")?;
    let agent_version: Option<String> = row.try_get("agent_version")?;
    let last_seen_at: Option<DateTime<Utc>> = row.try_get("last_seen_at")?;
    let libvirt_status: String = row.try_get("libvirt_status")?;

    validate_node_task_admission(
        kind,
        NodeTaskAdmission {
            credential_hash: credential_hash.as_deref(),
            scheduling_enabled,
            status: status.as_str(),
            agent_version: agent_version.as_deref(),
            last_seen_at,
            libvirt_status: libvirt_status.as_str(),
        },
    )
}

fn validate_node_task_admission(
    kind: &TaskKind,
    node: NodeTaskAdmission<'_>,
) -> Result<(), ApiError> {
    if node.credential_hash.is_none() {
        return Err(ApiError::Conflict("node is not registered"));
    }
    if !node.scheduling_enabled {
        return Err(ApiError::Conflict("node scheduling is disabled"));
    }

    if matches!(kind, TaskKind::CreateVm(_)) {
        if node.status != "online" {
            return Err(ApiError::Conflict("node is not online"));
        }
        if !matches!(node.agent_version, Some(version) if !version.is_empty()) {
            return Err(ApiError::Conflict(
                "node has not completed agent registration",
            ));
        }
        if node.last_seen_at.is_none() {
            return Err(ApiError::Conflict("node has not reported heartbeat"));
        }
        if node
            .last_seen_at
            .is_some_and(|last_seen_at| Utc::now() - last_seen_at > heartbeat_stale_after())
        {
            return Err(ApiError::Conflict("node heartbeat is stale"));
        }
        if node.libvirt_status == "unavailable" {
            return Err(ApiError::Conflict("node libvirt is unavailable"));
        }
    }

    Ok(())
}

fn heartbeat_stale_after() -> chrono::Duration {
    chrono::Duration::seconds(NODE_HEARTBEAT_STALE_AFTER_SECONDS)
}

pub async fn get(pool: &PgPool, task_id: TaskId) -> Result<TaskDto, ApiError> {
    let row = sqlx::query(
        r#"
        SELECT id, node_id, kind, payload, status, error_message, created_at, updated_at
        FROM tasks
        WHERE id = $1
        "#,
    )
    .bind(task_id.0)
    .fetch_optional(pool)
    .await?
    .ok_or(ApiError::NotFound("task not found"))?;

    task_from_row(row)
}

pub async fn list_recent(pool: &PgPool) -> Result<Vec<TaskDto>, ApiError> {
    let rows = sqlx::query(
        r#"
        SELECT id, node_id, kind, payload, status, error_message, created_at, updated_at
        FROM tasks
        ORDER BY created_at DESC
        LIMIT 100
        "#,
    )
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(task_from_row).collect()
}

pub async fn claim_next_for_node_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    node_id: NodeId,
) -> Result<Option<TaskDto>, ApiError> {
    let row = sqlx::query(CLAIM_NEXT_FOR_NODE_SQL)
        .bind(node_id.0)
        .fetch_optional(&mut **tx)
        .await?;

    row.map(task_from_row).transpose()
}

pub async fn update_status_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    task_id: TaskId,
    node_id: NodeId,
    status: TaskStatus,
    error_message: Option<&str>,
) -> Result<TaskDto, ApiError> {
    if !matches!(
        status,
        TaskStatus::Running | TaskStatus::Succeeded | TaskStatus::Failed | TaskStatus::Canceled
    ) {
        return Err(ApiError::Conflict(
            "agent can only report running, succeeded, failed or canceled",
        ));
    }

    let current = current_status_in_tx(tx, task_id, node_id).await?;
    if !valid_agent_transition(current, status) {
        return Err(ApiError::Conflict("invalid task status transition"));
    }

    let stored_error_message = normalize_error_message(status, error_message)?;
    let row = sqlx::query(
        r#"
        UPDATE tasks
        SET status = $1, error_message = $2, updated_at = now()
        WHERE id = $3 AND node_id = $4 AND status = $5
        RETURNING id, node_id, kind, payload, status, error_message, created_at, updated_at
        "#,
    )
    .bind(status.as_str())
    .bind(stored_error_message)
    .bind(task_id.0)
    .bind(node_id.0)
    .bind(current.as_str())
    .fetch_optional(&mut **tx)
    .await?;
    let row = guarded_agent_status_update_result(row)?;

    task_from_row(row)
}

pub async fn cancel_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    task_id: TaskId,
) -> Result<TaskDto, ApiError> {
    let current = current_task_in_tx(tx, task_id).await?;
    validate_admin_cancel_status(current.status)?;

    let row = sqlx::query(
        r#"
        UPDATE tasks
        SET status = 'canceled', error_message = NULL, updated_at = now()
        WHERE id = $1 AND status = $2
        RETURNING id, node_id, kind, payload, status, error_message, created_at, updated_at
        "#,
    )
    .bind(task_id.0)
    .bind(current.status.as_str())
    .fetch_optional(&mut **tx)
    .await?;
    let row = guarded_admin_cancel_update_result(row)?;

    task_from_row(row)
}

fn normalize_error_message(
    status: TaskStatus,
    error_message: Option<&str>,
) -> Result<Option<String>, ApiError> {
    if !matches!(status, TaskStatus::Failed) {
        return Ok(None);
    }

    let Some(message) = error_message else {
        return Ok(None);
    };
    if message.is_empty() || message.len() > MAX_DIAGNOSTIC_MESSAGE_BYTES || message.contains('\0')
    {
        return Err(ApiError::Conflict(
            "task error message must be between 1 and 4096 bytes",
        ));
    }

    Ok(Some(normalize_diagnostic_message(message)?))
}

async fn current_status_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    task_id: TaskId,
    node_id: NodeId,
) -> Result<TaskStatus, ApiError> {
    let status_text =
        sqlx::query_scalar::<_, String>("SELECT status FROM tasks WHERE id = $1 AND node_id = $2")
            .bind(task_id.0)
            .bind(node_id.0)
            .fetch_optional(&mut **tx)
            .await?
            .ok_or(ApiError::NotFound("task not found for node"))?;

    TaskStatus::from_db(&status_text).ok_or(ApiError::Internal(
        "database contains an unknown task status",
    ))
}

async fn current_task_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    task_id: TaskId,
) -> Result<TaskDto, ApiError> {
    let row = sqlx::query(
        r#"
        SELECT id, node_id, kind, payload, status, error_message, created_at, updated_at
        FROM tasks
        WHERE id = $1
        "#,
    )
    .bind(task_id.0)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or(ApiError::NotFound("task not found"))?;

    task_from_row(row)
}

fn validate_admin_cancel_status(status: TaskStatus) -> Result<(), ApiError> {
    if matches!(status, TaskStatus::Pending | TaskStatus::Assigned) {
        Ok(())
    } else {
        Err(ApiError::Conflict(
            "only pending or assigned tasks can be canceled by an admin",
        ))
    }
}

fn guarded_admin_cancel_update_result<T>(row: Option<T>) -> Result<T, ApiError> {
    row.ok_or(ApiError::Conflict("task status changed while canceling"))
}

fn guarded_agent_status_update_result<T>(row: Option<T>) -> Result<T, ApiError> {
    row.ok_or(ApiError::Conflict(
        "task status changed while updating status",
    ))
}

fn valid_agent_transition(current: TaskStatus, next: TaskStatus) -> bool {
    matches!(
        (current, next),
        (TaskStatus::Assigned, TaskStatus::Running)
            | (TaskStatus::Assigned, TaskStatus::Failed)
            | (TaskStatus::Assigned, TaskStatus::Canceled)
            | (TaskStatus::Running, TaskStatus::Succeeded)
            | (TaskStatus::Running, TaskStatus::Failed)
            | (TaskStatus::Running, TaskStatus::Canceled)
    )
}

fn validate_agent_log_status(status: TaskStatus) -> Result<(), ApiError> {
    if matches!(status, TaskStatus::Assigned | TaskStatus::Running) {
        Ok(())
    } else {
        Err(ApiError::Conflict(
            "task logs can only be appended while the task is assigned or running",
        ))
    }
}

pub async fn append_log_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    task_id: TaskId,
    node_id: NodeId,
    message: &str,
) -> Result<(), ApiError> {
    let status = current_status_in_tx(tx, task_id, node_id).await?;
    validate_agent_log_status(status)?;
    insert_active_log_in_tx(tx, task_id, node_id, message).await
}

pub async fn append_failure_log_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    task_id: TaskId,
    node_id: NodeId,
    message: &str,
) -> Result<(), ApiError> {
    let status = current_status_in_tx(tx, task_id, node_id).await?;
    if !matches!(status, TaskStatus::Failed) {
        return Err(ApiError::Conflict(
            "failure log can only be appended after a failed status update",
        ));
    }
    insert_log_in_tx(tx, task_id, node_id, message).await
}

async fn insert_log_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    task_id: TaskId,
    node_id: NodeId,
    message: &str,
) -> Result<(), ApiError> {
    let redacted_message = normalize_diagnostic_message(message)?;

    sqlx::query(
        r#"
        INSERT INTO task_logs (task_id, node_id, message)
        VALUES ($1, $2, $3)
        "#,
    )
    .bind(task_id.0)
    .bind(node_id.0)
    .bind(redacted_message)
    .execute(&mut **tx)
    .await?;

    Ok(())
}

async fn insert_active_log_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    task_id: TaskId,
    node_id: NodeId,
    message: &str,
) -> Result<(), ApiError> {
    let redacted_message = normalize_diagnostic_message(message)?;

    let result = sqlx::query(
        r#"
        INSERT INTO task_logs (task_id, node_id, message)
        SELECT $1, $2, $3
        WHERE EXISTS (
            SELECT 1
            FROM tasks
            WHERE id = $1
                AND node_id = $2
                AND status IN ('assigned', 'running')
        )
        "#,
    )
    .bind(task_id.0)
    .bind(node_id.0)
    .bind(redacted_message)
    .execute(&mut **tx)
    .await?;

    guarded_task_log_insert_result(result.rows_affected())
}

fn guarded_task_log_insert_result(rows_affected: u64) -> Result<(), ApiError> {
    match rows_affected {
        1 => Ok(()),
        0 => Err(ApiError::Conflict("task status changed before log append")),
        _ => Err(ApiError::Internal("task log insert affected multiple rows")),
    }
}

fn validate_log_message(message: &str) -> Result<(), ApiError> {
    if message.is_empty() || message.len() > MAX_DIAGNOSTIC_MESSAGE_BYTES || message.contains('\0')
    {
        return Err(ApiError::Conflict(
            "task log message must be between 1 and 4096 bytes and must not contain NUL bytes",
        ));
    }

    Ok(())
}

fn normalize_diagnostic_message(message: &str) -> Result<String, ApiError> {
    validate_log_message(message)?;
    let normalized = escape_non_line_ascii_controls(&redaction::redact_text(message));
    if normalized.len() > MAX_DIAGNOSTIC_MESSAGE_BYTES {
        return Err(ApiError::Conflict(
            "diagnostic message must stay within 4096 bytes after normalization",
        ));
    }
    Ok(normalized)
}

fn escape_non_line_ascii_controls(input: &str) -> String {
    let mut output = String::with_capacity(input.len());
    for character in input.chars() {
        if character.is_ascii_control() && !matches!(character, '\n' | '\r' | '\t') {
            output.push_str(&format!("\\x{:02X}", character as u32));
        } else {
            output.push(character);
        }
    }
    output
}

pub async fn list_logs(pool: &PgPool, task_id: TaskId) -> Result<Vec<TaskLogDto>, ApiError> {
    let rows = sqlx::query(
        r#"
        SELECT id, task_id, node_id, message, created_at
        FROM task_logs
        WHERE task_id = $1
        ORDER BY created_at ASC, id ASC
        LIMIT 500
        "#,
    )
    .bind(task_id.0)
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(task_log_from_row).collect()
}

fn task_from_row(row: sqlx::postgres::PgRow) -> Result<TaskDto, ApiError> {
    let status_text: String = row.try_get("status")?;
    let status = TaskStatus::from_db(&status_text).ok_or(ApiError::Internal(
        "database contains an unknown task status",
    ))?;
    let payload: serde_json::Value = row.try_get("payload")?;
    let kind = serde_json::from_value(payload)?;

    Ok(TaskDto {
        id: TaskId(row.try_get("id")?),
        node_id: NodeId(row.try_get("node_id")?),
        kind,
        status,
        error_message: row.try_get("error_message")?,
        created_at: row.try_get::<DateTime<Utc>, _>("created_at")?,
        updated_at: row.try_get::<DateTime<Utc>, _>("updated_at")?,
    })
}

fn task_log_from_row(row: sqlx::postgres::PgRow) -> Result<TaskLogDto, ApiError> {
    Ok(TaskLogDto {
        id: row.try_get("id")?,
        task_id: TaskId(row.try_get("task_id")?),
        node_id: NodeId(row.try_get("node_id")?),
        message: row.try_get("message")?,
        created_at: row.try_get::<DateTime<Utc>, _>("created_at")?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use vps_shared::{CreateVmRequest, VmId};

    #[test]
    fn agent_can_only_move_forward_from_assigned() {
        assert!(valid_agent_transition(
            TaskStatus::Assigned,
            TaskStatus::Running
        ));
        assert!(valid_agent_transition(
            TaskStatus::Assigned,
            TaskStatus::Failed
        ));
        assert!(valid_agent_transition(
            TaskStatus::Assigned,
            TaskStatus::Canceled
        ));
        assert!(!valid_agent_transition(
            TaskStatus::Assigned,
            TaskStatus::Succeeded
        ));
        assert!(!valid_agent_transition(
            TaskStatus::Assigned,
            TaskStatus::Pending
        ));
    }

    #[test]
    fn running_can_only_end_in_terminal_states() {
        assert!(valid_agent_transition(
            TaskStatus::Running,
            TaskStatus::Succeeded
        ));
        assert!(valid_agent_transition(
            TaskStatus::Running,
            TaskStatus::Failed
        ));
        assert!(valid_agent_transition(
            TaskStatus::Running,
            TaskStatus::Canceled
        ));
        assert!(!valid_agent_transition(
            TaskStatus::Running,
            TaskStatus::Assigned
        ));
        assert!(!valid_agent_transition(
            TaskStatus::Running,
            TaskStatus::Pending
        ));
    }

    #[test]
    fn terminal_states_cannot_move_backward() {
        for current in [
            TaskStatus::Succeeded,
            TaskStatus::Failed,
            TaskStatus::Canceled,
        ] {
            assert!(!valid_agent_transition(current, TaskStatus::Running));
            assert!(!valid_agent_transition(current, TaskStatus::Assigned));
            assert!(!valid_agent_transition(current, TaskStatus::Pending));
        }
    }

    #[test]
    fn guarded_agent_status_update_must_affect_one_row() {
        assert!(guarded_agent_status_update_result(Some(())).is_ok());
        assert!(matches!(
            guarded_agent_status_update_result::<()>(None),
            Err(ApiError::Conflict(
                "task status changed while updating status"
            ))
        ));
    }

    #[test]
    fn admin_cancel_only_accepts_not_yet_running_tasks() {
        assert!(validate_admin_cancel_status(TaskStatus::Pending).is_ok());
        assert!(validate_admin_cancel_status(TaskStatus::Assigned).is_ok());

        for status in [
            TaskStatus::Running,
            TaskStatus::Succeeded,
            TaskStatus::Failed,
            TaskStatus::Canceled,
        ] {
            assert!(
                matches!(
                    validate_admin_cancel_status(status),
                    Err(ApiError::Conflict(_))
                ),
                "admin cancellation should reject {status:?}"
            );
        }
    }

    #[test]
    fn guarded_admin_cancel_update_must_affect_one_row() {
        assert!(guarded_admin_cancel_update_result(Some(())).is_ok());
        assert!(matches!(
            guarded_admin_cancel_update_result::<()>(None),
            Err(ApiError::Conflict("task status changed while canceling"))
        ));
    }

    #[test]
    fn agent_log_endpoint_only_accepts_active_task_statuses() {
        assert!(validate_agent_log_status(TaskStatus::Assigned).is_ok());
        assert!(validate_agent_log_status(TaskStatus::Running).is_ok());

        for status in [
            TaskStatus::Pending,
            TaskStatus::Succeeded,
            TaskStatus::Failed,
            TaskStatus::Canceled,
        ] {
            assert!(
                matches!(
                    validate_agent_log_status(status),
                    Err(ApiError::Conflict(_))
                ),
                "agent log endpoint should reject {status:?}"
            );
        }
    }

    #[test]
    fn guarded_task_log_insert_must_affect_one_row() {
        assert!(guarded_task_log_insert_result(1).is_ok());
        assert!(matches!(
            guarded_task_log_insert_result(0),
            Err(ApiError::Conflict("task status changed before log append"))
        ));
        assert!(matches!(
            guarded_task_log_insert_result(2),
            Err(ApiError::Internal("task log insert affected multiple rows"))
        ));
    }

    #[test]
    fn audit_detail_names_create_vm_and_target_vm() {
        let node_id = NodeId::new();
        let vm_id = VmId::new();
        let detail = audit_detail(&TaskKind::CreateVm(CreateVmRequest {
            node_id,
            vm_id: Some(vm_id),
            ip_pool_id: None,
            plan_id: None,
            assigned_ip: None,
            assigned_ip_prefix: None,
            assigned_gateway_ip: None,
            name: "demo".into(),
            image: "debian-12.qcow2".into(),
            ssh_public_key: None,
            cpu_cores: 1,
            memory_mb: 512,
            disk_gb: 10,
        }));

        assert_eq!(detail["task_kind"], "create_vm");
        assert_eq!(detail["vm_id"], vm_id.0.to_string());
    }

    #[test]
    fn create_vm_admission_requires_online_heartbeating_node() {
        let kind = create_vm_kind();
        let ready = ready_node_admission();

        validate_node_task_admission(&kind, ready).expect("ready node should pass");

        let mock_executor = NodeTaskAdmission {
            libvirt_status: "not_checked",
            ..ready
        };
        validate_node_task_admission(&kind, mock_executor)
            .expect("mock executor nodes report not_checked and should still support MVP tasks");

        let offline = NodeTaskAdmission {
            status: "offline",
            ..ready
        };
        assert!(matches!(
            validate_node_task_admission(&kind, offline),
            Err(ApiError::Conflict("node is not online"))
        ));

        let no_heartbeat = NodeTaskAdmission {
            last_seen_at: None,
            ..ready
        };
        assert!(matches!(
            validate_node_task_admission(&kind, no_heartbeat),
            Err(ApiError::Conflict("node has not reported heartbeat"))
        ));

        let stale_heartbeat = NodeTaskAdmission {
            last_seen_at: Some(Utc::now() - chrono::Duration::seconds(7201)),
            ..ready
        };
        assert!(matches!(
            validate_node_task_admission(&kind, stale_heartbeat),
            Err(ApiError::Conflict("node heartbeat is stale"))
        ));

        let unavailable_libvirt = NodeTaskAdmission {
            libvirt_status: "unavailable",
            ..ready
        };
        assert!(matches!(
            validate_node_task_admission(&kind, unavailable_libvirt),
            Err(ApiError::Conflict("node libvirt is unavailable"))
        ));
    }

    #[test]
    fn non_create_tasks_keep_existing_registered_scheduling_admission() {
        let vm_id = VmId::new();
        let kind = TaskKind::StartVm { vm_id };
        let unavailable = NodeTaskAdmission {
            status: "offline",
            libvirt_status: "unavailable",
            last_seen_at: None,
            ..ready_node_admission()
        };

        validate_node_task_admission(&kind, unavailable)
            .expect("non-create lifecycle work may remain queued for the agent");

        let disabled = NodeTaskAdmission {
            scheduling_enabled: false,
            ..ready_node_admission()
        };
        assert!(matches!(
            validate_node_task_admission(&kind, disabled),
            Err(ApiError::Conflict("node scheduling is disabled"))
        ));
    }

    #[test]
    fn task_admission_and_claim_lock_node_scheduling_row() {
        let source = include_str!("mod.rs");
        let production_source = source
            .split("#[cfg(test)]")
            .next()
            .expect("production source before tests");

        assert!(
            production_source.contains("const NODE_TASK_ADMISSION_FOR_UPDATE_SQL"),
            "task insertion admission must use a named node-locking SQL boundary"
        );
        assert!(
            production_source.contains("const CLAIM_NEXT_FOR_NODE_SQL"),
            "task claim admission must use a named node-locking SQL boundary"
        );
        assert!(
            production_source.contains("FOR UPDATE OF n"),
            "node scheduling admission and claim must lock the node row"
        );
    }

    #[test]
    fn audit_detail_names_vm_action_targets() {
        let vm_id = VmId::new();
        for (kind, expected_name) in [
            (TaskKind::StartVm { vm_id }, "start_vm"),
            (TaskKind::StopVm { vm_id }, "stop_vm"),
            (TaskKind::RebootVm { vm_id }, "reboot_vm"),
            (TaskKind::DeleteVm { vm_id }, "delete_vm"),
        ] {
            let detail = audit_detail(&kind);
            assert_eq!(detail["task_kind"], expected_name);
            assert_eq!(detail["vm_id"], vm_id.0.to_string());
        }
    }

    #[test]
    fn task_log_message_rejects_nul_bytes_before_persistence() {
        let error = validate_log_message("before\0after").expect_err("NUL bytes should fail");

        assert!(
            matches!(error, ApiError::Conflict(_)),
            "unexpected error: {error:?}"
        );
    }

    #[test]
    fn diagnostic_messages_escape_non_line_control_bytes_before_persistence() {
        let normalized = normalize_diagnostic_message("line 1\nline 2\t\x1b[31m password=hunter2")
            .expect("diagnostic should be accepted");

        assert!(normalized.contains("line 1\nline 2\t"));
        assert!(normalized.contains("\\x1B[31m"));
        assert!(!normalized.contains('\x1b'));
        assert!(!normalized.contains("hunter2"));
        assert!(normalized.contains("password=[REDACTED]"));
    }

    #[test]
    fn diagnostic_messages_reject_when_escaping_exceeds_storage_limit() {
        let message = "\x07".repeat(1025);
        let error = normalize_diagnostic_message(&message)
            .expect_err("escaped diagnostic should stay within storage limit");

        assert!(
            matches!(error, ApiError::Conflict(_)),
            "unexpected error: {error:?}"
        );
    }

    fn create_vm_kind() -> TaskKind {
        TaskKind::CreateVm(CreateVmRequest {
            node_id: NodeId::new(),
            vm_id: Some(VmId::new()),
            ip_pool_id: None,
            plan_id: None,
            assigned_ip: None,
            assigned_ip_prefix: None,
            assigned_gateway_ip: None,
            name: "demo".into(),
            image: "debian-12.qcow2".into(),
            ssh_public_key: None,
            cpu_cores: 1,
            memory_mb: 512,
            disk_gb: 10,
        })
    }

    fn ready_node_admission() -> NodeTaskAdmission<'static> {
        NodeTaskAdmission {
            credential_hash: Some("stored-hash"),
            scheduling_enabled: true,
            status: "online",
            agent_version: Some("0.1.0"),
            last_seen_at: Some(Utc::now()),
            libvirt_status: "available",
        }
    }
}
