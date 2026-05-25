use chrono::{DateTime, Utc};
use sqlx::{PgPool, Postgres, Row, Transaction};
use uuid::Uuid;
use vps_shared::{is_safe_image_file_name, CreateImageRequest, ImageDto, ImageId};

use crate::http::ApiError;

pub async fn create_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    request: CreateImageRequest,
) -> Result<ImageDto, ApiError> {
    validate_image_name(&request.name)?;
    validate_image_file_name(&request.file_name)?;

    let row = sqlx::query(
        r#"
        INSERT INTO images (id, name, file_name, enabled)
        VALUES ($1, $2, $3, $4)
        RETURNING id, name, file_name, enabled, created_at, updated_at
        "#,
    )
    .bind(Uuid::new_v4())
    .bind(request.name)
    .bind(request.file_name)
    .bind(request.enabled)
    .fetch_one(&mut **tx)
    .await?;

    image_from_row(row)
}

pub async fn list(pool: &PgPool) -> Result<Vec<ImageDto>, ApiError> {
    let rows = sqlx::query(
        r#"
        SELECT id, name, file_name, enabled, created_at, updated_at
        FROM images
        ORDER BY name ASC
        "#,
    )
    .fetch_all(pool)
    .await?;

    rows.into_iter().map(image_from_row).collect()
}

pub async fn set_enabled_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    image_id: ImageId,
    enabled: bool,
) -> Result<ImageDto, ApiError> {
    let row = sqlx::query(
        r#"
        UPDATE images
        SET enabled = $2, updated_at = now()
        WHERE id = $1
        RETURNING id, name, file_name, enabled, created_at, updated_at
        "#,
    )
    .bind(image_id.0)
    .bind(enabled)
    .fetch_optional(&mut **tx)
    .await?
    .ok_or(ApiError::NotFound("image not found"))?;

    image_from_row(row)
}

pub async fn ensure_enabled_in_tx(
    tx: &mut Transaction<'_, Postgres>,
    file_name: &str,
) -> Result<(), ApiError> {
    validate_image_file_name(file_name)?;
    let enabled =
        sqlx::query_scalar::<_, Option<bool>>("SELECT enabled FROM images WHERE file_name = $1")
            .bind(file_name)
            .fetch_optional(&mut **tx)
            .await?
            .flatten();

    validate_image_enabled_result(enabled)
}

fn validate_image_enabled_result(enabled: Option<bool>) -> Result<(), ApiError> {
    match enabled {
        Some(true) => Ok(()),
        Some(false) => Err(ApiError::Conflict("image is disabled")),
        None => Err(ApiError::NotFound("image not registered")),
    }
}

fn image_from_row(row: sqlx::postgres::PgRow) -> Result<ImageDto, ApiError> {
    Ok(ImageDto {
        id: ImageId(row.try_get("id")?),
        name: row.try_get("name")?,
        file_name: row.try_get("file_name")?,
        enabled: row.try_get("enabled")?,
        created_at: row.try_get::<DateTime<Utc>, _>("created_at")?,
        updated_at: row.try_get::<DateTime<Utc>, _>("updated_at")?,
    })
}

fn validate_image_name(name: &str) -> Result<(), ApiError> {
    if name.is_empty()
        || name.len() > 80
        || !name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == ' ')
    {
        return Err(ApiError::Conflict(
            "image name must be 1-80 chars and only contain ascii letters, numbers, spaces, '-' or '_'",
        ));
    }
    Ok(())
}

fn validate_image_file_name(file_name: &str) -> Result<(), ApiError> {
    if !is_safe_image_file_name(file_name) {
        return Err(ApiError::Conflict(
            "image file name must be a safe 1-80 char ascii file name without empty dot segments",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn image_file_name_rejects_path_like_values() {
        assert!(validate_image_file_name("../debian.qcow2").is_err());
        assert!(validate_image_file_name("debian/12.qcow2").is_err());
        assert!(validate_image_file_name(".hidden.qcow2").is_err());
        assert!(validate_image_file_name("bad..name.qcow2").is_err());
        assert!(validate_image_file_name("debian-12.").is_err());
        assert!(validate_image_file_name("debian-12.qcow2").is_ok());
    }

    #[test]
    fn image_enabled_result_preserves_api_errors() {
        assert!(validate_image_enabled_result(Some(true)).is_ok());
        assert!(matches!(
            validate_image_enabled_result(Some(false)),
            Err(ApiError::Conflict("image is disabled"))
        ));
        assert!(matches!(
            validate_image_enabled_result(None),
            Err(ApiError::NotFound("image not registered"))
        ));
    }
}
