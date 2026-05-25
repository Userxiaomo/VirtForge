use std::time::Duration;

use vps_shared::{
    AgentTaskLogRequest, AgentTaskStatusRequest, HeartbeatRequest, HostPreflightCheck, TaskStatus,
};

use crate::{client::MasterClient, config::AgentConfig, redaction, resources, tasks};

const TERMINAL_STATUS_UPDATE_ATTEMPTS: usize = 3;
const TERMINAL_STATUS_UPDATE_RETRY_DELAY: Duration = Duration::from_secs(1);

pub struct HeartbeatLoop {
    config: AgentConfig,
    client: MasterClient,
}

impl HeartbeatLoop {
    pub fn new(config: AgentConfig, client: MasterClient) -> Self {
        Self { config, client }
    }

    pub async fn run_once_for_mvp(&self) -> anyhow::Result<()> {
        self.run_once().await
    }

    pub async fn run_forever(&self) -> anyhow::Result<()> {
        let mut ticker =
            tokio::time::interval(Duration::from_secs(self.config.heartbeat_interval_seconds));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

        loop {
            tokio::select! {
                _ = tokio::signal::ctrl_c() => {
                    tracing::info!("shutdown signal received");
                    return Ok(());
                }
                _ = ticker.tick() => {
                    if let Err(error) = self.run_once().await {
                        tracing::error!(
                            error = %redaction::redact_text(&error.to_string()),
                            "agent loop iteration failed"
                        );
                    }
                }
            }
        }
    }

    async fn run_once(&self) -> anyhow::Result<()> {
        let (libvirt_status, host_checks) = match self.config.executor.clone() {
            crate::config::ExecutorConfig::Libvirt {
                image_dir,
                network_name,
                bridge_name,
            } => {
                crate::libvirt::LibvirtExecutor::new(
                    self.config.data_dir.clone(),
                    image_dir,
                    network_name,
                    bridge_name,
                )
                .check_host_report_and_status()
                .await
            }
            crate::config::ExecutorConfig::Mock => {
                (crate::libvirt::LibvirtStatus::NotChecked, Vec::new())
            }
        };
        self.send_heartbeat(libvirt_status.clone(), host_checks)
            .await?;
        if let Some(task) = self.client.poll_task(self.config.node_id).await?.task {
            self.execute_mock_task(task, libvirt_status).await?;
        }
        Ok(())
    }

    async fn send_heartbeat(
        &self,
        libvirt_status: crate::libvirt::LibvirtStatus,
        host_checks: Vec<HostPreflightCheck>,
    ) -> anyhow::Result<()> {
        let resources = resources::collect(&self.config.data_dir);
        let request = HeartbeatRequest {
            node_id: self.config.node_id,
            agent_version: env!("CARGO_PKG_VERSION").into(),
            libvirt_status: crate::libvirt::LibvirtExecutor::status_label(&libvirt_status).into(),
            host_checks: sanitize_host_checks(host_checks),
            cpu_total: resources.cpu_total,
            cpu_used: resources.cpu_used,
            memory_total: resources.memory_total,
            memory_used: resources.memory_used,
            disk_total: resources.disk_total,
            disk_used: resources.disk_used,
            vm_count: resources.vm_count,
        };

        let response = self.client.heartbeat(request).await?;
        tracing::info!(accepted_at = %response.accepted_at, "heartbeat sent");
        Ok(())
    }

