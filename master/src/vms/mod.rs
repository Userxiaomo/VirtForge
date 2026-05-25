use chrono::{DateTime, Utc};
use sqlx::{PgPool, Postgres, Row, Transaction};
use vps_shared::{
    CreateVmRequest, NodeId, TaskDto, TaskId, TaskKind, TaskStatus, VmDto, VmId, VmStatus,
};

use crate::{http::ApiError, ipam};

const CURRENT_VM_LIFECYCLE_FOR_UPDATE_SQL: &str = r#"
        SELECT v.status, t.status AS last_task_status
        FROM vms v
        LEFT JOIN tasks t ON t.id = v.last_task_id
        WHERE v.id = $1 AND v.node_id = $2
        FOR UPDATE OF v
        "#;

const REINSTALL_SPEC_FOR_UPDATE_SQL: &str = r#"
        SELECT v.status, t.status AS last_task_status,
            v.name, v.image, v.ssh_public_key, v.disk_gb
        FROM vms v
        LEFT JOIN tasks t ON t.id = v.last_task_id
        WHERE v.id = $1 AND v.node_id = $2
        FOR UPDATE OF v
        "#;

pub async fn create_from_request_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    request: &CreateVmRequest,
    task_id: TaskId,
) -> Result<VmDto, ApiError> {
    let vm_id = request
        .vm_id
        .ok_or(ApiError::Internal("create_vm task is missing vm_id"))?;

    let row = sqlx::query(
        r#"
        INSERT INTO vms (
            id, node_id, ip_pool_id, plan_id, assigned_ip, name, image, ssh_public_key, cpu_cores, memory_mb, disk_gb,
            status, last_task_id
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
        RETURNING id, node_id, ip_pool_id, plan_id, assigned_ip, name, image, ssh_public_key, cpu_cores, memory_mb, disk_gb,
            status, last_task_id, 'pending'::TEXT AS last_task_status, created_at, updated_at, deleted_at
        "#,
    )
    .bind(vm_id.0)
    .bind(request.node_id.0)
    .bind(request.ip_pool_id.map(|id| id.0))
    .bind(request.plan_id.map(|id| id.0))
    .bind(&request.assigned_ip)
    .bind(&request.name)
    .bind(&request.image)
    .bind(&request.ssh_public_key)
    .bind(i16::try_from(request.cpu_cores).map_err(|_| ApiError::Internal("cpu out of range"))?)
    .bind(
        i32::try_from(request.memory_mb).map_err(|_| ApiError::Internal("memory out of range"))?,
    )
    .bind(i32::try_from(request.disk_gb).map_err(|_| ApiError::Internal("disk out of range"))?)
    .bind(VmStatus::Provisioning.as_str())
    .bind(task_id.0)
    .fetch_one(&mut **tx)
    .await?;

    vm_from_row(row)
}

pub async fn list(pool: &PgPool) -> Result<Vec<VmDto>, ApiError> {
    let rows = sqlx::query(
        r#"
        SELECT v.id, v.node_id, v.ip_pool_id, v.plan_id, v.assigned_ip, v.name, v.image, v.ssh_public_key,
            v.cpu_cores, v.memory_mb, v.disk_gb, v.status, v.last_task_id, t.status AS last_task_status,
            v.created_at, v.updated_at, v.deleted_at
        FROM vms v
        LEFT JOIN tasks t ON t.id = v.last_task_id
        WHERE v.status <> 'deleted'
        ORDER BY v.created_at DESC
        LIMIT 100
        "#,
    )
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(vm_from_row).collect()
}

pub async fn ensure_action_allowed_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    node_id: NodeId,
    vm_id: VmId,
    action: VmAction,
) -> Result<(), ApiError> {
    let lifecycle = current_vm_lifecycle_for_update_in_tx(tx, node_id, vm_id).await?;
    validate_action_allowed(action, lifecycle)
}

pub async fn ensure_retry_allowed_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    node_id: NodeId,
    kind: &TaskKind,
) -> Result<(), ApiError> {
    let vm_id = retry_vm_id(kind).ok_or(ApiError::Internal("retry task is missing vm_id"))?;
    let lifecycle = current_vm_lifecycle_for_update_in_tx(tx, node_id, vm_id).await?;
    validate_retry_allowed(kind, lifecycle)
}

