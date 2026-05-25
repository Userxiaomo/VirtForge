use axum::http::HeaderMap;
use chrono::{DateTime, Utc};
use serde_json::json;
use sha2::{Digest, Sha256};
use sqlx::{PgPool, Postgres, Row, Transaction};
use uuid::Uuid;
use vps_shared::{
    verify_agent_request_signature, AgentCredentialPlaintext, AgentRegisterRequest,
    AgentRegisterResponse, BootstrapTokenPlaintext, CreateBootstrapTokenRequest,
    CreateBootstrapTokenResponse, CreateNodeRequest, CreateVmRequest, HeartbeatRequest,
    HostPreflightCheck, NodeDto, NodeId, UpdateNodeSchedulingRequest,
};

use crate::{auth, config::MasterConfig, http::ApiError};

const MAX_BOOTSTRAP_TOKEN_TTL_HOURS: i64 = 24;

const AGENT_CREDENTIAL_HEADER: &str = "x-agent-credential";
const AGENT_SIGNATURE_HEADER: &str = "x-agent-signature";
const AGENT_TIMESTAMP_HEADER: &str = "x-agent-timestamp";
const AGENT_NONCE_HEADER: &str = "x-agent-nonce";
const AGENT_SIGNATURE_WINDOW_SECONDS: u64 = 300;
const MAX_AGENT_VERSION_LEN: usize = 64;
const INSTALLER_DOWNLOAD_CONNECT_TIMEOUT_SECONDS: u64 = 30;
const INSTALLER_DOWNLOAD_MAX_TIME_SECONDS: u64 = 300;

const NODE_CAPACITY_FOR_UPDATE_SQL: &str = r#"
        SELECT cpu_total, memory_total, disk_total
        FROM nodes
        WHERE id = $1
        FOR UPDATE
        "#;

const NODE_COMMITTED_CAPACITY_SQL: &str = r#"
        SELECT
            COALESCE(SUM(cpu_cores) FILTER (WHERE status IN ('provisioning', 'running', 'stopped', 'deleting')), 0)::bigint AS committed_cpu,
            COALESCE(SUM(memory_mb) FILTER (WHERE status IN ('provisioning', 'running', 'stopped', 'deleting')), 0)::bigint AS committed_memory_mb,
            COALESCE(SUM(disk_gb) FILTER (WHERE status IN ('provisioning', 'running', 'stopped', 'deleting')), 0)::bigint AS committed_disk_gb
        FROM vms
        WHERE node_id = $1
        "#;

pub async fn list(pool: &PgPool) -> Result<Vec<NodeDto>, ApiError> {
    let rows = sqlx::query(
        r#"
        SELECT id, name, status, scheduling_enabled, agent_version, last_seen_at,
            libvirt_status, host_checks,
            cpu_total, cpu_used, memory_total, memory_used, disk_total, disk_used, vm_count,
            committed_cpu, committed_memory_mb, committed_disk_gb,
            created_at
        FROM nodes_with_capacity
        ORDER BY created_at DESC
        "#,
    )
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(node_from_row).collect()
}

pub async fn create_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    request: CreateNodeRequest,
) -> Result<NodeDto, ApiError> {
    validate_node_name(&request.name)?;

    let id = Uuid::new_v4();
    let row = sqlx::query(
        r#"
        INSERT INTO nodes (id, name)
        VALUES ($1, $2)
        RETURNING id, name, status, scheduling_enabled, agent_version, last_seen_at,
            libvirt_status, host_checks,
            cpu_total, cpu_used, memory_total, memory_used, disk_total, disk_used, vm_count,
            0::bigint AS committed_cpu,
            0::bigint AS committed_memory_mb,
            0::bigint AS committed_disk_gb,
            created_at
        "#,
    )
    .bind(id)
    .bind(request.name)
    .fetch_one(&mut **tx)
    .await?;

    node_from_row(row)
}

pub async fn update_scheduling_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    node_id: NodeId,
    request: UpdateNodeSchedulingRequest,
) -> Result<NodeDto, ApiError> {
    let result = sqlx::query(
        r#"
        UPDATE nodes
        SET scheduling_enabled = $1, updated_at = now()
        WHERE id = $2
        "#,
    )
    .bind(request.enabled)
    .bind(node_id.0)
    .execute(&mut **tx)
    .await?;
    if result.rows_affected() == 0 {
        return Err(ApiError::NotFound("node not found"));
    }

    get_in_tx(tx, node_id).await
}

async fn get_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    node_id: NodeId,
) -> Result<NodeDto, ApiError> {
    let row = sqlx::query(
        r#"
        SELECT id, name, status, scheduling_enabled, agent_version, last_seen_at,
            libvirt_status, host_checks,
            cpu_total, cpu_used, memory_total, memory_used, disk_total, disk_used, vm_count,
            committed_cpu, committed_memory_mb, committed_disk_gb,
            created_at
        FROM nodes_with_capacity
        WHERE id = $1
        "#,
    )
    .bind(node_id.0)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or(ApiError::NotFound("node not found"))?;

    node_from_row(row)
}