    async fn execute_mock_task(
        &self,
        task: vps_shared::TaskDto,
        libvirt_status: crate::libvirt::LibvirtStatus,
    ) -> anyhow::Result<()> {
        if let Err(error) = tasks::validate_for_execution(&self.config, &task) {
            self.report_assigned_task_failure(&task, &error).await?;
            return Err(error);
        }

        tracing::info!(
            libvirt_status = ?libvirt_status,
            task_id = ?task.id,
            "task execution starting"
        );
        self.client
            .append_task_log(
                task.id,
                AgentTaskLogRequest {
                    node_id: self.config.node_id,
                    message: "task executor started".into(),
                },
            )
            .await?;
        let running = self
            .client
            .update_task_status(
                task.id,
                AgentTaskStatusRequest {
                    node_id: self.config.node_id,
                    status: TaskStatus::Running,
                    error_message: None,
                },
            )
            .await?;
        tracing::info!(task_id = ?running.id, "mock task marked running");

        match tasks::execute(&self.config, &task).await {
            Ok(messages) => {
                for message in messages {
                    let message = redaction::redact_text(&message);
                    if let Err(error) = self
                        .client
                        .append_task_log(
                            task.id,
                            AgentTaskLogRequest {
                                node_id: self.config.node_id,
                                message,
                            },
                        )
                        .await
                    {
                        tracing::warn!(
                            task_id = ?task.id,
                            error = %redaction::redact_text(&error.to_string()),
                            "task result log append failed; continuing to terminal status"
                        );
                    }
                }
                let _done = self
                    .update_terminal_task_status(task.id, TaskStatus::Succeeded, None)
                    .await?;
                Ok(())
            }
            Err(error) => {
                let safe_error = redaction::redact_text(&error.to_string());
                self.update_terminal_task_status(
                    task.id,
                    TaskStatus::Failed,
                    Some(safe_error.clone()),
                )
                .await?;
                Err(error)
            }
        }
    }

    async fn report_assigned_task_failure(
        &self,
        task: &vps_shared::TaskDto,
        error: &anyhow::Error,
    ) -> anyhow::Result<()> {
        if task.node_id != self.config.node_id || task.status != TaskStatus::Assigned {
            return Ok(());
        }

        let safe_error = redaction::redact_text(&error.to_string());
        self.update_terminal_task_status(task.id, TaskStatus::Failed, Some(safe_error))
            .await?;
        Ok(())
    }

    async fn update_terminal_task_status(
        &self,
        task_id: vps_shared::TaskId,
        status: TaskStatus,
        error_message: Option<String>,
    ) -> anyhow::Result<vps_shared::TaskDto> {
        debug_assert!(matches!(
            status,
            TaskStatus::Succeeded | TaskStatus::Failed | TaskStatus::Canceled
        ));

        let mut last_error = None;
        for attempt in 1..=TERMINAL_STATUS_UPDATE_ATTEMPTS {
            match self
                .client
                .update_task_status(
                    task_id,
                    AgentTaskStatusRequest {
                        node_id: self.config.node_id,
                        status,
                        error_message: error_message.clone(),
                    },
                )
                .await
            {
                Ok(task) => return Ok(task),
                Err(error) => {
                    tracing::warn!(
                        task_id = ?task_id,
                        status = status.as_str(),
                        attempt,
                        error = %redaction::redact_text(&error.to_string()),
                        "terminal task status update failed"
                    );
                    last_error = Some(error);
                    if attempt < TERMINAL_STATUS_UPDATE_ATTEMPTS {
                        tokio::time::sleep(TERMINAL_STATUS_UPDATE_RETRY_DELAY).await;
                    }
                }
            }
        }

        Err(last_error.expect("terminal status update attempts should run at least once"))
    }
}

