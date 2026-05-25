use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, thiserror::Error)]
pub enum RequestSignatureError {
    #[error("invalid hmac key")]
    InvalidKey,
    #[error("malformed signature")]
    MalformedSignature,
    #[error("invalid signature")]
    InvalidSignature,
}

pub fn sign_agent_request(
    credential: &str,
    method: &str,
    path: &str,
    body: &[u8],
    timestamp: i64,
    nonce: &str,
) -> Result<String, RequestSignatureError> {
    let canonical = canonical_request(method, path, body, timestamp, nonce);
    let mut mac = HmacSha256::new_from_slice(credential.as_bytes())
        .map_err(|_| RequestSignatureError::InvalidKey)?;
    mac.update(canonical.as_bytes());
    Ok(hex::encode(mac.finalize().into_bytes()))
}

pub fn verify_agent_request_signature(
    credential: &str,
    method: &str,
    path: &str,
    body: &[u8],
    timestamp: i64,
    nonce: &str,
    signature_hex: &str,
) -> Result<(), RequestSignatureError> {
    if !valid_signature_hex(signature_hex) {
        return Err(RequestSignatureError::MalformedSignature);
    }
    let canonical = canonical_request(method, path, body, timestamp, nonce);
    let signature =
        hex::decode(signature_hex).map_err(|_| RequestSignatureError::MalformedSignature)?;
    let mut mac = HmacSha256::new_from_slice(credential.as_bytes())
        .map_err(|_| RequestSignatureError::InvalidKey)?;
    mac.update(canonical.as_bytes());
    mac.verify_slice(&signature)
        .map_err(|_| RequestSignatureError::InvalidSignature)
}

fn valid_signature_hex(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn canonical_request(method: &str, path: &str, body: &[u8], timestamp: i64, nonce: &str) -> String {
    let body_hash = Sha256::digest(body);
    format!(
        "{}\n{}\n{}\n{}\n{}",
        method.to_ascii_uppercase(),
        path,
        hex::encode(body_hash),
        timestamp,
        nonce
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signature_round_trips() {
        let body = br#"{"node_id":"n1"}"#;
        let signature =
            sign_agent_request("secret", "post", "/api/agent/heartbeat", body, 1, "nonce")
                .expect("signature");

        verify_agent_request_signature(
            "secret",
            "POST",
            "/api/agent/heartbeat",
            body,
            1,
            "nonce",
            &signature,
        )
        .expect("valid signature");
    }

    #[test]
    fn signature_rejects_body_tampering() {
        let signature = sign_agent_request("secret", "POST", "/path", br#"{"a":1}"#, 1, "nonce")
            .expect("signature");

        let result = verify_agent_request_signature(
            "secret",
            "POST",
            "/path",
            br#"{"a":2}"#,
            1,
            "nonce",
            &signature,
        );

        assert!(matches!(
            result,
            Err(RequestSignatureError::InvalidSignature)
        ));
    }

    #[test]
    fn signature_rejects_malformed_signature_shape_before_verification() {
        for malformed in ["abc", &"z".repeat(64)] {
            let error = verify_agent_request_signature(
                "secret",
                "POST",
                "/path",
                br#"{"a":1}"#,
                1,
                "nonce",
                malformed,
            )
            .expect_err("malformed signature should fail before HMAC comparison");

            assert_eq!(error.to_string(), "malformed signature");
        }
    }
}
