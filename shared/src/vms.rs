use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::{IpPoolId, NodeId, PlanId, TaskId, TaskStatus, VmId};

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum VmStatus {
    Provisioning,
    Running,
    Stopped,
    Deleting,
    Deleted,
    Error,
}

impl VmStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Provisioning => "provisioning",
            Self::Running => "running",
            Self::Stopped => "stopped",
            Self::Deleting => "deleting",
            Self::Deleted => "deleted",
            Self::Error => "error",
        }
    }

    pub fn from_db(value: &str) -> Option<Self> {
        match value {
            "provisioning" => Some(Self::Provisioning),
            "running" => Some(Self::Running),
            "stopped" => Some(Self::Stopped),
            "deleting" => Some(Self::Deleting),
            "deleted" => Some(Self::Deleted),
            "error" => Some(Self::Error),
            _ => None,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct VmDto {
    pub id: VmId,
    pub node_id: NodeId,
    pub ip_pool_id: Option<IpPoolId>,
    pub plan_id: Option<PlanId>,
    pub assigned_ip: Option<String>,
    pub name: String,
    pub image: String,
    pub ssh_public_key: Option<String>,
    pub cpu_cores: u16,
    pub memory_mb: u32,
    pub disk_gb: u32,
    pub status: VmStatus,
    pub last_task_id: Option<TaskId>,
    pub last_task_status: Option<TaskStatus>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub deleted_at: Option<DateTime<Utc>>,
}

#[cfg(test)]
mod tests {
    use chrono::Utc;

    use crate::TaskStatus;

    use super::*;

    #[test]
    fn vm_dto_serializes_last_task_status_for_authoritative_action_state() {
        let now = Utc::now();
        let dto = VmDto {
            id: VmId::new(),
            node_id: NodeId::new(),
            ip_pool_id: None,
            plan_id: None,
            assigned_ip: None,
            name: "demo".into(),
            image: "debian-12.qcow2".into(),
            ssh_public_key: None,
            cpu_cores: 1,
            memory_mb: 512,
            disk_gb: 10,
            status: VmStatus::Running,
            last_task_id: Some(TaskId::new()),
            last_task_status: Some(TaskStatus::Running),
            created_at: now,
            updated_at: now,
            deleted_at: None,
        };

        let value = serde_json::to_value(dto).expect("VmDto should serialize");

        assert_eq!(value["last_task_status"], "running");
    }
}
