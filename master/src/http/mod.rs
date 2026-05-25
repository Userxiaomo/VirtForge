use std::{net::IpAddr, time::Duration};

use axum::{
    body::Bytes,
    extract::{DefaultBodyLimit, Path, Request, State},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
    Extension, Json, Router,
};
use chrono::Utc;
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use sqlx::PgPool;
use uuid::Uuid;
use vps_shared::{
    AgentPollTaskRequest, AgentPollTaskResponse, AgentRegisterRequest, AgentTaskLogRequest,
    AgentTaskStatusRequest, AuditLogDto, CreateBootstrapTokenRequest, CreateBootstrapTokenResponse,
    CreateImageRequest, CreateIpPoolRequest, CreateNodeRequest, CreatePlanRequest,
    CreateVmTaskRequest, HealthResponse, HeartbeatRequest, HeartbeatResponse, ImageDto, ImageId,
    IpPoolDto, NodeDto, NodeId, PlanDto, PlanId, ReinstallVmTaskRequest, TaskDto, TaskId, TaskKind,
    TaskLogDto, TaskStatus, UpdateImageEnabledRequest, UpdateNodeSchedulingRequest,
    UpdatePlanEnabledRequest, VmActionTaskRequest, VmDto, VmId,
};

use crate::{
    audit, auth, config::MasterConfig, images, ipam, nodes, plans, rate_limit, redaction, tasks,
    vms,
};

#[derive(Clone)]
pub struct AppState {
    pub config: MasterConfig,
    pub pool: PgPool,
    pub rate_limiter: rate_limit::RateLimiter,
}

#[derive(Clone, Debug)]
pub struct RequestContext {
    pub request_id: String,
}

pub fn build_router(config: MasterConfig, pool: PgPool) -> Router {
    let request_body_limit_bytes = config.request_body_limit_bytes;
    let state = AppState {
        config,
        pool,
        rate_limiter: rate_limit::RateLimiter::new(Duration::from_secs(60)),
    };

    Router::new()
        .route("/healthz", get(healthz))
        .route("/api/admin/session", post(admin_session))
        .route("/api/admin/audit-logs", get(list_audit_logs))
        .route("/api/admin/nodes", get(list_nodes).post(create_node))
        .route(
            "/api/admin/nodes/:node_id/scheduling",
            post(update_node_scheduling),
        )
        .route("/api/admin/plans", get(list_plans).post(create_plan))
        .route(
            "/api/admin/plans/:plan_id/enabled",
            post(update_plan_enabled),
        )
        .route(
            "/api/admin/ip-pools",
            get(list_ip_pools).post(create_ip_pool),
        )
        .route("/api/admin/images", get(list_images).post(create_image))
        .route(
            "/api/admin/images/:image_id/enabled",
            post(update_image_enabled),
        )
        .route(
            "/api/admin/nodes/:node_id/bootstrap-tokens",
            post(create_bootstrap_token),
        )
        .route("/api/agent/register", post(register_agent))
        .route("/api/agent/heartbeat", post(agent_heartbeat))
        .route("/api/agent/tasks/poll", post(agent_poll_task))
        .route(
            "/api/agent/tasks/:task_id/status",
            post(agent_update_task_status),
        )
        .route(
            "/api/agent/tasks/:task_id/logs",
            post(agent_append_task_log),
        )
        .route("/api/admin/tasks", get(list_tasks))
        .route("/api/admin/tasks/create-vm", post(create_vm_task))
        .route("/api/admin/tasks/start-vm", post(start_vm_task))
        .route("/api/admin/tasks/stop-vm", post(stop_vm_task))
        .route("/api/admin/tasks/reboot-vm", post(reboot_vm_task))
        .route("/api/admin/tasks/reinstall-vm", post(reinstall_vm_task))
        .route("/api/admin/tasks/delete-vm", post(delete_vm_task))
        .route("/api/admin/tasks/:task_id/cancel", post(cancel_task))
        .route("/api/admin/tasks/:task_id/retry", post(retry_task))
        .route("/api/admin/tasks/:task_id/logs", get(list_task_logs))
        .route("/api/admin/tasks/:task_id", get(get_task))
        .route("/api/admin/vms", get(list_vms))
        .route("/downloads/vps-agent", get(download_agent_binary))
        .route("/scripts/install-agent.sh", get(install_agent_script))
        .with_state(state)
        .layer(DefaultBodyLimit::max(request_body_limit_bytes))
        .layer(middleware::from_fn(request_id_middleware))
}

async fn healthz() -> Json<HealthResponse> {
    Json(HealthResponse {
        service: "vps-master".into(),
        status: "ok".into(),
    })
}

fn no_store_response(mut response: Response) -> Response {
    let headers = response.headers_mut();
    headers.insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("no-store, max-age=0"),
    );
    headers.insert(header::PRAGMA, HeaderValue::from_static("no-cache"));
    headers.insert(header::EXPIRES, HeaderValue::from_static("0"));
    response
}

fn no_store_json_response<T: Serialize>(body: T) -> Response {
    no_store_response(Json(body).into_response())
}

fn no_store_error_response(error: ApiError) -> Response {
    no_store_response(error.into_response())
}

fn one_time_secret_json_response<T: Serialize>(body: T) -> Response {
    no_store_json_response(body)
}

#[derive(Deserialize)]
struct AdminSessionRequest {
    username: String,
    password: String,
}

#[derive(Serialize)]
struct AdminSessionResponse {
    ok: bool,
    role: &'static str,
}

async fn admin_session(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Response, ApiError> {
    match validate_admin_session(&state, &headers, &body) {
        Ok(()) => Ok(no_store_json_response(AdminSessionResponse {
            ok: true,
            role: "admin",
        })),
        Err(error) => Ok(no_store_error_response(error)),
    }
}

fn validate_admin_session(
    state: &AppState,
    headers: &HeaderMap,
    body: &[u8],
) -> Result<(), ApiError> {
    let limit = state.config.admin_rate_limit_per_minute;
    check_limit(state, "admin:session", limit)?;
    if let Some(bucket) = forwarded_for_rate_limit_bucket(headers) {
        check_limit(state, bucket, limit)?;
    }
    let request: AdminSessionRequest = parse_json_body(body)?;
    if !auth::verify_admin_login(
        request.username.trim(),
        request.password.as_str(),
        &state.config,
    ) {
        return Err(ApiError::Unauthorized);
    }

    Ok(())
}

async fn request_id_middleware(mut request: Request, next: Next) -> Response {
    let request_id = request
        .headers()
        .get("x-request-id")
        .and_then(|value| value.to_str().ok())
        .filter(|value| valid_request_id(value))
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| Uuid::new_v4().to_string());

    request.extensions_mut().insert(RequestContext {
        request_id: request_id.clone(),
    });

    let mut response = next.run(request).await;
    if let Ok(value) = HeaderValue::from_str(&request_id) {
        response.headers_mut().insert("x-request-id", value);
    }
    response
}

fn valid_request_id(value: &str) -> bool {
    (8..=128).contains(&value.len())
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
        && !request_id_contains_sensitive_word(value)
}

