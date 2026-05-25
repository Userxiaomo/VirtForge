use vps_shared::{TaskDto, TaskKind, TaskStatus};

use crate::{
    config::{AgentConfig, ExecutorConfig},
    libvirt::LibvirtExecutor,
};

pub fn validate_for_execution(config: &AgentConfig, task: &TaskDto) -> anyhow::Result<()> {
    if task.node_id != config.node_id {
        anyhow::bail!("task node_id does not match local agent node_id");
    }
    if task.status != TaskStatus::Assigned {
        anyhow::bail!(
            "task status must be assigned before agent execution, got {}",
            task.status.as_str()
        );
    }
    if let TaskKind::CreateVm(request) = &task.kind {
        if request.node_id != task.node_id {
            anyhow::bail!("create_vm payload node_id does not match task node_id");
        }
    }
    task.kind.validate_for_agent()?;
    Ok(())
}

pub async fn execute(config: &AgentConfig, task: &TaskDto) -> anyhow::Result<Vec<String>> {
    validate_for_execution(config, task)?;
    match &config.executor {
        ExecutorConfig::Mock => execute_mock(&task.kind).await,
        ExecutorConfig::Libvirt {
            image_dir,
            network_name,
            bridge_name,
        } => {
            let executor = LibvirtExecutor::new(
                config.data_dir.clone(),
                image_dir.clone(),
                network_name.clone(),
                bridge_name.clone(),
            );
            executor.execute(&task.kind).await
        }
    }
}

async fn execute_mock(task: &TaskKind) -> anyhow::Result<Vec<String>> {
    Ok(vec![
        format!("mock executor accepted task: {}", task_name(task)),
        "mock executor finished successfully".into(),
    ])
}

