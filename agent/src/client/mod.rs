use std::{path::Path, time::Duration};

use anyhow::Context;
use chrono::Utc;
use reqwest::{redirect::Policy, Certificate, Client, Identity};
use serde::de::DeserializeOwned;
use uuid::Uuid;
use vps_shared::{
    sign_agent_request, AgentPollTaskRequest, AgentPollTaskResponse, AgentRegisterRequest,
    AgentRegisterResponse, AgentTaskLogRequest, AgentTaskStatusRequest, HeartbeatRequest,
    HeartbeatResponse, NodeId, TaskId,
};

const DEFAULT_HTTP_TIMEOUT_SECONDS: u64 = 30;
const MIN_HTTP_TIMEOUT_SECONDS: u64 = 1;
const MAX_HTTP_TIMEOUT_SECONDS: u64 = 300;

#[derive(Clone)]
pub struct MasterClient {
    pub base_url: String,
    http: Client,
    credential: Option<String>,
}

impl MasterClient {
    pub fn new(
        base_url: String,
        credential: Option<String>,
        ca_cert_path: Option<&Path>,
        client_identity_path: Option<&Path>,
    ) -> anyhow::Result<Self> {
        let timeout = configured_http_timeout()?;
        Self::new_with_timeout(
            base_url,
            credential,
            ca_cert_path,
            client_identity_path,
            timeout,
        )
    }

    fn new_with_timeout(
        base_url: String,
        credential: Option<String>,
        ca_cert_path: Option<&Path>,
        client_identity_path: Option<&Path>,
        timeout: Duration,
    ) -> anyhow::Result<Self> {
        let mut builder = Client::builder()
            .use_rustls_tls()
            .timeout(timeout)
            .redirect(Policy::none());
        if let Some(path) = ca_cert_path {
            let ca_pem = std::fs::read(path)
                .with_context(|| format!("failed to read CA certificate at {}", path.display()))?;
            let ca_cert = Certificate::from_pem(&ca_pem)
                .with_context(|| format!("failed to parse CA certificate at {}", path.display()))?;
            builder = builder.add_root_certificate(ca_cert);
        }
        if let Some(path) = client_identity_path {
            let identity_pem = std::fs::read(path)
                .with_context(|| format!("failed to read client identity at {}", path.display()))?;
            let identity = Identity::from_pem(&identity_pem).with_context(|| {
                format!("failed to parse client identity at {}", path.display())
            })?;
            builder = builder.identity(identity);
        }

        let http = builder.build().context("failed to build HTTP client")?;

        Ok(Self {
            base_url,
            http,
            credential,
        })
    }

    pub async fn register(
        &self,
        node_id: NodeId,
        bootstrap_token: String,
        agent_version: String,
    ) -> anyhow::Result<AgentRegisterResponse> {
        self.post_json(
            "/api/agent/register",
            &AgentRegisterRequest {
                node_id,
                bootstrap_token: vps_shared::BootstrapTokenPlaintext(bootstrap_token),
                agent_version,
            },
            None,
        )
        .await
    }

    pub async fn heartbeat(&self, request: HeartbeatRequest) -> anyhow::Result<HeartbeatResponse> {
        self.post_json(
            "/api/agent/heartbeat",
            &request,
            Some(self.required_credential()?),
        )
        .await
    }

    pub async fn poll_task(&self, node_id: NodeId) -> anyhow::Result<AgentPollTaskResponse> {
        self.post_json(
            "/api/agent/tasks/poll",
            &AgentPollTaskRequest { node_id },
            Some(self.required_credential()?),
        )
        .await
    }

    pub async fn update_task_status(
        &self,
        task_id: TaskId,
        request: AgentTaskStatusRequest,
    ) -> anyhow::Result<vps_shared::TaskDto> {
        self.post_json(
            &format!("/api/agent/tasks/{task_id}/status"),
            &request,
            Some(self.required_credential()?),
        )
        .await
    }