fn request_id_contains_sensitive_word(value: &str) -> bool {
    let normalized = value.to_ascii_lowercase().replace('-', "_");
    [
        "authorization",
        "bootstrap_token",
        "credential",
        "password",
        "private_key",
        "secret",
        "token",
    ]
    .iter()
    .any(|sensitive| normalized.contains(sensitive))
}

fn forwarded_for_rate_limit_bucket(headers: &HeaderMap) -> Option<String> {
    let forwarded_for = headers
        .get("x-forwarded-for")?
        .to_str()
        .ok()?
        .split(',')
        .next()?
        .trim();
    let ip = forwarded_for.parse::<IpAddr>().ok()?;

    Some(format!("admin:session:{ip}"))
}

#[cfg(test)]
mod tests {
    use std::{net::SocketAddr, path::PathBuf};

    use axum::{
        body::Body,
        http::{header, HeaderValue, Request as HttpRequest, StatusCode},
        response::{IntoResponse, Response},
    };
    use sqlx::postgres::PgPoolOptions;
    use tower::ServiceExt;
    use vps_shared::{CreateVmRequest, NodeId, TaskId, TaskKind, VmId};

    use crate::config::{MasterConfig, REQUEST_BODY_LIMIT_MIN_BYTES};

    use super::{
        build_router, forwarded_for_rate_limit_bucket, loggable_database_error,
        one_time_secret_json_response, parse_json_body, retry_image_file_name, valid_request_id,
        ApiError,
    };

    fn test_config(request_body_limit_bytes: usize) -> MasterConfig {
        MasterConfig {
            http_bind: "127.0.0.1:8080".parse::<SocketAddr>().expect("socket"),
            public_base_url: "https://agents.example.com".into(),
            installer_base_url: "https://panel.example.com".into(),
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
            request_body_limit_bytes,
        }
    }

    fn test_config_with_auth(
        request_body_limit_bytes: usize,
        admin_secret: &str,
        readonly_secret: &str,
    ) -> MasterConfig {
        let mut config = test_config(request_body_limit_bytes);
        config.admin_token_hash =
            crate::auth::hash_secret(admin_secret).expect("hash test admin secret");
        config.readonly_token_hash =
            crate::auth::hash_secret(readonly_secret).expect("hash test readonly secret");
        config
    }

    #[tokio::test]
    async fn malformed_signed_agent_json_consumes_global_agent_rate_limit() {
        let pool = PgPoolOptions::new()
            .connect_lazy("postgres://vps:vps@localhost:5432/vps")
            .expect("lazy pool");
        let mut config = test_config(REQUEST_BODY_LIMIT_MIN_BYTES);
        config.agent_rate_limit_per_minute = 1;
        let app = build_router(config, pool);

        let first = app
            .clone()
            .oneshot(malformed_agent_request())
            .await
            .expect("first response");
        let second = app
            .oneshot(malformed_agent_request())
            .await
            .expect("second response");

        assert_eq!(first.status(), StatusCode::BAD_REQUEST);
        assert_eq!(second.status(), StatusCode::TOO_MANY_REQUESTS);
    }

    #[tokio::test]
    async fn malformed_agent_registration_json_consumes_global_agent_rate_limit() {
        let pool = PgPoolOptions::new()
            .connect_lazy("postgres://vps:vps@localhost:5432/vps")
            .expect("lazy pool");
        let mut config = test_config(REQUEST_BODY_LIMIT_MIN_BYTES);
        config.agent_registration_rate_limit_per_minute = 1;
        let app = build_router(config, pool);

        let first = app
            .clone()
            .oneshot(malformed_register_request())
            .await
            .expect("first response");
        let second = app
            .oneshot(malformed_register_request())
            .await
            .expect("second response");

        assert_eq!(first.status(), StatusCode::BAD_REQUEST);
        assert_eq!(second.status(), StatusCode::TOO_MANY_REQUESTS);
    }

    #[tokio::test]
    async fn agent_registration_error_responses_use_no_store_boundary() {
        let pool = PgPoolOptions::new()
            .connect_lazy("postgres://vps:vps@localhost:5432/vps")
            .expect("lazy pool");
        let mut config = test_config(REQUEST_BODY_LIMIT_MIN_BYTES);
        config.agent_registration_rate_limit_per_minute = 1;
        let app = build_router(config, pool);

        let malformed = app
            .clone()
            .oneshot(malformed_register_request())
            .await
            .expect("malformed response");
        let rate_limited = app
            .oneshot(malformed_register_request())
            .await
            .expect("rate-limited response");

        assert_eq!(malformed.status(), StatusCode::BAD_REQUEST);
        assert_no_store_response(&malformed);
        assert_eq!(rate_limited.status(), StatusCode::TOO_MANY_REQUESTS);
        assert_no_store_response(&rate_limited);
    }

    #[tokio::test]
    async fn router_rejects_oversized_json_bodies() {
        let pool = PgPoolOptions::new()
            .connect_lazy("postgres://vps:vps@localhost:5432/vps")
            .expect("lazy pool");
        let app = build_router(test_config(REQUEST_BODY_LIMIT_MIN_BYTES), pool);
        let body = format!(
            r#"{{"username":"admin","password":"{}"}}"#,
            "x".repeat(REQUEST_BODY_LIMIT_MIN_BYTES)
        );

        let response = app
            .oneshot(
                HttpRequest::builder()
                    .method("POST")
                    .uri("/api/admin/session")
                    .header("content-type", "application/json")
                    .body(Body::from(body))
                    .expect("request"),
            )
            .await
            .expect("response");

        assert_eq!(response.status(), StatusCode::PAYLOAD_TOO_LARGE);
    }

    #[tokio::test]
    async fn malformed_admin_session_json_consumes_session_rate_limit() {
        let pool = PgPoolOptions::new()
            .connect_lazy("postgres://vps:vps@localhost:5432/vps")
            .expect("lazy pool");
        let mut config = test_config_with_auth(
            REQUEST_BODY_LIMIT_MIN_BYTES,
            "adm_SAFE-token.1",
            "ro_SAFE-token.1",
        );
        config.admin_rate_limit_per_minute = 1;
        let app = build_router(config, pool);

        let first = app
            .clone()
            .oneshot(malformed_admin_session_request())
            .await
            .expect("first response");
        let second = app
            .oneshot(malformed_admin_session_request())
            .await
            .expect("second response");

        assert_eq!(first.status(), StatusCode::BAD_REQUEST);
        assert_eq!(second.status(), StatusCode::TOO_MANY_REQUESTS);
    }

