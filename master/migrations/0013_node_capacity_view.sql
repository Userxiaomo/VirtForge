CREATE VIEW nodes_with_capacity AS
SELECT
    n.id,
    n.name,
    n.status,
    n.scheduling_enabled,
    n.agent_version,
    n.last_seen_at,
    n.credential_hash,
    n.libvirt_status,
    n.host_checks,
    n.cpu_total,
    n.cpu_used,
    n.memory_total,
    n.memory_used,
    n.disk_total,
    n.disk_used,
    n.vm_count,
    n.created_at,
    n.updated_at,
    COALESCE(SUM(v.cpu_cores) FILTER (WHERE v.status IN ('provisioning', 'running', 'stopped', 'deleting')), 0)::bigint AS committed_cpu,
    COALESCE(SUM(v.memory_mb) FILTER (WHERE v.status IN ('provisioning', 'running', 'stopped', 'deleting')), 0)::bigint AS committed_memory_mb,
    COALESCE(SUM(v.disk_gb) FILTER (WHERE v.status IN ('provisioning', 'running', 'stopped', 'deleting')), 0)::bigint AS committed_disk_gb
FROM nodes n
LEFT JOIN vms v ON v.node_id = n.id
GROUP BY n.id;
