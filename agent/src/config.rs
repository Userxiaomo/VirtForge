use std::{
    fmt, fs,
    net::IpAddr,
    path::{Path, PathBuf},
};

use anyhow::Context;
use reqwest::Url;
use serde::{Deserialize, Serialize};
use vps_shared::{AgentCredentialPlaintext, BootstrapTokenPlaintext, NodeId};

use crate::network;

const MAX_HEARTBEAT_INTERVAL_SECONDS: u64 = 60 * 60;

#[cfg(any(unix, test))]
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PermissionOverrideScope {
    AgentConfig,
    ExternalSecret,
}

#[derive(Clone, Deserialize, Serialize)]
pub struct AgentConfig {
    pub master_base_url: String,
    pub node_id: NodeId,
    pub data_dir: PathBuf,
    #[serde(default = "default_heartbeat_interval_seconds")]
    pub heartbeat_interval_seconds: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ca_cert_path: Option<PathBuf>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub client_identity_path: Option<PathBuf>,
    #[serde(default)]
    pub executor: ExecutorConfig,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bootstrap_token: Option<BootstrapTokenPlaintext>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credential: Option<AgentCredentialPlaintext>,
}

impl fmt::Debug for AgentConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AgentConfig")
            .field(
                "master_base_url",
                &crate::redaction::redact_text(&self.master_base_url),
            )
            .field("node_id", &self.node_id)
            .field("data_dir", &self.data_dir)
            .field(
                "heartbeat_interval_seconds",
                &self.heartbeat_interval_seconds,
            )
            .field("ca_cert_path", &self.ca_cert_path)
            .field("client_identity_path", &self.client_identity_path)
            .field("executor", &self.executor)
            .field("bootstrap_token", &self.bootstrap_token)
            .field("credential", &self.credential)
            .finish()
    }
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(tag = "mode", rename_all = "snake_case")]
pub enum ExecutorConfig {
    #[default]
    Mock,
    Libvirt {
        image_dir: PathBuf,
        network_name: String,
        bridge_name: String,
    },
}

impl AgentConfig {
    pub fn load_from_default_path() -> anyhow::Result<Self> {
        let path = Self::config_path();
        validate_config_file_permissions(&path)?;
        let contents = fs::read_to_string(&path)
            .with_context(|| format!("unable to read agent config at {}", path.display()))?;
        let config: Self = toml::from_str(&contents).context("agent config is not valid TOML")?;
        config.validate()?;
        Ok(config)
    }

    pub fn config_path() -> PathBuf {
        std::env::var("VPS_AGENT_CONFIG")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("/etc/vps-agent/agent.toml"))
    }

    pub fn bootstrap_ready(&self) -> bool {
        self.credential.is_none() && self.bootstrap_token.is_some()
    }

    pub fn credential(&self) -> Option<&AgentCredentialPlaintext> {
        self.credential.as_ref()
    }

    pub fn validate(&self) -> anyhow::Result<()> {
        validate_master_base_url(&self.master_base_url)?;
        validate_controlled_directory("data_dir", &self.data_dir)?;
        if self.bootstrap_token.is_some() && self.credential.is_some() {
            anyhow::bail!("agent config must not contain both bootstrap_token and credential");
        }
        if let Some(token) = &self.bootstrap_token {
            validate_local_secret("bootstrap_token", &token.0)?;
        }
        if let Some(credential) = &self.credential {
            validate_local_secret("credential", &credential.0)?;
        }
        if let Some(path) = &self.ca_cert_path {
            validate_linux_file_path("ca_cert_path", path)?;
            validate_trust_anchor_file_permissions("ca_cert_path", path)?;
        }
        if let Some(path) = &self.client_identity_path {
            validate_linux_file_path("client_identity_path", path)?;
            let metadata = fs::metadata(path)
                .with_context(|| format!("unable to read client identity at {}", path.display()))?;
            if !metadata.is_file() {
                anyhow::bail!(
                    "client identity path must point to a file: {}",
                    path.display()
                );
            }
            validate_secret_file_permissions(path)?;
        }
        if self.heartbeat_interval_seconds == 0 {
            anyhow::bail!("heartbeat_interval_seconds must be at least 1");
        }
        if self.heartbeat_interval_seconds > MAX_HEARTBEAT_INTERVAL_SECONDS {
            anyhow::bail!(
                "heartbeat_interval_seconds must be {MAX_HEARTBEAT_INTERVAL_SECONDS} or lower"
            );
        }
        if let ExecutorConfig::Libvirt {
            image_dir,
            network_name,
            bridge_name,
        } = &self.executor
        {
            validate_controlled_directory("image_dir", image_dir)?;
            validate_child_directory("image_dir", image_dir, "data_dir", &self.data_dir)?;
            network::validate_libvirt_network_config(network_name, bridge_name)?;
        }

        Ok(())
    }

    pub fn save(&self) -> anyhow::Result<()> {
        self.prepare_save_target()?;
        let path = Self::config_path();
        let contents = toml::to_string_pretty(self).context("failed to serialize agent config")?;
        write_config_contents(&path, &contents)
            .with_context(|| format!("unable to write agent config at {}", path.display()))?;

        set_owner_only_permissions(&path)?;
        Ok(())
    }

    pub fn prepare_save_target(&self) -> anyhow::Result<()> {
        let path = Self::config_path();
        validate_config_parent_directory_before_save(&path)?;
        if let Some(parent) = path.parent() {
            create_config_parent_directory(parent)
                .with_context(|| format!("unable to create {}", parent.display()))?;
            validate_config_parent_directory_before_save(&path)?;
        }

        validate_config_path_before_save(&path)?;
        Ok(())
    }
}

fn default_heartbeat_interval_seconds() -> u64 {
    30
}

