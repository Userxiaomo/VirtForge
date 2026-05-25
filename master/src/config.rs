use std::{
    fmt,
    net::SocketAddr,
    path::{Path, PathBuf},
};

use anyhow::{bail, Context};
use argon2::password_hash::PasswordHash;

pub const REQUEST_BODY_LIMIT_DEFAULT_BYTES: usize = 64 * 1024;
pub const REQUEST_BODY_LIMIT_MIN_BYTES: usize = 1024;
pub const REQUEST_BODY_LIMIT_MAX_BYTES: usize = 1024 * 1024;
pub const RATE_LIMIT_MIN_PER_MINUTE: u32 = 1;
pub const RATE_LIMIT_MAX_PER_MINUTE: u32 = 60_000;
pub const AGENT_BINARY_MAX_BYTES: u64 = 128 * 1024 * 1024;

#[derive(Clone)]
pub struct MasterConfig {
    pub http_bind: SocketAddr,
    pub public_base_url: String,
    pub installer_base_url: String,
    pub database_url: String,
    pub admin_username: String,
    pub admin_token_hash: String,
    pub readonly_token_hash: String,
    pub agent_binary_path: Option<PathBuf>,
    pub installer_ca_cert_path: Option<PathBuf>,
    pub installer_client_identity_path: Option<PathBuf>,
    pub admin_rate_limit_per_minute: u32,
    pub agent_rate_limit_per_minute: u32,
    pub agent_registration_rate_limit_per_minute: u32,
    pub request_body_limit_bytes: usize,
}

impl fmt::Debug for MasterConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("MasterConfig")
            .field("http_bind", &self.http_bind)
            .field(
                "public_base_url",
                &crate::redaction::redact_text(&self.public_base_url),
            )
            .field(
                "installer_base_url",
                &crate::redaction::redact_text(&self.installer_base_url),
            )
            .field(
                "database_url",
                &crate::redaction::redact_text(&self.database_url),
            )
            .field("admin_username", &self.admin_username)
            .field("admin_token_hash", &"[REDACTED]")
            .field("readonly_token_hash", &"[REDACTED]")
            .field("agent_binary_path", &self.agent_binary_path)
            .field("installer_ca_cert_path", &self.installer_ca_cert_path)
            .field(
                "installer_client_identity_path",
                &self.installer_client_identity_path,
            )
            .field(
                "admin_rate_limit_per_minute",
                &self.admin_rate_limit_per_minute,
            )
            .field(
                "agent_rate_limit_per_minute",
                &self.agent_rate_limit_per_minute,
            )
            .field(
                "agent_registration_rate_limit_per_minute",
                &self.agent_registration_rate_limit_per_minute,
            )
            .field("request_body_limit_bytes", &self.request_body_limit_bytes)
            .finish()
    }
}

impl MasterConfig {
    pub fn try_from_env() -> anyhow::Result<Self> {
        let http_bind = env_string("MASTER_HTTP_BIND")?
            .unwrap_or_else(|| "127.0.0.1:8080".to_string())
            .parse()
            .context("MASTER_HTTP_BIND must be a valid socket address")?;

        let public_base_url =
            env_string("MASTER_PUBLIC_BASE_URL")?.unwrap_or_else(|| "https://localhost".into());
        let installer_base_url = env_string("MASTER_INSTALLER_BASE_URL")?
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| public_base_url.clone());

        let database_url = env_string("DATABASE_URL")?
            .unwrap_or_else(|| "postgres://vps:vps@localhost:5432/vps".into());
        let admin_username = env_string("MASTER_ADMIN_USERNAME")?.unwrap_or_else(|| "admin".into());
        let admin_token_hash = env_string("MASTER_ADMIN_TOKEN_HASH")?.unwrap_or_default();
        let readonly_token_hash = env_string("MASTER_READONLY_TOKEN_HASH")?.unwrap_or_default();
        let agent_binary_path = env_string("MASTER_AGENT_BINARY_PATH")?
            .filter(|value| !value.trim().is_empty())
            .map(PathBuf::from);
        let installer_ca_cert_path = env_optional_path("MASTER_INSTALLER_CA_CERT_PATH")?;
        let installer_client_identity_path =
            env_optional_path("MASTER_INSTALLER_CLIENT_IDENTITY_PATH")?;
        let admin_rate_limit_per_minute = env_u32("MASTER_ADMIN_RATE_LIMIT_PER_MINUTE", 120)?;
        let agent_rate_limit_per_minute = env_u32("MASTER_AGENT_RATE_LIMIT_PER_MINUTE", 600)?;
        let agent_registration_rate_limit_per_minute =
            env_u32("MASTER_AGENT_REGISTRATION_RATE_LIMIT_PER_MINUTE", 30)?;
        let request_body_limit_bytes = env_usize(
            "MASTER_REQUEST_BODY_LIMIT_BYTES",
            REQUEST_BODY_LIMIT_DEFAULT_BYTES,
        )?;