pub async fn ensure_capacity_for_create_vm_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    request: &CreateVmRequest,
) -> Result<(), ApiError> {
    let totals = sqlx::query(NODE_CAPACITY_FOR_UPDATE_SQL)
        .bind(request.node_id.0)
        .fetch_optional(&mut **tx)
        .await?
        .ok_or(ApiError::NotFound("node not found"))?;
    let committed = sqlx::query(NODE_COMMITTED_CAPACITY_SQL)
        .bind(request.node_id.0)
        .fetch_one(&mut **tx)
        .await?;

    validate_capacity_snapshot(
        request,
        CapacitySnapshot {
            cpu_total: read_non_negative_u64(&totals, "cpu_total")?,
            memory_total: read_non_negative_u64(&totals, "memory_total")?,
            disk_total: read_non_negative_u64(&totals, "disk_total")?,
            committed_cpu: read_non_negative_u64(&committed, "committed_cpu")?,
            committed_memory_mb: read_non_negative_u64(&committed, "committed_memory_mb")?,
            committed_disk_gb: read_non_negative_u64(&committed, "committed_disk_gb")?,
        },
    )
}

#[derive(Clone, Copy, Debug)]
struct CapacitySnapshot {
    cpu_total: u64,
    memory_total: u64,
    disk_total: u64,
    committed_cpu: u64,
    committed_memory_mb: u64,
    committed_disk_gb: u64,
}

fn validate_capacity_snapshot(
    request: &CreateVmRequest,
    capacity: CapacitySnapshot,
) -> Result<(), ApiError> {
    let requested_cpu = u64::from(request.cpu_cores);
    if capacity.cpu_total > 0
        && capacity.committed_cpu.saturating_add(requested_cpu) > capacity.cpu_total
    {
        return Err(ApiError::Conflict("node cpu capacity is insufficient"));
    }

    let requested_memory_mb = u64::from(request.memory_mb);
    let memory_total_mb = capacity.memory_total / 1024 / 1024;
    if memory_total_mb > 0
        && capacity
            .committed_memory_mb
            .saturating_add(requested_memory_mb)
            > memory_total_mb
    {
        return Err(ApiError::Conflict("node memory capacity is insufficient"));
    }

    let requested_disk_gb = u64::from(request.disk_gb);
    let disk_total_gb = capacity.disk_total / 1024 / 1024 / 1024;
    if disk_total_gb > 0
        && capacity.committed_disk_gb.saturating_add(requested_disk_gb) > disk_total_gb
    {
        return Err(ApiError::Conflict("node disk capacity is insufficient"));
    }

    Ok(())
}

pub async fn create_bootstrap_token_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    config: &MasterConfig,
    node_id: NodeId,
    request: CreateBootstrapTokenRequest,
) -> Result<CreateBootstrapTokenResponse, ApiError> {
    validate_bootstrap_token_expiry(request.expires_at, Utc::now())?;

    ensure_node_exists_in_tx(tx, node_id).await?;

    let token = BootstrapTokenPlaintext(format!(
        "bt_{}_{}",
        Uuid::new_v4().simple(),
        Uuid::new_v4().simple()
    ));
    let token_hash = auth::hash_secret(&token.0)?;

    let install_command = install_command(config, node_id, &token)?;

    sqlx::query(
        r#"
        INSERT INTO bootstrap_tokens (id, node_id, token_hash, expires_at)
        VALUES ($1, $2, $3, $4)
        "#,
    )
    .bind(Uuid::new_v4())
    .bind(node_id.0)
    .bind(token_hash)
    .bind(request.expires_at)
    .execute(&mut **tx)
    .await?;

    Ok(CreateBootstrapTokenResponse {
        node_id,
        expires_at: request.expires_at,
        install_command,
        bootstrap_token: token,
    })
}

fn validate_bootstrap_token_expiry(
    expires_at: DateTime<Utc>,
    now: DateTime<Utc>,
) -> Result<(), ApiError> {
    if expires_at <= now {
        return Err(ApiError::Conflict(
            "bootstrap token expiry must be in the future",
        ));
    }

    let max_expires_at = now
        .checked_add_signed(chrono::Duration::hours(MAX_BOOTSTRAP_TOKEN_TTL_HOURS))
        .ok_or(ApiError::Conflict(
            "bootstrap token expiry must be within 24 hours",
        ))?;
    if expires_at > max_expires_at {
        return Err(ApiError::Conflict(
            "bootstrap token expiry must be within 24 hours",
        ));
    }

    Ok(())
}

pub async fn register_agent_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    request: AgentRegisterRequest,
) -> Result<AgentRegisterResponse, ApiError> {
    validate_agent_secret_shape(&request.bootstrap_token.0)?;
    validate_agent_version(&request.agent_version)?;
    ensure_node_exists_in_tx(tx, request.node_id).await?;

    let rows = sqlx::query(
        r#"
        SELECT id, token_hash
        FROM bootstrap_tokens
        WHERE node_id = $1 AND used_at IS NULL AND expires_at > now()
        ORDER BY created_at ASC
        "#,
    )
    .bind(request.node_id.0)
    .fetch_all(&mut **tx)
    .await?;

    let mut matched_token_id = None;
    for row in rows {
        let token_hash: String = row.try_get("token_hash")?;
        if auth::verify_secret(&request.bootstrap_token.0, &token_hash) {
            matched_token_id = Some(row.try_get::<Uuid, _>("id")?);
            break;
        }
    }

    let token_id = matched_token_id.ok_or(ApiError::Unauthorized)?;
    let credential = AgentCredentialPlaintext(format!(
        "ag_{}_{}",
        Uuid::new_v4().simple(),
        Uuid::new_v4().simple()
    ));
    let credential_hash = auth::hash_secret(&credential.0)?;

    let consume_result = sqlx::query(
        "UPDATE bootstrap_tokens SET used_at = now() WHERE id = $1 AND used_at IS NULL AND expires_at > now()",
    )
    .bind(token_id)
    .execute(&mut **tx)
    .await?;
    consume_bootstrap_token_result(consume_result.rows_affected())?;
    let update_node_result = sqlx::query(
        r#"
        UPDATE nodes
        SET credential_hash = $1,
            agent_version = $2,
            status = 'online',
            updated_at = now()
        WHERE id = $3
        "#,
    )
    .bind(credential_hash)
    .bind(request.agent_version)
    .bind(request.node_id.0)
    .execute(&mut **tx)
    .await?;
    registered_node_update_result(update_node_result.rows_affected())?;

    Ok(AgentRegisterResponse {
        node_id: request.node_id,
        credential,
    })
}