#[derive(Clone, Copy)]
struct VmLifecycle {
    status: VmStatus,
    last_task_status: Option<TaskStatus>,
}

fn validate_action_allowed(action: VmAction, lifecycle: VmLifecycle) -> Result<(), ApiError> {
    match lifecycle.status {
        VmStatus::Deleted => Err(ApiError::Conflict("vm is already deleted")),
        VmStatus::Deleting => Err(ApiError::Conflict("vm is being deleted")),
        VmStatus::Provisioning => Err(ApiError::Conflict("vm is provisioning")),
        _ if has_active_task(lifecycle.last_task_status) => {
            Err(ApiError::Conflict("vm already has an active task"))
        }
        _ if action_allowed_for_status(action, lifecycle.status) => Ok(()),
        _ => Err(ApiError::Conflict(
            "vm action is not allowed for the current status",
        )),
    }
}

fn validate_retry_allowed(kind: &TaskKind, lifecycle: VmLifecycle) -> Result<(), ApiError> {
    if has_active_task(lifecycle.last_task_status) {
        return Err(ApiError::Conflict("vm already has an active task"));
    }

    if retry_allowed_for_status(kind, lifecycle.status) {
        Ok(())
    } else {
        Err(ApiError::Conflict(
            "task retry is not allowed for the current vm status",
        ))
    }
}

fn has_active_task(status: Option<TaskStatus>) -> bool {
    matches!(
        status,
        Some(TaskStatus::Pending | TaskStatus::Assigned | TaskStatus::Running)
    )
}

async fn current_vm_lifecycle_for_update_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    node_id: NodeId,
    vm_id: VmId,
) -> Result<VmLifecycle, ApiError> {
    let row = sqlx::query(CURRENT_VM_LIFECYCLE_FOR_UPDATE_SQL)
        .bind(vm_id.0)
        .bind(node_id.0)
        .fetch_optional(&mut **tx)
        .await?
        .ok_or(ApiError::NotFound("vm not found for node"))?;

    vm_lifecycle_from_row(&row)
}

fn vm_lifecycle_from_row(row: &sqlx::postgres::PgRow) -> Result<VmLifecycle, ApiError> {
    let status_text: String = row.try_get("status")?;
    let status = VmStatus::from_db(&status_text)
        .ok_or(ApiError::Internal("database contains an unknown vm status"))?;
    let last_task_status_text: Option<String> = row.try_get("last_task_status")?;
    let last_task_status = task_status_from_optional_db(last_task_status_text.as_deref())?;
    Ok(VmLifecycle {
        status,
        last_task_status,
    })
}

#[derive(Clone, Debug)]
pub struct ReinstallSpec {
    pub name: String,
    pub image: String,
    pub ssh_public_key: Option<String>,
    pub disk_gb: u32,
}

pub async fn reinstall_spec_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    node_id: NodeId,
    vm_id: VmId,
    requested_image: Option<String>,
) -> Result<ReinstallSpec, ApiError> {
    let row = sqlx::query(REINSTALL_SPEC_FOR_UPDATE_SQL)
        .bind(vm_id.0)
        .bind(node_id.0)
        .fetch_optional(&mut **tx)
        .await?
        .ok_or(ApiError::NotFound("vm not found for node"))?;

    let lifecycle = vm_lifecycle_from_row(&row)?;
    validate_action_allowed(VmAction::Reinstall, lifecycle)?;

    let disk_gb: i32 = row.try_get("disk_gb")?;
    Ok(ReinstallSpec {
        name: row.try_get("name")?,
        image: requested_image.unwrap_or(row.try_get("image")?),
        ssh_public_key: row.try_get("ssh_public_key")?,
        disk_gb: u32::try_from(disk_gb).map_err(|_| ApiError::Internal("disk out of range"))?,
    })
}

