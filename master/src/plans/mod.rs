use chrono::{DateTime, Utc};
use sqlx::{PgPool, Postgres, Row, Transaction};
use uuid::Uuid;
use vps_shared::{CreatePlanRequest, CreateVmRequest, PlanDto, PlanId};

use crate::http::ApiError;

const ENABLED_PLAN_SPEC_FOR_SHARE_SQL: &str = r#"
        SELECT cpu_cores, memory_mb, disk_gb, enabled
        FROM plans
        WHERE id = $1
        FOR SHARE
        "#;

#[derive(Clone, Debug)]
pub struct PlanSpec {
    pub cpu_cores: u16,
    pub memory_mb: u32,
    pub disk_gb: u32,
}

pub async fn create_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    request: CreatePlanRequest,
) -> Result<PlanDto, ApiError> {
    validate_plan_name(&request.name)?;
    validate_plan_slug(&request.slug)?;
    validate_plan_spec(request.cpu_cores, request.memory_mb, request.disk_gb)?;

    let row = sqlx::query(
        r#"
        INSERT INTO plans (id, name, slug, cpu_cores, memory_mb, disk_gb, enabled)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        RETURNING id, name, slug, cpu_cores, memory_mb, disk_gb, enabled, created_at, updated_at
        "#,
    )
    .bind(Uuid::new_v4())
    .bind(request.name)
    .bind(request.slug)
    .bind(i16::try_from(request.cpu_cores).map_err(|_| ApiError::Internal("cpu out of range"))?)
    .bind(i32::try_from(request.memory_mb).map_err(|_| ApiError::Internal("memory out of range"))?)
    .bind(i32::try_from(request.disk_gb).map_err(|_| ApiError::Internal("disk out of range"))?)
    .bind(request.enabled)
    .fetch_one(&mut **tx)
    .await?;

    plan_from_row(row)
}

pub async fn list(pool: &PgPool) -> Result<Vec<PlanDto>, ApiError> {
    let rows = sqlx::query(
        r#"
        SELECT id, name, slug, cpu_cores, memory_mb, disk_gb, enabled, created_at, updated_at
        FROM plans
        ORDER BY cpu_cores ASC, memory_mb ASC, disk_gb ASC, name ASC
        "#,
    )
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(plan_from_row).collect()
}

pub async fn set_enabled_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    plan_id: PlanId,
    enabled: bool,
) -> Result<PlanDto, ApiError> {
    let row = sqlx::query(
        r#"
        UPDATE plans
        SET enabled = $2, updated_at = now()
        WHERE id = $1
        RETURNING id, name, slug, cpu_cores, memory_mb, disk_gb, enabled, created_at, updated_at
        "#,
    )
    .bind(plan_id.0)
    .bind(enabled)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or(ApiError::NotFound("plan not found"))?;

    plan_from_row(row)
}

pub async fn apply_to_create_vm_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    request: &mut CreateVmRequest,
) -> Result<(), ApiError> {
    let Some(plan_id) = request.plan_id else {
        return Ok(());
    };

    let spec = enabled_spec_in_tx(tx, plan_id).await?;
    request.cpu_cores = spec.cpu_cores;
    request.memory_mb = spec.memory_mb;
    request.disk_gb = spec.disk_gb;
    Ok(())
}

async fn enabled_spec_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    plan_id: PlanId,
) -> Result<PlanSpec, ApiError> {
    let row = sqlx::query(ENABLED_PLAN_SPEC_FOR_SHARE_SQL)
        .bind(plan_id.0)
        .fetch_optional(&mut **tx)
        .await?
        .ok_or(ApiError::NotFound("plan not found"))?;

    let enabled: bool = row.try_get("enabled")?;
    if !enabled {
        return Err(ApiError::Conflict("plan is disabled"));
    }

    let cpu_cores: i16 = row.try_get("cpu_cores")?;
    let memory_mb: i32 = row.try_get("memory_mb")?;
    let disk_gb: i32 = row.try_get("disk_gb")?;

    Ok(PlanSpec {
        cpu_cores: u16::try_from(cpu_cores).map_err(|_| ApiError::Internal("cpu out of range"))?,
        memory_mb: u32::try_from(memory_mb)
            .map_err(|_| ApiError::Internal("memory out of range"))?,
        disk_gb: u32::try_from(disk_gb).map_err(|_| ApiError::Internal("disk out of range"))?,
    })
}