fn consume_bootstrap_token_result(rows_affected: u64) -> Result<(), ApiError> {
    match rows_affected {
        1 => Ok(()),
        0 => Err(ApiError::Unauthorized),
        _ => Err(ApiError::Internal(
            "bootstrap token update affected multiple rows",
        )),
    }
}

fn registered_node_update_result(rows_affected: u64) -> Result<(), ApiError> {
    match rows_affected {
        1 => Ok(()),
        0 => Err(ApiError::Unauthorized),
        _ => Err(ApiError::Internal(
            "agent registration node update affected multiple rows",
        )),
    }
}

pub async fn verify_agent_request(
    pool: &PgPool,
    headers: &HeaderMap,
    node_id: NodeId,
    method: &str,
    path: &str,
    body: &[u8],
) -> Result<(), ApiError> {
    let credential = headers
        .get(AGENT_CREDENTIAL_HEADER)
        .and_then(|value| value.to_str().ok())
        .ok_or(ApiError::Unauthorized)?;
    validate_agent_secret_shape(credential)?;
    let signature = headers
        .get(AGENT_SIGNATURE_HEADER)
        .and_then(|value| value.to_str().ok())
        .ok_or(ApiError::Unauthorized)?;
    let timestamp = headers
        .get(AGENT_TIMESTAMP_HEADER)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse::<i64>().ok())
        .ok_or(ApiError::Unauthorized)?;
    let nonce = headers
        .get(AGENT_NONCE_HEADER)
        .and_then(|value| value.to_str().ok())
        .filter(|value| valid_nonce(value))
        .ok_or(ApiError::Unauthorized)?;

    if !timestamp_within_agent_signature_window(Utc::now().timestamp(), timestamp) {
        return Err(ApiError::Unauthorized);
    }

    let credential_hash =
        sqlx::query_scalar::<_, Option<String>>("SELECT credential_hash FROM nodes WHERE id = $1")
            .bind(node_id.0)
            .fetch_optional(pool)
            .await?
            .flatten()
            .ok_or(ApiError::Unauthorized)?;

    if !auth::verify_secret(credential, &credential_hash) {
        return Err(ApiError::Unauthorized);
    }

    verify_agent_request_signature(credential, method, path, body, timestamp, nonce, signature)
        .map_err(|_| ApiError::Unauthorized)?;
    remember_nonce(pool, node_id, nonce).await?;

    Ok(())
}

async fn remember_nonce(pool: &PgPool, node_id: NodeId, nonce: &str) -> Result<(), ApiError> {
    sqlx::query("DELETE FROM agent_request_nonces WHERE seen_at < now() - interval '10 minutes'")
        .execute(pool)
        .await?;

    let result = sqlx::query(
        r#"
        INSERT INTO agent_request_nonces (node_id, nonce)
        VALUES ($1, $2)
        ON CONFLICT DO NOTHING
        "#,
    )
    .bind(node_id.0)
    .bind(nonce)
    .execute(pool)
    .await?;

    if result.rows_affected() == 1 {
        Ok(())
    } else {
        Err(ApiError::Unauthorized)
    }
}

fn valid_nonce(value: &str) -> bool {
    (16..=128).contains(&value.len())
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn timestamp_within_agent_signature_window(now: i64, timestamp: i64) -> bool {
    now.abs_diff(timestamp) <= AGENT_SIGNATURE_WINDOW_SECONDS
}

fn validate_agent_secret_shape(value: &str) -> Result<(), ApiError> {
    if value.is_empty() || value.len() > 256 {
        return Err(ApiError::Unauthorized);
    }
    if !value
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-')
    {
        return Err(ApiError::Unauthorized);
    }

    Ok(())
}

pub async fn record_heartbeat_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    request: &HeartbeatRequest,
) -> Result<(), ApiError> {
    validate_heartbeat_metrics(request)?;

    let result = sqlx::query(
        r#"
        UPDATE nodes
        SET status = 'online',
            agent_version = $1,
            last_seen_at = now(),
            cpu_total = $2,
            cpu_used = $3,
            memory_total = $4,
            memory_used = $5,
            disk_total = $6,
            disk_used = $7,
            vm_count = $8,
            libvirt_status = $9,
            host_checks = $10,
            updated_at = now()
        WHERE id = $11
        "#,
    )
    .bind(&request.agent_version)
    .bind(i64::try_from(request.cpu_total).map_err(|_| ApiError::Conflict("cpu_total too large"))?)
    .bind(i64::try_from(request.cpu_used).map_err(|_| ApiError::Conflict("cpu_used too large"))?)
    .bind(
        i64::try_from(request.memory_total)
            .map_err(|_| ApiError::Conflict("memory_total too large"))?,
    )
    .bind(
        i64::try_from(request.memory_used)
            .map_err(|_| ApiError::Conflict("memory_used too large"))?,
    )
    .bind(
        i64::try_from(request.disk_total)
            .map_err(|_| ApiError::Conflict("disk_total too large"))?,
    )
    .bind(i64::try_from(request.disk_used).map_err(|_| ApiError::Conflict("disk_used too large"))?)
    .bind(i32::try_from(request.vm_count).map_err(|_| ApiError::Conflict("vm_count too large"))?)
    .bind(&request.libvirt_status)
    .bind(serde_json::to_value(&request.host_checks)?)
    .bind(request.node_id.0)
    .execute(&mut **tx)
    .await?;

    if result.rows_affected() == 0 {
        return Err(ApiError::NotFound("node not found"));
    }

    Ok(())
}