fn validate_master_base_url(value: &str) -> anyhow::Result<()> {
    if value.chars().any(|c| {
        c.is_ascii_control() || c.is_ascii_whitespace() || matches!(c, '\'' | '"' | '\\' | '`')
    }) {
        anyhow::bail!("agent master_base_url contains unsupported characters");
    }
    validate_raw_url_path_segments("agent master_base_url", value)?;

    let url = Url::parse(value).context("agent master_base_url must be a valid URL")?;
    let insecure_allowed = std::env::var("VPS_AGENT_ALLOW_INSECURE_MASTER").as_deref() == Ok("1");
    let loopback_http = insecure_allowed && url.scheme() == "http" && is_loopback_host(&url);
    if url.scheme() != "https" && !loopback_http {
        anyhow::bail!("agent master_base_url must use https://");
    }
    if url.host_str().is_none() {
        anyhow::bail!("agent master_base_url must include a host");
    }
    if url.port() == Some(0) {
        anyhow::bail!("agent master_base_url port must be between 1 and 65535");
    }
    if !url.username().is_empty() || url.password().is_some() {
        anyhow::bail!("agent master_base_url must not include username or password");
    }
    if url.query().is_some() || url.fragment().is_some() {
        anyhow::bail!("agent master_base_url must not include query or fragment");
    }

    Ok(())
}

fn validate_raw_url_path_segments(name: &str, value: &str) -> anyhow::Result<()> {
    let Some((_, after_scheme)) = value.split_once("://") else {
        return Ok(());
    };
    let Some((_, path_and_suffix)) = after_scheme.split_once('/') else {
        return Ok(());
    };
    let path = path_and_suffix.split(['?', '#']).next().unwrap_or_default();
    validate_url_path_segments(name, path)
}

