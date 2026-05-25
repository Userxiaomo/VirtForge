use std::{collections::HashSet, net::Ipv4Addr};

use chrono::{DateTime, Utc};
use sqlx::{PgPool, Postgres, Row, Transaction};
use uuid::Uuid;
use vps_shared::{CreateIpPoolRequest, IpPoolDto, IpPoolId, TaskId, VmId};

use crate::http::ApiError;

#[derive(Clone, Debug)]
struct ParsedIpv4Cidr {
    network: u32,
    broadcast: u32,
    prefix: u8,
}

#[derive(Clone, Debug)]
pub struct ReservedIp {
    pub address: String,
    pub prefix: u8,
    pub gateway_ip: String,
}

pub async fn create_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    request: CreateIpPoolRequest,
) -> Result<IpPoolDto, ApiError> {
    validate_name(&request.name)?;
    let cidr = parse_ipv4_cidr(&request.cidr)?;
    let gateway_ip = parse_ipv4(
        &request.gateway_ip,
        "gateway_ip must be a valid IPv4 address",
    )?;

    if !cidr.contains_host(gateway_ip) {
        return Err(ApiError::Conflict(
            "gateway_ip must be a usable address inside the CIDR",
        ));
    }

    let id = IpPoolId::new();
    let row = sqlx::query(
        r#"
        INSERT INTO ip_pools (id, name, cidr, gateway_ip)
        VALUES ($1, $2, $3, $4)
        RETURNING id, name, cidr, gateway_ip, 0::BIGINT AS allocated_count, created_at, updated_at
        "#,
    )
    .bind(id.0)
    .bind(request.name)
    .bind(normalize_cidr(&request.cidr)?)
    .bind(request.gateway_ip)
    .fetch_one(&mut **tx)
    .await?;

    ip_pool_from_row(row)
}

pub async fn list(pool: &PgPool) -> Result<Vec<IpPoolDto>, ApiError> {
    let rows = sqlx::query(
        r#"
        SELECT
            p.id,
            p.name,
            p.cidr,
            p.gateway_ip,
            COUNT(a.id) FILTER (WHERE a.released_at IS NULL) AS allocated_count,
            p.created_at,
            p.updated_at
        FROM ip_pools p
        LEFT JOIN ip_allocations a ON a.ip_pool_id = p.id
        GROUP BY p.id
        ORDER BY p.created_at DESC
        "#,
    )
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(ip_pool_from_row).collect()
}

pub async fn reserve_next_for_vm_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    ip_pool_id: IpPoolId,
    vm_id: VmId,
) -> Result<ReservedIp, ApiError> {
    let row = sqlx::query("SELECT cidr, gateway_ip FROM ip_pools WHERE id = $1")
        .bind(ip_pool_id.0)
        .fetch_optional(&mut **tx)
        .await?
        .ok_or(ApiError::NotFound("ip pool not found"))?;

    let cidr_text: String = row.try_get("cidr")?;
    let gateway_text: String = row.try_get("gateway_ip")?;
    let cidr = parse_ipv4_cidr(&cidr_text)?;
    let gateway_ip = parse_ipv4(&gateway_text, "stored gateway_ip is invalid")?;

    let allocated = active_allocations_in_tx(tx, ip_pool_id).await?;
    for candidate in cidr.usable_hosts() {
        if candidate == gateway_ip || allocated.contains(&candidate.to_string()) {
            continue;
        }

        let result = sqlx::query(
            r#"
            INSERT INTO ip_allocations (id, ip_pool_id, vm_id, ip_address)
            VALUES ($1, $2, $3, $4)
            ON CONFLICT DO NOTHING
            "#,
        )
        .bind(Uuid::new_v4())
        .bind(ip_pool_id.0)
        .bind(vm_id.0)
        .bind(candidate.to_string())
        .execute(&mut **tx)
        .await?;

        if result.rows_affected() == 1 {
            return Ok(ReservedIp {
                address: candidate.to_string(),
                prefix: cidr.prefix,
                gateway_ip: gateway_ip.to_string(),
            });
        }
    }

    Err(ApiError::Conflict("ip pool has no available addresses"))
}

pub async fn attach_task_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    vm_id: VmId,
    task_id: TaskId,
) -> Result<(), ApiError> {
    let result = sqlx::query(
        r#"
        UPDATE ip_allocations
        SET reserved_by_task_id = $1
        WHERE vm_id = $2 AND released_at IS NULL
        "#,
    )
    .bind(task_id.0)
    .bind(vm_id.0)
    .execute(&mut **tx)
    .await?;

    attach_task_update_result(result.rows_affected())
}

fn attach_task_update_result(rows_affected: u64) -> Result<(), ApiError> {
    match rows_affected {
        1 => Ok(()),
        0 => Err(ApiError::Conflict(
            "ip reservation changed before task attachment",
        )),
        _ => Err(ApiError::Internal(
            "task IP attachment affected multiple allocation rows",
        )),
    }
}

pub async fn release_for_vm_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    vm_id: VmId,
) -> Result<(), ApiError> {
    sqlx::query(
        r#"
        UPDATE ip_allocations
        SET released_at = now()
        WHERE vm_id = $1 AND released_at IS NULL
        "#,
    )
    .bind(vm_id.0)
    .execute(&mut **tx)
    .await?;

    Ok(())
}