        Ok(Self {
            http_bind,
            public_base_url,
            installer_base_url,
            database_url,
            admin_username,
            admin_token_hash,
            readonly_token_hash,
            agent_binary_path,
            installer_ca_cert_path,
            installer_client_identity_path,
            admin_rate_limit_per_minute,
            agent_rate_limit_per_minute,
            agent_registration_rate_limit_per_minute,
            request_body_limit_bytes,
        })
    }

    pub fn require_admin_auth(&self) -> bool {
        !self.admin_token_hash.is_empty()
    }

    pub fn has_readonly_auth(&self) -> bool {
        !self.readonly_token_hash.is_empty()
    }

    pub fn validate(&self) -> anyhow::Result<()> {
        validate_https_base_url("MASTER_PUBLIC_BASE_URL", &self.public_base_url)?;
        validate_https_base_url("MASTER_INSTALLER_BASE_URL", &self.installer_base_url)?;
        validate_admin_username("MASTER_ADMIN_USERNAME", &self.admin_username)?;
        validate_required_password_hash("MASTER_ADMIN_TOKEN_HASH", &self.admin_token_hash)?;
        validate_optional_password_hash("MASTER_READONLY_TOKEN_HASH", &self.readonly_token_hash)?;
        if let Some(path) = &self.installer_ca_cert_path {
            installer_host_file_path_str("MASTER_INSTALLER_CA_CERT_PATH", path)?;
        }
        if let Some(path) = &self.installer_client_identity_path {
            installer_host_file_path_str("MASTER_INSTALLER_CLIENT_IDENTITY_PATH", path)?;
        }
        if let Some(path) = &self.agent_binary_path {
            validate_agent_binary_artifact_path(path)?;
        }
        validate_rate_limit_per_minute(
            "MASTER_ADMIN_RATE_LIMIT_PER_MINUTE",
            self.admin_rate_limit_per_minute,
        )?;
        validate_rate_limit_per_minute(
            "MASTER_AGENT_RATE_LIMIT_PER_MINUTE",
            self.agent_rate_limit_per_minute,
        )?;
        validate_rate_limit_per_minute(
            "MASTER_AGENT_REGISTRATION_RATE_LIMIT_PER_MINUTE",
            self.agent_registration_rate_limit_per_minute,
        )?;
        if !(REQUEST_BODY_LIMIT_MIN_BYTES..=REQUEST_BODY_LIMIT_MAX_BYTES)
            .contains(&self.request_body_limit_bytes)
        {
            bail!(
                "MASTER_REQUEST_BODY_LIMIT_BYTES must be between {REQUEST_BODY_LIMIT_MIN_BYTES} and {REQUEST_BODY_LIMIT_MAX_BYTES}"
            );
        }

        Ok(())
    }
}

pub(crate) fn validate_agent_binary_artifact_path(path: &Path) -> anyhow::Result<()> {
    let metadata = std::fs::symlink_metadata(path).with_context(|| {
        format!(
            "MASTER_AGENT_BINARY_PATH cannot be read: {}",
            path.display()
        )
    })?;
    if metadata.file_type().is_symlink() {
        bail!(
            "MASTER_AGENT_BINARY_PATH must not be a symlink: {}",
            path.display()
        );
    }
    if !metadata.is_file() {
        bail!(
            "MASTER_AGENT_BINARY_PATH must be a regular file: {}",
            path.display()
        );
    }
    if metadata.len() > AGENT_BINARY_MAX_BYTES {
        bail!(
            "MASTER_AGENT_BINARY_PATH is too large: {} bytes exceeds {} bytes",
            metadata.len(),
            AGENT_BINARY_MAX_BYTES
        );
    }
    Ok(())
}