pub async fn apply_task_status_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    task: &TaskDto,
) -> Result<(), ApiError> {
    let Some((vm_id, next_status, deleted, release_ip, clear_assigned_ip)) = next_vm_status(task)
    else {
        return Ok(());
    };
    let next_image = match (task.status, &task.kind) {
        (TaskStatus::Succeeded, TaskKind::ReinstallVm { image, .. }) => Some(image.as_str()),
        _ => None,
    };

    let update_result = sqlx::query(
        r#"
        UPDATE vms
        SET status = $1,
            last_task_id = $2,
            updated_at = now(),
            deleted_at = CASE WHEN $3 THEN now() ELSE deleted_at END,
            assigned_ip = CASE WHEN $4 THEN NULL ELSE assigned_ip END,
            image = COALESCE($7, image)
        WHERE id = $5 AND node_id = $6
        "#,
    )
    .bind(next_status.as_str())
    .bind(task.id.0)
    .bind(deleted)
    .bind(clear_assigned_ip)
    .bind(vm_id.0)
    .bind(task.node_id.0)
    .bind(next_image)
    .execute(&mut **tx)
    .await?;
    applied_task_status_update_result(update_result.rows_affected())?;

    if release_ip {
        ipam::release_for_vm_in_tx(tx, vm_id).await?;
    }

    Ok(())
}

fn applied_task_status_update_result(rows_affected: u64) -> Result<(), ApiError> {
    match rows_affected {
        1 => Ok(()),
        0 => Err(ApiError::NotFound("vm not found for task status update")),
        _ => Err(ApiError::Internal(
            "task status update affected multiple vm rows",
        )),
    }
}

pub async fn apply_retry_created_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    task: &TaskDto,
) -> Result<(), ApiError> {
    let Some((vm_id, next_status, assigned_ip)) = retry_vm_update(task) else {
        return Ok(());
    };

    let update_result = sqlx::query(
        r#"
        UPDATE vms
        SET status = COALESCE($1, status),
            last_task_id = $2,
            assigned_ip = COALESCE($3, assigned_ip),
            updated_at = now()
        WHERE id = $4 AND node_id = $5 AND status <> 'deleted'
        "#,
    )
    .bind(next_status.map(|status| status.as_str()))
    .bind(task.id.0)
    .bind(assigned_ip)
    .bind(vm_id.0)
    .bind(task.node_id.0)
    .execute(&mut **tx)
    .await?;
    retry_created_update_result(update_result.rows_affected())?;

    Ok(())
}

pub async fn record_action_task_created_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    task: &TaskDto,
) -> Result<(), ApiError> {
    let Some(vm_id) = retry_vm_id(&task.kind) else {
        return Ok(());
    };

    let result = sqlx::query(
        r#"
        UPDATE vms
        SET last_task_id = $1,
            updated_at = now()
        WHERE id = $2 AND node_id = $3 AND status <> 'deleted'
        "#,
    )
    .bind(task.id.0)
    .bind(vm_id.0)
    .bind(task.node_id.0)
    .execute(&mut **tx)
    .await?;
    action_task_created_update_result(result.rows_affected())?;

    Ok(())
}

fn action_task_created_update_result(rows_affected: u64) -> Result<(), ApiError> {
    match rows_affected {
        1 => Ok(()),
        0 => Err(ApiError::NotFound("vm not found for action task")),
        _ => Err(ApiError::Internal("action task affected multiple vm rows")),
    }
}

fn retry_created_update_result(rows_affected: u64) -> Result<(), ApiError> {
    match rows_affected {
        1 => Ok(()),
        0 => Err(ApiError::NotFound("vm not found for retry task")),
        _ => Err(ApiError::Internal("retry task affected multiple vm rows")),
    }
}

#[derive(Clone, Copy, Debug)]
pub enum VmAction {
    Start,
    Stop,
    Reboot,
    Reinstall,
    Delete,
}

fn action_allowed_for_status(action: VmAction, status: VmStatus) -> bool {
    match status {
        VmStatus::Deleted | VmStatus::Deleting => false,
        VmStatus::Provisioning => false,
        VmStatus::Running => matches!(
            action,
            VmAction::Stop | VmAction::Reboot | VmAction::Reinstall | VmAction::Delete
        ),
        VmStatus::Stopped | VmStatus::Error => {
            matches!(
                action,
                VmAction::Start | VmAction::Reinstall | VmAction::Delete
            )
        }
    }
}