fn plan_from_row(row: sqlx::postgres::PgRow) -> Result<PlanDto, ApiError> {
    let cpu_cores: i16 = row.try_get("cpu_cores")?;
    let memory_mb: i32 = row.try_get("memory_mb")?;
    let disk_gb: i32 = row.try_get("disk_gb")?;

    Ok(PlanDto {
        id: PlanId(row.try_get("id")?),
        name: row.try_get("name")?,
        slug: row.try_get("slug")?,
        cpu_cores: u16::try_from(cpu_cores).map_err(|_| ApiError::Internal("cpu out of range"))?,
        memory_mb: u32::try_from(memory_mb)
            .map_err(|_| ApiError::Internal("memory out of range"))?,
        disk_gb: u32::try_from(disk_gb).map_err(|_| ApiError::Internal("disk out of range"))?,
        enabled: row.try_get("enabled")?,
        created_at: row.try_get::<DateTime<Utc>, _>("created_at")?,
        updated_at: row.try_get::<DateTime<Utc>, _>("updated_at")?,
    })
}

fn validate_plan_name(name: &str) -> Result<(), ApiError> {
    if name.is_empty()
        || name.len() > 80
        || !name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == ' ')
    {
        return Err(ApiError::Conflict(
            "plan name must be 1-80 chars and only contain ascii letters, numbers, spaces, '-' or '_'",
        ));
    }
    Ok(())
}

fn validate_plan_slug(slug: &str) -> Result<(), ApiError> {
    if slug.is_empty()
        || slug.len() > 80
        || !slug
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err(ApiError::Conflict(
            "plan slug must be 1-80 chars and only contain ascii letters, numbers, '-' or '_'",
        ));
    }
    Ok(())
}

fn validate_plan_spec(cpu_cores: u16, memory_mb: u32, disk_gb: u32) -> Result<(), ApiError> {
    if cpu_cores == 0 || cpu_cores > 32 {
        return Err(ApiError::Conflict(
            "plan cpu cores must be between 1 and 32",
        ));
    }
    if !(128..=262_144).contains(&memory_mb) {
        return Err(ApiError::Conflict(
            "plan memory must be between 128 MB and 262144 MB",
        ));
    }
    if disk_gb == 0 || disk_gb > 4096 {
        return Err(ApiError::Conflict(
            "plan disk size must be between 1 GB and 4096 GB",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plan_slug_rejects_path_like_values() {
        assert!(validate_plan_slug("../small").is_err());
        assert!(validate_plan_slug("small/linux").is_err());
        assert!(validate_plan_slug("small_1").is_ok());
    }

    #[test]
    fn plan_spec_enforces_vm_limits() {
        assert!(validate_plan_spec(1, 512, 10).is_ok());
        assert!(validate_plan_spec(0, 512, 10).is_err());
        assert!(validate_plan_spec(1, 64, 10).is_err());
        assert!(validate_plan_spec(1, 512, 0).is_err());
    }

    #[test]
    fn create_vm_plan_lookup_uses_transactional_row_lock() {
        let source = include_str!("mod.rs");
        let production_source = source
            .split("#[cfg(test)]")
            .next()
            .expect("production source before tests");

        assert!(
            production_source.contains("pub async fn apply_to_create_vm_in_tx"),
            "create_vm plan normalization must use the caller's transaction"
        );
        assert!(
            production_source.contains("async fn enabled_spec_in_tx"),
            "plan sizing must be loaded through a transaction-scoped helper"
        );
        assert!(
            production_source.contains("FOR SHARE") || production_source.contains("FOR UPDATE"),
            "plan sizing must hold a row lock so disable/update waits for the create decision"
        );
    }
}