pub(crate) fn installer_host_file_path_str<'a>(
    name: &str,
    path: &'a std::path::Path,
) -> anyhow::Result<&'a str> {
    let value = path
        .to_str()
        .ok_or_else(|| anyhow::anyhow!("{name} must be valid UTF-8"))?;

    if value.is_empty() {
        bail!("{name} must not be empty");
    }
    if value == "/" {
        bail!("{name} must point to a file, not the filesystem root");
    }
    if !value.starts_with('/') {
        bail!("{name} must be an absolute Linux path");
    }
    if value.chars().any(|c| {
        c.is_ascii_control() || c.is_ascii_whitespace() || matches!(c, '\'' | '"' | '\\' | '`')
    }) {
        bail!("{name} contains characters that are not safe for generated install commands");
    }
    if value.split('/').any(|component| component == "..") {
        bail!("{name} must not contain parent directory traversal");
    }

    Ok(value)
}

pub(crate) fn validate_https_base_url(name: &str, value: &str) -> anyhow::Result<()> {
    if !value.starts_with("https://") {
        bail!("{name} must start with https://");
    }
    if value.len() > 2048 {
        bail!("{name} is too long");
    }
    if value.chars().any(|c| {
        c.is_ascii_control() || c.is_ascii_whitespace() || matches!(c, '\'' | '"' | '\\' | '`')
    }) {
        bail!("{name} contains characters that are not safe for generated install commands");
    }
    if value.contains(['?', '#']) {
        bail!("{name} must not include query strings or fragments");
    }

    let host_and_path = &value["https://".len()..];
    let (authority, path) = host_and_path
        .split_once('/')
        .map_or((host_and_path, None), |(authority, path)| {
            (authority, Some(path))
        });
    if authority.is_empty() {
        bail!("{name} must include a host");
    }
    if authority.contains('@') {
        bail!("{name} must not include username or password");
    }
    validate_url_authority(name, authority)?;
    if let Some(path) = path {
        validate_url_path_segments(name, path)?;
    }

    Ok(())
}

fn validate_required_password_hash(name: &str, value: &str) -> anyhow::Result<()> {
    if value.trim().is_empty() {
        bail!("{name} must be set to an Argon2 PHC hash");
    }
    validate_password_hash(name, value)
}

fn validate_optional_password_hash(name: &str, value: &str) -> anyhow::Result<()> {
    if value.trim().is_empty() {
        return Ok(());
    }
    validate_password_hash(name, value)
}

fn validate_admin_username(name: &str, value: &str) -> anyhow::Result<()> {
    if value.trim().is_empty() {
        bail!("{name} must not be empty");
    }
    if value.trim() != value {
        bail!("{name} must not contain surrounding whitespace");
    }
    if value.len() > 64 {
        bail!("{name} must be 1-64 bytes");
    }
    if !value
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
    {
        bail!("{name} may contain only ASCII letters, numbers, dots, underscores, or dashes");
    }
    Ok(())
}

fn validate_rate_limit_per_minute(name: &str, value: u32) -> anyhow::Result<()> {
    if !(RATE_LIMIT_MIN_PER_MINUTE..=RATE_LIMIT_MAX_PER_MINUTE).contains(&value) {
        bail!("{name} must be between {RATE_LIMIT_MIN_PER_MINUTE} and {RATE_LIMIT_MAX_PER_MINUTE}");
    }
    Ok(())
}

fn validate_password_hash(name: &str, value: &str) -> anyhow::Result<()> {
    if value.trim() != value {
        bail!("{name} must not contain surrounding whitespace");
    }
    PasswordHash::new(value).map_err(|_| anyhow::anyhow!("{name} must be an Argon2 PHC hash"))?;
    Ok(())
}