fn validate_url_path_segments(name: &str, path: &str) -> anyhow::Result<()> {
    if contains_percent_encoded_control(path) {
        anyhow::bail!("{name} must not include percent-encoded control characters");
    }

    let lower_path = path.to_ascii_lowercase();
    if lower_path.contains("%2f") || lower_path.contains("%5c") {
        anyhow::bail!("{name} must not include encoded path separators");
    }

    for segment in path.split('/') {
        let decoded = segment.to_ascii_lowercase().replace("%2e", ".");
        if decoded == "." || decoded == ".." {
            anyhow::bail!("{name} must not include dot path segments");
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

fn is_loopback_host(url: &Url) -> bool {
    let Some(host) = url.host_str() else {
        return false;
    };

    let host = host.trim_start_matches('[').trim_end_matches(']');

    host.eq_ignore_ascii_case("localhost")
        || host
            .parse::<IpAddr>()
            .map(|address| address.is_loopback())
            .unwrap_or(false)
}

fn validate_local_secret(name: &str, value: &str) -> anyhow::Result<()> {
    if value.is_empty() || value.len() > 256 {
        anyhow::bail!("{name} must be between 1 and 256 characters");
    }
    if !value
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-')
    {
        anyhow::bail!("{name} contains unsupported characters");
    }

    Ok(())
}

fn validate_controlled_directory(name: &str, path: &Path) -> anyhow::Result<()> {
    let value = path
        .to_str()
        .with_context(|| format!("{name} must be valid UTF-8"))?;

    if value.is_empty() {
        anyhow::bail!("{name} must not be empty");
    }
    if value == "/" {
        anyhow::bail!("{name} must not be the filesystem root");
    }
    if !value.starts_with('/') {
        anyhow::bail!("{name} must be an absolute Linux path");
    }
    if value.chars().any(|c| {
        c.is_ascii_control() || c.is_ascii_whitespace() || matches!(c, '\'' | '"' | '\\' | '`')
    }) {
        anyhow::bail!("{name} contains unsupported characters");
    }
    if value.split('/').any(|component| component == "..") {
        anyhow::bail!("{name} must not contain parent directory traversal");
    }

    Ok(())
}

fn validate_linux_file_path(name: &str, path: &Path) -> anyhow::Result<()> {
    let value = path
        .to_str()
        .with_context(|| format!("{name} must be valid UTF-8"))?;

    if value.is_empty() {
        anyhow::bail!("{name} must not be empty");
    }
    if value == "/" {
        anyhow::bail!("{name} must point to a file, not the filesystem root");
    }
    if !value.starts_with('/') {
        anyhow::bail!("{name} must be an absolute Linux path");
    }
    if value.chars().any(|c| {
        c.is_ascii_control() || c.is_ascii_whitespace() || matches!(c, '\'' | '"' | '\\' | '`')
    }) {
        anyhow::bail!("{name} contains unsupported characters");
    }
    if value.split('/').any(|component| component == "..") {
        anyhow::bail!("{name} must not contain parent directory traversal");
    }

    Ok(())
}

fn validate_child_directory(
    child_name: &str,
    child: &Path,
    parent_name: &str,
    parent: &Path,
) -> anyhow::Result<()> {
    let child = child
        .to_str()
        .with_context(|| format!("{child_name} must be valid UTF-8"))?;
    let parent = parent
        .to_str()
        .with_context(|| format!("{parent_name} must be valid UTF-8"))?;
    let parent_prefix = format!("{parent}/");

    if !child.starts_with(&parent_prefix) {
        anyhow::bail!("{child_name} must be under {parent_name}");
    }

    Ok(())
}

#[cfg(unix)]
fn validate_config_file_permissions(path: &Path) -> anyhow::Result<()> {
    let metadata = real_local_secret_file_metadata(path)?;
    if insecure_config_permissions_override_applies_to(PermissionOverrideScope::AgentConfig) {
        return Ok(());
    }
    owner_only_permissions_from_metadata(path, &metadata)?;
    validate_current_user_owner("agent config", path, &metadata)
}

#[cfg(not(unix))]
fn validate_config_file_permissions(_path: &Path) -> anyhow::Result<()> {
    Ok(())
}

#[cfg(unix)]
fn validate_secret_file_permissions(path: &Path) -> anyhow::Result<()> {
    let metadata = real_local_secret_file_metadata(path)?;
    if insecure_config_permissions_override_applies_to(PermissionOverrideScope::ExternalSecret) {
        return Ok(());
    }
    owner_only_permissions_from_metadata(path, &metadata)?;
    validate_current_user_owner("agent local secret file", path, &metadata)
}

#[cfg(not(unix))]
fn validate_secret_file_permissions(_path: &Path) -> anyhow::Result<()> {
    Ok(())
}

#[cfg(unix)]
fn validate_trust_anchor_file_permissions(name: &str, path: &Path) -> anyhow::Result<()> {
    use std::os::unix::fs::PermissionsExt;

    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("unable to read metadata for {name}: {}", path.display()))?;
    if metadata.file_type().is_symlink() {
        anyhow::bail!("{name} must not be a symlink: {}", path.display());
    }
    if !metadata.is_file() {
        anyhow::bail!("{name} must point to a file: {}", path.display());
    }
    let mode = metadata.permissions().mode() & 0o777;
    if mode & 0o022 != 0 {
        anyhow::bail!(
            "{name} must not be writable by group or other: {} has mode {:o}",
            path.display(),
            mode
        );
    }
    Ok(())
}

#[cfg(not(unix))]
fn validate_trust_anchor_file_permissions(name: &str, path: &Path) -> anyhow::Result<()> {
    let metadata = fs::metadata(path)
        .with_context(|| format!("unable to read metadata for {name}: {}", path.display()))?;
    if !metadata.is_file() {
        anyhow::bail!("{name} must point to a file: {}", path.display());
    }
    Ok(())
}

#[cfg(unix)]
fn owner_only_permissions_from_metadata(
    path: &Path,
    metadata: &fs::Metadata,
) -> anyhow::Result<()> {
    use std::os::unix::fs::PermissionsExt;

    let mode = metadata.permissions().mode() & 0o777;
    if !owner_only_mode(mode) {
        anyhow::bail!(
            "agent config permissions must be 0600 or stricter: {} has mode {:o}",
            path.display(),
            mode
        );
    }
    Ok(())
}

#[cfg(any(unix, test))]
fn insecure_config_permissions_override_applies_to(scope: PermissionOverrideScope) -> bool {
    scope == PermissionOverrideScope::AgentConfig
        && std::env::var("VPS_AGENT_ALLOW_INSECURE_CONFIG_PERMS").as_deref() == Ok("1")
}

#[cfg(unix)]
fn validate_current_user_owner(
    name: &str,
    path: &Path,
    metadata: &fs::Metadata,
) -> anyhow::Result<()> {
    use std::os::unix::fs::MetadataExt;

    let owner_uid = u64::from(metadata.uid());
    // SAFETY: geteuid has no preconditions and only reads the effective UID of
    // the current process.
    let current_uid = unsafe { libc::geteuid() as u64 };
    validate_current_user_owner_uid(name, path, owner_uid, current_uid)
}

#[cfg(any(unix, test))]
fn validate_current_user_owner_uid(
    name: &str,
    path: &Path,
    owner_uid: u64,
    current_uid: u64,
) -> anyhow::Result<()> {
    if owner_uid != current_uid {
        anyhow::bail!(
            "{name} must be owned by the current user: {} has uid {}, current uid {}",
            path.display(),
            owner_uid,
            current_uid
        );
    }
    Ok(())
}

#[cfg(unix)]
fn owner_only_mode(mode: u32) -> bool {
    config_directory_owner_only_mode(mode)
}

#[cfg(any(unix, test))]
fn config_directory_owner_only_mode(mode: u32) -> bool {
    mode & 0o077 == 0
}

#[cfg(unix)]
fn write_config_contents(path: &Path, contents: &str) -> anyhow::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    use std::{ffi::OsString, fs::OpenOptions, io::Write};

    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let file_name = path.file_name().with_context(|| {
        format!(
            "agent config path must include a file name: {}",
            path.display()
        )
    })?;
    let mut temp_file_name = OsString::from(".");
    temp_file_name.push(file_name);
    temp_file_name.push(format!(
        ".tmp-{}-{}",
        std::process::id(),
        uuid::Uuid::new_v4()
    ));
    let temp_path = parent.join(temp_file_name);

    let result = (|| -> anyhow::Result<()> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temp_path)
            .with_context(|| {
                format!(
                    "unable to create temporary agent config at {}",
                    temp_path.display()
                )
            })?;
        file.write_all(contents.as_bytes())?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temp_path, path).with_context(|| {
            format!(
                "unable to replace agent config {} with temporary file",
                path.display()
            )
        })?;
        Ok(())
    })();

    if result.is_err() {
        let _ = fs::remove_file(&temp_path);
    }
    result
}

#[cfg(not(unix))]
fn write_config_contents(path: &Path, contents: &str) -> anyhow::Result<()> {
    fs::write(path, contents)?;
    Ok(())
}

#[cfg(unix)]
fn set_owner_only_permissions(path: &Path) -> anyhow::Result<()> {
    use std::os::unix::fs::PermissionsExt;

    let mut permissions = real_local_secret_file_metadata(path)?.permissions();
    permissions.set_mode(0o600);
    fs::set_permissions(path, permissions)
        .with_context(|| format!("unable to set 0600 permissions on {}", path.display()))?;
    Ok(())
}

#[cfg(not(unix))]
fn set_owner_only_permissions(_path: &Path) -> anyhow::Result<()> {
    Ok(())
}

#[cfg(unix)]
fn create_config_parent_directory(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::DirBuilderExt;

    let mut builder = fs::DirBuilder::new();
    builder.recursive(true).mode(0o700).create(path)
}

#[cfg(not(unix))]
fn create_config_parent_directory(path: &Path) -> std::io::Result<()> {
    fs::create_dir_all(path)
}