    #[tokio::test]
    async fn admin_session_error_responses_use_no_store_boundary() {
        let pool = PgPoolOptions::new()
            .connect_lazy("postgres://vps:vps@localhost:5432/vps")
            .expect("lazy pool");
        let mut config = test_config_with_auth(
            REQUEST_BODY_LIMIT_MIN_BYTES,
            "adm_SAFE-token.1",
            "ro_SAFE-token.1",
        );
        config.admin_rate_limit_per_minute = 1;
        let app = build_router(config, pool);

        let malformed = app
            .clone()
            .oneshot(malformed_admin_session_request())
            .await
            .expect("malformed response");
        let rate_limited = app
            .oneshot(malformed_admin_session_request())
            .await
            .expect("rate-limited response");

        assert_eq!(malformed.status(), StatusCode::BAD_REQUEST);
        assert_no_store_response(&malformed);
        assert_eq!(rate_limited.status(), StatusCode::TOO_MANY_REQUESTS);
        assert_no_store_response(&rate_limited);

        let pool = PgPoolOptions::new()
            .connect_lazy("postgres://vps:vps@localhost:5432/vps")
            .expect("lazy pool");
        let app = build_router(
            test_config_with_auth(
                REQUEST_BODY_LIMIT_MIN_BYTES,
                "adm_SAFE-token.1",
                "ro_SAFE-token.1",
            ),
            pool,
        );
        let unauthorized = app
            .oneshot(admin_session_request("admin", "wrong_SAFE-token.1"))
            .await
            .expect("unauthorized response");

        assert_eq!(unauthorized.status(), StatusCode::UNAUTHORIZED);
        assert_no_store_response(&unauthorized);
    }

    #[tokio::test]
    async fn bootstrap_token_error_responses_use_no_store_boundary() {
        let pool = PgPoolOptions::new()
            .connect_lazy("postgres://vps:vps@localhost:5432/vps")
            .expect("lazy pool");
        let mut config = test_config_with_auth(
            REQUEST_BODY_LIMIT_MIN_BYTES,
            "adm_SAFE-token.1",
            "ro_SAFE-token.1",
        );
        config.admin_rate_limit_per_minute = 1;
        let app = build_router(config, pool);
        let node_id = NodeId::new();
        let uri = format!("/api/admin/nodes/{node_id}/bootstrap-tokens");

        let malformed = app
            .clone()
            .oneshot(malformed_admin_mutation_request(&uri))
            .await
            .expect("malformed response");
        let rate_limited = app
            .oneshot(malformed_admin_mutation_request(&uri))
            .await
            .expect("rate-limited response");

        assert_eq!(malformed.status(), StatusCode::BAD_REQUEST);
        assert_no_store_response(&malformed);
        assert_eq!(rate_limited.status(), StatusCode::TOO_MANY_REQUESTS);
        assert_no_store_response(&rate_limited);
    }

    #[tokio::test]
    async fn malformed_admin_mutation_json_consumes_admin_rate_limit() {
        let pool = PgPoolOptions::new()
            .connect_lazy("postgres://vps:vps@localhost:5432/vps")
            .expect("lazy pool");
        let mut config = test_config_with_auth(
            REQUEST_BODY_LIMIT_MIN_BYTES,
            "adm_SAFE-token.1",
            "ro_SAFE-token.1",
        );
        config.admin_rate_limit_per_minute = 1;
        let app = build_router(config, pool);

        let first = app
            .clone()
            .oneshot(malformed_admin_mutation_request("/api/admin/plans"))
            .await
            .expect("first response");
        let second = app
            .oneshot(malformed_admin_mutation_request("/api/admin/plans"))
            .await
            .expect("second response");

        assert_eq!(first.status(), StatusCode::BAD_REQUEST);
        assert_eq!(second.status(), StatusCode::TOO_MANY_REQUESTS);
    }

    fn malformed_admin_session_request() -> HttpRequest<Body> {
        HttpRequest::builder()
            .method("POST")
            .uri("/api/admin/session")
            .header("content-type", "application/json")
            .body(Body::from("{not json"))
            .expect("request")
    }

    fn admin_session_request(username: &str, password: &str) -> HttpRequest<Body> {
        HttpRequest::builder()
            .method("POST")
            .uri("/api/admin/session")
            .header("content-type", "application/json")
            .body(Body::from(format!(
                r#"{{"username":"{username}","password":"{password}"}}"#
            )))
            .expect("request")
    }

    fn malformed_admin_mutation_request(uri: &str) -> HttpRequest<Body> {
        HttpRequest::builder()
            .method("POST")
            .uri(uri)
            .header("content-type", "application/json")
            .header(header::AUTHORIZATION, "Bearer adm_SAFE-token.1")
            .body(Body::from("{not json"))
            .expect("request")
    }

    fn malformed_agent_request() -> HttpRequest<Body> {
        HttpRequest::builder()
            .method("POST")
            .uri("/api/agent/heartbeat")
            .header("content-type", "application/json")
            .body(Body::from("{not json"))
            .expect("request")
    }

    fn malformed_register_request() -> HttpRequest<Body> {
        HttpRequest::builder()
            .method("POST")
            .uri("/api/agent/register")
            .header("content-type", "application/json")
            .body(Body::from("{not json"))
            .expect("request")
    }

    #[tokio::test]
    async fn readonly_token_is_forbidden_on_admin_mutation_routes() {
        let pool = PgPoolOptions::new()
            .connect_lazy("postgres://vps:vps@localhost:5432/vps")
            .expect("lazy pool");
        let app = build_router(
            test_config_with_auth(
                REQUEST_BODY_LIMIT_MIN_BYTES,
                "adm_SAFE-token.1",
                "ro_SAFE-token.1",
            ),
            pool,
        );
        let task_id = TaskId::new();

        let response = app
            .oneshot(
                HttpRequest::builder()
                    .method("POST")
                    .uri(format!("/api/admin/tasks/{}/cancel", task_id.0))
                    .header(axum::http::header::AUTHORIZATION, "Bearer ro_SAFE-token.1")
                    .body(Body::empty())
                    .expect("request"),
            )
            .await
            .expect("response");

        assert_eq!(response.status(), StatusCode::FORBIDDEN);
    }

    #[test]
    fn agent_json_parser_rejects_malformed_body_as_bad_request() {
        let error = parse_json_body::<serde_json::Value>(b"{not json")
            .expect_err("malformed request JSON should fail");

        assert!(
            matches!(error, ApiError::MalformedJson),
            "unexpected error: {error:?}"
        );
        assert_eq!(error.into_response().status(), StatusCode::BAD_REQUEST);
    }

    #[test]
    fn database_error_log_text_redacts_sensitive_values() {
        let error = sqlx::Error::Protocol(
            "connection failed for postgres://vps:db-secret@postgres:5432/vps token=bt_secret"
                .into(),
        );

        let loggable = loggable_database_error(&error);

        assert!(!loggable.contains("db-secret"));
        assert!(!loggable.contains("bt_secret"));
        assert!(loggable.contains("postgres://[REDACTED]@postgres:5432/vps"));
        assert!(loggable.contains("token=[REDACTED]"));
    }

    #[test]
    fn one_time_secret_response_disables_http_caching() {
        let response = one_time_secret_json_response(serde_json::json!({
            "bootstrap_token": "bt_test_secret"
        }))
        .into_response();

        assert_no_store_response(&response);
    }

    fn assert_no_store_response(response: &Response) {
        assert_eq!(
            response.headers().get(header::CACHE_CONTROL),
            Some(&HeaderValue::from_static("no-store, max-age=0"))
        );
        assert_eq!(
            response.headers().get(header::PRAGMA),
            Some(&HeaderValue::from_static("no-cache"))
        );
        assert_eq!(
            response.headers().get(header::EXPIRES),
            Some(&HeaderValue::from_static("0"))
        );
    }