fn retry_allowed_for_status(kind: &TaskKind, status: VmStatus) -> bool {
    match kind {
        TaskKind::CreateVm(request) => request.vm_id.is_some() && status == VmStatus::Error,
        TaskKind::StartVm { .. } => action_allowed_for_status(VmAction::Start, status),
        TaskKind::StopVm { .. } => action_allowed_for_status(VmAction::Stop, status),
        TaskKind::RebootVm { .. } => action_allowed_for_status(VmAction::Reboot, status),
        TaskKind::ReinstallVm { .. } => action_allowed_for_status(VmAction::Reinstall, status),
        TaskKind::DeleteVm { .. } => action_allowed_for_status(VmAction::Delete, status),
    }
}

fn retry_vm_id(kind: &TaskKind) -> Option<VmId> {
    match kind {
        TaskKind::CreateVm(request) => request.vm_id,
        TaskKind::StartVm { vm_id }
        | TaskKind::StopVm { vm_id }
        | TaskKind::RebootVm { vm_id }
        | TaskKind::ReinstallVm { vm_id, .. }
        | TaskKind::DeleteVm { vm_id } => Some(*vm_id),
    }
}

fn next_vm_status(task: &TaskDto) -> Option<(VmId, VmStatus, bool, bool, bool)> {
    match (task.status, &task.kind) {
        (TaskStatus::Running, TaskKind::CreateVm(request)) => {
            Some((request.vm_id?, VmStatus::Provisioning, false, false, false))
        }
        (TaskStatus::Succeeded, TaskKind::CreateVm(request)) => {
            Some((request.vm_id?, VmStatus::Running, false, false, false))
        }
        (TaskStatus::Failed | TaskStatus::Canceled, TaskKind::CreateVm(request)) => {
            Some((request.vm_id?, VmStatus::Error, false, true, true))
        }
        (TaskStatus::Succeeded, TaskKind::StartVm { vm_id }) => {
            Some((*vm_id, VmStatus::Running, false, false, false))
        }
        (TaskStatus::Succeeded, TaskKind::StopVm { vm_id }) => {
            Some((*vm_id, VmStatus::Stopped, false, false, false))
        }
        (TaskStatus::Succeeded, TaskKind::RebootVm { vm_id }) => {
            Some((*vm_id, VmStatus::Running, false, false, false))
        }
        (
            TaskStatus::Pending | TaskStatus::Assigned | TaskStatus::Running,
            TaskKind::ReinstallVm { vm_id, .. },
        ) => Some((*vm_id, VmStatus::Provisioning, false, false, false)),
        (TaskStatus::Succeeded, TaskKind::ReinstallVm { vm_id, .. }) => {
            Some((*vm_id, VmStatus::Running, false, false, false))
        }
        (TaskStatus::Failed | TaskStatus::Canceled, TaskKind::ReinstallVm { vm_id, .. }) => {
            Some((*vm_id, VmStatus::Error, false, false, false))
        }
        (
            TaskStatus::Pending | TaskStatus::Assigned | TaskStatus::Running,
            TaskKind::DeleteVm { vm_id },
        ) => Some((*vm_id, VmStatus::Deleting, false, false, false)),
        (TaskStatus::Succeeded, TaskKind::DeleteVm { vm_id }) => {
            Some((*vm_id, VmStatus::Deleted, true, true, true))
        }
        (TaskStatus::Failed | TaskStatus::Canceled, TaskKind::DeleteVm { vm_id }) => {
            Some((*vm_id, VmStatus::Error, false, false, false))
        }
        _ => None,
    }
}

fn retry_vm_update(task: &TaskDto) -> Option<(VmId, Option<VmStatus>, Option<&str>)> {
    match &task.kind {
        TaskKind::CreateVm(request) => Some((
            request.vm_id?,
            Some(VmStatus::Provisioning),
            request.assigned_ip.as_deref(),
        )),
        TaskKind::ReinstallVm { vm_id, .. } => Some((*vm_id, Some(VmStatus::Provisioning), None)),
        TaskKind::DeleteVm { vm_id } => Some((*vm_id, Some(VmStatus::Deleting), None)),
        TaskKind::StartVm { vm_id } | TaskKind::StopVm { vm_id } | TaskKind::RebootVm { vm_id } => {
            Some((*vm_id, None, None))
        }
    }
}

