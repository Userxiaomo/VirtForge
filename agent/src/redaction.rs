const REDACTED: &str = "[REDACTED]";
const PRIVATE_KEY_REDACTED: &str = "[REDACTED PRIVATE KEY]";
const SENSITIVE_KEYS: &[&str] = &[
    "authorization",
    "bootstrap_token",
    "credential",
    "cookie",
    "install_command",
    "password",
    "private_key",
    "secret",
    "signature",
    "token",
];

pub fn redact_text(input: &str) -> String {
    let without_private_keys = redact_private_key_blocks(input);
    let without_url_userinfo = redact_url_userinfo(&without_private_keys);
    redact_key_values(&without_url_userinfo)
}

fn redact_url_userinfo(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut output = String::with_capacity(input.len());
    let mut cursor = 0;
    let mut search_start = 0;

    while let Some(relative_scheme_end) = input[search_start..].find("://") {
        let authority_start = search_start + relative_scheme_end + 3;
        let mut scan = authority_start;
        let mut at_sign = None;

        while scan < bytes.len() {
            match bytes[scan] {
                b'@' => {
                    at_sign = Some(scan);
                    break;
                }
                b'/' | b'?' | b'#' | b'"' | b'\'' | b'<' | b'>' | b'`' | b'\\' | b' ' | b'\t'
                | b'\r' | b'\n' => break,
                _ => scan += 1,
            }
        }

        output.push_str(&input[cursor..authority_start]);
        if let Some(at_sign) = at_sign {
            output.push_str(REDACTED);
            output.push('@');
            cursor = at_sign + 1;
            search_start = cursor;
        } else {
            cursor = authority_start;
            search_start = scan;
        }
    }

    output.push_str(&input[cursor..]);
    output
}

fn redact_private_key_blocks(input: &str) -> String {
    let mut output = String::new();
    let mut in_private_key = false;

    for line in input.lines() {
        if line.contains("-----BEGIN ") && line.contains(" PRIVATE KEY-----") {
            if !output.is_empty() {
                output.push('\n');
            }
            output.push_str(PRIVATE_KEY_REDACTED);
            in_private_key = true;
            continue;
        }

        if in_private_key {
            if line.contains("-----END ") && line.contains(" PRIVATE KEY-----") {
                in_private_key = false;
            }
            continue;
        }

        if !output.is_empty() {
            output.push('\n');
        }
        output.push_str(line);
    }

    if input.ends_with('\n') {
        output.push('\n');
    }

    output
}

fn redact_key_values(input: &str) -> String {
    let mut output = String::with_capacity(input.len());
    let chars: Vec<char> = input.chars().collect();
    let mut index = 0;

    while index < chars.len() {
        if let Some((key_end, value_start, quote)) = sensitive_assignment_at(&chars, index) {
            let key: String = chars[index..key_end].iter().collect();
            output.extend(chars[index..value_start].iter());
            output.push_str(REDACTED);
            index = value_end(&chars, value_start, quote, &key);
        } else {
            output.push(chars[index]);
            index += 1;
        }
    }

    output
}

fn sensitive_assignment_at(chars: &[char], start: usize) -> Option<(usize, usize, Option<char>)> {
    if start > 0 && is_key_char(chars[start - 1]) {
        return None;
    }

    let mut key_end = start;
    while key_end < chars.len() && is_key_char(chars[key_end]) {
        key_end += 1;
    }
    if key_end == start {
        return None;
    }

    let key: String = chars[start..key_end].iter().collect();
    if !is_sensitive_key(&key) {
        return None;
    }

    let mut cursor = key_end;
    while cursor < chars.len() && chars[cursor].is_ascii_whitespace() {
        cursor += 1;
    }
    if cursor >= chars.len() || !matches!(chars[cursor], '=' | ':') {
        return None;
    }
    cursor += 1;
    while cursor < chars.len() && chars[cursor].is_ascii_whitespace() {
        cursor += 1;
    }
    if cursor >= chars.len() {
        return None;
    }

    let quote = matches!(chars[cursor], '"' | '\'').then_some(chars[cursor]);
    let value_start = if quote.is_some() { cursor + 1 } else { cursor };
    Some((key_end, value_start, quote))
}

