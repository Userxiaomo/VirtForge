use std::fmt;

use serde::{Deserialize, Serialize};

#[derive(Clone, Deserialize, Serialize)]
pub struct BootstrapTokenPlaintext(pub String);

#[derive(Clone, Deserialize, Serialize)]
pub struct AgentCredentialPlaintext(pub String);

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct RedactedSecret {
    pub hint: String,
}

impl fmt::Debug for BootstrapTokenPlaintext {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_tuple("BootstrapTokenPlaintext")
            .field(&RedactedSecret::from_secret(&self.0))
            .finish()
    }
}

impl fmt::Debug for AgentCredentialPlaintext {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_tuple("AgentCredentialPlaintext")
            .field(&RedactedSecret::from_secret(&self.0))
            .finish()
    }
}

impl RedactedSecret {
    pub fn from_secret(secret: &str) -> Self {
        if secret.chars().count() <= 8 {
            return Self { hint: "***".into() };
        }

        let suffix = secret
            .chars()
            .rev()
            .take(4)
            .collect::<String>()
            .chars()
            .rev()
            .collect::<String>();

        Self {
            hint: format!("***{suffix}"),
        }
    }
}

pub fn is_safe_image_file_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 80
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
        && name.split('.').all(|part| !part.is_empty())
}

#[cfg(test)]
mod tests {
    use super::{AgentCredentialPlaintext, BootstrapTokenPlaintext, RedactedSecret};

    #[test]
    fn redacted_secret_debug_does_not_expose_short_secrets() {
        let bootstrap = format!("{:?}", BootstrapTokenPlaintext("bt_x".into()));
        let credential = format!("{:?}", AgentCredentialPlaintext("ag_y".into()));
        let hint = RedactedSecret::from_secret("abc").hint;

        assert!(!bootstrap.contains("bt_x"));
        assert!(!credential.contains("ag_y"));
        assert_eq!(hint, "***");
    }

    #[test]
    fn redacted_secret_keeps_suffix_hint_for_long_secrets() {
        let hint = RedactedSecret::from_secret("bt_safe-token.1").hint;

        assert_eq!(hint, "***en.1");
    }
}
