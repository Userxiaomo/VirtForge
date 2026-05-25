mod client;
mod config;
mod heartbeat;
mod libvirt;
mod network;
mod redaction;
mod resources;
mod security;
mod tasks;

use std::future::Future;

use anyhow::Context;
use tracing::info;
use vps_shared::NodeId;

use crate::{
    client::MasterClient,
    config::{AgentConfig, ExecutorConfig},
    heartbeat::HeartbeatLoop,
    libvirt::LibvirtExecutor,
};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(std::env::var("RUST_LOG").unwrap_or_else(|_| "vps_agent=info".into()))
        .init();

    if let Err(error) = run().await {
        tracing::error!(error = %loggable_startup_error(&error), "vps-agent startup failed");
        return Err(anyhow::anyhow!("vps-agent startup failed"));
    }

    Ok(())
}

async fn run() -> anyhow::Result<()> {
    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if args.iter().any(|arg| arg == "doctor" || arg == "--doctor") {
        let config =
            AgentConfig::load_from_default_path().context("failed to load agent config")?;
        run_doctor(&config).await?;
        return Ok(());
    }

    let mut config =
        AgentConfig::load_from_default_path().context("failed to load agent config")?;

    if config.bootstrap_ready() {
        let bootstrap_client = MasterClient::new(
            config.master_base_url.clone(),
            None,
            config.ca_cert_path.as_deref(),
            config.client_identity_path.as_deref(),
        )?;
        persist_registration_if_bootstrap_ready(
            &mut config,
            |node_id, bootstrap_token, version| {
                bootstrap_client.register(node_id, bootstrap_token, version)
            },
        )
        .await?;
    }

    let credential = config
        .credential()
        .map(|secret| secret.0.clone())
        .context("agent config is missing credential")?;
    let client = MasterClient::new(
        config.master_base_url.clone(),
        Some(credential),
        config.ca_cert_path.as_deref(),
        config.client_identity_path.as_deref(),
    )?;

    let run_once = std::env::var("VPS_AGENT_RUN_ONCE").as_deref() == Ok("1");
    info!(
        node_id = ?config.node_id,
        heartbeat_interval_seconds = config.heartbeat_interval_seconds,
        run_once,
        "vps-agent starting"
    );
    let heartbeat = HeartbeatLoop::new(config, client);
    if run_once {
        heartbeat.run_once_for_mvp().await?;
    } else {
        heartbeat.run_forever().await?;
    }
    Ok(())
}

fn loggable_startup_error(error: &anyhow::Error) -> String {
    crate::redaction::redact_text(&format!("{error:?}"))
}

async fn persist_registration_if_bootstrap_ready<F, Fut>(
    config: &mut AgentConfig,
    register: F,
) -> anyhow::Result<()>
where
    F: FnOnce(NodeId, String, String) -> Fut,
    Fut: Future<Output = anyhow::Result<vps_shared::AgentRegisterResponse>>,
{
    if !config.bootstrap_ready() {
        return Ok(());
    }

    config
        .prepare_save_target()
        .context("agent config cannot safely persist registered credential")?;
    let bootstrap_token = config
        .bootstrap_token
        .as_ref()
        .context("agent config is missing bootstrap token")?
        .0
        .clone();
    let registered = register(
        config.node_id,
        bootstrap_token,
        env!("CARGO_PKG_VERSION").into(),
    )
    .await
    .context("failed to register agent")?;
    config.bootstrap_token = None;
    config.credential = Some(registered.credential);
    config
        .save()
        .context("failed to persist registered agent config")?;
    Ok(())
}

async fn run_doctor(config: &AgentConfig) -> anyhow::Result<()> {
    println!("vps-agent doctor: config loaded");
    println!(
        "vps-agent doctor: master_base_url={}",
        config.master_base_url
    );
    println!("vps-agent doctor: data_dir={}", config.data_dir.display());
    if let Some(path) = &config.ca_cert_path {
        println!("vps-agent doctor: ca_cert_path={}", path.display());
    }
    if let Some(path) = &config.client_identity_path {
        println!("vps-agent doctor: client_identity_path={}", path.display());
    }

    match &config.executor {
        ExecutorConfig::Mock => {
            println!("vps-agent doctor: executor=mock");
            println!("vps-agent doctor: libvirt preflight skipped");
        }
        ExecutorConfig::Libvirt {
            image_dir,
            network_name,
            bridge_name,
        } => {
            println!("vps-agent doctor: executor=libvirt");
            let executor = LibvirtExecutor::new(
                config.data_dir.clone(),
                image_dir.clone(),
                network_name.clone(),
                bridge_name.clone(),
            );
            for line in executor.check_host().await? {
                println!("vps-agent doctor: {line}");
            }
        }
    }

    println!("vps-agent doctor: ok");
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex, OnceLock,
    };

    use vps_shared::{
        AgentCredentialPlaintext, AgentRegisterResponse, BootstrapTokenPlaintext, NodeId,
    };

    use super::*;

    #[test]
    fn startup_error_log_text_redacts_sensitive_values() {
        let error = anyhow::anyhow!(
            "failed with master_url=https://agent:master-secret@example.com/api bootstrap_token=bt_secret credential=ag_secret"
        );

        let loggable = loggable_startup_error(&error);

        assert!(!loggable.contains("master-secret"));
        assert!(!loggable.contains("bt_secret"));
        assert!(!loggable.contains("ag_secret"));
        assert!(loggable.contains("master_url=https://[REDACTED]@example.com/api"));
        assert!(loggable.contains("bootstrap_token=[REDACTED]"));
        assert!(loggable.contains("credential=[REDACTED]"));
    }

    #[test]
    fn bootstrap_registration_preflights_config_save_target_before_consuming_token() {
        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let parent = std::env::temp_dir().join(format!(
            "vps-agent-bootstrap-preflight-parent-file-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::write(&parent, "not a directory").expect("write regular parent file");
        let config_path = parent.join("agent.toml");
        std::env::set_var("VPS_AGENT_CONFIG", &config_path);

        let node_id = NodeId(uuid::Uuid::new_v4());
        let mut config = AgentConfig {
            master_base_url: "https://panel.example.com".into(),
            node_id,
            data_dir: "/var/lib/vps-agent".into(),
            heartbeat_interval_seconds: 30,
            ca_cert_path: None,
            client_identity_path: None,
            executor: ExecutorConfig::Mock,
            bootstrap_token: Some(BootstrapTokenPlaintext("bt_safe-token.1".into())),
            credential: None,
        };
        let register_called = Arc::new(AtomicBool::new(false));
        let register_called_in_closure = Arc::clone(&register_called);

        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("build test runtime");
        let result = runtime.block_on(persist_registration_if_bootstrap_ready(
            &mut config,
            move |_, _, _| {
                register_called_in_closure.store(true, Ordering::SeqCst);
                async move {
                    Ok(AgentRegisterResponse {
                        node_id,
                        credential: AgentCredentialPlaintext("ag_safe-token.1".into()),
                    })
                }
            },
        ));

        assert!(
            result.is_err(),
            "unsafe save target should stop bootstrap registration"
        );
        assert!(
            !register_called.load(Ordering::SeqCst),
            "registration must not be attempted before local credential persistence is safe"
        );
        assert!(config.bootstrap_token.is_some());
        assert!(config.credential.is_none());

        std::env::remove_var("VPS_AGENT_CONFIG");
        let _ = std::fs::remove_file(parent);
    }

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }
}