fn validate_url_authority(name: &str, authority: &str) -> anyhow::Result<()> {
    if contains_percent_encoded_control(authority) {
        bail!("{name} must not include percent-encoded control characters");
    }

    let lower_authority = authority.to_ascii_lowercase();
    if lower_authority.contains("%2f") || lower_authority.contains("%5c") {
        bail!("{name} must not include encoded path separators");
    }

    if authority.starts_with('[') {
        let Some(closing_bracket) = authority.find(']') else {
            bail!("{name} must include a valid bracketed IPv6 host");
        };
        let host = &authority[1..closing_bracket];
        if host.is_empty() {
            bail!("{name} must include a host");
        }

        let after_bracket = &authority[closing_bracket + 1..];
        if after_bracket.is_empty() {
            return Ok(());
        }
        let Some(port) = after_bracket.strip_prefix(':') else {
            bail!("{name} must include a valid bracketed IPv6 host");
        };
        return validate_url_port(name, port);
    }

    if authority.contains(['[', ']']) {
        bail!("{name} must include a valid bracketed IPv6 host");
    }
    if authority.matches(':').count() > 1 {
        bail!("{name} IPv6 hosts must be bracketed");
    }

    let (host, port) = authority
        .split_once(':')
        .map_or((authority, None), |(host, port)| (host, Some(port)));
    if host.is_empty() {
        bail!("{name} must include a host");
    }
    if let Some(port) = port {
        validate_url_port(name, port)?;
    }

    Ok(())
}

fn validate_url_port(name: &str, port: &str) -> anyhow::Result<()> {
    if port.is_empty() {
        bail!("{name} port must not be empty");
    }
    if !port.chars().all(|c| c.is_ascii_digit()) {
        bail!("{name} port must be numeric");
    }
    let port = port
        .parse::<u16>()
        .with_context(|| format!("{name} port must be between 1 and 65535"))?;
    if port == 0 {
        bail!("{name} port must be between 1 and 65535");
    }

    Ok(())
}

fn validate_url_path_segments(name: &str, path: &str) -> anyhow::Result<()> {
    if contains_percent_encoded_control(path) {
        bail!("{name} must not include percent-encoded control characters");
    }

    let lower_path = path.to_ascii_lowercase();
    if lower_path.contains("%2f") || lower_path.contains("%5c") {
        bail!("{name} must not include encoded path separators");
    }

    for segment in path.split('/') {
        let decoded = segment.to_ascii_lowercase().replace("%2e", ".");
        if decoded == "." || decoded == ".." {
            bail!("{name} must not include dot path segments");
        }
    }

    Ok(())
}

fn contains_percent_encoded_control(path: &str) -> bool {
    let bytes = path.as_bytes();
    for index in 0..bytes.len().saturating_sub(2) {
        if bytes[index] != b'%' {
            continue;
        }

        let Some(high) = hex_value(bytes[index + 1]) else {
            continue;
        };
        let Some(low) = hex_value(bytes[index + 2]) else {
            continue;
        };

        let value = high * 16 + low;
        if value <= 0x1f || value == 0x7f {
            return true;
        }
    }

    false
}