fn sanitize_host_checks(host_checks: Vec<HostPreflightCheck>) -> Vec<HostPreflightCheck> {
    host_checks
        .into_iter()
        .map(|mut check| {
            check.message = redaction::redact_text(&check.message);
            check
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use chrono::Utc;
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
        task::JoinHandle,
    };
    use vps_shared::{
        AgentTaskStatusRequest, CreateVmRequest, HostPreflightCheck, NodeId, TaskDto, TaskId,
        TaskKind, TaskStatus, VmId,
    };

    use super::{sanitize_host_checks, HeartbeatLoop};
    use crate::{
        client::MasterClient,
        config::{AgentConfig, ExecutorConfig},
        libvirt::LibvirtStatus,
    };

    #[test]
    fn sanitize_host_checks_redacts_sensitive_message_values() {
        let checks = vec![HostPreflightCheck {
            name: "libvirt".into(),
            status: "failed".into(),
            message: "virsh failed: password=hunter2 credential=ag_plaintext".into(),
        }];

        let sanitized = sanitize_host_checks(checks);

        assert_eq!(sanitized.len(), 1);
        assert_eq!(sanitized[0].name, "libvirt");
        assert_eq!(sanitized[0].status, "failed");
        assert!(!sanitized[0].message.contains("hunter2"));
        assert!(!sanitized[0].message.contains("ag_plaintext"));
        assert!(sanitized[0].message.contains("password=[REDACTED]"));
        assert!(sanitized[0].message.contains("credential=[REDACTED]"));
    }

    #[tokio::test]
    async fn task_validation_failure_reports_failed_without_starting_execution() {
        let config = mock_config();
        let task = create_vm_task_missing_vm_id(config.node_id);
        let failed_task = TaskDto {
            status: TaskStatus::Failed,
            error_message: Some("agent create_vm task must include master-assigned vm_id".into()),
            ..task.clone()
        };
        let (base_url, request_handle) = spawn_status_capture_server(&failed_task).await;
        let client = test_master_client(base_url);
        let heartbeat = HeartbeatLoop::new(config, client);

        let error = heartbeat
            .execute_mock_task(task.clone(), LibvirtStatus::NotChecked)
            .await
            .expect_err("invalid task payload should still fail local execution");

        assert!(
            error.to_string().contains("vm_id"),
            "unexpected error: {error}"
        );
        let request = tokio::time::timeout(Duration::from_secs(2), request_handle)
            .await
            .expect("agent should report failed status to master")
            .expect("status capture server should finish");
        assert_eq!(request.path, format!("/api/agent/tasks/{}/status", task.id));

        let body: AgentTaskStatusRequest =
            serde_json::from_str(&request.body).expect("status request body should be JSON");
        assert_eq!(body.node_id, task.node_id);
        assert_eq!(body.status, TaskStatus::Failed);
        assert!(
            body.error_message
                .as_deref()
                .is_some_and(|message| message.contains("vm_id")),
            "failure status should include the validation diagnostic"
        );
    }

    #[tokio::test]
    async fn successful_execution_reports_succeeded_even_when_result_log_append_fails() {
        let config = mock_config();
        let task = start_vm_task(config.node_id);
        let (base_url, request_handle) = spawn_log_failure_then_success_server(&task).await;
        let client = test_master_client(base_url);
        let heartbeat = HeartbeatLoop::new(config, client);

        heartbeat
            .execute_mock_task(task.clone(), LibvirtStatus::NotChecked)
            .await
            .expect("result log append failure should not block terminal status");

        let requests = tokio::time::timeout(Duration::from_secs(2), request_handle)
            .await
            .expect("agent should report succeeded status after result log failure")
            .expect("log failure capture server should finish");
        let status_requests = requests
            .iter()
            .filter(|request| request.path == format!("/api/agent/tasks/{}/status", task.id))
            .map(|request| {
                serde_json::from_str::<AgentTaskStatusRequest>(&request.body)
                    .expect("status request body should be JSON")
            })
            .collect::<Vec<_>>();

        assert_eq!(status_requests.len(), 2);
        assert_eq!(status_requests[0].status, TaskStatus::Running);
        assert_eq!(status_requests[1].status, TaskStatus::Succeeded);
    }

    #[tokio::test]
    async fn terminal_succeeded_status_is_retried_after_transient_failure() {
        let config = mock_config();
        let task = start_vm_task(config.node_id);
        let (base_url, request_handle) = spawn_succeeded_status_retry_server(&task).await;
        let client = test_master_client(base_url);
        let heartbeat = HeartbeatLoop::new(config, client);

        heartbeat
            .execute_mock_task(task.clone(), LibvirtStatus::NotChecked)
            .await
            .expect("transient terminal status failure should be retried");

        let requests = tokio::time::timeout(Duration::from_secs(3), request_handle)
            .await
            .expect("agent should retry succeeded status")
            .expect("succeeded retry capture server should finish");
        let succeeded_attempts = requests
            .iter()
            .filter(|request| request.path == format!("/api/agent/tasks/{}/status", task.id))
            .filter(|request| {
                serde_json::from_str::<AgentTaskStatusRequest>(&request.body)
                    .expect("status request body should be JSON")
                    .status
                    == TaskStatus::Succeeded
            })
            .count();

        assert_eq!(succeeded_attempts, 2);
    }

    #[derive(Debug)]
    struct CapturedRequest {
        path: String,
        body: String,
    }

    async fn spawn_status_capture_server(
        response_task: &TaskDto,
    ) -> (String, JoinHandle<CapturedRequest>) {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind status capture server");
        let address = listener.local_addr().expect("read listener address");
        let response_body = serde_json::to_string(response_task).expect("serialize task response");
        let handle = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept status request");
            let request = read_http_request(&mut socket).await;
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                response_body.len(),
                response_body
            );
            socket
                .write_all(response.as_bytes())
                .await
                .expect("write status response");
            request
        });

        (format!("http://{address}"), handle)
    }

    async fn spawn_succeeded_status_retry_server(
        task: &TaskDto,
    ) -> (String, JoinHandle<Vec<CapturedRequest>>) {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind status retry capture server");
        let address = listener.local_addr().expect("read listener address");
        let task = task.clone();
        let handle = tokio::spawn(async move {
            let mut requests = Vec::new();
            let mut rejected_succeeded_once = false;
            loop {
                let (mut socket, _) = listener.accept().await.expect("accept agent request");
                let request = read_http_request(&mut socket).await;
                let (response, should_finish) = response_for_succeeded_retry_request(
                    &task,
                    &request,
                    &mut rejected_succeeded_once,
                );
                socket
                    .write_all(response.as_bytes())
                    .await
                    .expect("write agent response");
                requests.push(request);
                if should_finish {
                    return requests;
                }
            }
        });

        (format!("http://{address}"), handle)
    }

    fn response_for_succeeded_retry_request(
        task: &TaskDto,
        request: &CapturedRequest,
        rejected_succeeded_once: &mut bool,
    ) -> (String, bool) {
        if request.path.ends_with("/logs") {
            return (empty_response(200, false).bytes, false);
        }

        let status_request = serde_json::from_str::<AgentTaskStatusRequest>(&request.body)
            .expect("status request body should be JSON");
        if status_request.status == TaskStatus::Succeeded && !*rejected_succeeded_once {
            *rejected_succeeded_once = true;
            return (empty_response(500, false).bytes, false);
        }

        let response_task = TaskDto {
            status: status_request.status,
            error_message: status_request.error_message.clone(),
            ..task.clone()
        };
        let should_finish = status_request.status == TaskStatus::Succeeded;
        (
            json_response(&response_task, should_finish).bytes,
            should_finish,
        )
    }

    async fn spawn_log_failure_then_success_server(
        task: &TaskDto,
    ) -> (String, JoinHandle<Vec<CapturedRequest>>) {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind log failure capture server");
        let address = listener.local_addr().expect("read listener address");
        let task = task.clone();
        let handle = tokio::spawn(async move {
            let mut requests = Vec::new();
            loop {
                let (mut socket, _) = listener.accept().await.expect("accept agent request");
                let request = read_http_request(&mut socket).await;
                let response = response_for_agent_request(&task, &request);
                let should_finish = response.should_finish;
                socket
                    .write_all(response.bytes.as_bytes())
                    .await
                    .expect("write agent response");
                requests.push(request);
                if should_finish {
                    return requests;
                }
            }
        });

        (format!("http://{address}"), handle)
    }

    struct TestHttpResponse {
        bytes: String,
        should_finish: bool,
    }

    fn response_for_agent_request(task: &TaskDto, request: &CapturedRequest) -> TestHttpResponse {
        if request.path.ends_with("/logs") {
            if request.body.contains("task executor started") {
                return empty_response(200, false);
            }
            return empty_response(500, false);
        }

        let status_request = serde_json::from_str::<AgentTaskStatusRequest>(&request.body)
            .expect("status request body should be JSON");
        let response_task = TaskDto {
            status: status_request.status,
            error_message: status_request.error_message.clone(),
            ..task.clone()
        };
        json_response(
            &response_task,
            status_request.status == TaskStatus::Succeeded,
        )
    }

    fn empty_response(status: u16, should_finish: bool) -> TestHttpResponse {
        let reason = if status == 200 {
            "OK"
        } else {
            "Internal Server Error"
        };
        TestHttpResponse {
            bytes: format!(
                "HTTP/1.1 {status} {reason}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            ),
            should_finish,
        }
    }

    fn json_response(body: &TaskDto, should_finish: bool) -> TestHttpResponse {
        let body = serde_json::to_string(body).expect("serialize task response");
        TestHttpResponse {
            bytes: format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            ),
            should_finish,
        }
    }

    async fn read_http_request(socket: &mut tokio::net::TcpStream) -> CapturedRequest {
        let mut buffer = Vec::new();
        let mut chunk = [0_u8; 1024];
        loop {
            let count = socket.read(&mut chunk).await.expect("read request");
            if count == 0 {
                break;
            }
            buffer.extend_from_slice(&chunk[..count]);
            if let Some((body_start, content_length)) = http_body_bounds(&buffer) {
                if buffer.len() >= body_start + content_length {
                    break;
                }
            }
        }

        let text = String::from_utf8(buffer).expect("request should be UTF-8");
        let header_end = text.find("\r\n\r\n").expect("request should have headers");
        let headers = &text[..header_end];
        let request_line = headers.lines().next().expect("request line");
        let path = request_line
            .split_whitespace()
            .nth(1)
            .expect("request path")
            .to_owned();
        let content_length = content_length_from_headers(headers);
        let body_start = header_end + 4;
        let body = text[body_start..body_start + content_length].to_owned();

        CapturedRequest { path, body }
    }

    fn http_body_bounds(buffer: &[u8]) -> Option<(usize, usize)> {
        let marker = b"\r\n\r\n";
        let header_end = buffer
            .windows(marker.len())
            .position(|window| window == marker)?;
        let headers = std::str::from_utf8(&buffer[..header_end]).ok()?;
        Some((
            header_end + marker.len(),
            content_length_from_headers(headers),
        ))
    }

    fn content_length_from_headers(headers: &str) -> usize {
        headers
            .lines()
            .find_map(|line| {
                let (name, value) = line.split_once(':')?;
                if name.eq_ignore_ascii_case("content-length") {
                    value.trim().parse::<usize>().ok()
                } else {
                    None
                }
            })
            .unwrap_or(0)
    }

    fn start_vm_task(node_id: NodeId) -> TaskDto {
        let now = Utc::now();
        TaskDto {
            id: TaskId::new(),
            node_id,
            kind: TaskKind::StartVm { vm_id: VmId::new() },
            status: TaskStatus::Assigned,
            error_message: None,
            created_at: now,
            updated_at: now,
        }
    }

    fn create_vm_task_missing_vm_id(node_id: NodeId) -> TaskDto {
        let now = Utc::now();
        TaskDto {
            id: TaskId::new(),
            node_id,
            kind: TaskKind::CreateVm(CreateVmRequest {
                node_id,
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
        }
    }

    fn mock_config() -> AgentConfig {
        AgentConfig {
            master_base_url: "https://panel.example.com".into(),
            node_id: NodeId::new(),
            data_dir: "/var/lib/vps-agent".into(),
            heartbeat_interval_seconds: 30,
            ca_cert_path: None,
            client_identity_path: None,
            executor: ExecutorConfig::Mock,
            bootstrap_token: None,
            credential: None,
        }
    }

    fn test_master_client(base_url: String) -> MasterClient {
        MasterClient::new(base_url, Some("ag_test-credential.1".into()), None, None)
            .expect("build test client")
    }
}