    #[test]
    fn agent_registration_response_uses_no_store_secret_response() {
        let source = include_str!("mod.rs");
        let handler = extract_function_source(source, "\nasync fn register_agent");

        assert!(
            handler.contains("-> Result<Response, ApiError>"),
            "agent registration returns a long-term credential and must be able to set response headers"
        );
        assert!(
            handler.contains("one_time_secret_json_response(response)"),
            "agent registration response must use the no-store secret response boundary"
        );
        assert!(
            !handler.contains("Ok(Json(response))"),
            "agent registration must not return a bare JSON credential response"
        );
    }

    #[test]
    fn admin_session_response_uses_no_store_boundary() {
        let source = include_str!("mod.rs");
        let handler = extract_function_source(source, "\nasync fn admin_session");

        assert!(
            handler.contains("-> Result<Response, ApiError>"),
            "admin session validates credentials and must be able to set response headers"
        );
        assert!(
            handler.contains("no_store_json_response(AdminSessionResponse"),
            "admin session response must use the no-store response boundary"
        );
        assert!(
            !handler.contains("Ok(Json(AdminSessionResponse"),
            "admin session must not return a bare JSON auth-boundary response"
        );
    }

    #[test]
    fn request_id_rejects_sensitive_secret_words() {
        assert!(!valid_request_id("token_bt_123456"));
        assert!(!valid_request_id("credential_ag_123456"));
        assert!(!valid_request_id("password_hunter2"));
        assert!(valid_request_id("req_01HZ8Y6P2N4Q7R8S9T0V1W2X3Y"));
    }

    #[test]
    fn forwarded_for_rate_limit_bucket_accepts_only_ip_first_hop() {
        let mut headers = axum::http::HeaderMap::new();
        headers.insert(
            "x-forwarded-for",
            axum::http::HeaderValue::from_static("203.0.113.10, 198.51.100.2"),
        );
        assert_eq!(
            forwarded_for_rate_limit_bucket(&headers).as_deref(),
            Some("admin:session:203.0.113.10")
        );

        headers.insert(
            "x-forwarded-for",
            axum::http::HeaderValue::from_static("token=secret"),
        );
        assert!(forwarded_for_rate_limit_bucket(&headers).is_none());

        headers.insert(
            "x-forwarded-for",
            axum::http::HeaderValue::from_static("203.0.113.10:12345"),
        );
        assert!(forwarded_for_rate_limit_bucket(&headers).is_none());
    }

    fn extract_function_source<'a>(source: &'a str, declaration: &str) -> &'a str {
        let start = source.find(declaration).expect("function declaration");
        let body_start = source[start..].find('{').expect("function body") + start;
        let mut depth = 0usize;
        for (offset, ch) in source[body_start..].char_indices() {
            match ch {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if depth == 0 {
                        return &source[start..body_start + offset + ch.len_utf8()];
                    }
                }
                _ => {}
            }
        }
        panic!("function body did not close: {declaration}");
    }

    #[test]
    fn retry_image_file_name_covers_create_and_reinstall_tasks() {
        let node_id = NodeId::new();
        let vm_id = VmId::new();
        let create = TaskKind::CreateVm(CreateVmRequest {
            node_id,
            vm_id: Some(vm_id),
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
        });
        let reinstall = TaskKind::ReinstallVm {
            vm_id,
            name: "demo".into(),
            image: "ubuntu-24.04.qcow2".into(),
            ssh_public_key: None,
            disk_gb: 10,
        };

        assert_eq!(retry_image_file_name(&create), Some("debian-12.qcow2"));
        assert_eq!(
            retry_image_file_name(&reinstall),
            Some("ubuntu-24.04.qcow2")
        );
        assert_eq!(retry_image_file_name(&TaskKind::DeleteVm { vm_id }), None);
    }

    #[test]
    fn create_vm_task_applies_plan_inside_create_transaction() {
        let source = include_str!("mod.rs");
        let handler = extract_function_source(source, "\nasync fn create_vm_task");
        let begin_index = handler
            .find("state.pool.begin().await?")
            .expect("create_vm_task starts a transaction");
        let plan_index = handler
            .find("plans::apply_to_create_vm_in_tx(")
            .expect("create_vm_task applies plan sizing in transaction");

        assert!(
            begin_index < plan_index,
            "plan sizing must be normalized after the create transaction starts"
        );
        assert!(
            !handler.contains("plans::apply_to_create_vm(&state.pool"),
            "create_vm_task must not use pool-scoped plan normalization"
        );
    }
}

fn check_limit(
    state: &AppState,
    bucket: impl Into<String>,
    max_requests: u32,
) -> Result<(), ApiError> {
    if state.rate_limiter.check(bucket, max_requests) {
        Ok(())
    } else {
        Err(ApiError::TooManyRequests)
    }
}

fn require_admin_request(state: &AppState, headers: &HeaderMap) -> Result<(), ApiError> {
    let limit = state.config.admin_rate_limit_per_minute;
    check_limit(state, "admin:all", limit)?;
    if let Some(token) = auth::bearer_token(headers) {
        check_limit(state, rate_limit::secret_bucket("admin", token), limit)?;
    } else {
        check_limit(state, "admin:missing-token", limit)?;
    }
    auth::require_admin(headers, &state.config)
}

fn require_read_request(state: &AppState, headers: &HeaderMap) -> Result<auth::Role, ApiError> {
    let limit = state.config.admin_rate_limit_per_minute;
    check_limit(state, "admin-read:all", limit)?;
    if let Some(token) = auth::bearer_token(headers) {
        check_limit(state, rate_limit::secret_bucket("admin-read", token), limit)?;
    } else {
        check_limit(state, "admin-read:missing-token", limit)?;
    }
    auth::require_read(headers, &state.config)
}

fn rate_limit_agent_registration_envelope(state: &AppState) -> Result<(), ApiError> {
    let limit = state.config.agent_registration_rate_limit_per_minute;
    check_limit(state, "agent-register:all", limit)
}

fn rate_limit_agent_registration_request(
    state: &AppState,
    request: &AgentRegisterRequest,
) -> Result<(), ApiError> {
    let limit = state.config.agent_registration_rate_limit_per_minute;
    check_limit(
        state,
        rate_limit::secret_bucket(
            &format!("agent-register:{}", request.node_id.0),
            &request.bootstrap_token.0,
        ),
        limit,
    )
}

fn rate_limit_agent_envelope(state: &AppState) -> Result<(), ApiError> {
    let limit = state.config.agent_rate_limit_per_minute;
    check_limit(state, "agent:all", limit)
}

fn rate_limit_agent_node(state: &AppState, node_id: NodeId) -> Result<(), ApiError> {
    let limit = state.config.agent_rate_limit_per_minute;
    check_limit(state, format!("agent:node:{}", node_id.0), limit)
}

fn with_request_id(context: &RequestContext, event: audit::AuditEvent) -> audit::AuditEvent {
    event.with_request_id(context.request_id.clone())
}