fn hex_value(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn env_string(name: &str) -> anyhow::Result<Option<String>> {
    match std::env::var(name) {
        Ok(value) => Ok(Some(value)),
        Err(std::env::VarError::NotPresent) => Ok(None),
        Err(std::env::VarError::NotUnicode(_)) => bail!("{name} must be valid UTF-8"),
    }
}

fn env_u32(name: &str, default: u32) -> anyhow::Result<u32> {
    Ok(env_string(name)?
        .filter(|value| !value.trim().is_empty())
        .map(|value| {
            value
                .parse()
                .with_context(|| format!("{name} must be an unsigned integer"))
        })
        .transpose()?
        .unwrap_or(default))
}

fn env_usize(name: &str, default: usize) -> anyhow::Result<usize> {
    Ok(env_string(name)?
        .filter(|value| !value.trim().is_empty())
        .map(|value| {
            value
                .parse()
                .with_context(|| format!("{name} must be an unsigned integer"))
        })
        .transpose()?
        .unwrap_or(default))
}

fn env_optional_path(name: &str) -> anyhow::Result<Option<PathBuf>> {
    Ok(env_string(name)?
        .filter(|value| !value.trim().is_empty())
        .map(PathBuf::from))
}

#[cfg(test)]
mod tests {
    use std::{net::SocketAddr, path::PathBuf};

    use super::{
        MasterConfig, AGENT_BINARY_MAX_BYTES, RATE_LIMIT_MAX_PER_MINUTE, RATE_LIMIT_MIN_PER_MINUTE,
        REQUEST_BODY_LIMIT_DEFAULT_BYTES, REQUEST_BODY_LIMIT_MAX_BYTES,
        REQUEST_BODY_LIMIT_MIN_BYTES,
    };

    fn test_config(public_base_url: &str, installer_base_url: &str) -> MasterConfig {
        MasterConfig {
            http_bind: "127.0.0.1:8080".parse::<SocketAddr>().expect("socket"),
            public_base_url: public_base_url.into(),
            installer_base_url: installer_base_url.into(),
            database_url: "postgres://vps:vps@localhost:5432/vps".into(),
            admin_username: "admin".into(),
            admin_token_hash: test_hash(),
            readonly_token_hash: String::new(),
            agent_binary_path: Option::<PathBuf>::None,
            installer_ca_cert_path: Option::<PathBuf>::None,
            installer_client_identity_path: Option::<PathBuf>::None,
            admin_rate_limit_per_minute: 120,
            agent_rate_limit_per_minute: 600,
            agent_registration_rate_limit_per_minute: 30,
            request_body_limit_bytes: REQUEST_BODY_LIMIT_DEFAULT_BYTES,
        }
    }

    fn test_hash() -> String {
        crate::auth::hash_secret("test-secret").expect("hash test secret")
    }

    #[test]
    fn debug_output_redacts_secret_bearing_config_values() {
        let mut config = test_config("https://agents.example.com", "https://panel.example.com");
        config.database_url = "postgres://vps:db-secret@db.example.com:5432/vps".into();
        config.admin_token_hash = "admin-hash-SHOULD-NOT-LOG".into();
        config.readonly_token_hash = "readonly-hash-SHOULD-NOT-LOG".into();

        let debug_text = format!("{config:?}");

        assert!(!debug_text.contains("db-secret"));
        assert!(!debug_text.contains("admin-hash-SHOULD-NOT-LOG"));
        assert!(!debug_text.contains("readonly-hash-SHOULD-NOT-LOG"));
        assert!(debug_text.contains("postgres://[REDACTED]@db.example.com:5432/vps"));
        assert!(debug_text.contains("admin_token_hash: \"[REDACTED]\""));
        assert!(debug_text.contains("readonly_token_hash: \"[REDACTED]\""));
    }

    #[test]
    fn env_config_rejects_invalid_numeric_values_without_panicking() {
        let _guard = env_guard();
        std::env::set_var("MASTER_ADMIN_RATE_LIMIT_PER_MINUTE", "not-a-number");

        let result = std::panic::catch_unwind(MasterConfig::try_from_env);

        std::env::remove_var("MASTER_ADMIN_RATE_LIMIT_PER_MINUTE");

        assert!(result.is_ok(), "config parsing should return an error");
        let error = result
            .expect("config parsing should not panic")
            .expect_err("invalid numeric env should fail");
        assert!(
            error
                .to_string()
                .contains("MASTER_ADMIN_RATE_LIMIT_PER_MINUTE"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn env_config_preserves_configured_blank_admin_username_for_validation() {
        let _guard = env_guard();
        std::env::set_var("MASTER_ADMIN_USERNAME", " ");

        let config = MasterConfig::try_from_env().expect("parse env config");

        std::env::remove_var("MASTER_ADMIN_USERNAME");

        assert_eq!(config.admin_username, " ");
        assert!(config.validate().is_err());
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

    #[test]
    fn validates_https_public_and_installer_urls() {
        assert!(
            test_config("https://agents.example.com", "https://panel.example.com")
                .validate()
                .is_ok()
        );
        assert!(
            test_config("http://agents.example.com", "https://panel.example.com")
                .validate()
                .is_err()
        );
        assert!(
            test_config("https://agents.example.com", "http://panel.example.com")
                .validate()
                .is_err()
        );
    }

    #[test]
    fn rejects_shell_unsafe_public_and_installer_urls() {
        for unsafe_url in [
            "https://panel.example.com' --bad",
            "https://panel.example.com/path with space",
            "https://panel.example.com/\nnext",
            "https://panel.example.com/`cmd`",
        ] {
            assert!(test_config(unsafe_url, "https://panel.example.com")
                .validate()
                .is_err());
            assert!(test_config("https://agents.example.com", unsafe_url)
                .validate()
                .is_err());
        }
    }

    #[test]
    fn rejects_malformed_public_and_installer_url_authorities() {
        for unsafe_url in [
            "https://user:secret@panel.example.com",
            "https://panel.example.com?token=secret",
            "https://panel.example.com#fragment",
            "https://:8443",
            "https://panel.example.com:0",
            "https://panel.example.com:65536",
            "https://panel.example.com:99999",
            "https://panel%0a.example.com",
            "https://panel%7f.example.com",
            "https://panel%2f.example.com",
            "https://panel%5c.example.com",
            "https://[::1",
            "https://[::1]extra",
            "https://2001:db8::1",
        ] {
            assert!(test_config(unsafe_url, "https://panel.example.com")
                .validate()
                .is_err());
            assert!(test_config("https://agents.example.com", unsafe_url)
                .validate()
                .is_err());
        }
    }

    #[test]
    fn rejects_dot_segment_public_and_installer_url_paths() {
        for unsafe_url in [
            "https://panel.example.com/.",
            "https://panel.example.com/..",
            "https://panel.example.com/install/../admin",
            "https://panel.example.com/install/%2e%2e/admin",
            "https://panel.example.com/install/%2E/admin",
            "https://panel.example.com/install%2f..%2fadmin",
            "https://panel.example.com/install%5c..%5cadmin",
            "https://panel.example.com/install%0aadmin",
            "https://panel.example.com/install%7fadmin",
        ] {
            assert!(test_config(unsafe_url, "https://panel.example.com")
                .validate()
                .is_err());
            assert!(test_config("https://agents.example.com", unsafe_url)
                .validate()
                .is_err());
        }
    }

    #[test]
    fn validates_request_body_limit_bounds() {
        let mut config = test_config("https://agents.example.com", "https://panel.example.com");
        config.request_body_limit_bytes = REQUEST_BODY_LIMIT_MIN_BYTES;
        assert!(config.validate().is_ok());

        config.request_body_limit_bytes = REQUEST_BODY_LIMIT_MAX_BYTES;
        assert!(config.validate().is_ok());

        config.request_body_limit_bytes = REQUEST_BODY_LIMIT_MIN_BYTES - 1;
        assert!(config.validate().is_err());

        config.request_body_limit_bytes = REQUEST_BODY_LIMIT_MAX_BYTES + 1;
        assert!(config.validate().is_err());
    }

    #[test]
    fn validates_rate_limit_bounds() {
        let mut config = test_config("https://agents.example.com", "https://panel.example.com");
        config.admin_rate_limit_per_minute = RATE_LIMIT_MIN_PER_MINUTE;
        config.agent_registration_rate_limit_per_minute = RATE_LIMIT_MIN_PER_MINUTE;
        config.agent_rate_limit_per_minute = RATE_LIMIT_MIN_PER_MINUTE;
        assert!(config.validate().is_ok());

        config.admin_rate_limit_per_minute = RATE_LIMIT_MAX_PER_MINUTE;
        config.agent_registration_rate_limit_per_minute = RATE_LIMIT_MAX_PER_MINUTE;
        config.agent_rate_limit_per_minute = RATE_LIMIT_MAX_PER_MINUTE;
        assert!(config.validate().is_ok());

        for update in [
            |config: &mut MasterConfig, value| config.admin_rate_limit_per_minute = value,
            |config: &mut MasterConfig, value| {
                config.agent_registration_rate_limit_per_minute = value
            },
            |config: &mut MasterConfig, value| config.agent_rate_limit_per_minute = value,
        ] {
            let mut zero_config =
                test_config("https://agents.example.com", "https://panel.example.com");
            update(&mut zero_config, 0);
            assert!(zero_config.validate().is_err());

            let mut oversized_config =
                test_config("https://agents.example.com", "https://panel.example.com");
            update(&mut oversized_config, RATE_LIMIT_MAX_PER_MINUTE + 1);
            assert!(oversized_config.validate().is_err());
        }
    }

    #[test]
    fn validates_admin_and_readonly_token_hashes() {
        let mut missing_admin =
            test_config("https://agents.example.com", "https://panel.example.com");
        missing_admin.admin_token_hash = String::new();
        assert!(missing_admin.validate().is_err());

        let mut malformed_admin =
            test_config("https://agents.example.com", "https://panel.example.com");
        malformed_admin.admin_token_hash = "plaintext-admin-secret".into();
        assert!(malformed_admin.validate().is_err());

        let mut malformed_readonly =
            test_config("https://agents.example.com", "https://panel.example.com");
        malformed_readonly.readonly_token_hash = "plaintext-readonly-secret".into();
        assert!(malformed_readonly.validate().is_err());
    }

    #[test]
    fn rejects_unsafe_admin_usernames() {
        let mut config = test_config("https://agents.example.com", "https://panel.example.com");
        config.admin_username = "admin-ops_1.service".into();
        assert!(config.validate().is_ok());

        for unsafe_username in [
            String::new(),
            " ".into(),
            " admin".into(),
            "admin ".into(),
            "admin ops".into(),
            "admin\nops".into(),
            "admin\tops".into(),
            "admin\"ops".into(),
            "admin'ops".into(),
            "admin\\ops".into(),
            "admin`ops".into(),
            "admin/ops".into(),
            "管理员".into(),
            "a".repeat(65),
        ] {
            let mut config = test_config("https://agents.example.com", "https://panel.example.com");
            config.admin_username = unsafe_username.clone();

            assert!(
                config.validate().is_err(),
                "admin username should be rejected: {unsafe_username:?}"
            );
        }
    }

    #[test]
    fn validates_optional_installer_tls_paths() {
        let mut config = test_config("https://agents.example.com", "https://panel.example.com");
        config.installer_ca_cert_path = Some(PathBuf::from("/etc/ssl/certs/master-ca.pem"));
        config.installer_client_identity_path =
            Some(PathBuf::from("/etc/vps-agent/client-identity.pem"));

        assert!(config.validate().is_ok());
    }

    #[test]
    fn rejects_non_regular_agent_binary_artifact_path() {
        let artifact_path =
            std::env::temp_dir().join(format!("vps-agent-artifact-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&artifact_path).expect("create directory artifact path");
        let mut config = test_config("https://agents.example.com", "https://panel.example.com");
        config.agent_binary_path = Some(artifact_path.clone());

        let error = config
            .validate()
            .expect_err("agent binary artifact path must be a regular file");

        std::fs::remove_dir_all(artifact_path).expect("remove directory artifact path");
        assert!(
            error.to_string().contains("regular file"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn rejects_oversized_agent_binary_artifact_path() {
        let artifact_path =
            std::env::temp_dir().join(format!("vps-agent-artifact-{}.bin", uuid::Uuid::new_v4()));
        let file = std::fs::File::create(&artifact_path).expect("create artifact");
        file.set_len(AGENT_BINARY_MAX_BYTES + 1)
            .expect("extend artifact");
        drop(file);
        let mut config = test_config("https://agents.example.com", "https://panel.example.com");
        config.agent_binary_path = Some(artifact_path.clone());

        let error = config
            .validate()
            .expect_err("oversized agent binary artifact must be rejected");

        std::fs::remove_file(artifact_path).expect("remove artifact");
        assert!(
            error.to_string().contains("too large"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn rejects_unsafe_installer_tls_paths() {
        for unsafe_path in [
            "/",
            "relative/master-ca.pem",
            "/etc/vps-agent/../secret.pem",
            "/etc/vps-agent/bad path.pem",
            "/etc/vps-agent/`cmd`.pem",
            "/etc/vps-agent/client'identity.pem",
            "/etc/vps-agent/client\\identity.pem",
        ] {
            let mut ca_config =
                test_config("https://agents.example.com", "https://panel.example.com");
            ca_config.installer_ca_cert_path = Some(PathBuf::from(unsafe_path));
            assert!(ca_config.validate().is_err());

            let mut identity_config =
                test_config("https://agents.example.com", "https://panel.example.com");
            identity_config.installer_client_identity_path = Some(PathBuf::from(unsafe_path));
            assert!(identity_config.validate().is_err());
        }
    }
}