fn vm_from_row(row: sqlx::postgres::PgRow) -> Result<VmDto, ApiError> {
    let status_text: String = row.try_get("status")?;
    let status = VmStatus::from_db(&status_text)
        .ok_or(ApiError::Internal("database contains an unknown vm status"))?;
    let cpu_cores: i16 = row.try_get("cpu_cores")?;
    let memory_mb: i32 = row.try_get("memory_mb")?;
    let disk_gb: i32 = row.try_get("disk_gb")?;
    let last_task_id: Option<uuid::Uuid> = row.try_get("last_task_id")?;
    let last_task_status_text: Option<String> = row.try_get("last_task_status")?;
    let last_task_status = task_status_from_optional_db(last_task_status_text.as_deref())?;

    Ok(VmDto {
        id: VmId(row.try_get("id")?),
        node_id: NodeId(row.try_get("node_id")?),
        ip_pool_id: row
            .try_get::<Option<uuid::Uuid>, _>("ip_pool_id")?
            .map(vps_shared::IpPoolId),
        plan_id: row
            .try_get::<Option<uuid::Uuid>, _>("plan_id")?
            .map(vps_shared::PlanId),
        assigned_ip: row.try_get("assigned_ip")?,
        name: row.try_get("name")?,
        image: row.try_get("image")?,
        ssh_public_key: row.try_get("ssh_public_key")?,
        cpu_cores: u16::try_from(cpu_cores).map_err(|_| ApiError::Internal("cpu out of range"))?,
        memory_mb: u32::try_from(memory_mb)
            .map_err(|_| ApiError::Internal("memory out of range"))?,
        disk_gb: u32::try_from(disk_gb).map_err(|_| ApiError::Internal("disk out of range"))?,
        status,
        last_task_id: last_task_id.map(TaskId),
        last_task_status,
        created_at: row.try_get::<DateTime<Utc>, _>("created_at")?,
        updated_at: row.try_get::<DateTime<Utc>, _>("updated_at")?,
        deleted_at: row.try_get::<Option<DateTime<Utc>>, _>("deleted_at")?,
    })
}

fn task_status_from_optional_db(value: Option<&str>) -> Result<Option<TaskStatus>, ApiError> {
    value
        .map(|status| {
            TaskStatus::from_db(status).ok_or(ApiError::Internal(
                "database contains an unknown task status",
            ))
        })
        .transpose()
}

#[cfg(test)]
mod tests {
    use chrono::Utc;
    use vps_shared::{NodeId, TaskId};

    use super::*;

    fn reinstall_task(status: TaskStatus, vm_id: VmId) -> TaskDto {
        TaskDto {
            id: TaskId::new(),
            node_id: NodeId::new(),
            kind: TaskKind::ReinstallVm {
                vm_id,
                name: "demo".into(),
                image: "debian-12.qcow2".into(),
                ssh_public_key: None,
                disk_gb: 10,
            },
            status,
            error_message: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        }
    }

    #[test]
    fn reinstall_status_updates_vm_lifecycle() {
        let vm_id = VmId::new();

        let running = next_vm_status(&reinstall_task(TaskStatus::Running, vm_id)).unwrap();
        assert_eq!(running.0, vm_id);
        assert_eq!(running.1, VmStatus::Provisioning);

        let succeeded = next_vm_status(&reinstall_task(TaskStatus::Succeeded, vm_id)).unwrap();
        assert_eq!(succeeded.0, vm_id);
        assert_eq!(succeeded.1, VmStatus::Running);

        let failed = next_vm_status(&reinstall_task(TaskStatus::Failed, vm_id)).unwrap();
        assert_eq!(failed.0, vm_id);
        assert_eq!(failed.1, VmStatus::Error);
    }