fn validate_config_parent_directory_before_save(path: &Path) -> anyhow::Result<()> {
    let Some(parent) = path.parent() else {
        return Ok(());
    };

    match fs::symlink_metadata(parent) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            anyhow::bail!(
                "agent config directory must not be a symlink: {}",
                parent.display()
            )
        }
        Ok(metadata) => {
            if !metadata.is_dir() {
                anyhow::bail!(
                    "agent config directory must be a directory: {}",
                    parent.display()
                );
            }
            validate_config_directory_permissions(parent, &metadata)?;
            Ok(())
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error).with_context(|| {
            format!(
                "unable to inspect agent config directory at {}",
                parent.display()
            )
        }),
    }
}

#[cfg(unix)]
fn validate_config_directory_permissions(
    path: &Path,
    metadata: &fs::Metadata,
) -> anyhow::Result<()> {
    use std::os::unix::fs::PermissionsExt;

    if insecure_config_permissions_override_applies_to(PermissionOverrideScope::AgentConfig) {
        return Ok(());
    }

    let mode = metadata.permissions().mode() & 0o777;
    if !config_directory_owner_only_mode(mode) {
        anyhow::bail!(
            "agent config directory permissions must not grant group or other access: {} has mode {:o}",
            path.display(),
            mode
        );
    }
    validate_current_user_owner("agent config directory", path, metadata)?;
    Ok(())
}

#[cfg(not(unix))]
fn validate_config_directory_permissions(
    _path: &Path,
    _metadata: &fs::Metadata,
) -> anyhow::Result<()> {
    Ok(())
}

#[cfg(unix)]
fn validate_config_path_before_save(path: &Path) -> anyhow::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            anyhow::bail!(
                "agent config path must not be a symlink: {}",
                path.display()
            )
        }
        Ok(metadata) => {
            if !metadata.is_file() {
                anyhow::bail!(
                    "agent config path must be a regular file: {}",
                    path.display()
                );
            }
            if insecure_config_permissions_override_applies_to(PermissionOverrideScope::AgentConfig)
            {
                return Ok(());
            }
            owner_only_permissions_from_metadata(path, &metadata)?;
            validate_current_user_owner("agent config", path, &metadata)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error)
            .with_context(|| format!("unable to inspect agent config at {}", path.display())),
    }
}

#[cfg(not(unix))]
fn validate_config_path_before_save(_path: &Path) -> anyhow::Result<()> {
    Ok(())
}