    pub async fn append_task_log(
        &self,
        task_id: TaskId,
        request: AgentTaskLogRequest,
    ) -> anyhow::Result<()> {
        let path = format!("/api/agent/tasks/{task_id}/logs");
        let credential = self.required_credential()?;
        let response = self
            .send_json_request(&path, &request, Some(credential))
            .await?;
        if response.status().is_success() {
            Ok(())
        } else {
            Err(anyhow::anyhow!(
                "task log request failed with {}",
                response.status()
            ))
        }
    }

    async fn post_json<T: serde::Serialize, R: DeserializeOwned>(
        &self,
        path: &str,
        body: &T,
        credential_header: Option<String>,
    ) -> anyhow::Result<R> {
        let response = self
            .send_json_request(path, body, credential_header)
            .await?;
        if !response.status().is_success() {
            return Err(anyhow::anyhow!("request failed with {}", response.status()));
        }

        response
            .json::<R>()
            .await
            .context("failed to decode master response")
    }

    async fn send_json_request<T: serde::Serialize>(
        &self,
        path: &str,
        body: &T,
        credential_header: Option<String>,
    ) -> anyhow::Result<reqwest::Response> {
        let url = format!("{}{}", self.base_url.trim_end_matches('/'), path);
        let body = serde_json::to_vec(body).context("failed to encode request body")?;
        let mut request = self
            .http
            .post(url)
            .header("Content-Type", "application/json")
            .body(body.clone());

        if let Some(credential) = credential_header {
            let timestamp = Utc::now().timestamp();
            let nonce = Uuid::new_v4().simple().to_string();
            let signature = sign_agent_request(&credential, "POST", path, &body, timestamp, &nonce)
                .context("failed to sign agent request")?;
            request = request
                .header("X-Agent-Credential", credential)
                .header("X-Agent-Timestamp", timestamp.to_string())
                .header("X-Agent-Nonce", nonce)
                .header("X-Agent-Signature", signature);
        }

        request.send().await.context("failed to send request")
    }

    fn required_credential(&self) -> anyhow::Result<String> {
        self.credential
            .clone()
            .context("agent credential is missing")
    }
}