fn validate_heartbeat_metrics(request: &HeartbeatRequest) -> Result<(), ApiError> {
    validate_agent_version(&request.agent_version)?;
    if !matches!(
        request.libvirt_status.as_str(),
        "not_checked" | "available" | "unavailable"
    ) {
        return Err(ApiError::Conflict("invalid libvirt_status"));
    }
    if request.host_checks.len() > 16 {
        return Err(ApiError::Conflict("too many host preflight checks"));
    }
    for check in &request.host_checks {
        validate_host_check(check)?;
    }
    if request.cpu_used > request.cpu_total {
        return Err(ApiError::Conflict("cpu_used cannot exceed cpu_total"));
    }
    if request.memory_used > request.memory_total {
        return Err(ApiError::Conflict("memory_used cannot exceed memory_total"));
    }
    if request.disk_used > request.disk_total {
        return Err(ApiError::Conflict("disk_used cannot exceed disk_total"));
    }
    Ok(())
}

fn validate_agent_version(value: &str) -> Result<(), ApiError> {
    if value.is_empty()
        || value.len() > MAX_AGENT_VERSION_LEN
        || !value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_' | '+'))
    {
        return Err(ApiError::Conflict("invalid agent_version"));
    }

    let normalized = value.to_ascii_lowercase();
    if [
        "token",
        "credential",
        "password",
        "secret",
        "private_key",
        "private-key",
    ]
    .iter()
    .any(|word| normalized.contains(word))
    {
        return Err(ApiError::Conflict("invalid agent_version"));
    }

    Ok(())
}

fn validate_host_check(check: &HostPreflightCheck) -> Result<(), ApiError> {
    if check.name.is_empty()
        || check.name.len() > 64
        || !check
            .name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
    {
        return Err(ApiError::Conflict("invalid host preflight check name"));
    }
    if !matches!(check.status.as_str(), "passed" | "failed" | "skipped") {
        return Err(ApiError::Conflict("invalid host preflight check status"));
    }
    if check.message.len() > 300 || check.message.chars().any(|c| c.is_ascii_control()) {
        return Err(ApiError::Conflict("invalid host preflight check message"));
    }
    Ok(())
}

fn read_non_negative_u64(row: &sqlx::postgres::PgRow, column: &str) -> Result<u64, ApiError> {
    let value: i64 = row.try_get(column)?;
    u64::try_from(value).map_err(|_| ApiError::Internal("database contains negative capacity"))
}

fn node_from_row(row: sqlx::postgres::PgRow) -> Result<NodeDto, ApiError> {
    let host_checks = serde_json::from_value::<Vec<HostPreflightCheck>>(
        row.try_get::<serde_json::Value, _>("host_checks")?,
    )?;
    Ok(NodeDto {
        id: NodeId(row.try_get("id")?),
        name: row.try_get("name")?,
        status: row.try_get("status")?,
        scheduling_enabled: row.try_get("scheduling_enabled")?,
        agent_version: row.try_get("agent_version")?,
        last_seen_at: row.try_get::<Option<DateTime<Utc>>, _>("last_seen_at")?,
        libvirt_status: row.try_get("libvirt_status")?,
        host_checks,
        cpu_total: row.try_get::<i64, _>("cpu_total")?.try_into().unwrap_or(0),
        cpu_used: row.try_get::<i64, _>("cpu_used")?.try_into().unwrap_or(0),
        memory_total: row
            .try_get::<i64, _>("memory_total")?
            .try_into()
            .unwrap_or(0),
        memory_used: row
            .try_get::<i64, _>("memory_used")?
            .try_into()
            .unwrap_or(0),
        disk_total: row.try_get::<i64, _>("disk_total")?.try_into().unwrap_or(0),
        disk_used: row.try_get::<i64, _>("disk_used")?.try_into().unwrap_or(0),
        committed_cpu: row
            .try_get::<i64, _>("committed_cpu")?
            .try_into()
            .unwrap_or(0),
        committed_memory_mb: row
            .try_get::<i64, _>("committed_memory_mb")?
            .try_into()
            .unwrap_or(0),
        committed_disk_gb: row
            .try_get::<i64, _>("committed_disk_gb")?
            .try_into()
            .unwrap_or(0),
        vm_count: row.try_get::<i32, _>("vm_count")?.try_into().unwrap_or(0),
        created_at: row.try_get("created_at")?,
    })
}