#[cfg(unix)]
fn real_local_secret_file_metadata(path: &Path) -> anyhow::Result<fs::Metadata> {
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("unable to read metadata for {}", path.display()))?;
    if metadata.file_type().is_symlink() {
        anyhow::bail!(
            "agent local secret file must not be a symlink: {}",
            path.display()
        );
    }
    if !metadata.is_file() {
        anyhow::bail!(
            "agent local secret file must be a regular file: {}",
            path.display()
        );
    }
    Ok(metadata)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_keeps_optional_ca_cert_path() {
        let node_id = NodeId(uuid::Uuid::new_v4());
        let config = AgentConfig {
            master_base_url: "https://panel.example.com".into(),
            node_id,
            data_dir: PathBuf::from("/var/lib/vps-agent"),
            heartbeat_interval_seconds: 30,
            ca_cert_path: Some(PathBuf::from("/etc/vps-agent/master-ca.pem")),
            client_identity_path: Some(PathBuf::from("/etc/vps-agent/client-identity.pem")),
            executor: ExecutorConfig::Mock,
            bootstrap_token: None,
            credential: None,
        };

        let serialized = toml::to_string(&config).expect("serialize config");
        let parsed: AgentConfig = toml::from_str(&serialized).expect("parse config");

        assert_eq!(
            parsed.ca_cert_path,
            Some(PathBuf::from("/etc/vps-agent/master-ca.pem"))
        );
        assert_eq!(
            parsed.client_identity_path,
            Some(PathBuf::from("/etc/vps-agent/client-identity.pem"))
        );
        assert_eq!(parsed.heartbeat_interval_seconds, 30);
        assert_eq!(parsed.node_id, node_id);
    }

    #[test]
    fn debug_output_redacts_secret_bearing_agent_config_values() {
        let mut config = test_agent_config("https://agent:master-secret@panel.example.com");
        config.bootstrap_token = Some(BootstrapTokenPlaintext("bt_safe-token.1".into()));
        config.credential = Some(AgentCredentialPlaintext("ag_safe-token.1".into()));

        let debug_text = format!("{config:?}");

        assert!(!debug_text.contains("master-secret"));
        assert!(!debug_text.contains("bt_safe-token.1"));
        assert!(!debug_text.contains("ag_safe-token.1"));
        assert!(debug_text.contains("https://[REDACTED]@panel.example.com"));
        assert!(debug_text.contains("master_base_url"));
        assert!(debug_text.contains("data_dir"));
    }

    #[test]
    fn config_defaults_heartbeat_interval() {
        let node_id = NodeId(uuid::Uuid::new_v4());
        let parsed: AgentConfig = toml::from_str(&format!(
            r#"
master_base_url = "https://panel.example.com"
node_id = "{node_id}"
data_dir = "/var/lib/vps-agent"

[executor]
mode = "mock"
"#,
            node_id = node_id.0
        ))
        .expect("parse config");

        assert_eq!(parsed.heartbeat_interval_seconds, 30);
    }

    #[test]
    fn config_rejects_oversized_heartbeat_interval() {
        let mut config = test_agent_config("https://panel.example.com");
        config.heartbeat_interval_seconds = super::MAX_HEARTBEAT_INTERVAL_SECONDS;
        config
            .validate()
            .expect("max heartbeat interval should pass");

        config.heartbeat_interval_seconds = super::MAX_HEARTBEAT_INTERVAL_SECONDS + 1;
        let error = config
            .validate()
            .expect_err("oversized heartbeat interval should fail");
        assert!(
            error.to_string().contains("heartbeat_interval_seconds"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn config_rejects_unsafe_libvirt_network_names() {
        let node_id = NodeId(uuid::Uuid::new_v4());
        let parsed: AgentConfig = toml::from_str(&format!(
            r#"
master_base_url = "https://panel.example.com"
node_id = "{node_id}"
data_dir = "/var/lib/vps-agent"

[executor]
mode = "libvirt"
image_dir = "/var/lib/vps-agent/images"
network_name = "../default"
bridge_name = "virbr0"
"#,
            node_id = node_id.0
        ))
        .expect("parse config");

        let error = parsed.validate().expect_err("unsafe network name");
        assert!(error.to_string().contains("network_name"));
    }

    #[test]
    fn config_rejects_unsafe_master_base_urls() {
        let config = test_agent_config("https://panel.example.com");
        config.validate().expect("safe URL");

        for unsafe_url in [
            "https://user:secret@panel.example.com",
            "https://panel.example.com?token=secret",
            "https://panel.example.com/#fragment",
            "https://panel.example.com/.",
            "https://panel.example.com/..",
            "https://panel.example.com/install/../api",
            "https://panel.example.com/install/%2e%2e/api",
            "https://panel.example.com/install/%2E/api",
            "https://panel.example.com/install%2f..%2fapi",
            "https://panel.example.com/install%5c..%5capi",
            "https://panel.example.com/install%0aapi",
            "https://panel.example.com/install%7fapi",
            "https://panel%0a.example.com",
            "https://panel%7f.example.com",
            "https://panel%2f.example.com",
            "https://panel%5c.example.com",
            "https://panel.example.com/space here",
            "https://panel.example.com/`cmd`",
            "https://panel.example.com:0",
            "https://",
        ] {
            let config = test_agent_config(unsafe_url);
            let error = config.validate().expect_err("unsafe URL should fail");
            assert!(
                error.to_string().contains("master_base_url"),
                "unexpected error for {unsafe_url}: {error}"
            );
        }
    }

    #[test]
    fn config_rejects_malformed_local_secrets() {
        for unsafe_value in ["bad token", "bad/token", "bad\\token", "", &"a".repeat(257)] {
            let mut config = test_agent_config("https://panel.example.com");
            config.bootstrap_token = Some(BootstrapTokenPlaintext(unsafe_value.into()));
            let error = config
                .validate()
                .expect_err("unsafe bootstrap token should fail");
            assert!(
                error.to_string().contains("bootstrap_token"),
                "unexpected error for bootstrap_token={unsafe_value:?}: {error}"
            );

            let mut config = test_agent_config("https://panel.example.com");
            config.credential = Some(AgentCredentialPlaintext(unsafe_value.into()));
            let error = config
                .validate()
                .expect_err("unsafe credential should fail");
            assert!(
                error.to_string().contains("credential"),
                "unexpected error for credential={unsafe_value:?}: {error}"
            );
        }

        let mut config = test_agent_config("https://panel.example.com");
        config.bootstrap_token = Some(BootstrapTokenPlaintext("bt_safe-token.1".into()));
        config.validate().expect("safe bootstrap token should pass");

        let mut config = test_agent_config("https://panel.example.com");
        config.credential = Some(AgentCredentialPlaintext("ag_safe-token.1".into()));
        config.validate().expect("safe credential should pass");
    }

    #[test]
    fn config_rejects_bootstrap_token_and_credential_together() {
        let mut config = test_agent_config("https://panel.example.com");
        config.bootstrap_token = Some(BootstrapTokenPlaintext("bt_safe".into()));
        config.credential = Some(AgentCredentialPlaintext("ag_safe".into()));

        let error = config
            .validate()
            .expect_err("config must not keep bootstrap token after credential exists");
        assert!(
            error.to_string().contains("bootstrap_token"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn insecure_master_override_only_allows_loopback_http() {
        let _guard = env_lock().lock().expect("env lock");
        std::env::set_var("VPS_AGENT_ALLOW_INSECURE_MASTER", "1");

        test_agent_config("http://127.0.0.1:8080")
            .validate()
            .expect("loopback HTTP is allowed for local smoke tests");
        test_agent_config("http://localhost:8080")
            .validate()
            .expect("localhost HTTP is allowed for local smoke tests");
        test_agent_config("http://[::1]:8080")
            .validate()
            .expect("IPv6 loopback HTTP is allowed for local smoke tests");

        let error = test_agent_config("http://evil.example.com")
            .validate()
            .expect_err("non-loopback HTTP must stay rejected even with the test override");
        assert!(
            error.to_string().contains("https"),
            "unexpected error: {error}"
        );

        std::env::remove_var("VPS_AGENT_ALLOW_INSECURE_MASTER");
    }

    #[test]
    fn config_rejects_unsafe_controlled_directories() {
        for unsafe_data_dir in [
            PathBuf::from("relative"),
            PathBuf::from("/"),
            PathBuf::from("/var/lib/vps-agent/../host"),
        ] {
            let mut config = test_agent_config("https://panel.example.com");
            config.data_dir = unsafe_data_dir;

            let error = config.validate().expect_err("unsafe data_dir should fail");
            assert!(
                error.to_string().contains("data_dir"),
                "unexpected error: {error}"
            );
        }

        let mut config = test_agent_config("https://panel.example.com");
        config.executor = ExecutorConfig::Libvirt {
            image_dir: PathBuf::from("/tmp/vps-agent-images"),
            network_name: "default".into(),
            bridge_name: "virbr0".into(),
        };
        let error = config
            .validate()
            .expect_err("image_dir outside data_dir should fail");
        assert!(
            error.to_string().contains("image_dir"),
            "unexpected error: {error}"
        );

        let mut config = test_agent_config("https://panel.example.com");
        config.executor = ExecutorConfig::Libvirt {
            image_dir: PathBuf::from("/var/lib/vps-agent/images"),
            network_name: "default".into(),
            bridge_name: "virbr0".into(),
        };
        config.validate().expect("controlled directories");
    }

    #[test]
    fn prepare_save_target_rejects_regular_file_config_parent() {
        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let parent = std::env::temp_dir().join(format!(
            "vps-agent-config-parent-file-{}",
            uuid::Uuid::new_v4()
        ));
        fs::write(&parent, "not a directory").expect("write regular parent file");
        let config_path = parent.join("agent.toml");

        std::env::set_var("VPS_AGENT_CONFIG", &config_path);
        let config = test_agent_config("https://panel.example.com");
        let error = config
            .prepare_save_target()
            .expect_err("regular parent file should reject config save preflight");
        assert!(
            error.to_string().contains("must be a directory"),
            "unexpected error: {error}"
        );
        std::env::remove_var("VPS_AGENT_CONFIG");

        let _ = fs::remove_file(parent);
    }

    #[test]
    fn config_rejects_unsafe_tls_file_paths_before_file_lookup() {
        for unsafe_path in [
            PathBuf::from("relative.pem"),
            PathBuf::from("/etc/vps-agent/../client.pem"),
            PathBuf::from("/etc/vps-agent/bad path.pem"),
            PathBuf::from("/etc/vps-agent/bad`path.pem"),
        ] {
            let mut config = test_agent_config("https://panel.example.com");
            config.ca_cert_path = Some(unsafe_path.clone());

            let error = config
                .validate()
                .expect_err("unsafe ca_cert_path should fail");
            assert!(
                error.to_string().contains("ca_cert_path"),
                "unexpected error for {unsafe_path:?}: {error}"
            );

            let mut config = test_agent_config("https://panel.example.com");
            config.client_identity_path = Some(unsafe_path.clone());

            let error = config
                .validate()
                .expect_err("unsafe client_identity_path should fail");
            assert!(
                error.to_string().contains("client_identity_path"),
                "unexpected error for {unsafe_path:?}: {error}"
            );
        }
    }

    #[cfg(unix)]
    #[test]
    fn ca_certificate_must_not_be_group_or_world_writable() {
        use std::os::unix::fs::PermissionsExt;

        let path = test_config_path("ca-cert-wide-writable");
        fs::write(
            &path,
            "-----BEGIN CERTIFICATE-----\nsmoke\n-----END CERTIFICATE-----\n",
        )
        .expect("write test CA cert");

        fs::set_permissions(&path, fs::Permissions::from_mode(0o660))
            .expect("set writable CA permissions");
        let mut config = test_agent_config("https://panel.example.com");
        config.ca_cert_path = Some(path.clone());
        let error = config
            .validate()
            .expect_err("group-writable CA certificate should be rejected");
        assert!(
            error.to_string().contains("ca_cert_path"),
            "unexpected error: {error}"
        );

        fs::set_permissions(&path, fs::Permissions::from_mode(0o644))
            .expect("set read-only CA permissions");
        config
            .validate()
            .expect("world-readable CA certificate should be accepted");

        let _ = fs::remove_file(path);
    }

    #[cfg(unix)]
    #[test]
    fn config_rejects_symlinked_ca_certificate_file() {
        use std::os::unix::fs::{symlink, PermissionsExt};

        let target = test_config_path("ca-cert-target");
        let link = test_config_path("ca-cert-link");
        fs::write(
            &target,
            "-----BEGIN CERTIFICATE-----\nsmoke\n-----END CERTIFICATE-----\n",
        )
        .expect("write CA certificate");
        fs::set_permissions(&target, fs::Permissions::from_mode(0o644))
            .expect("set CA certificate permissions");
        symlink(&target, &link).expect("create symlinked CA certificate");

        let mut config = test_agent_config("https://panel.example.com");
        config.ca_cert_path = Some(link.clone());
        let error = config
            .validate()
            .expect_err("symlinked CA certificate should fail");
        assert!(
            error.to_string().contains("symlink"),
            "unexpected error: {error}"
        );

        let _ = fs::remove_file(link);
        let _ = fs::remove_file(target);
    }

    #[cfg(unix)]
    #[test]
    fn owner_only_permission_check_rejects_group_or_other_access() {
        use std::os::unix::fs::PermissionsExt;

        let path = test_config_path("wide-permissions");
        fs::write(&path, "test").expect("write test config");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644))
            .expect("set test permissions");

        let metadata = real_local_secret_file_metadata(&path).expect("read test metadata");
        let error = owner_only_permissions_from_metadata(&path, &metadata)
            .expect_err("permissions should be rejected");
        assert!(error.to_string().contains("0600"));

        let _ = fs::remove_file(path);
    }

    #[cfg(unix)]
    #[test]
    fn owner_only_mode_rejects_group_or_other_bits() {
        assert!(owner_only_mode(0o600));
        assert!(owner_only_mode(0o400));
        assert!(!owner_only_mode(0o640));
        assert!(!owner_only_mode(0o604));
        assert!(!owner_only_mode(0o666));
    }

    #[test]
    fn config_directory_owner_only_mode_rejects_group_or_other_bits() {
        assert!(config_directory_owner_only_mode(0o700));
        assert!(config_directory_owner_only_mode(0o500));
        assert!(!config_directory_owner_only_mode(0o750));
        assert!(!config_directory_owner_only_mode(0o707));
        assert!(!config_directory_owner_only_mode(0o777));
    }

    #[test]
    fn current_user_owner_check_rejects_different_uid() {
        let path = Path::new("/etc/vps-agent/agent.toml");
        let error = validate_current_user_owner_uid("agent config", path, 1001, 0)
            .expect_err("different owner uid should be rejected");
        assert!(
            error.to_string().contains("owned by the current user"),
            "unexpected error: {error}"
        );
    }

    #[test]
    fn current_user_owner_check_accepts_same_uid() {
        let path = Path::new("/etc/vps-agent/agent.toml");
        validate_current_user_owner_uid("agent config", path, 0, 0)
            .expect("matching owner uid should be accepted");
    }

    #[test]
    fn insecure_config_permission_override_is_limited_to_agent_config() {
        let _guard = env_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        std::env::set_var("VPS_AGENT_ALLOW_INSECURE_CONFIG_PERMS", "1");

        assert!(insecure_config_permissions_override_applies_to(
            PermissionOverrideScope::AgentConfig
        ));
        assert!(!insecure_config_permissions_override_applies_to(
            PermissionOverrideScope::ExternalSecret
        ));

        std::env::remove_var("VPS_AGENT_ALLOW_INSECURE_CONFIG_PERMS");
    }

    #[cfg(unix)]
    #[test]
    fn owner_only_permission_check_accepts_0600() {
        use std::os::unix::fs::PermissionsExt;

        let path = test_config_path("owner-only");
        fs::write(&path, "test").expect("write test config");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
            .expect("set test permissions");

        let metadata = real_local_secret_file_metadata(&path).expect("read test metadata");
        owner_only_permissions_from_metadata(&path, &metadata)
            .expect("permissions should be accepted");

        let _ = fs::remove_file(path);
    }

    #[cfg(unix)]
    #[test]
    fn load_rejects_symlinked_config_file() {
        use std::os::unix::fs::{symlink, PermissionsExt};

        let _guard = env_guard();
        let target = test_config_path("symlinked-config-target");
        let link = test_config_path("symlinked-config-link");
        let node_id = NodeId(uuid::Uuid::new_v4());
        let contents = format!(
            r#"
master_base_url = "https://panel.example.com"
node_id = "{node_id}"
data_dir = "/var/lib/vps-agent"
heartbeat_interval_seconds = 30

[executor]
mode = "mock"
"#,
            node_id = node_id.0
        );
        fs::write(&target, contents).expect("write target config");
        fs::set_permissions(&target, fs::Permissions::from_mode(0o600))
            .expect("set target config permissions");
        symlink(&target, &link).expect("create symlinked config");

        std::env::set_var("VPS_AGENT_CONFIG", &link);
        let error =
            AgentConfig::load_from_default_path().expect_err("symlinked config should fail");
        assert!(
            error.to_string().contains("symlink"),
            "unexpected error: {error}"
        );
        std::env::remove_var("VPS_AGENT_CONFIG");

        let _ = fs::remove_file(link);
        let _ = fs::remove_file(target);
    }

    #[cfg(unix)]
    #[test]
    fn save_rejects_symlinked_config_directory_before_writing_secret() {
        use std::os::unix::fs::symlink;

        let _guard = env_guard();
        let target_dir = test_config_path("save-symlinked-config-dir-target");
        let link_dir = test_config_path("save-symlinked-config-dir-link");
        fs::create_dir_all(&target_dir).expect("create target config directory");
        symlink(&target_dir, &link_dir).expect("create symlinked config directory");

        std::env::set_var("VPS_AGENT_CONFIG", link_dir.join("agent.toml"));
        let mut config = test_agent_config("https://panel.example.com");
        config.credential = Some(AgentCredentialPlaintext("ag_safe-token.1".into()));
        let error = config
            .save()
            .expect_err("save must not write through a symlinked config directory");
        assert!(
            error.to_string().contains("symlink"),
            "unexpected error: {error}"
        );
        std::env::remove_var("VPS_AGENT_CONFIG");

        let target_file = target_dir.join("agent.toml");
        assert!(
            !target_file.exists(),
            "save unexpectedly created a config file through the symlinked directory"
        );

        let _ = fs::remove_file(link_dir);
        let _ = fs::remove_dir_all(target_dir);
    }

    #[cfg(unix)]
    #[test]
    fn save_rejects_loose_config_directory_before_writing_secret() {
        use std::os::unix::fs::PermissionsExt;

        let _guard = env_guard();
        let config_dir = test_config_path("save-loose-config-dir");
        fs::create_dir_all(&config_dir).expect("create loose config directory");
        fs::set_permissions(&config_dir, fs::Permissions::from_mode(0o777))
            .expect("set loose config directory permissions");
        let config_path = config_dir.join("agent.toml");

        std::env::set_var("VPS_AGENT_CONFIG", &config_path);
        let mut config = test_agent_config("https://panel.example.com");
        config.credential = Some(AgentCredentialPlaintext("ag_safe-token.1".into()));
        let error = config
            .save()
            .expect_err("save must reject a loose config directory before writing secrets");
        assert!(
            error
                .to_string()
                .contains("agent config directory permissions"),
            "unexpected error: {error}"
        );
        std::env::remove_var("VPS_AGENT_CONFIG");

        assert!(
            !config_path.exists(),
            "save unexpectedly created a config file in a loose directory"
        );

        fs::set_permissions(&config_dir, fs::Permissions::from_mode(0o700))
            .expect("restore config directory permissions for cleanup");
        let _ = fs::remove_dir_all(config_dir);
    }

    #[cfg(unix)]
    #[test]
    fn save_rejects_symlinked_config_file_before_writing_secret() {
        use std::os::unix::fs::{symlink, PermissionsExt};

        let _guard = env_guard();
        let config_dir = test_secure_config_dir("save-symlink-config-file-dir");
        let target = config_dir.join("target.toml");
        let link = config_dir.join("agent.toml");
        fs::write(&target, "sentinel").expect("write target config");
        fs::set_permissions(&target, fs::Permissions::from_mode(0o600))
            .expect("set target config permissions");
        symlink(&target, &link).expect("create symlinked config path");

        std::env::set_var("VPS_AGENT_CONFIG", &link);
        let mut config = test_agent_config("https://panel.example.com");
        config.credential = Some(AgentCredentialPlaintext("ag_safe-token.1".into()));
        let error = config
            .save()
            .expect_err("save must not write through symlinked config path");
        assert!(
            error.to_string().contains("symlink"),
            "unexpected error: {error}"
        );
        std::env::remove_var("VPS_AGENT_CONFIG");

        let target_contents = fs::read_to_string(&target).expect("read target config");
        assert_eq!(target_contents, "sentinel");

        let _ = fs::remove_dir_all(config_dir);
    }

    #[cfg(unix)]
    #[test]
    fn write_config_contents_replaces_symlink_path_without_writing_target() {
        use std::os::unix::fs::{symlink, PermissionsExt};

        let target = test_config_path("atomic-write-target");
        let link = test_config_path("atomic-write-link");
        fs::write(&target, "sentinel").expect("write target config");
        fs::set_permissions(&target, fs::Permissions::from_mode(0o600))
            .expect("set target config permissions");
        symlink(&target, &link).expect("create symlinked config path");

        write_config_contents(&link, "credential = \"ag_safe-token.1\"\n")
            .expect("atomic write should replace the symlink path");

        let target_contents = fs::read_to_string(&target).expect("read target config");
        assert_eq!(target_contents, "sentinel");

        let link_metadata = fs::symlink_metadata(&link).expect("read replacement config metadata");
        assert!(!link_metadata.file_type().is_symlink());
        assert!(link_metadata.is_file());
        let link_contents = fs::read_to_string(&link).expect("read replacement config");
        assert!(link_contents.contains("ag_safe-token.1"));

        let _ = fs::remove_file(link);
        let _ = fs::remove_file(target);
    }

    #[cfg(unix)]
    #[test]
    fn save_rejects_loose_existing_config_file_before_writing_secret() {
        use std::os::unix::fs::PermissionsExt;

        let _guard = env_guard();
        let config_dir = test_secure_config_dir("save-loose-existing-dir");
        let path = config_dir.join("agent.toml");
        fs::write(&path, "sentinel").expect("write loose config");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644))
            .expect("set loose config permissions");

        std::env::set_var("VPS_AGENT_CONFIG", &path);
        let mut config = test_agent_config("https://panel.example.com");
        config.credential = Some(AgentCredentialPlaintext("ag_safe-token.1".into()));
        let error = config
            .save()
            .expect_err("save must reject an existing non-0600 config before writing secrets");
        assert!(
            error.to_string().contains("0600"),
            "unexpected error: {error}"
        );
        std::env::remove_var("VPS_AGENT_CONFIG");

        let contents = fs::read_to_string(&path).expect("read loose config");
        assert_eq!(contents, "sentinel");

        let _ = fs::remove_dir_all(config_dir);
    }

    #[cfg(unix)]
    #[test]
    fn save_allows_loose_existing_config_file_when_insecure_permission_override_is_set() {
        use std::os::unix::fs::PermissionsExt;

        let _guard = env_guard();
        let path = test_config_path("save-loose-existing-with-override");
        fs::write(&path, "sentinel").expect("write loose config");
        fs::set_permissions(&path, fs::Permissions::from_mode(0o777))
            .expect("set loose config permissions");

        std::env::set_var("VPS_AGENT_CONFIG", &path);
        std::env::set_var("VPS_AGENT_ALLOW_INSECURE_CONFIG_PERMS", "1");
        let mut config = test_agent_config("https://panel.example.com");
        config.credential = Some(AgentCredentialPlaintext("ag_safe-token.1".into()));
        config
            .save()
            .expect("smoke-test override should allow loose mounted config files");
        std::env::remove_var("VPS_AGENT_ALLOW_INSECURE_CONFIG_PERMS");
        std::env::remove_var("VPS_AGENT_CONFIG");

        let contents = fs::read_to_string(&path).expect("read saved config");
        assert!(contents.contains("credential = \"ag_safe-token.1\""));

        let _ = fs::remove_file(path);
    }

    #[cfg(unix)]
    #[test]
    fn config_rejects_symlinked_client_identity_file() {
        use std::os::unix::fs::{symlink, PermissionsExt};

        let target = test_config_path("client-identity-target");
        let link = test_config_path("client-identity-link");
        fs::write(&target, "private identity").expect("write client identity");
        fs::set_permissions(&target, fs::Permissions::from_mode(0o600))
            .expect("set client identity permissions");
        symlink(&target, &link).expect("create symlinked client identity");

        let mut config = test_agent_config("https://panel.example.com");
        config.client_identity_path = Some(link.clone());
        let error = config
            .validate()
            .expect_err("symlinked client identity should fail");
        assert!(
            error.to_string().contains("symlink"),
            "unexpected error: {error}"
        );

        let _ = fs::remove_file(link);
        let _ = fs::remove_file(target);
    }

    #[cfg(unix)]
    fn test_config_path(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("vps-agent-config-{name}-{}", uuid::Uuid::new_v4()))
    }

    #[cfg(unix)]
    fn test_secure_config_dir(name: &str) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;

        let dir = test_config_path(name);
        fs::create_dir_all(&dir).expect("create secure config directory");
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))
            .expect("set secure config directory permissions");
        dir
    }

    fn env_lock() -> &'static std::sync::Mutex<()> {
        static LOCK: std::sync::OnceLock<std::sync::Mutex<()>> = std::sync::OnceLock::new();
        LOCK.get_or_init(|| std::sync::Mutex::new(()))
    }

    #[cfg(unix)]
    fn env_guard() -> std::sync::MutexGuard<'static, ()> {
        env_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn test_agent_config(master_base_url: &str) -> AgentConfig {
        AgentConfig {
            master_base_url: master_base_url.into(),
            node_id: NodeId(uuid::Uuid::new_v4()),
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
