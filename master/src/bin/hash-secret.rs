use argon2::{
    password_hash::{PasswordHasher, SaltString},
    Argon2,
};
use rand_core::OsRng;

fn main() -> anyhow::Result<()> {
    let secret = std::env::var("SECRET_TO_HASH")
        .map_err(|_| anyhow::anyhow!("set SECRET_TO_HASH to the token you want to hash"))?;
    let salt = SaltString::generate(&mut OsRng);
    let hash = Argon2::default()
        .hash_password(secret.as_bytes(), &salt)
        .map_err(|error| anyhow::anyhow!("failed to hash secret: {error}"))?;

    println!("{hash}");
    Ok(())
}