async fn ensure_node_exists_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    node_id: NodeId,
) -> Result<(), ApiError> {
    let exists = sqlx::query_scalar::<_, bool>("SELECT EXISTS (SELECT 1 FROM nodes WHERE id = $1)")
        .bind(node_id.0)
        .fetch_one(&mut **tx)
        .await?;

    if exists {
        Ok(())
    } else {
        Err(ApiError::NotFound("node not found"))
    }
}

fn validate_node_name(name: &str) -> Result<(), ApiError> {
    if name.is_empty()
        || name.len() > 80
        || !name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
    {
        return Err(ApiError::Conflict(
            "node name must be 1-80 chars and contain only ascii letters, numbers, '-', '_' or '.'",
        ));
    }

    Ok(())
}

fn install_command(
    config: &MasterConfig,
    node_id: NodeId,
    token: &BootstrapTokenPlaintext,
) -> Result<String, ApiError> {
    validate_agent_secret_shape(&token.0)
        .map_err(|_| ApiError::Internal("invalid bootstrap token shape"))?;
    crate::config::validate_https_base_url("MASTER_PUBLIC_BASE_URL", &config.public_base_url)
        .map_err(|_| ApiError::Internal("invalid install command URL"))?;
    crate::config::validate_https_base_url("MASTER_INSTALLER_BASE_URL", &config.installer_base_url)
        .map_err(|_| ApiError::Internal("invalid install command URL"))?;
    let curl_ca_cert_arg = installer_path_arg(
        "MASTER_INSTALLER_CA_CERT_PATH",
        "--cacert",
        config.installer_ca_cert_path.as_deref(),
    )?;
    let ca_cert_arg = installer_path_arg(
        "MASTER_INSTALLER_CA_CERT_PATH",
        "--ca-cert-path",
        config.installer_ca_cert_path.as_deref(),
    )?;
    let client_identity_arg = installer_path_arg(
        "MASTER_INSTALLER_CLIENT_IDENTITY_PATH",
        "--client-identity-path",
        config.installer_client_identity_path.as_deref(),
    )?;
    let agent_sha256_arg = agent_binary_sha256(config)?
        .map(|sha256| format!(" --agent-sha256 '{sha256}'"))
        .unwrap_or_default();

    Ok(format!(
        "(install_agent_script=\"\"; cleanup_install_agent_script() {{ [ -z \"$install_agent_script\" ] || rm -f \"$install_agent_script\"; }}; trap cleanup_install_agent_script EXIT; install_agent_script=\"$(mktemp)\" && curl -q -fsS --proto '=https' --connect-timeout {} --max-time {}{} -o \"$install_agent_script\" '{}/scripts/install-agent.sh' && sudo bash -- \"$install_agent_script\" --master-url '{}' --node-id '{}' --bootstrap-token '{}' --agent-url '{}/downloads/vps-agent'{}{}{})",
        INSTALLER_DOWNLOAD_CONNECT_TIMEOUT_SECONDS,
        INSTALLER_DOWNLOAD_MAX_TIME_SECONDS,
        curl_ca_cert_arg,
        config.installer_base_url.trim_end_matches('/'),
        config.public_base_url,
        node_id.0,
        token.0,
        config.installer_base_url.trim_end_matches('/'),
        ca_cert_arg,
        client_identity_arg,
        agent_sha256_arg
    ))
}

fn installer_path_arg(
    name: &str,
    flag: &str,
    path: Option<&std::path::Path>,
) -> Result<String, ApiError> {
    let Some(path) = path else {
        return Ok(String::new());
    };
    let value = crate::config::installer_host_file_path_str(name, path)
        .map_err(|_| ApiError::Internal("invalid installer TLS path"))?;
    Ok(format!(" {flag} '{value}'"))
}

fn agent_binary_sha256(config: &MasterConfig) -> Result<Option<String>, ApiError> {
    let Some(path) = config.agent_binary_path.as_ref() else {
        return Ok(None);
    };

    crate::config::validate_agent_binary_artifact_path(path)
        .map_err(|_| ApiError::NotFound("agent binary must be a regular file"))?;
    let bytes = std::fs::read(path).map_err(|_| ApiError::NotFound("agent binary not found"))?;
    Ok(Some(hex::encode(Sha256::digest(bytes))))
}

pub fn heartbeat_detail(request: &HeartbeatRequest) -> serde_json::Value {
    json!({
        "agent_version": request.agent_version,
        "libvirt_status": request.libvirt_status,
        "host_checks": request.host_checks,
        "cpu_total": request.cpu_total,
        "cpu_used": request.cpu_used,
        "memory_total": request.memory_total,
        "memory_used": request.memory_used,
        "disk_total": request.disk_total,
        "disk_used": request.disk_used,
        "vm_count": request.vm_count
    })
}

#[cfg(test)]
mod tests {
    use std::{net::SocketAddr, path::PathBuf};

    use super::*;