    #[test]
    fn queued_reinstall_and_delete_enter_transient_vm_statuses() {
        let vm_id = VmId::new();

        let reinstall = next_vm_status(&reinstall_task(TaskStatus::Pending, vm_id)).unwrap();
        assert_eq!(reinstall.0, vm_id);
        assert_eq!(reinstall.1, VmStatus::Provisioning);

        let delete = next_vm_status(&TaskDto {
            id: TaskId::new(),
            node_id: NodeId::new(),
            kind: TaskKind::DeleteVm { vm_id },
            status: TaskStatus::Pending,
            error_message: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        })
        .unwrap();
        assert_eq!(delete.0, vm_id);
        assert_eq!(delete.1, VmStatus::Deleting);
    }

    #[test]
    fn applied_task_status_must_update_exactly_one_vm_row() {
        assert!(applied_task_status_update_result(1).is_ok());
        assert!(matches!(
            applied_task_status_update_result(0),
            Err(ApiError::NotFound("vm not found for task status update"))
        ));
        assert!(matches!(
            applied_task_status_update_result(2),
            Err(ApiError::Internal(
                "task status update affected multiple vm rows"
            ))
        ));
    }

    #[test]
    fn retry_created_must_update_exactly_one_vm_row() {
        assert!(retry_created_update_result(1).is_ok());
        assert!(matches!(
            retry_created_update_result(0),
            Err(ApiError::NotFound("vm not found for retry task"))
        ));
        assert!(matches!(
            retry_created_update_result(2),
            Err(ApiError::Internal("retry task affected multiple vm rows"))
        ));
    }

    #[test]
    fn action_task_created_must_update_exactly_one_vm_row() {
        assert!(action_task_created_update_result(1).is_ok());
        assert!(matches!(
            action_task_created_update_result(0),
            Err(ApiError::NotFound("vm not found for action task"))
        ));
        assert!(matches!(
            action_task_created_update_result(2),
            Err(ApiError::Internal("action task affected multiple vm rows"))
        ));
    }

    #[test]
    fn lifecycle_admission_queries_lock_the_vm_inventory_row() {
        for query in [
            CURRENT_VM_LIFECYCLE_FOR_UPDATE_SQL,
            REINSTALL_SPEC_FOR_UPDATE_SQL,
        ] {
            assert!(
                query.contains("FOR UPDATE OF v"),
                "VM task admission must lock the VM inventory row: {query}"
            );
            assert!(
                query.contains("LEFT JOIN tasks t ON t.id = v.last_task_id"),
                "VM task admission must read authoritative last task status: {query}"
            );
        }
    }

    #[test]
    fn vm_actions_follow_the_server_side_lifecycle_guard() {
        for action in [
            VmAction::Start,
            VmAction::Stop,
            VmAction::Reboot,
            VmAction::Reinstall,
            VmAction::Delete,
        ] {
            assert!(
                !action_allowed_for_status(action, VmStatus::Provisioning),
                "provisioning must reject {action:?}"
            );
        }

        assert!(action_allowed_for_status(VmAction::Stop, VmStatus::Running));
        assert!(action_allowed_for_status(
            VmAction::Reboot,
            VmStatus::Running
        ));
        assert!(action_allowed_for_status(
            VmAction::Reinstall,
            VmStatus::Running
        ));
        assert!(action_allowed_for_status(
            VmAction::Delete,
            VmStatus::Running
        ));
        assert!(!action_allowed_for_status(
            VmAction::Start,
            VmStatus::Running
        ));

        assert!(action_allowed_for_status(
            VmAction::Start,
            VmStatus::Stopped
        ));
        assert!(action_allowed_for_status(
            VmAction::Reinstall,
            VmStatus::Stopped
        ));
        assert!(action_allowed_for_status(
            VmAction::Delete,
            VmStatus::Stopped
        ));
        assert!(!action_allowed_for_status(
            VmAction::Stop,
            VmStatus::Stopped
        ));
        assert!(!action_allowed_for_status(
            VmAction::Reboot,
            VmStatus::Stopped
        ));

        assert!(action_allowed_for_status(VmAction::Start, VmStatus::Error));
        assert!(action_allowed_for_status(
            VmAction::Reinstall,
            VmStatus::Error
        ));
        assert!(action_allowed_for_status(VmAction::Delete, VmStatus::Error));
        assert!(!action_allowed_for_status(VmAction::Stop, VmStatus::Error));
        assert!(!action_allowed_for_status(
            VmAction::Reboot,
            VmStatus::Error
        ));

        assert!(!action_allowed_for_status(
            VmAction::Start,
            VmStatus::Deleted
        ));
        assert!(!action_allowed_for_status(
            VmAction::Stop,
            VmStatus::Deleted
        ));
        assert!(!action_allowed_for_status(
            VmAction::Reboot,
            VmStatus::Deleted
        ));
        assert!(!action_allowed_for_status(
            VmAction::Reinstall,
            VmStatus::Deleted
        ));
        assert!(!action_allowed_for_status(
            VmAction::Delete,
            VmStatus::Deleted
        ));

        assert!(!action_allowed_for_status(
            VmAction::Start,
            VmStatus::Deleting
        ));
        assert!(!action_allowed_for_status(
            VmAction::Stop,
            VmStatus::Deleting
        ));
        assert!(!action_allowed_for_status(
            VmAction::Reboot,
            VmStatus::Deleting
        ));
        assert!(!action_allowed_for_status(
            VmAction::Reinstall,
            VmStatus::Deleting
        ));
        assert!(!action_allowed_for_status(
            VmAction::Delete,
            VmStatus::Deleting
        ));
    }

