use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use sha2::{Digest, Sha256};

#[derive(Clone, Debug)]
pub struct RateLimiter {
    buckets: Arc<Mutex<HashMap<String, Bucket>>>,
    window: Duration,
}

#[derive(Clone, Copy, Debug)]
struct Bucket {
    count: u32,
    reset_at: Instant,
}

impl RateLimiter {
    pub fn new(window: Duration) -> Self {
        Self {
            buckets: Arc::new(Mutex::new(HashMap::new())),
            window,
        }
    }

    pub fn check(&self, key: impl Into<String>, max_requests: u32) -> bool {
        if max_requests == 0 {
            return false;
        }

        let now = Instant::now();
        let mut buckets = self.buckets.lock().expect("rate limiter mutex poisoned");
        buckets.retain(|_, bucket| bucket.reset_at > now);

        let bucket = buckets.entry(key.into()).or_insert(Bucket {
            count: 0,
            reset_at: now + self.window,
        });

        if bucket.reset_at <= now {
            *bucket = Bucket {
                count: 0,
                reset_at: now + self.window,
            };
        }

        if bucket.count >= max_requests {
            return false;
        }

        bucket.count += 1;
        true
    }
}

pub fn secret_bucket(prefix: &str, secret: &str) -> String {
    format!("{prefix}:secret:{}", hex::encode(Sha256::digest(secret)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_requests_after_the_limit() {
        let limiter = RateLimiter::new(Duration::from_secs(60));

        assert!(limiter.check("admin:all", 2));
        assert!(limiter.check("admin:all", 2));
        assert!(!limiter.check("admin:all", 2));
    }

    #[test]
    fn separates_buckets() {
        let limiter = RateLimiter::new(Duration::from_secs(60));

        assert!(limiter.check("agent:a", 1));
        assert!(limiter.check("agent:b", 1));
        assert!(!limiter.check("agent:a", 1));
    }

    #[test]
    fn secret_bucket_does_not_include_the_secret() {
        let bucket = secret_bucket("admin", "super-secret-token");

        assert!(bucket.starts_with("admin:secret:"));
        assert!(!bucket.contains("super-secret-token"));
    }

    #[test]
    fn secret_bucket_uses_full_sha256_digest() {
        let bucket = secret_bucket("admin", "super-secret-token");
        let digest = bucket
            .strip_prefix("admin:secret:")
            .expect("bucket should include prefix");

        assert_eq!(digest.len(), 64);
        assert!(digest.chars().all(|c| c.is_ascii_hexdigit()));
    }
}