fn parse_json_body<T: DeserializeOwned>(body: &[u8]) -> Result<T, ApiError> {
    serde_json::from_slice(body).map_err(|_| ApiError::MalformedJson)
}

fn parse_admin_json_body<T: DeserializeOwned>(
    state: &AppState,
    headers: &HeaderMap,
    body: &[u8],
) -> Result<T, ApiError> {
    require_admin_request(state, headers)?;
    parse_json_body(body)
}

async fn install_agent_script() -> impl IntoResponse {
    (
        [(header::CONTENT_TYPE, "text/x-shellscript; charset=utf-8")],
        include_str!("../../../scripts/install-agent.sh"),
    )
}

async fn download_agent_binary(State(state): State<AppState>) -> Result<Response, ApiError> {
    let Some(path) = state.config.agent_binary_path.clone() else {
        return Err(ApiError::NotFound(
            "agent binary download is not configured",
        ));
    };

    crate::config::validate_agent_binary_artifact_path(&path)
        .map_err(|_| ApiError::NotFound("agent binary must be a regular file"))?;
    let bytes = tokio::fs::read(&path)
        .await
        .map_err(|_| ApiError::NotFound("agent binary not found"))?;

    Ok(([(header::CONTENT_TYPE, "application/octet-stream")], bytes).into_response())
}