    fn test_config(public_base_url: &str, installer_base_url: &str) -> MasterConfig {
        MasterConfig {
            http_bind: "127.0.0.1:8080".parse::<SocketAddr>().expect("socket"),
            public_base_url: public_base_url.to_string(),
            installer_base_url: installer_base_url.to_string(),
            database_url: "postgres://vps:vps@localhost:5432/vps".into(),
            admin_username: "admin".into(),
            admin_token_hash: String::new(),
            readonly_token_hash: String::new(),
            agent_binary_path: Option::<PathBuf>::None,
            installer_ca_cert_path: Option::<PathBuf>::None,
            installer_client_identity_path: Option::<PathBuf>::None,
            admin_rate_limit_per_minute: 120,
            agent_rate_limit_per_minute: 600,
            agent_registration_rate_limit_per_minute: 30,
            request_body_limit_bytes: crate::config::REQUEST_BODY_LIMIT_DEFAULT_BYTES,
        }
    }

    #[test]
    fn capacity_admission_locks_node_before_reading_committed_vms() {
        assert!(
            NODE_CAPACITY_FOR_UPDATE_SQL.contains("FROM nodes")
                && NODE_CAPACITY_FOR_UPDATE_SQL.contains("FOR UPDATE"),
            "capacity admission must lock the node row before task insertion"
        );
        assert!(
            NODE_COMMITTED_CAPACITY_SQL.contains("FROM vms")
                && NODE_COMMITTED_CAPACITY_SQL.contains("'provisioning'")
                && NODE_COMMITTED_CAPACITY_SQL.contains("'running'")
                && NODE_COMMITTED_CAPACITY_SQL.contains("'stopped'")
                && NODE_COMMITTED_CAPACITY_SQL.contains("'deleting'"),
            "capacity admission must sum committed non-deleted VM inventory"
        );
    }

    #[test]
    fn install_command_can_split_installer_and_agent_urls() {
        let config = test_config("https://agents.example.com", "https://panel.example.com");
        let node_id = NodeId(uuid::Uuid::new_v4());
        let token = BootstrapTokenPlaintext("bootstrap-secret".into());

        let command = install_command(&config, node_id, &token).expect("install command");

        assert!(command.starts_with(
            "(install_agent_script=\"\"; cleanup_install_agent_script() { [ -z \"$install_agent_script\" ] || rm -f \"$install_agent_script\"; }; trap cleanup_install_agent_script EXIT; install_agent_script=\"$(mktemp)\" && curl -q -fsS --proto '=https' --connect-timeout 30 --max-time 300 -o \"$install_agent_script\" 'https://panel.example.com/scripts/install-agent.sh'"
        ));
        assert!(command.contains("--master-url 'https://agents.example.com'"));
        assert!(command.contains("--agent-url 'https://panel.example.com/downloads/vps-agent'"));
        assert!(command.contains(&format!("--node-id '{}'", node_id.0)));
    }

    #[test]
    fn install_command_uses_https_only_non_redirecting_curl() {
        let config = test_config("https://agents.example.com", "https://panel.example.com");
        let node_id = NodeId(uuid::Uuid::new_v4());
        let token = BootstrapTokenPlaintext("bootstrap-secret".into());

        let command = install_command(&config, node_id, &token).expect("install command");

        assert!(command.starts_with(
            "(install_agent_script=\"\"; cleanup_install_agent_script() { [ -z \"$install_agent_script\" ] || rm -f \"$install_agent_script\"; }; trap cleanup_install_agent_script EXIT; install_agent_script=\"$(mktemp)\" && curl -q -fsS --proto '=https' --connect-timeout 30 --max-time 300 -o \"$install_agent_script\" 'https://panel.example.com/scripts/install-agent.sh'"
        ));
        assert!(
            !command.contains("-L") && !command.contains("--location"),
            "generated installer download must not follow redirects: {command}"
        );
    }

    #[test]
    fn install_command_uses_bounded_installer_download_timeouts() {
        let config = test_config("https://agents.example.com", "https://panel.example.com");
        let node_id = NodeId(uuid::Uuid::new_v4());
        let token = BootstrapTokenPlaintext("bootstrap-secret".into());

        let command = install_command(&config, node_id, &token).expect("install command");

        assert!(
            command.contains("--connect-timeout 30 --max-time 300"),
            "generated installer download must have bounded curl timeouts before sudo bash: {command}"
        );
        let timeout_index = command
            .find("--connect-timeout 30 --max-time 300")
            .expect("timeout args should exist");
        let sudo_index = command
            .find("&& sudo bash --")
            .expect("sudo bash invocation should exist");
        assert!(
            timeout_index < sudo_index,
            "generated installer download timeouts must be part of the pre-sudo curl command: {command}"
        );
    }

    #[test]
    fn install_command_downloads_installer_before_sudo_bash() {
        let config = test_config("https://agents.example.com", "https://panel.example.com");
        let node_id = NodeId(uuid::Uuid::new_v4());
        let token = BootstrapTokenPlaintext("bootstrap-secret".into());

        let command = install_command(&config, node_id, &token).expect("install command");

        assert!(
            command.starts_with("(install_agent_script=\"\"; cleanup_install_agent_script() { [ -z \"$install_agent_script\" ] || rm -f \"$install_agent_script\"; }; trap cleanup_install_agent_script EXIT; install_agent_script=\"$(mktemp)\" && curl -q -fsS --proto '=https' "),
            "generated install command must download the installer before invoking sudo bash: {command}"
        );
        assert!(
            command.contains(" --connect-timeout 30 --max-time 300 -o \"$install_agent_script\" 'https://panel.example.com/scripts/install-agent.sh' && sudo bash -- \"$install_agent_script\" "),
            "generated install command should run sudo bash only after curl writes the temp file: {command}"
        );
        assert!(
            command.ends_with(")"),
            "generated install command should stay inside a subshell: {command}"
        );
        assert!(
            command.contains("trap cleanup_install_agent_script EXIT"),
            "generated install command should clean up the temp file on exit or interruption: {command}"
        );
        assert!(
            !command.contains("| sudo bash"),
            "generated install command must not mask curl failure through a pipeline: {command}"
        );
    }

