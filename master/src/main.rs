mod audit;
mod auth;
mod config;
mod http;
mod images;
mod ipam;
mod nodes;
mod plans;
mod rate_limit;
mod redaction;
mod tasks;
mod vms;

use anyhow::Context;
use sqlx::postgres::PgPoolOptions;
use tokio::net::TcpListener;
use tower_http::trace::TraceLayer;
use tracing::info;

use crate::{config::MasterConfig, http::build_router};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            std::env::var("RUST_LOG").unwrap_or_else(|_| "vps_master=info,tower_http=info".into()),
        )
        .init();

    if let Err(error) = run().await {
        tracing::error!(error = %loggable_startup_error(&error), "vps-master startup failed");
        return Err(anyhow::anyhow!("vps-master startup failed"));
    }

    Ok(())
}

async fn run() -> anyhow::Result<()> {
    let config = MasterConfig::try_from_env()?;
    config.validate()?;
    let pool = PgPoolOptions::new()
        .max_connections(10)
        .connect(&config.database_url)
        .await
        .context("failed to connect to PostgreSQL")?;
    sqlx::migrate!("./migrations")
        .run(&pool)
        .await
        .context("failed to run master migrations")?;

    let router = build_router(config.clone(), pool).layer(TraceLayer::new_for_http());
    let listener = TcpListener::bind(config.http_bind)
        .await
        .context("failed to bind master HTTP listener")?;

    info!("vps-master listening");
    axum::serve(listener, router)
        .await
        .context("master HTTP server failed")?;

    Ok(())
}

fn loggable_startup_error(error: &anyhow::Error) -> String {
    crate::redaction::redact_text(&format!("{error:?}"))
}

#[cfg(test)]
mod tests {
    use super::loggable_startup_error;

    #[test]
    fn startup_error_log_text_redacts_sensitive_values() {
        let error = anyhow::anyhow!(
            "failed with database_url=postgres://vps:db-secret@postgres:5432/vps token=bt_secret"
        );

        let loggable = loggable_startup_error(&error);

        assert!(!loggable.contains("db-secret"));
        assert!(!loggable.contains("bt_secret"));
        assert!(loggable.contains("database_url=postgres://[REDACTED]@postgres:5432/vps"));
        assert!(loggable.contains("token=[REDACTED]"));
    }
}