    #[test]
    fn active_last_task_blocks_follow_up_vm_actions() {
        let active = VmLifecycle {
            status: VmStatus::Running,
            last_task_status: Some(TaskStatus::Running),
        };

        assert!(matches!(
            validate_action_allowed(VmAction::Stop, active),
            Err(ApiError::Conflict("vm already has an active task"))
        ));

        let terminal = VmLifecycle {
            status: VmStatus::Running,
            last_task_status: Some(TaskStatus::Succeeded),
        };

        assert!(validate_action_allowed(VmAction::Stop, terminal).is_ok());
    }

    #[test]
    fn active_last_task_blocks_retry_admission() {
        let kind = TaskKind::StartVm { vm_id: VmId::new() };
        let active = VmLifecycle {
            status: VmStatus::Stopped,
            last_task_status: Some(TaskStatus::Assigned),
        };

        assert!(matches!(
            validate_retry_allowed(&kind, active),
            Err(ApiError::Conflict("vm already has an active task"))
        ));

        let terminal = VmLifecycle {
            status: VmStatus::Stopped,
            last_task_status: Some(TaskStatus::Failed),
        };

        assert!(validate_retry_allowed(&kind, terminal).is_ok());
    }

    #[test]
    fn task_retries_follow_the_current_vm_lifecycle_guard() {
        let node_id = NodeId::new();
        let vm_id = VmId::new();
        let create = TaskKind::CreateVm(CreateVmRequest {
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
        });

        assert!(retry_allowed_for_status(&create, VmStatus::Error));
        assert!(!retry_allowed_for_status(&create, VmStatus::Running));
        assert!(!retry_allowed_for_status(&create, VmStatus::Deleted));

        assert!(retry_allowed_for_status(
            &TaskKind::DeleteVm { vm_id },
            VmStatus::Running
        ));
        assert!(retry_allowed_for_status(
            &TaskKind::DeleteVm { vm_id },
            VmStatus::Error
        ));
        assert!(!retry_allowed_for_status(
            &TaskKind::DeleteVm { vm_id },
            VmStatus::Deleting
        ));

        assert!(retry_allowed_for_status(
            &TaskKind::ReinstallVm {
                vm_id,
                name: "demo".into(),
                image: "debian-12.qcow2".into(),
                ssh_public_key: None,
                disk_gb: 10,
            },
            VmStatus::Stopped
        ));
        assert!(!retry_allowed_for_status(
            &TaskKind::ReinstallVm {
                vm_id,
                name: "demo".into(),
                image: "debian-12.qcow2".into(),
                ssh_public_key: None,
                disk_gb: 10,
            },
            VmStatus::Provisioning
        ));

        assert!(retry_allowed_for_status(
            &TaskKind::StopVm { vm_id },
            VmStatus::Running
        ));
        assert!(!retry_allowed_for_status(
            &TaskKind::StopVm { vm_id },
            VmStatus::Stopped
        ));
    }
}
