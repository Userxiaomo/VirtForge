use std::net::Ipv4Addr;

use serde::{Deserialize, Serialize};

use crate::{IpPoolId, NodeId, PlanId, VmId};

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskStatus {
    Pending,
    Assigned,
    Running,
    Succeeded,
    Failed,
    Canceled,
}

impl TaskStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Assigned => "assigned",
            Self::Running => "running",
            Self::Succeeded => "succeeded",
            Self::Failed => "failed",
            Self::Canceled => "canceled",
        }
    }

    pub fn from_db(value: &str) -> Option<Self> {
        match value {
            "pending" => Some(Self::Pending),
            "assigned" => Some(Self::Assigned),
            "running" => Some(Self::Running),
            "succeeded" => Some(Self::Succeeded),
            "failed" => Some(Self::Failed),
            "canceled" => Some(Self::Canceled),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum TaskKind {
    CreateVm(CreateVmRequest),
    StartVm {
        vm_id: VmId,
    },
    StopVm {
        vm_id: VmId,
    },
    RebootVm {
        vm_id: VmId,
    },
    ReinstallVm {
        vm_id: VmId,
        name: String,
        image: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        ssh_public_key: Option<String>,
        disk_gb: u32,
    },
    DeleteVm {
        vm_id: VmId,
    },
}

impl TaskKind {
    pub fn validate_for_agent(&self) -> Result<(), TaskValidationError> {
        match self {
            Self::CreateVm(request) => {
                request.validate_for_mvp()?;
                if request.vm_id.is_none() {
                    return Err(TaskValidationError::MissingVmId);
                }
                Ok(())
            }
            Self::ReinstallVm {
                name,
                image,
                ssh_public_key,
                disk_gb,
                ..
            } => {
                validate_vm_name(name)?;
                validate_image_name(image)?;
                validate_disk_size(*disk_gb)?;
                if let Some(key) = ssh_public_key {
                    validate_ssh_public_key(key)?;
                }
                Ok(())
            }
            Self::StartVm { .. }
            | Self::StopVm { .. }
            | Self::RebootVm { .. }
            | Self::DeleteVm { .. } => Ok(()),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct CreateVmRequest {
    pub node_id: NodeId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub vm_id: Option<VmId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ip_pool_id: Option<IpPoolId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan_id: Option<PlanId>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub assigned_ip: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub assigned_ip_prefix: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub assigned_gateway_ip: Option<String>,
    pub name: String,
    pub image: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ssh_public_key: Option<String>,
    pub cpu_cores: u16,
    pub memory_mb: u32,
    pub disk_gb: u32,
}

impl CreateVmRequest {
    pub fn validate_for_mvp(&self) -> Result<(), TaskValidationError> {
        validate_vm_name(&self.name)?;
        validate_image_name(&self.image)?;

        if self.cpu_cores == 0 || self.cpu_cores > 32 {
            return Err(TaskValidationError::InvalidCpuCores);
        }

        if self.memory_mb < 128 || self.memory_mb > 262_144 {
            return Err(TaskValidationError::InvalidMemory);
        }

        validate_disk_size(self.disk_gb)?;

        if let Some(key) = &self.ssh_public_key {
            validate_ssh_public_key(key)?;
        }

        validate_assigned_network(
            self.assigned_ip.as_deref(),
            self.assigned_ip_prefix,
            self.assigned_gateway_ip.as_deref(),
        )?;

        Ok(())
    }
}

fn validate_vm_name(name: &str) -> Result<(), TaskValidationError> {
    if name.is_empty()
        || name.len() > 64
        || !name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err(TaskValidationError::InvalidVmName);
    }

    Ok(())
}

fn validate_image_name(image: &str) -> Result<(), TaskValidationError> {
    if !crate::is_safe_image_file_name(image) {
        return Err(TaskValidationError::InvalidImageName);
    }

    Ok(())
}

fn validate_disk_size(disk_gb: u32) -> Result<(), TaskValidationError> {
    if disk_gb == 0 || disk_gb > 4096 {
        return Err(TaskValidationError::InvalidDiskSize);
    }

    Ok(())
}

pub fn validate_ssh_public_key(key: &str) -> Result<(), TaskValidationError> {
    if key.is_empty() || key.len() > 1024 || key.contains('\n') || key.contains('\r') {
        return Err(TaskValidationError::InvalidSshPublicKey);
    }

    let mut parts = key.split_whitespace();
    let Some(kind) = parts.next() else {
        return Err(TaskValidationError::InvalidSshPublicKey);
    };
    let Some(body) = parts.next() else {
        return Err(TaskValidationError::InvalidSshPublicKey);
    };
    let comment = parts.next();
    if parts.next().is_some() {
        return Err(TaskValidationError::InvalidSshPublicKey);
    }

    if !matches!(
        kind,
        "ssh-ed25519"
            | "ssh-rsa"
            | "ecdsa-sha2-nistp256"
            | "ecdsa-sha2-nistp384"
            | "ecdsa-sha2-nistp521"
    ) {
        return Err(TaskValidationError::InvalidSshPublicKey);
    }

    if body.len() < 32
        || body.len() > 900
        || !body
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '+' || c == '/' || c == '=')
    {
        return Err(TaskValidationError::InvalidSshPublicKey);
    }

    if let Some(comment) = comment {
        if comment.len() > 128 || !comment.chars().all(is_safe_ssh_public_key_comment_char) {
            return Err(TaskValidationError::InvalidSshPublicKey);
        }
    }

    Ok(())
}

fn is_safe_ssh_public_key_comment_char(c: char) -> bool {
    c.is_ascii_graphic()
        && !matches!(
            c,
            '"' | '\''
                | '\\'
                | '`'
                | '$'
                | ';'
                | '|'
                | '&'
                | '<'
                | '>'
                | '('
                | ')'
                | '{'
                | '}'
                | '['
                | ']'
                | '*'
                | '?'
                | '!'
                | '#'
        )
}

fn validate_assigned_network(
    assigned_ip: Option<&str>,
    prefix: Option<u8>,
    gateway_ip: Option<&str>,
) -> Result<(), TaskValidationError> {
    let present_count = usize::from(assigned_ip.is_some())
        + usize::from(prefix.is_some())
        + usize::from(gateway_ip.is_some());
    if present_count == 0 {
        return Ok(());
    }
    if present_count != 3 {
        return Err(TaskValidationError::InvalidAssignedIp);
    }

    let assigned_ip = validate_assigned_ip(assigned_ip.expect("checked assigned_ip"))?;
    let gateway_ip = validate_assigned_ip(gateway_ip.expect("checked gateway_ip"))?;
    let prefix = prefix.expect("checked assigned_ip_prefix");
    if !(16..=30).contains(&prefix) {
        return Err(TaskValidationError::InvalidAssignedIp);
    }
    if assigned_ip == gateway_ip || !same_ipv4_network(assigned_ip, gateway_ip, prefix) {
        return Err(TaskValidationError::InvalidAssignedIp);
    }

    Ok(())
}

fn validate_assigned_ip(value: &str) -> Result<Ipv4Addr, TaskValidationError> {
    let ip = value
        .parse::<Ipv4Addr>()
        .map_err(|_| TaskValidationError::InvalidAssignedIp)?;
    if ip.is_unspecified() || ip.is_broadcast() {
        return Err(TaskValidationError::InvalidAssignedIp);
    }

    Ok(ip)
}

fn same_ipv4_network(left: Ipv4Addr, right: Ipv4Addr, prefix: u8) -> bool {
    let mask = u32::MAX << (32 - u32::from(prefix));
    (u32::from(left) & mask) == (u32::from(right) & mask)
}

#[derive(Debug, thiserror::Error)]
pub enum TaskValidationError {
    #[error("vm name must be 1-64 chars and only contain ascii letters, numbers, '-' or '_'")]
    InvalidVmName,
    #[error("image name must be a safe 1-80 char ascii file name without empty dot segments")]
    InvalidImageName,
    #[error("cpu cores must be between 1 and 32")]
    InvalidCpuCores,
    #[error("memory must be between 128 MB and 262144 MB")]
    InvalidMemory,
    #[error("disk size must be between 1 GB and 4096 GB")]
    InvalidDiskSize,
    #[error("ssh public key must be a single OpenSSH public key with a supported key type")]
    InvalidSshPublicKey,
    #[error("assigned_ip metadata must describe a valid IPv4 host address, prefix, and gateway")]
    InvalidAssignedIp,
    #[error("agent create_vm task must include master-assigned vm_id")]
    MissingVmId,
}

#[cfg(test)]
mod tests {
    use super::{validate_ssh_public_key, CreateVmRequest, TaskKind, TaskValidationError};
    use crate::{NodeId, VmId};

    #[test]
    fn ssh_public_key_accepts_basic_openssh_key() {
        assert!(validate_ssh_public_key(
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb user@example"
        )
        .is_ok());
    }

    #[test]
    fn ssh_public_key_rejects_multiline_or_shell_like_values() {
        assert!(validate_ssh_public_key("ssh-ed25519 AAAA\nbad").is_err());
        assert!(validate_ssh_public_key("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb bad\"comment").is_err());
        assert!(validate_ssh_public_key("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb bad`comment").is_err());
        assert!(validate_ssh_public_key("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb bad;comment").is_err());
        assert!(validate_ssh_public_key("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb bad$comment").is_err());
        assert!(validate_ssh_public_key(
            "bad-key AAAAC3NzaC1lZDI1NTE5AAAAIBbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        )
        .is_err());
    }

    #[test]
    fn create_vm_rejects_dot_segment_image_names() {
        for image in [".hidden.qcow2", "bad..name.qcow2", "debian-12."] {
            let request = CreateVmRequest {
                node_id: NodeId::new(),
                vm_id: None,
                ip_pool_id: None,
                plan_id: None,
                assigned_ip: None,
                assigned_ip_prefix: None,
                assigned_gateway_ip: None,
                name: "demo".into(),
                image: image.into(),
                ssh_public_key: None,
                cpu_cores: 1,
                memory_mb: 512,
                disk_gb: 10,
            };

            assert!(matches!(
                request.validate_for_mvp(),
                Err(TaskValidationError::InvalidImageName)
            ));
        }
    }

    #[test]
    fn create_vm_rejects_malformed_assigned_ip_at_agent_boundary() {
        let mut request = CreateVmRequest {
            node_id: NodeId::new(),
            vm_id: Some(VmId::new()),
            ip_pool_id: None,
            plan_id: None,
            assigned_ip: Some("192.0.2.2".into()),
            assigned_ip_prefix: Some(29),
            assigned_gateway_ip: Some("192.0.2.1".into()),
            name: "demo".into(),
            image: "debian-12.qcow2".into(),
            ssh_public_key: None,
            cpu_cores: 1,
            memory_mb: 512,
            disk_gb: 10,
        };

        assert!(request.validate_for_mvp().is_ok());

        for assigned_ip in [
            "203.0.113.10;reboot",
            "../203.0.113.10",
            "999.0.0.1",
            "0.0.0.0",
            "255.255.255.255",
        ] {
            request.assigned_ip = Some(assigned_ip.into());
            let error = request
                .validate_for_mvp()
                .expect_err("malformed assigned_ip should fail validation");
            assert!(
                error.to_string().contains("assigned_ip"),
                "unexpected error for {assigned_ip}: {error}"
            );
        }
    }

    #[test]
    fn create_vm_preserves_and_validates_assigned_ipv4_network_metadata() {
        let value = serde_json::json!({
            "node_id": NodeId::new(),
            "vm_id": VmId::new(),
            "ip_pool_id": null,
            "plan_id": null,
            "assigned_ip": "192.0.2.2",
            "assigned_ip_prefix": 29,
            "assigned_gateway_ip": "192.0.2.1",
            "name": "demo",
            "image": "debian-12.qcow2",
            "ssh_public_key": null,
            "cpu_cores": 1,
            "memory_mb": 512,
            "disk_gb": 10
        });
        let request: CreateVmRequest =
            serde_json::from_value(value).expect("request should deserialize");

        request
            .validate_for_mvp()
            .expect("complete assigned IP metadata should be valid");
        let serialized = serde_json::to_value(&request).expect("request should serialize");
        assert_eq!(serialized["assigned_ip_prefix"], 29);
        assert_eq!(serialized["assigned_gateway_ip"], "192.0.2.1");

        for value in [
            serde_json::json!({
                "node_id": NodeId::new(),
                "vm_id": VmId::new(),
                "assigned_ip": "192.0.2.2",
                "assigned_ip_prefix": 29,
                "assigned_gateway_ip": null,
                "name": "demo",
                "image": "debian-12.qcow2",
                "cpu_cores": 1,
                "memory_mb": 512,
                "disk_gb": 10
            }),
            serde_json::json!({
                "node_id": NodeId::new(),
                "vm_id": VmId::new(),
                "assigned_ip": "192.0.2.2",
                "assigned_ip_prefix": 31,
                "assigned_gateway_ip": "192.0.2.1",
                "name": "demo",
                "image": "debian-12.qcow2",
                "cpu_cores": 1,
                "memory_mb": 512,
                "disk_gb": 10
            }),
            serde_json::json!({
                "node_id": NodeId::new(),
                "vm_id": VmId::new(),
                "assigned_ip": "192.0.2.2",
                "assigned_ip_prefix": 29,
                "assigned_gateway_ip": "198.51.100.1",
                "name": "demo",
                "image": "debian-12.qcow2",
                "cpu_cores": 1,
                "memory_mb": 512,
                "disk_gb": 10
            }),
        ] {
            let request: CreateVmRequest =
                serde_json::from_value(value).expect("request should deserialize");
            let error = request
                .validate_for_mvp()
                .expect_err("incomplete or inconsistent IP metadata should fail");
            assert!(
                error.to_string().contains("assigned"),
                "unexpected error: {error}"
            );
        }
    }

    #[test]
    fn agent_create_vm_task_requires_master_assigned_vm_id() {
        let mut request = CreateVmRequest {
            node_id: NodeId::new(),
            vm_id: None,
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
        };

        let error = TaskKind::CreateVm(request.clone())
            .validate_for_agent()
            .expect_err("agent create_vm task without vm_id should fail");
        assert!(
            error.to_string().contains("vm_id"),
            "unexpected error: {error}"
        );

        request.vm_id = Some(VmId::new());
        TaskKind::CreateVm(request)
            .validate_for_agent()
            .expect("agent create_vm task with vm_id should pass");
    }

    #[test]
    fn agent_task_validation_rejects_unsafe_reinstall_payloads() {
        for task in [
            TaskKind::ReinstallVm {
                vm_id: VmId::new(),
                name: "bad name".into(),
                image: "debian-12.qcow2".into(),
                ssh_public_key: None,
                disk_gb: 10,
            },
            TaskKind::ReinstallVm {
                vm_id: VmId::new(),
                name: "demo".into(),
                image: "../debian.qcow2".into(),
                ssh_public_key: None,
                disk_gb: 10,
            },
            TaskKind::ReinstallVm {
                vm_id: VmId::new(),
                name: "demo".into(),
                image: "debian-12.qcow2".into(),
                ssh_public_key: Some("ssh-ed25519 AAAA\nbad".into()),
                disk_gb: 10,
            },
            TaskKind::ReinstallVm {
                vm_id: VmId::new(),
                name: "demo".into(),
                image: "debian-12.qcow2".into(),
                ssh_public_key: None,
                disk_gb: 0,
            },
        ] {
            assert!(task.validate_for_agent().is_err());
        }

        let task = TaskKind::ReinstallVm {
            vm_id: VmId::new(),
            name: "demo".into(),
            image: "debian-12.qcow2".into(),
            ssh_public_key: Some(
                "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb user@example"
                    .into(),
            ),
            disk_gb: 10,
        };
        assert!(task.validate_for_agent().is_ok());
    }
}
