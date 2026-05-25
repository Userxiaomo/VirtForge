use std::fmt;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::{
    AgentCredentialPlaintext, BootstrapTokenPlaintext, CreateVmRequest, ImageId, IpPoolId, NodeId,
    TaskId, TaskKind, TaskStatus, VmId,
};

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct HealthResponse {
    pub service: String,
    pub status: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct CreateNodeRequest {
    pub name: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct UpdateNodeSchedulingRequest {
    pub enabled: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct NodeDto {
    pub id: NodeId,
    pub name: String,
    pub status: String,
    pub scheduling_enabled: bool,
    pub agent_version: Option<String>,
    pub last_seen_at: Option<DateTime<Utc>>,
    pub libvirt_status: String,
    pub host_checks: Vec<HostPreflightCheck>,
    pub cpu_total: u64,
    pub cpu_used: u64,
    pub memory_total: u64,
    pub memory_used: u64,
    pub disk_total: u64,
    pub disk_used: u64,
    pub committed_cpu: u64,
    pub committed_memory_mb: u64,
    pub committed_disk_gb: u64,
    pub vm_count: u32,
    pub created_at: DateTime<Utc>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct AuditLogDto {
    pub id: i64,
    pub request_id: Option<String>,
    pub actor_id: String,
    pub actor_role: String,
    pub node_id: Option<NodeId>,
    pub task_id: Option<TaskId>,
    pub action: String,
    pub result: String,
    pub detail: serde_json::Value,
    pub created_at: DateTime<Utc>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct CreateBootstrapTokenRequest {
    pub expires_at: DateTime<Utc>,
}

#[derive(Clone, Deserialize, Serialize)]
pub struct CreateBootstrapTokenResponse {
    pub node_id: NodeId,
    pub expires_at: DateTime<Utc>,
    pub bootstrap_token: BootstrapTokenPlaintext,
    pub install_command: String,
}

impl fmt::Debug for CreateBootstrapTokenResponse {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CreateBootstrapTokenResponse")
            .field("node_id", &self.node_id)
            .field("expires_at", &self.expires_at)
            .field("bootstrap_token", &self.bootstrap_token)
            .field("install_command", &"[REDACTED INSTALL COMMAND]")
            .finish()
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct AgentRegisterRequest {
    pub node_id: NodeId,
    pub bootstrap_token: BootstrapTokenPlaintext,
    pub agent_version: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct AgentRegisterResponse {
    pub node_id: NodeId,
    pub credential: AgentCredentialPlaintext,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct HostPreflightCheck {
    pub name: String,
    pub status: String,
    pub message: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct HeartbeatRequest {
    pub node_id: NodeId,
    pub agent_version: String,
    pub libvirt_status: String,
    #[serde(default)]
    pub host_checks: Vec<HostPreflightCheck>,
    pub cpu_total: u64,
    pub cpu_used: u64,
    pub memory_total: u64,
    pub memory_used: u64,
    pub disk_total: u64,
    pub disk_used: u64,
    pub vm_count: u32,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct HeartbeatResponse {
    pub accepted_at: DateTime<Utc>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct TaskDto {
    pub id: TaskId,
    pub node_id: NodeId,
    pub kind: TaskKind,
    pub status: TaskStatus,
    pub error_message: Option<String>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct TaskLogDto {
    pub id: i64,
    pub task_id: TaskId,
    pub node_id: NodeId,
    pub message: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct CreateVmTaskRequest {
    pub vm: CreateVmRequest,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct CreateIpPoolRequest {
    pub name: String,
    pub cidr: String,
    pub gateway_ip: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct CreateImageRequest {
    pub name: String,
    pub file_name: String,
    #[serde(default)]
    pub enabled: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct UpdateImageEnabledRequest {
    pub enabled: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ImageDto {
    pub id: ImageId,
    pub name: String,
    pub file_name: String,
    pub enabled: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct IpPoolDto {
    pub id: IpPoolId,
    pub name: String,
    pub cidr: String,
    pub gateway_ip: String,
    pub allocated_count: i64,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct VmActionTaskRequest {
    pub node_id: NodeId,
    pub vm_id: VmId,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ReinstallVmTaskRequest {
    pub node_id: NodeId,
    pub vm_id: VmId,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct AgentPollTaskRequest {
    pub node_id: NodeId,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct AgentPollTaskResponse {
    pub task: Option<TaskDto>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct AgentTaskStatusRequest {
    pub node_id: NodeId,
    pub status: TaskStatus,
    pub error_message: Option<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct AgentTaskLogRequest {
    pub node_id: NodeId,
    pub message: String,
}

#[cfg(test)]
mod tests {
    use chrono::Utc;

    use super::*;

    #[test]
    fn bootstrap_token_response_debug_redacts_install_command_token() {
        let response = CreateBootstrapTokenResponse {
            node_id: NodeId::new(),
            expires_at: Utc::now(),
            bootstrap_token: BootstrapTokenPlaintext("bt_plaintext".into()),
            install_command:
                "curl https://master/install.sh | sudo bash -s -- --bootstrap-token bt_plaintext"
                    .into(),
        };

        let debug = format!("{response:?}");

        assert!(!debug.contains("bt_plaintext"));
        assert!(!debug.contains("--bootstrap-token"));
    }
}