async fn list_audit_logs(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<AuditLogDto>>, ApiError> {
    require_read_request(&state, &headers)?;
    let logs = audit::list_recent(&state.pool).await?;
    Ok(Json(logs))
}

async fn create_plan(
    State(state): State<AppState>,
    Extension(request_context): Extension<RequestContext>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<PlanDto>, ApiError> {
    let request: CreatePlanRequest = parse_admin_json_body(&state, &headers, &body)?;
    let mut tx = state.pool.begin().await?;
    let plan = plans::create_in_tx(&mut tx, request).await?;
    audit::write_in_tx(
        &mut tx,
        with_request_id(&request_context, audit::AuditEvent::admin("plan.create")).succeeded(),
    )
    .await?;
    tx.commit().await?;
    Ok(Json(plan))
}

async fn list_plans(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<PlanDto>>, ApiError> {
    require_read_request(&state, &headers)?;
    let plans = plans::list(&state.pool).await?;
    Ok(Json(plans))
}

async fn update_plan_enabled(
    State(state): State<AppState>,
    Extension(request_context): Extension<RequestContext>,
    headers: HeaderMap,
    Path(plan_id): Path<Uuid>,
    body: Bytes,
) -> Result<Json<PlanDto>, ApiError> {
    let request: UpdatePlanEnabledRequest = parse_admin_json_body(&state, &headers, &body)?;
    let mut tx = state.pool.begin().await?;
    let plan = plans::set_enabled_in_tx(&mut tx, PlanId(plan_id), request.enabled).await?;
    audit::write_in_tx(
        &mut tx,
        with_request_id(
            &request_context,
            audit::AuditEvent::admin("plan.enabled_update"),
        )
        .with_detail(serde_json::json!({
            "plan_id": plan.id,
            "enabled": plan.enabled,
        }))
        .succeeded(),
    )
    .await?;
    tx.commit().await?;
    Ok(Json(plan))
}

async fn list_nodes(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<NodeDto>>, ApiError> {
    require_read_request(&state, &headers)?;
    let nodes = nodes::list(&state.pool).await?;
    Ok(Json(nodes))
}

async fn create_node(
    State(state): State<AppState>,
    Extension(request_context): Extension<RequestContext>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<NodeDto>, ApiError> {
    let request: CreateNodeRequest = parse_admin_json_body(&state, &headers, &body)?;
    let mut tx = state.pool.begin().await?;
    let node = nodes::create_in_tx(&mut tx, request).await?;
    audit::write_in_tx(
        &mut tx,
        with_request_id(&request_context, audit::AuditEvent::admin("node.create"))
            .with_node(node.id)
            .succeeded(),
    )
    .await?;
    tx.commit().await?;
    Ok(Json(node))
}

async fn update_node_scheduling(
    State(state): State<AppState>,
    Extension(request_context): Extension<RequestContext>,
    headers: HeaderMap,
    Path(node_id): Path<Uuid>,
    body: Bytes,
) -> Result<Json<NodeDto>, ApiError> {
    let request: UpdateNodeSchedulingRequest = parse_admin_json_body(&state, &headers, &body)?;
    let mut tx = state.pool.begin().await?;
    let node = nodes::update_scheduling_in_tx(&mut tx, NodeId(node_id), request).await?;
    audit::write_in_tx(
        &mut tx,
        with_request_id(
            &request_context,
            audit::AuditEvent::admin("node.scheduling_update"),
        )
        .with_node(node.id)
        .with_detail(serde_json::json!({ "enabled": node.scheduling_enabled }))
        .succeeded(),
    )
    .await?;
    tx.commit().await?;
    Ok(Json(node))
}

async fn list_ip_pools(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<IpPoolDto>>, ApiError> {
    require_read_request(&state, &headers)?;
    let pools = ipam::list(&state.pool).await?;
    Ok(Json(pools))
}

async fn create_ip_pool(
    State(state): State<AppState>,
    Extension(request_context): Extension<RequestContext>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<IpPoolDto>, ApiError> {
    let request: CreateIpPoolRequest = parse_admin_json_body(&state, &headers, &body)?;
    let mut tx = state.pool.begin().await?;
    let pool = ipam::create_in_tx(&mut tx, request).await?;
    audit::write_in_tx(
        &mut tx,
        with_request_id(&request_context, audit::AuditEvent::admin("ip_pool.create")).succeeded(),
    )
    .await?;
    tx.commit().await?;
    Ok(Json(pool))
}

async fn list_images(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<ImageDto>>, ApiError> {
    require_read_request(&state, &headers)?;
    let images = images::list(&state.pool).await?;
    Ok(Json(images))
}

async fn create_image(
    State(state): State<AppState>,
    Extension(request_context): Extension<RequestContext>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<ImageDto>, ApiError> {
    let request: CreateImageRequest = parse_admin_json_body(&state, &headers, &body)?;
    let mut tx = state.pool.begin().await?;
    let image = images::create_in_tx(&mut tx, request).await?;
    audit::write_in_tx(
        &mut tx,
        with_request_id(&request_context, audit::AuditEvent::admin("image.create")).succeeded(),
    )
    .await?;
    tx.commit().await?;
    Ok(Json(image))
}

async fn update_image_enabled(
    State(state): State<AppState>,
    Extension(request_context): Extension<RequestContext>,
    headers: HeaderMap,
    Path(image_id): Path<Uuid>,
    body: Bytes,
) -> Result<Json<ImageDto>, ApiError> {
    let request: UpdateImageEnabledRequest = parse_admin_json_body(&state, &headers, &body)?;
    let mut tx = state.pool.begin().await?;
    let image = images::set_enabled_in_tx(&mut tx, ImageId(image_id), request.enabled).await?;
    audit::write_in_tx(
        &mut tx,
        with_request_id(
            &request_context,
            audit::AuditEvent::admin("image.enabled_update"),
        )
        .with_detail(serde_json::json!({
            "image_id": image.id,
            "enabled": image.enabled,
        }))
        .succeeded(),
    )
    .await?;
    tx.commit().await?;
    Ok(Json(image))
}

async fn create_bootstrap_token(
    State(state): State<AppState>,
    Extension(request_context): Extension<RequestContext>,
    headers: HeaderMap,
    Path(node_id): Path<Uuid>,
    body: Bytes,
) -> Result<Response, ApiError> {
    match create_bootstrap_token_inner(&state, &request_context, &headers, NodeId(node_id), &body)
        .await
    {
        Ok(response) => Ok(one_time_secret_json_response(response)),
        Err(error) => Ok(no_store_error_response(error)),
    }
}

async fn create_bootstrap_token_inner(
    state: &AppState,
    request_context: &RequestContext,
    headers: &HeaderMap,
    node_id: NodeId,
    body: &[u8],
) -> Result<CreateBootstrapTokenResponse, ApiError> {
    let request: CreateBootstrapTokenRequest = parse_admin_json_body(state, headers, body)?;
    let mut tx = state.pool.begin().await?;
    let response =
        nodes::create_bootstrap_token_in_tx(&mut tx, &state.config, node_id, request).await?;
    audit::write_in_tx(
        &mut tx,
        with_request_id(
            request_context,
            audit::AuditEvent::admin("bootstrap_token.create"),
        )
        .with_node(node_id)
        .succeeded(),
    )
    .await?;
    tx.commit().await?;
    Ok(response)
}

async fn register_agent(
    State(state): State<AppState>,
    Extension(request_context): Extension<RequestContext>,
    body: Bytes,
) -> Result<Response, ApiError> {
    match register_agent_inner(&state, &request_context, &body).await {
        Ok(response) => Ok(one_time_secret_json_response(response)),
        Err(error) => Ok(no_store_error_response(error)),
    }
}

async fn register_agent_inner(
    state: &AppState,
    request_context: &RequestContext,
    body: &[u8],
) -> Result<vps_shared::AgentRegisterResponse, ApiError> {
    rate_limit_agent_registration_envelope(state)?;
    let request: AgentRegisterRequest = parse_json_body(body)?;
    rate_limit_agent_registration_request(state, &request)?;
    let mut tx = state.pool.begin().await?;
    let response = nodes::register_agent_in_tx(&mut tx, request).await?;
    audit::write_in_tx(
        &mut tx,
        with_request_id(request_context, audit::AuditEvent::agent("agent.register"))
            .with_node(response.node_id)
            .succeeded(),
    )
    .await?;
    tx.commit().await?;
    Ok(response)
}

async fn agent_heartbeat(
    State(state): State<AppState>,
    Extension(request_context): Extension<RequestContext>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<HeartbeatResponse>, ApiError> {
    rate_limit_agent_envelope(&state)?;
    let request: HeartbeatRequest = parse_json_body(&body)?;
    rate_limit_agent_node(&state, request.node_id)?;
    nodes::verify_agent_request(
        &state.pool,
        &headers,
        request.node_id,
        "POST",
        "/api/agent/heartbeat",
        &body,
    )
    .await?;
    let mut tx = state.pool.begin().await?;
    nodes::record_heartbeat_in_tx(&mut tx, &request).await?;
    audit::write_in_tx(
        &mut tx,
        with_request_id(
            &request_context,
            audit::AuditEvent::agent("agent.heartbeat"),
        )
        .with_node(request.node_id)
        .with_detail(nodes::heartbeat_detail(&request))
        .succeeded(),
    )
    .await?;
    tx.commit().await?;
    Ok(Json(HeartbeatResponse {
        accepted_at: Utc::now(),
    }))
}

async fn agent_poll_task(
    State(state): State<AppState>,
    Extension(request_context): Extension<RequestContext>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<AgentPollTaskResponse>, ApiError> {
    rate_limit_agent_envelope(&state)?;
    let request: AgentPollTaskRequest = parse_json_body(&body)?;
    rate_limit_agent_node(&state, request.node_id)?;
    nodes::verify_agent_request(
        &state.pool,
        &headers,
        request.node_id,
        "POST",
        "/api/agent/tasks/poll",
        &body,
    )
    .await?;
    let mut tx = state.pool.begin().await?;
    let task = tasks::claim_next_for_node_in_tx(&mut tx, request.node_id).await?;
    if let Some(task) = &task {
        audit::write_in_tx(
            &mut tx,
            with_request_id(&request_context, audit::AuditEvent::agent("task.assigned"))
                .with_node(request.node_id)
                .with_task(task.id)
                .with_detail(tasks::audit_detail(&task.kind))
                .succeeded(),
        )
        .await?;
    }
    tx.commit().await?;
    Ok(Json(AgentPollTaskResponse { task }))
}

async fn agent_update_task_status(
    State(state): State<AppState>,
    Extension(request_context): Extension<RequestContext>,
    headers: HeaderMap,
    Path(task_id): Path<Uuid>,
    body: Bytes,
) -> Result<Json<TaskDto>, ApiError> {
    rate_limit_agent_envelope(&state)?;
    let request: AgentTaskStatusRequest = parse_json_body(&body)?;
    rate_limit_agent_node(&state, request.node_id)?;
    let path = format!("/api/agent/tasks/{task_id}/status");
    nodes::verify_agent_request(&state.pool, &headers, request.node_id, "POST", &path, &body)
        .await?;
    let error_message = request.error_message.as_deref();
    let mut tx = state.pool.begin().await?;
    let task = tasks::update_status_in_tx(
        &mut tx,
        TaskId(task_id),
        request.node_id,
        request.status,
        error_message,
    )
    .await?;
    vms::apply_task_status_in_tx(&mut tx, &task).await?;
    let mut audit_detail = tasks::audit_detail(&task.kind);
    if let Some(detail) = audit_detail.as_object_mut() {
        detail.insert("status".into(), serde_json::json!(request.status.as_str()));
        detail.insert(
            "has_error".into(),
            serde_json::json!(error_message.is_some()),
        );
    }
    audit::write_in_tx(
        &mut tx,
        with_request_id(
            &request_context,
            audit::AuditEvent::agent("task.status_update"),
        )
        .with_node(request.node_id)
        .with_task(task.id)
        .with_detail(audit_detail)
        .succeeded(),
    )
    .await?;

    if matches!(request.status, TaskStatus::Failed) {
        let Some(error_message) = error_message else {
            tx.commit().await?;
            return Ok(Json(task));
        };
        tasks::append_failure_log_in_tx(&mut tx, TaskId(task_id), request.node_id, error_message)
            .await?;
    }

    tx.commit().await?;
    Ok(Json(task))
}

async fn agent_append_task_log(
    State(state): State<AppState>,
    Extension(request_context): Extension<RequestContext>,
    headers: HeaderMap,
    Path(task_id): Path<Uuid>,
    body: Bytes,
) -> Result<StatusCode, ApiError> {
    rate_limit_agent_envelope(&state)?;
    let request: AgentTaskLogRequest = parse_json_body(&body)?;
    rate_limit_agent_node(&state, request.node_id)?;
    let path = format!("/api/agent/tasks/{task_id}/logs");
    nodes::verify_agent_request(&state.pool, &headers, request.node_id, "POST", &path, &body)
        .await?;
    let mut tx = state.pool.begin().await?;
    tasks::append_log_in_tx(&mut tx, TaskId(task_id), request.node_id, &request.message).await?;
    audit::write_in_tx(
        &mut tx,
        with_request_id(
            &request_context,
            audit::AuditEvent::agent("task.log.append"),
        )
        .with_node(request.node_id)
        .with_task(TaskId(task_id))
        .with_detail(serde_json::json!({
            "message_bytes": request.message.len()
        }))
        .succeeded(),
    )
    .await?;
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn create_vm_task(
    State(state): State<AppState>,
    Extension(request_context): Extension<RequestContext>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<TaskDto>, ApiError> {
    let mut request: CreateVmTaskRequest = parse_admin_json_body(&state, &headers, &body)?;
    if request.vm.vm_id.is_none() {
        request.vm.vm_id = Some(VmId::new());
    }
    request.vm.assigned_ip = None;
    request.vm.assigned_ip_prefix = None;
    request.vm.assigned_gateway_ip = None;
    let mut tx = state.pool.begin().await?;
    plans::apply_to_create_vm_in_tx(&mut tx, &mut request.vm).await?;
    request
        .vm
        .validate_for_mvp()
        .map_err(ApiError::BadRequest)?;
    images::ensure_enabled_in_tx(&mut tx, &request.vm.image).await?;
    nodes::ensure_capacity_for_create_vm_in_tx(&mut tx, &request.vm).await?;
    let vm_id = request
        .vm
        .vm_id
        .ok_or(ApiError::Internal("create_vm task is missing vm_id"))?;

    if let Some(ip_pool_id) = request.vm.ip_pool_id {
        let reservation = ipam::reserve_next_for_vm_in_tx(&mut tx, ip_pool_id, vm_id).await?;
        request.vm.assigned_ip = Some(reservation.address);
        request.vm.assigned_ip_prefix = Some(reservation.prefix);
        request.vm.assigned_gateway_ip = Some(reservation.gateway_ip);
        request
            .vm
            .validate_for_mvp()
            .map_err(ApiError::BadRequest)?;
    }

    let node_id = request.vm.node_id;
    let vm = request.vm.clone();
    let task = tasks::create_in_tx(&mut tx, node_id, TaskKind::CreateVm(vm.clone())).await?;
    if vm.ip_pool_id.is_some() {
        ipam::attach_task_in_tx(&mut tx, vm_id, task.id).await?;
    }
    vms::create_from_request_in_tx(&mut tx, &vm, task.id).await?;
    audit::write_in_tx(
        &mut tx,
        with_request_id(&request_context, audit::AuditEvent::admin("task.create_vm"))
            .with_node(node_id)
            .with_task(task.id)
            .with_detail(tasks::audit_detail(&task.kind))
            .succeeded(),
    )
    .await?;
    tx.commit().await?;
    Ok(Json(task))
}

async fn start_vm_task(
    State(state): State<AppState>,
    Extension(request_context): Extension<RequestContext>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<TaskDto>, ApiError> {
    let request: VmActionTaskRequest = parse_admin_json_body(&state, &headers, &body)?;
    create_vm_action_task(
        &state,
        request,
        &request_context,
        "task.start_vm",
        vms::VmAction::Start,
        |vm_id| TaskKind::StartVm { vm_id },
    )
    .await
}

async fn stop_vm_task(
    State(state): State<AppState>,
    Extension(request_context): Extension<RequestContext>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<TaskDto>, ApiError> {
    let request: VmActionTaskRequest = parse_admin_json_body(&state, &headers, &body)?;
    create_vm_action_task(
        &state,
        request,
        &request_context,
        "task.stop_vm",
        vms::VmAction::Stop,
        |vm_id| TaskKind::StopVm { vm_id },
    )
    .await
}

async fn reboot_vm_task(
    State(state): State<AppState>,
    Extension(request_context): Extension<RequestContext>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<TaskDto>, ApiError> {
    let request: VmActionTaskRequest = parse_admin_json_body(&state, &headers, &body)?;
    create_vm_action_task(
        &state,
        request,
        &request_context,
        "task.reboot_vm",
        vms::VmAction::Reboot,
        |vm_id| TaskKind::RebootVm { vm_id },
    )
    .await
}

async fn reinstall_vm_task(
    State(state): State<AppState>,
    Extension(request_context): Extension<RequestContext>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<TaskDto>, ApiError> {
    let request: ReinstallVmTaskRequest = parse_admin_json_body(&state, &headers, &body)?;
    let mut tx = state.pool.begin().await?;
    let spec = vms::reinstall_spec_in_tx(
        &mut tx,
        request.node_id,
        request.vm_id,
        request.image.map(|image| image.trim().to_owned()),
    )
    .await?;
    images::ensure_enabled_in_tx(&mut tx, &spec.image).await?;
    let task = tasks::create_in_tx(
        &mut tx,
        request.node_id,
        TaskKind::ReinstallVm {
            vm_id: request.vm_id,
            name: spec.name,
            image: spec.image,
            ssh_public_key: spec.ssh_public_key,
            disk_gb: spec.disk_gb,
        },
    )
    .await?;
    vms::apply_task_status_in_tx(&mut tx, &task).await?;
    audit::write_in_tx(
        &mut tx,
        with_request_id(
            &request_context,
            audit::AuditEvent::admin("task.reinstall_vm"),
        )
        .with_node(request.node_id)
        .with_task(task.id)
        .with_detail(tasks::audit_detail(&task.kind))
        .succeeded(),
    )
    .await?;
    tx.commit().await?;
    Ok(Json(task))
}

async fn delete_vm_task(
    State(state): State<AppState>,
    Extension(request_context): Extension<RequestContext>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<TaskDto>, ApiError> {
    let request: VmActionTaskRequest = parse_admin_json_body(&state, &headers, &body)?;
    create_vm_action_task(
        &state,
        request,
        &request_context,
        "task.delete_vm",
        vms::VmAction::Delete,
        |vm_id| TaskKind::DeleteVm { vm_id },
    )
    .await
}

async fn create_vm_action_task(
    state: &AppState,
    request: VmActionTaskRequest,
    request_context: &RequestContext,
    audit_action: &'static str,
    action: vms::VmAction,
    build: impl FnOnce(VmId) -> TaskKind,
) -> Result<Json<TaskDto>, ApiError> {
    let mut tx = state.pool.begin().await?;
    vms::ensure_action_allowed_in_tx(&mut tx, request.node_id, request.vm_id, action).await?;
    let task = tasks::create_in_tx(&mut tx, request.node_id, build(request.vm_id)).await?;
    vms::record_action_task_created_in_tx(&mut tx, &task).await?;
    vms::apply_task_status_in_tx(&mut tx, &task).await?;
    audit::write_in_tx(
        &mut tx,
        with_request_id(request_context, audit::AuditEvent::admin(audit_action))
            .with_node(request.node_id)
            .with_task(task.id)
            .with_detail(tasks::audit_detail(&task.kind))
            .succeeded(),
    )
    .await?;
    tx.commit().await?;
    Ok(Json(task))
}

async fn list_vms(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<VmDto>>, ApiError> {
    require_read_request(&state, &headers)?;
    let vms = vms::list(&state.pool).await?;
    Ok(Json(vms))
}

async fn list_tasks(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Vec<TaskDto>>, ApiError> {
    require_read_request(&state, &headers)?;
    let tasks = tasks::list_recent(&state.pool).await?;
    Ok(Json(tasks))
}

async fn cancel_task(
    State(state): State<AppState>,
    Extension(request_context): Extension<RequestContext>,
    headers: HeaderMap,
    Path(task_id): Path<Uuid>,
) -> Result<Json<TaskDto>, ApiError> {
    require_admin_request(&state, &headers)?;
    let mut tx = state.pool.begin().await?;
    let task = tasks::cancel_in_tx(&mut tx, TaskId(task_id)).await?;
    vms::apply_task_status_in_tx(&mut tx, &task).await?;
    audit::write_in_tx(
        &mut tx,
        with_request_id(&request_context, audit::AuditEvent::admin("task.cancel"))
            .with_node(task.node_id)
            .with_task(task.id)
            .with_detail(tasks::audit_detail(&task.kind))
            .succeeded(),
    )
    .await?;
    tx.commit().await?;
    Ok(Json(task))
}

async fn retry_task(
    State(state): State<AppState>,
    Extension(request_context): Extension<RequestContext>,
    headers: HeaderMap,
    Path(task_id): Path<Uuid>,
) -> Result<Json<TaskDto>, ApiError> {
    require_admin_request(&state, &headers)?;
    let source = tasks::get(&state.pool, TaskId(task_id)).await?;
    if !matches!(source.status, TaskStatus::Failed | TaskStatus::Canceled) {
        return Err(ApiError::Conflict(
            "only failed or canceled tasks can be retried",
        ));
    }

    let mut retry_kind = source.kind.clone();
    let mut tx = state.pool.begin().await?;
    if let Some(image) = retry_image_file_name(&retry_kind) {
        images::ensure_enabled_in_tx(&mut tx, image).await?;
    }
    vms::ensure_retry_allowed_in_tx(&mut tx, source.node_id, &retry_kind).await?;
    if let TaskKind::CreateVm(request) = &mut retry_kind {
        nodes::ensure_capacity_for_create_vm_in_tx(&mut tx, request).await?;
        if let (Some(ip_pool_id), Some(vm_id)) = (request.ip_pool_id, request.vm_id) {
            let reservation = ipam::reserve_next_for_vm_in_tx(&mut tx, ip_pool_id, vm_id).await?;
            request.assigned_ip = Some(reservation.address);
            request.assigned_ip_prefix = Some(reservation.prefix);
            request.assigned_gateway_ip = Some(reservation.gateway_ip);
            request.validate_for_mvp().map_err(ApiError::BadRequest)?;
        }
    }

    let retry = tasks::create_in_tx(&mut tx, source.node_id, retry_kind).await?;
    if let TaskKind::CreateVm(request) = &retry.kind {
        if request.ip_pool_id.is_some() {
            let vm_id = request
                .vm_id
                .ok_or(ApiError::Internal("retry create_vm task is missing vm_id"))?;
            ipam::attach_task_in_tx(&mut tx, vm_id, retry.id).await?;
        }
    }
    vms::apply_retry_created_in_tx(&mut tx, &retry).await?;
    let mut retry_detail = tasks::audit_detail(&retry.kind);
    if let Some(detail) = retry_detail.as_object_mut() {
        detail.insert(
            "source_task_id".into(),
            serde_json::json!(source.id.0.to_string()),
        );
    }
    audit::write_in_tx(
        &mut tx,
        with_request_id(&request_context, audit::AuditEvent::admin("task.retry"))
            .with_node(retry.node_id)
            .with_task(retry.id)
            .with_detail(retry_detail)
            .succeeded(),
    )
    .await?;
    tx.commit().await?;
    Ok(Json(retry))
}

fn retry_image_file_name(kind: &TaskKind) -> Option<&str> {
    match kind {
        TaskKind::CreateVm(request) => Some(request.image.as_str()),
        TaskKind::ReinstallVm { image, .. } => Some(image.as_str()),
        TaskKind::StartVm { .. }
        | TaskKind::StopVm { .. }
        | TaskKind::RebootVm { .. }
        | TaskKind::DeleteVm { .. } => None,
    }
}

async fn get_task(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(task_id): Path<Uuid>,
) -> Result<Json<TaskDto>, ApiError> {
    require_read_request(&state, &headers)?;
    let task = tasks::get(&state.pool, TaskId(task_id)).await?;
    Ok(Json(task))
}

async fn list_task_logs(
    State(state): State<AppState>,
    headers: HeaderMap,
    Path(task_id): Path<Uuid>,
) -> Result<Json<Vec<TaskLogDto>>, ApiError> {
    require_read_request(&state, &headers)?;
    let logs = tasks::list_logs(&state.pool, TaskId(task_id)).await?;
    Ok(Json(logs))
}

#[derive(Debug)]
pub enum ApiError {
    BadRequest(vps_shared::TaskValidationError),
    MalformedJson,
    Unauthorized,
    TooManyRequests,
    Forbidden(&'static str),
    NotFound(&'static str),
    Conflict(&'static str),
    Internal(&'static str),
    Database(sqlx::Error),
    Json(serde_json::Error),
}

#[derive(Serialize)]
struct ErrorBody {
    error: String,
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, message) = match self {
            Self::BadRequest(error) => (StatusCode::BAD_REQUEST, error.to_string()),
            Self::MalformedJson => (StatusCode::BAD_REQUEST, "invalid json body".into()),
            Self::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized".into()),
            Self::TooManyRequests => (StatusCode::TOO_MANY_REQUESTS, "rate limit exceeded".into()),
            Self::Forbidden(message) => (StatusCode::FORBIDDEN, message.into()),
            Self::NotFound(message) => (StatusCode::NOT_FOUND, message.into()),
            Self::Conflict(message) => (StatusCode::CONFLICT, message.into()),
            Self::Internal(message) => (StatusCode::INTERNAL_SERVER_ERROR, message.into()),
            Self::Database(error) => {
                tracing::error!(error = %loggable_database_error(&error), "database error");
                (StatusCode::INTERNAL_SERVER_ERROR, "database error".into())
            }
            Self::Json(error) => {
                tracing::error!(?error, "json error");
                (StatusCode::INTERNAL_SERVER_ERROR, "json error".into())
            }
        };

        (status, Json(ErrorBody { error: message })).into_response()
    }
}

fn loggable_database_error(error: &sqlx::Error) -> String {
    redaction::redact_text(&format!("{error:?}"))
}

impl From<sqlx::Error> for ApiError {
    fn from(value: sqlx::Error) -> Self {
        Self::Database(value)
    }
}

impl From<serde_json::Error> for ApiError {
    fn from(value: serde_json::Error) -> Self {
        Self::Json(value)
    }
}