    #[test]
    fn install_command_includes_agent_sha256_when_artifact_is_configured() {
        let artifact_path =
            std::env::temp_dir().join(format!("vps-agent-{}.bin", uuid::Uuid::new_v4()));
        std::fs::write(&artifact_path, b"agent-binary").expect("write test artifact");
        let mut config = test_config("https://agents.example.com", "https://panel.example.com");
        config.agent_binary_path = Some(artifact_path.clone());
        let node_id = NodeId(uuid::Uuid::new_v4());
        let token = BootstrapTokenPlaintext("bootstrap-secret".into());

        let command = install_command(&config, node_id, &token).expect("install command");

        std::fs::remove_file(artifact_path).expect("remove test artifact");
        assert!(command.contains(
            "--agent-sha256 'f03e279954a05b1fd253a5be7299019af3ebdf44c57e0c69eecc738601ca6d35'"
        ));
    }

    #[test]
    fn install_command_rejects_non_regular_agent_binary_artifact_path() {
        let artifact_path =
            std::env::temp_dir().join(format!("vps-agent-artifact-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&artifact_path).expect("create directory artifact path");
        let mut config = test_config("https://agents.example.com", "https://panel.example.com");
        config.agent_binary_path = Some(artifact_path.clone());
        let node_id = NodeId(uuid::Uuid::new_v4());
        let token = BootstrapTokenPlaintext("bootstrap-secret".into());

        let error = install_command(&config, node_id, &token)
            .expect_err("install command must reject non-regular agent artifacts");

        std::fs::remove_dir_all(artifact_path).expect("remove directory artifact path");
        assert!(
            matches!(
                error,
                ApiError::NotFound("agent binary must be a regular file")
            ),
            "unexpected error: {error:?}"
        );
    }

    #[test]
    fn install_command_includes_tls_paths_when_configured() {
        let mut config = test_config("https://agents.example.com", "https://panel.example.com");
        config.installer_ca_cert_path = Some(PathBuf::from("/etc/ssl/certs/master-ca.pem"));
        config.installer_client_identity_path =
            Some(PathBuf::from("/etc/vps-agent/client-identity.pem"));
        let node_id = NodeId(uuid::Uuid::new_v4());
        let token = BootstrapTokenPlaintext("bootstrap-secret".into());

        let command = install_command(&config, node_id, &token).expect("install command");

        assert!(command.contains("--ca-cert-path '/etc/ssl/certs/master-ca.pem'"));
        assert!(command.contains("--client-identity-path '/etc/vps-agent/client-identity.pem'"));
    }

    #[test]
    fn install_command_uses_configured_ca_for_installer_download() {
        let mut config = test_config("https://agents.example.com", "https://panel.example.com");
        config.installer_ca_cert_path = Some(PathBuf::from("/etc/ssl/certs/master-ca.pem"));
        let node_id = NodeId(uuid::Uuid::new_v4());
        let token = BootstrapTokenPlaintext("bootstrap-secret".into());

        let command = install_command(&config, node_id, &token).expect("install command");

        assert!(command.starts_with(
            "(install_agent_script=\"\"; cleanup_install_agent_script() { [ -z \"$install_agent_script\" ] || rm -f \"$install_agent_script\"; }; trap cleanup_install_agent_script EXIT; install_agent_script=\"$(mktemp)\" && curl -q -fsS --proto '=https' --connect-timeout 30 --max-time 300 --cacert '/etc/ssl/certs/master-ca.pem' -o \"$install_agent_script\" 'https://panel.example.com/scripts/install-agent.sh'"
        ));
        assert!(command.contains("--ca-cert-path '/etc/ssl/certs/master-ca.pem'"));
    }

    #[test]
    fn install_command_rejects_shell_unsafe_base_urls() {
        let node_id = NodeId(uuid::Uuid::new_v4());
        let token = BootstrapTokenPlaintext("bootstrap-secret".into());

        for (public_base_url, installer_base_url) in [
            (
                "https://agents.example.com' --bad",
                "https://panel.example.com",
            ),
            (
                "https://agents.example.com",
                "https://panel.example.com' --bad",
            ),
        ] {
            let config = test_config(public_base_url, installer_base_url);
            let error = install_command(&config, node_id, &token)
                .expect_err("install command must reject shell-unsafe URLs");

            assert!(
                matches!(error, ApiError::Internal("invalid install command URL")),
                "unexpected error: {error:?}"
            );
        }
    }

    #[test]
    fn install_command_rejects_shell_unsafe_bootstrap_tokens() {
        let config = test_config("https://agents.example.com", "https://panel.example.com");
        let node_id = NodeId(uuid::Uuid::new_v4());
        let oversized = "a".repeat(257);

        for unsafe_token in ["bad token", "bad'token", "bad/token", &oversized] {
            let token = BootstrapTokenPlaintext(unsafe_token.into());
            let error = install_command(&config, node_id, &token)
                .expect_err("install command must reject malformed bootstrap tokens");

            assert!(
                matches!(error, ApiError::Internal("invalid bootstrap token shape")),
                "unexpected error: {error:?}"
            );
        }
    }

    #[test]
    fn bootstrap_token_expiry_must_be_short_lived() {
        let now = Utc::now();

        validate_bootstrap_token_expiry(now + chrono::Duration::minutes(30), now)
            .expect("short future expiry should be accepted");

        let past_error = validate_bootstrap_token_expiry(now - chrono::Duration::seconds(1), now)
            .expect_err("past expiry must be rejected");
        assert!(
            matches!(
                past_error,
                ApiError::Conflict("bootstrap token expiry must be in the future")
            ),
            "unexpected error: {past_error:?}"
        );

        let long_lived_error = validate_bootstrap_token_expiry(
            now + chrono::Duration::hours(24) + chrono::Duration::seconds(1),
            now,
        )
        .expect_err("long-lived bootstrap token must be rejected");
        assert!(
            matches!(
                long_lived_error,
                ApiError::Conflict("bootstrap token expiry must be within 24 hours")
            ),
            "unexpected error: {long_lived_error:?}"
        );
    }

    #[test]
    fn consumed_bootstrap_token_must_update_exactly_one_row() {
        assert!(consume_bootstrap_token_result(1).is_ok());
        assert!(matches!(
            consume_bootstrap_token_result(0),
            Err(ApiError::Unauthorized)
        ));
        assert!(matches!(
            consume_bootstrap_token_result(2),
            Err(ApiError::Internal(
                "bootstrap token update affected multiple rows"
            ))
        ));
    }

    #[test]
    fn registered_node_update_must_update_exactly_one_row() {
        assert!(registered_node_update_result(1).is_ok());
        assert!(matches!(
            registered_node_update_result(0),
            Err(ApiError::Unauthorized)
        ));
        assert!(matches!(
            registered_node_update_result(2),
            Err(ApiError::Internal(
                "agent registration node update affected multiple rows"
            ))
        ));
    }

    #[test]
    fn agent_secret_shape_rejects_malformed_values_before_hash_verification() {
        assert!(validate_agent_secret_shape("ag_safe-token.1").is_ok());
        assert!(validate_agent_secret_shape("bt_safe-token.1").is_ok());

        for unsafe_value in ["", "bad token", "bad/token", "bad\\token", "bad\nsecret"] {
            assert!(
                matches!(
                    validate_agent_secret_shape(unsafe_value),
                    Err(ApiError::Unauthorized)
                ),
                "unsafe agent secret should be rejected: {unsafe_value:?}"
            );
        }

        let oversized = "a".repeat(257);
        assert!(matches!(
            validate_agent_secret_shape(&oversized),
            Err(ApiError::Unauthorized)
        ));
    }

    #[test]
    fn agent_signature_timestamp_window_accepts_boundary_and_rejects_skew() {
        let now = 1_000;

        assert!(timestamp_within_agent_signature_window(now, now));
        assert!(timestamp_within_agent_signature_window(now, now - 300));
        assert!(timestamp_within_agent_signature_window(now, now + 300));
        assert!(!timestamp_within_agent_signature_window(now, now - 301));
        assert!(!timestamp_within_agent_signature_window(now, now + 301));
    }

    #[test]
    fn host_preflight_check_rejects_ascii_control_messages() {
        let check = HostPreflightCheck {
            name: "libvirt".into(),
            status: "failed".into(),
            message: "virsh failed: \x1b[31mred".into(),
        };

        let error = validate_host_check(&check).expect_err("control bytes should fail");

        assert!(
            matches!(error, ApiError::Conflict(_)),
            "unexpected error: {error:?}"
        );
    }

    #[test]
    fn heartbeat_validation_rejects_unsafe_agent_versions() {
        let mut request = heartbeat_request();
        request.agent_version = "0.1.0".into();
        validate_heartbeat_metrics(&request).expect("safe agent version should pass");

        for unsafe_version in [
            "",
            "vps agent 0.1.0",
            "0.1.0\nnext",
            "credential-leak",
            &"a".repeat(65),
        ] {
            let mut request = heartbeat_request();
            request.agent_version = unsafe_version.into();
            let error =
                validate_heartbeat_metrics(&request).expect_err("unsafe version should fail");
            assert!(
                matches!(error, ApiError::Conflict(_)),
                "unexpected error for {unsafe_version:?}: {error:?}"
            );
        }
    }

    #[test]
    fn heartbeat_validation_rejects_cpu_used_above_total() {
        let mut request = heartbeat_request();
        request.cpu_total = 1;
        request.cpu_used = 2;

        let error =
            validate_heartbeat_metrics(&request).expect_err("cpu_used above cpu_total should fail");

        assert!(
            matches!(
                error,
                ApiError::Conflict("cpu_used cannot exceed cpu_total")
            ),
            "unexpected error: {error:?}"
        );
    }

    fn heartbeat_request() -> HeartbeatRequest {
        HeartbeatRequest {
            node_id: NodeId(uuid::Uuid::new_v4()),
            agent_version: "0.1.0".into(),
            libvirt_status: "not_checked".into(),
            host_checks: Vec::new(),
            cpu_total: 2,
            cpu_used: 1,
            memory_total: 1024,
            memory_used: 512,
            disk_total: 2048,
            disk_used: 1024,
            vm_count: 0,
        }
    }
}