async fn active_allocations_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    ip_pool_id: IpPoolId,
) -> Result<HashSet<String>, ApiError> {
    let rows = sqlx::query(
        r#"
        SELECT ip_address
        FROM ip_allocations
        WHERE ip_pool_id = $1 AND released_at IS NULL
        "#,
    )
    .bind(ip_pool_id.0)
    .fetch_all(&mut **tx)
    .await?;

    rows.into_iter()
        .map(|row| row.try_get("ip_address"))
        .collect::<Result<HashSet<String>, sqlx::Error>>()
        .map_err(ApiError::from)
}

fn ip_pool_from_row(row: sqlx::postgres::PgRow) -> Result<IpPoolDto, ApiError> {
    Ok(IpPoolDto {
        id: IpPoolId(row.try_get("id")?),
        name: row.try_get("name")?,
        cidr: row.try_get("cidr")?,
        gateway_ip: row.try_get("gateway_ip")?,
        allocated_count: row.try_get("allocated_count")?,
        created_at: row.try_get::<DateTime<Utc>, _>("created_at")?,
        updated_at: row.try_get::<DateTime<Utc>, _>("updated_at")?,
    })
}

fn validate_name(name: &str) -> Result<(), ApiError> {
    if name.is_empty()
        || name.len() > 80
        || !name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
    {
        return Err(ApiError::Conflict(
            "ip pool name must be 1-80 chars and contain only ascii letters, numbers, '-', '_' or '.'",
        ));
    }

    Ok(())
}

fn normalize_cidr(value: &str) -> Result<String, ApiError> {
    let (network, prefix) = split_cidr(value)?;
    let parsed = parse_ipv4_cidr(value)?;
    Ok(format!(
        "{}/{}",
        Ipv4Addr::from(parsed.network),
        prefix_for(network, prefix)?
    ))
}

fn parse_ipv4_cidr(value: &str) -> Result<ParsedIpv4Cidr, ApiError> {
    let (network_text, prefix_text) = split_cidr(value)?;
    let ip = parse_ipv4(network_text, "cidr must contain a valid IPv4 network")?;
    let prefix = prefix_for(network_text, prefix_text)?;

    let ip_u32 = u32::from(ip);
    let mask = u32::MAX << (32 - prefix);
    let network = ip_u32 & mask;
    let broadcast = network | !mask;

    Ok(ParsedIpv4Cidr {
        network,
        broadcast,
        prefix: u8::try_from(prefix).map_err(|_| ApiError::Internal("cidr prefix out of range"))?,
    })
}

fn split_cidr(value: &str) -> Result<(&str, &str), ApiError> {
    value
        .split_once('/')
        .ok_or(ApiError::Conflict("cidr must use IPv4 CIDR notation"))
}

fn prefix_for(_network: &str, prefix_text: &str) -> Result<u32, ApiError> {
    let prefix = prefix_text
        .parse::<u32>()
        .map_err(|_| ApiError::Conflict("cidr prefix must be a number"))?;
    if !(16..=30).contains(&prefix) {
        return Err(ApiError::Conflict(
            "MVP IPv4 pools must use a /16 through /30 prefix",
        ));
    }

    Ok(prefix)
}

fn parse_ipv4(value: &str, error: &'static str) -> Result<Ipv4Addr, ApiError> {
    value
        .parse::<Ipv4Addr>()
        .map_err(|_| ApiError::Conflict(error))
}

impl ParsedIpv4Cidr {
    fn contains_host(&self, ip: Ipv4Addr) -> bool {
        let value = u32::from(ip);
        value > self.network && value < self.broadcast
    }

    fn usable_hosts(&self) -> impl Iterator<Item = Ipv4Addr> {
        ((self.network + 1)..self.broadcast).map(Ipv4Addr::from)
    }
}

#[cfg(test)]
mod tests {
    use crate::http::ApiError;

    use super::{attach_task_update_result, parse_ipv4_cidr};

    #[test]
    fn cidr_parser_rejects_huge_or_tiny_pools() {
        assert!(parse_ipv4_cidr("192.0.2.0/15").is_err());
        assert!(parse_ipv4_cidr("192.0.2.0/31").is_err());
    }

    #[test]
    fn cidr_parser_exposes_usable_hosts() {
        let cidr = parse_ipv4_cidr("192.0.2.0/30").unwrap();
        let hosts: Vec<_> = cidr.usable_hosts().map(|ip| ip.to_string()).collect();
        assert_eq!(hosts, vec!["192.0.2.1", "192.0.2.2"]);
    }

    #[test]
    fn attach_task_must_update_exactly_one_active_allocation() {
        assert!(attach_task_update_result(1).is_ok());
        assert!(matches!(
            attach_task_update_result(0),
            Err(ApiError::Conflict(
                "ip reservation changed before task attachment"
            ))
        ));
        assert!(matches!(
            attach_task_update_result(2),
            Err(ApiError::Internal(
                "task IP attachment affected multiple allocation rows"
            ))
        ));
    }
}