fn task_name(task: &TaskKind) -> &'static str {
    match task {
        TaskKind::CreateVm(_) => "create_vm",
        TaskKind::StartVm { .. } => "start_vm",
        TaskKind::StopVm { .. } => "stop_vm",
        TaskKind::RebootVm { .. } => "reboot_vm",
        TaskKind::ReinstallVm { .. } => "reinstall_vm",
        TaskKind::DeleteVm { .. } => "delete_vm",
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use chrono::Utc;
    use vps_shared::{CreateVmRequest, NodeId, TaskDto, TaskId, TaskKind, TaskStatus, VmId};

    use super::{execute, validate_for_execution};
    use crate::config::{AgentConfig, ExecutorConfig};

    #[tokio::test]
    async fn execute_rejects_task_for_different_node_before_mock_executor() {
        let config = mock_config();
        let now = Utc::now();
        let task = TaskDto {
            id: TaskId::new(),
            node_id: NodeId::new(),
            kind: TaskKind::StartVm { vm_id: VmId::new() },
            status: TaskStatus::Assigned,
            error_message: None,
            created_at: now,
            updated_at: now,
        };

        let error = execute(&config, &task)
            .await
            .expect_err("wrong-node task should fail before mock execution");

        assert!(
            error.to_string().contains("node_id"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn validate_for_execution_rejects_wrong_node_without_executor() {
        let config = mock_config();
        let now = Utc::now();
        let task = TaskDto {
            id: TaskId::new(),
            node_id: NodeId::new(),
            kind: TaskKind::StartVm { vm_id: VmId::new() },
            status: TaskStatus::Assigned,
            error_message: None,
            created_at: now,
            updated_at: now,
        };

        let error = validate_for_execution(&config, &task).expect_err("wrong node should fail");
        assert!(
            error.to_string().contains("node_id"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn validate_for_execution_rejects_non_assigned_task_status_without_executor() {
        let config = mock_config();
        let now = Utc::now();

        for status in [
            TaskStatus::Pending,
            TaskStatus::Running,
            TaskStatus::Succeeded,
            TaskStatus::Failed,
            TaskStatus::Canceled,
        ] {
            let task = TaskDto {
                id: TaskId::new(),
                node_id: config.node_id,
                kind: TaskKind::StartVm { vm_id: VmId::new() },
                status,
                error_message: None,
                created_at: now,
                updated_at: now,
            };

            let error = validate_for_execution(&config, &task)
                .expect_err("non-assigned task status should fail");
            assert!(
                error.to_string().contains("status"),
                "unexpected error for {status:?}: {error}"
            );
        }
    }

    #[test]
    fn validate_for_execution_rejects_invalid_payload_without_executor() {
        let config = mock_config();
        let task = reinstall_task(config.node_id, "bad name", "debian-12.qcow2", None, 10);

        let error =
            validate_for_execution(&config, &task).expect_err("invalid payload should fail");
        assert!(
            error.to_string().contains("vm name"),
            "unexpected error: {error}"
        );
    }

    #[tokio::test]
    async fn execute_rejects_unsafe_reinstall_name_before_mock_executor() {
        let config = mock_config();
        let task = reinstall_task(config.node_id, "bad name", "debian-12.qcow2", None, 10);

        let error = execute(&config, &task)
            .await
            .expect_err("unsafe reinstall name should fail before mock execution");

        assert!(
            error.to_string().contains("vm name"),
            "unexpected error: {error}"
        );
    }

    #[tokio::test]
    async fn execute_rejects_unsafe_reinstall_ssh_key_before_mock_executor() {
        let config = mock_config();
        let task = reinstall_task(
            config.node_id,
            "demo",
            "debian-12.qcow2",
            Some("ssh-ed25519 AAAA\nbad".into()),
            10,
        );

        let error = execute(&config, &task)
            .await
            .expect_err("unsafe reinstall ssh key should fail before mock execution");

        assert!(
            error.to_string().contains("ssh public key"),
            "unexpected error: {error}"
        );
    }

    #[tokio::test]
    async fn execute_rejects_create_vm_without_vm_id_before_mock_executor() {
        let config = mock_config();
        let now = Utc::now();
        let task = TaskDto {
            id: TaskId::new(),
            node_id: config.node_id,
            kind: TaskKind::CreateVm(CreateVmRequest {
                node_id: config.node_id,
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
            }),
            status: TaskStatus::Assigned,
            error_message: None,
            created_at: now,
            updated_at: now,
        };

        let error = execute(&config, &task)
            .await
            .expect_err("missing vm_id should fail before mock execution");

        assert!(
            error.to_string().contains("vm_id"),
            "unexpected error: {error}"
        );
    }

    #[tokio::test]
    async fn execute_rejects_create_vm_payload_for_different_node_before_mock_executor() {
        let config = mock_config();
        let now = Utc::now();
        let task = TaskDto {
            id: TaskId::new(),
            node_id: config.node_id,
            kind: TaskKind::CreateVm(CreateVmRequest {
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
            }),
            status: TaskStatus::Assigned,
            error_message: None,
            created_at: now,
            updated_at: now,
        };

        let error = execute(&config, &task)
            .await
            .expect_err("payload node_id mismatch should fail before mock execution");

        assert!(
            error.to_string().contains("node_id"),
            "unexpected error: {error}"
        );
    }

    fn reinstall_task(
        node_id: NodeId,
        name: &str,
        image: &str,
        ssh_public_key: Option<String>,
        disk_gb: u32,
    ) -> TaskDto {
        let now = Utc::now();
        TaskDto {
            id: TaskId::new(),
            node_id,
            kind: TaskKind::ReinstallVm {
                vm_id: VmId::new(),
                name: name.into(),
                image: image.into(),
                ssh_public_key,
                disk_gb,
            },
            status: TaskStatus::Assigned,
            error_message: None,
            created_at: now,
            updated_at: now,
        }
    }

    fn mock_config() -> AgentConfig {
        AgentConfig {
            master_base_url: "https://panel.example.com".into(),
            node_id: NodeId::new(),
            data_dir: PathBuf::from("/var/lib/vps-agent"),
            heartbeat_interval_seconds: 30,
            ca_cert_path: None,
            client_identity_path: None,
            executor: ExecutorConfig::Mock,
            bootstrap_token: None,
            credential: None,
        }
    }
}