fn value_end(chars: &[char], start: usize, quote: Option<char>, key: &str) -> usize {
    let mut cursor = start;
    if let Some(quote) = quote {
        while cursor < chars.len() && chars[cursor] != quote {
            cursor += 1;
        }
        return cursor;
    }

    if is_cookie_header_like_key(key) {
        while cursor < chars.len() && !matches!(chars[cursor], '\r' | '\n') {
            cursor += 1;
        }
        return cursor;
    }

    let first_token_end = unquoted_token_end(chars, start);
    if is_auth_header_like_key(key) {
        let first_token: String = chars[start..first_token_end].iter().collect();
        if is_auth_scheme(&first_token) {
            cursor = first_token_end;
            while cursor < chars.len()
                && chars[cursor].is_ascii_whitespace()
                && !matches!(chars[cursor], '\r' | '\n')
            {
                cursor += 1;
            }
            let credential_end = unquoted_token_end(chars, cursor);
            if credential_end > cursor {
                return credential_end;
            }
        }
    }

    first_token_end
}

fn unquoted_token_end(chars: &[char], start: usize) -> usize {
    let mut cursor = start;
    while cursor < chars.len()
        && !chars[cursor].is_ascii_whitespace()
        && !matches!(chars[cursor], ',' | ';')
    {
        cursor += 1;
    }
    cursor
}

fn is_auth_header_like_key(key: &str) -> bool {
    let normalized = key.to_ascii_lowercase().replace('-', "_");
    normalized.contains("authorization") || normalized.contains("credential")
}

fn is_cookie_header_like_key(key: &str) -> bool {
    key.to_ascii_lowercase()
        .replace('-', "_")
        .contains("cookie")
}

fn is_auth_scheme(value: &str) -> bool {
    matches!(
        value.to_ascii_lowercase().as_str(),
        "bearer" | "basic" | "digest" | "token"
    )
}

fn is_key_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '_' | '-')
}

fn is_sensitive_key(key: &str) -> bool {
    let normalized = key.to_ascii_lowercase().replace('-', "_");
    SENSITIVE_KEYS
        .iter()
        .any(|sensitive| normalized.contains(sensitive))
}

#[cfg(test)]
mod tests {
    use super::redact_text;

    #[test]
    fn redacts_common_secret_shapes() {
        let redacted = redact_text(
            r#"bootstrap_token=bt_123 password: "hunter2" X-Agent-Credential='ag_456'"#,
        );

        assert!(!redacted.contains("bt_123"));
        assert!(!redacted.contains("hunter2"));
        assert!(!redacted.contains("ag_456"));
        assert!(redacted.contains("bootstrap_token=[REDACTED]"));
        assert!(redacted.contains("password: \"[REDACTED]\""));
    }

    #[test]
    fn redacts_url_userinfo_credentials() {
        let redacted = redact_text(
            "failed to connect to postgres://vps:db-secret@postgres:5432/vps and https://agent:ag-secret@example.com/api",
        );

        assert!(!redacted.contains("db-secret"));
        assert!(!redacted.contains("ag-secret"));
        assert!(redacted.contains("postgres://[REDACTED]@postgres:5432/vps"));
        assert!(redacted.contains("https://[REDACTED]@example.com/api"));
    }

    #[test]
    fn redacts_authorization_scheme_and_token() {
        let redacted = redact_text("Authorization: Bearer ag_plaintext request failed");

        assert!(!redacted.contains("Bearer"));
        assert!(!redacted.contains("ag_plaintext"));
        assert!(redacted.contains("Authorization: [REDACTED] request failed"));
    }

    #[test]
    fn redacts_agent_auth_header_values() {
        let redacted = redact_text(
            "X-Agent-Credential: ag_header_secret X-Agent-Signature: sig_header_secret",
        );

        assert!(!redacted.contains("ag_header_secret"));
        assert!(!redacted.contains("sig_header_secret"));
        assert!(redacted.contains("X-Agent-Credential: [REDACTED]"));
        assert!(redacted.contains("X-Agent-Signature: [REDACTED]"));
    }

    #[test]
    fn redacts_cookie_headers_without_leaking_later_cookie_values() {
        let redacted =
            redact_text("Set-Cookie: agent_session=session-secret; Path=/; HttpOnly\nnext header");

        assert!(!redacted.contains("session-secret"));
        assert!(!redacted.contains("HttpOnly"));
        assert_eq!(redacted, "Set-Cookie: [REDACTED]\nnext header");
    }

    #[test]
    fn redacts_private_key_blocks() {
        let redacted = redact_text(
            "before\n-----BEGIN OPENSSH PRIVATE KEY-----\nsecret\n-----END OPENSSH PRIVATE KEY-----\nafter",
        );

        assert_eq!(redacted, "before\n[REDACTED PRIVATE KEY]\nafter");
    }

    #[test]
    fn redacts_install_command_key_values() {
        let redacted = redact_text(
            r#"install_command="sudo bash install-agent.sh --bootstrap-token bt_install_secret""#,
        );

        assert!(!redacted.contains("bt_install_secret"));
        assert_eq!(redacted, r#"install_command="[REDACTED]""#);
    }
}
