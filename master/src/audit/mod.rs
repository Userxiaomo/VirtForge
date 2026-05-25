use chrono::{DateTime, Utc};
use serde_json::json;
use sqlx::{PgPool, Postgres, Row, Transaction};
use vps_shared::{AuditLogDto, NodeId, TaskId};

use crate::{http::ApiError, redaction};

#[derive(Clone, Debug)]
pub struct AuditEvent {
    request_id: Option<String>,
    actor_id: String,
    actor_role: String,
    node_id: Option<NodeId>,
    task_id: Option<TaskId>,
    action: String,
    result: String,
    detail: serde_json::Value,
}

impl AuditEvent {
    pub fn admin(action: impl Into<String>) -> Self {
        Self::new("admin", "admin", action)
    }

    pub fn agent(action: impl Into<String>) -> Self {
        Self::new("agent", "agent", action)
    }

    pub fn with_node(mut self, node_id: NodeId) -> Self {
        self.node_id = Some(node_id);
        self
    }

    pub fn with_request_id(mut self, request_id: impl Into<String>) -> Self {
        self.request_id = Some(request_id.into());
        self
    }

    pub fn with_task(mut self, task_id: TaskId) -> Self {
        self.task_id = Some(task_id);
        self
    }

    pub fn with_detail(mut self, detail: serde_json::Value) -> Self {
        self.detail = detail;
        self
    }

    pub fn succeeded(mut self) -> Self {
        self.result = "succeeded".into();
        self
    }

    fn new(
        actor_id: impl Into<String>,
        actor_role: impl Into<String>,
        action: impl Into<String>,
    ) -> Self {
        Self {
            request_id: None,
            actor_id: actor_id.into(),
            actor_role: actor_role.into(),
            node_id: None,
            task_id: None,
            action: action.into(),
            result: "started".into(),
            detail: json!({}),
        }
    }
}

pub async fn write_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    event: AuditEvent,
) -> Result<(), ApiError> {
    let detail = redaction::redact_json_value(event.detail);

    sqlx::query(
        r#"
        INSERT INTO audit_logs (
            request_id,
            actor_id,
            actor_role,
            node_id,
            task_id,
            action,
            result,
            detail
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        "#,
    )
    .bind(event.request_id)
    .bind(event.actor_id)
    .bind(event.actor_role)
    .bind(event.node_id.map(|id| id.0))
    .bind(event.task_id.map(|id| id.0))
    .bind(event.action)
    .bind(event.result)
    .bind(detail)
    .execute(&mut **tx)
    .await?;

    Ok(())
}

pub async fn list_recent(pool: &PgPool) -> Result<Vec<AuditLogDto>, ApiError> {
    let rows = sqlx::query(
        r#"
        SELECT id, request_id, actor_id, actor_role, node_id, task_id, action, result, detail, created_at
        FROM audit_logs
        ORDER BY created_at DESC, id DESC
        LIMIT 200
        "#,
    )
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(audit_log_from_row).collect()
}

fn audit_log_from_row(row: sqlx::postgres::PgRow) -> Result<AuditLogDto, ApiError> {
    Ok(AuditLogDto {
        id: row.try_get("id")?,
        request_id: row.try_get("request_id")?,
        actor_id: row.try_get("actor_id")?,
        actor_role: row.try_get("actor_role")?,
        node_id: row.try_get::<Option<uuid::Uuid>, _>("node_id")?.map(NodeId),
        task_id: row.try_get::<Option<uuid::Uuid>, _>("task_id")?.map(TaskId),
        action: row.try_get("action")?,
        result: row.try_get("result")?,
        detail: row.try_get("detail")?,
        created_at: row.try_get::<DateTime<Utc>, _>("created_at")?,
    })
}
