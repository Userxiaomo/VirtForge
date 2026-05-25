use argon2::{
    password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString},
    Argon2,
};
use axum::http::HeaderMap;
use rand_core::OsRng;

use crate::{config::MasterConfig, http::ApiError};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Role {
    Admin,
    ReadOnly,
    // Reserved for tenant-facing ownership APIs after the MVP admin/read-only boundary.
    #[allow(dead_code)]
    User,
}

impl Role {
    fn can_read(self) -> bool {
        matches!(self, Self::Admin | Self::ReadOnly)
    }

    fn can_admin(self) -> bool {
        matches!(self, Self::Admin)
    }
}

pub fn hash_secret(secret: &str) -> Result<String, ApiError> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(secret.as_bytes(), &salt)
        .map(|hash| hash.to_string())
        .map_err(|_| ApiError::Internal("failed to hash secret"))
}

pub fn verify_secret(secret: &str, stored_hash: &str) -> bool {
    let Ok(parsed_hash) = PasswordHash::new(stored_hash) else {
        return false;
    };

    Argon2::default()
        .verify_password(secret.as_bytes(), &parsed_hash)
        .is_ok()
}

pub fn require_admin(headers: &HeaderMap, config: &MasterConfig) -> Result<(), ApiError> {
    let role = require_role(headers, config)?;
    if role.can_admin() {
        Ok(())
    } else {
        Err(ApiError::Forbidden("admin role required"))
    }
}

pub fn require_read(headers: &HeaderMap, config: &MasterConfig) -> Result<Role, ApiError> {
    let role = require_role(headers, config)?;
    if role.can_read() {
        Ok(role)
    } else {
        Err(ApiError::Forbidden("read role required"))
    }
}

pub fn verify_admin_login(username: &str, password: &str, config: &MasterConfig) -> bool {
    config.require_admin_auth()
        && username == config.admin_username
        && valid_bearer_token_shape(password)
        && verify_secret(password, &config.admin_token_hash)
}

fn require_role(headers: &HeaderMap, config: &MasterConfig) -> Result<Role, ApiError> {
    if !config.require_admin_auth() {
        return Err(ApiError::Internal(
            "MASTER_ADMIN_TOKEN_HASH must be set before using admin APIs",
        ));
    }

    let token = bearer_token(headers).ok_or(ApiError::Unauthorized)?;
    if verify_secret(token, &config.admin_token_hash) {
        return Ok(Role::Admin);
    }
    if config.has_readonly_auth() && verify_secret(token, &config.readonly_token_hash) {
        return Ok(Role::ReadOnly);
    }

    Err(ApiError::Unauthorized)
}

pub fn bearer_token(headers: &HeaderMap) -> Option<&str> {
    let token = headers
        .get(axum::http::header::AUTHORIZATION)?
        .to_str()
        .ok()?
        .strip_prefix("Bearer ")?;
    valid_bearer_token_shape(token).then_some(token)
}

fn valid_bearer_token_shape(value: &str) -> bool {
    (1..=256).contains(&value.len())
        && value.chars().all(|c| {
            c.is_ascii_graphic()
                && !c.is_ascii_whitespace()
                && !matches!(c, '"' | '\'' | '\\' | '`')
        })
}

#[cfg(test)]
mod tests {
    use std::{net::SocketAddr, path::PathBuf};

    use axum::http::{header, HeaderMap, HeaderValue};

    use crate::config::{MasterConfig, REQUEST_BODY_LIMIT_DEFAULT_BYTES};

    use super::{bearer_token, hash_secret, require_admin, require_read, verify_admin_login, Role};

    #[test]
    fn bearer_token_rejects_malformed_values_before_auth_verification() {
        assert_eq!(
            token_from_header("Bearer adm_SAFE-token.1:/+="),
            Some("adm_SAFE-token.1:/+=".to_string())
        );

        for value in [
            "Basic adm_SAFE-token.1",
            "Bearer ",
            "Bearer bad token",
            "Bearer bad\"token",
            "Bearer bad'token",
            "Bearer bad\\token",
            "Bearer bad`token",
        ] {
            assert_eq!(
                token_from_header(value),
                None,
                "value should fail: {value:?}"
            );
        }

        let oversized = format!("Bearer {}", "a".repeat(257));
        assert_eq!(token_from_header(&oversized), None);
    }

    #[test]
    fn admin_login_rejects_secrets_that_cannot_be_forwarded_as_bearer_tokens() {
        let safe_config = test_config("adm_SAFE-token.1:/+=");
        assert!(verify_admin_login(
            "admin",
            "adm_SAFE-token.1:/+=",
            &safe_config
        ));

        let unsafe_config = test_config("bad token");
        assert!(!verify_admin_login("admin", "bad token", &unsafe_config));
    }

    #[test]
    fn admin_token_can_read_and_mutate() {
        let config = test_config_with_readonly("adm_SAFE-token.1", "ro_SAFE-token.1");
        let headers = headers_for_bearer("adm_SAFE-token.1");

        assert_eq!(
            require_read(&headers, &config).expect("admin can read"),
            Role::Admin
        );
        require_admin(&headers, &config).expect("admin can mutate");
    }

    #[test]
    fn readonly_token_can_read_but_cannot_mutate() {
        let config = test_config_with_readonly("adm_SAFE-token.1", "ro_SAFE-token.1");
        let headers = headers_for_bearer("ro_SAFE-token.1");

        assert_eq!(
            require_read(&headers, &config).expect("readonly can read"),
            Role::ReadOnly
        );
        assert!(
            matches!(
                require_admin(&headers, &config),
                Err(crate::http::ApiError::Forbidden("admin role required"))
            ),
            "readonly token must not satisfy admin authorization"
        );
    }

    fn token_from_header(value: &str) -> Option<String> {
        headers_for_authorization(value)
            .and_then(|headers| bearer_token(&headers).map(str::to_owned))
    }

    fn headers_for_bearer(token: &str) -> HeaderMap {
        headers_for_authorization(&format!("Bearer {token}")).expect("valid bearer header")
    }

    fn headers_for_authorization(value: &str) -> Option<HeaderMap> {
        let mut headers = HeaderMap::new();
        headers.insert(header::AUTHORIZATION, HeaderValue::from_str(value).ok()?);
        Some(headers)
    }

    fn test_config(admin_secret: &str) -> MasterConfig {
        test_config_with_readonly(admin_secret, "")
    }

    fn test_config_with_readonly(admin_secret: &str, readonly_secret: &str) -> MasterConfig {
        MasterConfig {
            http_bind: "127.0.0.1:8080".parse::<SocketAddr>().expect("socket"),
            public_base_url: "https://agents.example.com".into(),
            installer_base_url: "https://panel.example.com".into(),
            database_url: "postgres://vps:vps@localhost:5432/vps".into(),
            admin_username: "admin".into(),
            admin_token_hash: hash_secret(admin_secret).expect("hash test admin secret"),
            readonly_token_hash: if readonly_secret.is_empty() {
                String::new()
            } else {
                hash_secret(readonly_secret).expect("hash test readonly secret")
            },
            agent_binary_path: Option::<PathBuf>::None,
            installer_ca_cert_path: Option::<PathBuf>::None,
            installer_client_identity_path: Option::<PathBuf>::None,
            admin_rate_limit_per_minute: 120,
            agent_rate_limit_per_minute: 600,
            agent_registration_rate_limit_per_minute: 30,
            request_body_limit_bytes: REQUEST_BODY_LIMIT_DEFAULT_BYTES,
        }
    }
}