fn configured_http_timeout() -> anyhow::Result<Duration> {
    let value = match std::env::var("VPS_AGENT_HTTP_TIMEOUT_SECONDS") {
        Ok(value) => value,
        Err(std::env::VarError::NotPresent) => DEFAULT_HTTP_TIMEOUT_SECONDS.to_string(),
        Err(error) => return Err(error).context("VPS_AGENT_HTTP_TIMEOUT_SECONDS is invalid UTF-8"),
    };
    let seconds = value
        .parse::<u64>()
        .context("VPS_AGENT_HTTP_TIMEOUT_SECONDS must be an integer")?;
    if !(MIN_HTTP_TIMEOUT_SECONDS..=MAX_HTTP_TIMEOUT_SECONDS).contains(&seconds) {
        anyhow::bail!(
            "VPS_AGENT_HTTP_TIMEOUT_SECONDS must be between {MIN_HTTP_TIMEOUT_SECONDS} and {MAX_HTTP_TIMEOUT_SECONDS}"
        );
    }
    Ok(Duration::from_secs(seconds))
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, Instant};

    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };
    use vps_shared::{
        AgentTaskLogRequest, AgentTaskStatusRequest, HeartbeatRequest, NodeId, TaskId, TaskStatus,
    };

    use super::MasterClient;

    #[tokio::test]
    async fn master_client_uses_bounded_timeout_for_silent_peers() {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind silent test server");
        let address = listener.local_addr().expect("read listener address");
        let _server = tokio::spawn(async move {
            let _connection = listener.accept().await;
            tokio::time::sleep(Duration::from_secs(5)).await;
        });

        let client = MasterClient::new_with_timeout(
            format!("http://{address}"),
            None,
            None,
            None,
            Duration::from_secs(1),
        )
        .expect("build master client");
        let started = Instant::now();
        let result = tokio::time::timeout(
            Duration::from_secs(2),
            client.register(NodeId::new(), "bt_timeout".into(), "test-agent".into()),
        )
        .await;

        assert!(
            matches!(result, Ok(Err(_))),
            "request should fail from the client timeout, not the test timeout"
        );
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "client timeout did not fire before the test guard"
        );
    }

    #[tokio::test]
    async fn authenticated_agent_requests_require_credential_before_network() {
        let node_id = NodeId::new();
        let task_id = TaskId::new();

        for call in [
            AuthenticatedCall::Heartbeat,
            AuthenticatedCall::PollTask,
            AuthenticatedCall::UpdateTaskStatus,
            AuthenticatedCall::AppendTaskLog,
        ] {
            let (base_url, request_handle) = spawn_single_request_rejecting_server().await;
            let client =
                MasterClient::new_with_timeout(base_url, None, None, None, Duration::from_secs(1))
                    .expect("build master client without credential");

            let error = call
                .run(&client, node_id, task_id)
                .await
                .expect_err("authenticated request should require a local credential");

            assert!(
                error.to_string().contains("agent credential is missing"),
                "unexpected error for {}: {error}",
                call.name()
            );
            let captured_request = request_handle
                .await
                .expect("request capture server should finish");
            assert!(
                captured_request.is_none(),
                "{} reached the network without a credential: {captured_request:?}",
                call.name()
            );
        }
    }

    #[tokio::test]
    async fn master_client_does_not_follow_redirects_with_bootstrap_secret() {
        let redirect_target = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind redirect target");
        let redirect_target_address = redirect_target
            .local_addr()
            .expect("read redirect target address");
        let redirect_target_task = tokio::spawn(async move {
            match tokio::time::timeout(Duration::from_millis(500), redirect_target.accept()).await {
                Ok(Ok((mut socket, _))) => {
                    let mut buffer = [0_u8; 4096];
                    let count = socket
                        .read(&mut buffer)
                        .await
                        .expect("read redirect target");
                    let request = String::from_utf8_lossy(&buffer[..count]).into_owned();
                    socket
                        .write_all(
                            b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}",
                        )
                        .await
                        .expect("write redirect target response");
                    Some(request)
                }
                _ => None,
            }
        });

        let redirector = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind redirecting master");
        let redirector_address = redirector.local_addr().expect("read redirector address");
        let redirector_task = tokio::spawn(async move {
            let (mut socket, _) = redirector
                .accept()
                .await
                .expect("accept redirected request");
            let mut buffer = [0_u8; 4096];
            let _ = socket
                .read(&mut buffer)
                .await
                .expect("read redirected request");
            let response = format!(
                "HTTP/1.1 307 Temporary Redirect\r\nLocation: http://{redirect_target_address}/capture\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            );
            socket
                .write_all(response.as_bytes())
                .await
                .expect("write redirect response");
        });

        let client = MasterClient::new_with_timeout(
            format!("http://{redirector_address}"),
            None,
            None,
            None,
            Duration::from_secs(1),
        )
        .expect("build master client");
        let result = client
            .register(
                NodeId::new(),
                "bt_redirect_secret".into(),
                "test-agent".into(),
            )
            .await;

        redirector_task
            .await
            .expect("redirector task should finish");
        let redirected_request = redirect_target_task
            .await
            .expect("redirect target task should finish");

        assert!(
            result.is_err(),
            "redirect response should not be treated as a successful registration"
        );
        assert!(
            redirected_request.is_none(),
            "master client followed a redirect and replayed a secret-bearing request: {redirected_request:?}"
        );
    }

    #[derive(Clone, Copy)]
    enum AuthenticatedCall {
        Heartbeat,
        PollTask,
        UpdateTaskStatus,
        AppendTaskLog,
    }

    impl AuthenticatedCall {
        fn name(self) -> &'static str {
            match self {
                Self::Heartbeat => "heartbeat",
                Self::PollTask => "poll_task",
                Self::UpdateTaskStatus => "update_task_status",
                Self::AppendTaskLog => "append_task_log",
            }
        }

        async fn run(
            self,
            client: &MasterClient,
            node_id: NodeId,
            task_id: TaskId,
        ) -> anyhow::Result<()> {
            match self {
                Self::Heartbeat => client
                    .heartbeat(heartbeat_request(node_id))
                    .await
                    .map(|_| ()),
                Self::PollTask => client.poll_task(node_id).await.map(|_| ()),
                Self::UpdateTaskStatus => client
                    .update_task_status(
                        task_id,
                        AgentTaskStatusRequest {
                            node_id,
                            status: TaskStatus::Running,
                            error_message: None,
                        },
                    )
                    .await
                    .map(|_| ()),
                Self::AppendTaskLog => {
                    client
                        .append_task_log(
                            task_id,
                            AgentTaskLogRequest {
                                node_id,
                                message: "test log".into(),
                            },
                        )
                        .await
                }
            }
        }
    }

    fn heartbeat_request(node_id: NodeId) -> HeartbeatRequest {
        HeartbeatRequest {
            node_id,
            agent_version: "test-agent".into(),
            libvirt_status: "not_checked".into(),
            host_checks: Vec::new(),
            cpu_total: 1,
            cpu_used: 0,
            memory_total: 1024,
            memory_used: 0,
            disk_total: 10,
            disk_used: 0,
            vm_count: 0,
        }
    }

    async fn spawn_single_request_rejecting_server(
    ) -> (String, tokio::task::JoinHandle<Option<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind request capture server");
        let address = listener.local_addr().expect("read listener address");
        let handle = tokio::spawn(async move {
            match tokio::time::timeout(Duration::from_millis(500), listener.accept()).await {
                Ok(Ok((mut socket, _))) => {
                    let mut buffer = [0_u8; 4096];
                    let count = socket.read(&mut buffer).await.expect("read request");
                    let request = String::from_utf8_lossy(&buffer[..count]).into_owned();
                    socket
                        .write_all(
                            b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                        )
                        .await
                        .expect("write rejecting response");
                    Some(request)
                }
                _ => None,
            }
        });

        (format!("http://{address}"), handle)
    }

    #[test]
    fn http_timeout_env_is_bounded() {
        let _guard = env_guard();

        std::env::remove_var("VPS_AGENT_HTTP_TIMEOUT_SECONDS");
        assert_eq!(
            super::configured_http_timeout().expect("default timeout"),
            Duration::from_secs(super::DEFAULT_HTTP_TIMEOUT_SECONDS)
        );

        std::env::set_var("VPS_AGENT_HTTP_TIMEOUT_SECONDS", "0");
        let error = super::configured_http_timeout().expect_err("zero timeout should fail");
        assert!(
            error.to_string().contains("VPS_AGENT_HTTP_TIMEOUT_SECONDS"),
            "unexpected error: {error}"
        );

        std::env::set_var("VPS_AGENT_HTTP_TIMEOUT_SECONDS", "301");
        let error = super::configured_http_timeout().expect_err("oversized timeout should fail");
        assert!(
            error.to_string().contains("VPS_AGENT_HTTP_TIMEOUT_SECONDS"),
            "unexpected error: {error}"
        );

        std::env::set_var("VPS_AGENT_HTTP_TIMEOUT_SECONDS", "not-a-number");
        let error = super::configured_http_timeout().expect_err("non-numeric timeout should fail");
        assert!(
            error.to_string().contains("VPS_AGENT_HTTP_TIMEOUT_SECONDS"),
            "unexpected error: {error}"
        );

        std::env::remove_var("VPS_AGENT_HTTP_TIMEOUT_SECONDS");
    }

    fn env_lock() -> &'static std::sync::Mutex<()> {
        static LOCK: std::sync::OnceLock<std::sync::Mutex<()>> = std::sync::OnceLock::new();
        LOCK.get_or_init(|| std::sync::Mutex::new(()))
    }

    fn env_guard() -> std::sync::MutexGuard<'static, ()> {
        env_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }
}
