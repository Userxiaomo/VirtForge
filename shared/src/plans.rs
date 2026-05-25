use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::PlanId;

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct CreatePlanRequest {
    pub name: String,
    pub slug: String,
    pub cpu_cores: u16,
    pub memory_mb: u32,
    pub disk_gb: u32,
    #[serde(default = "default_enabled")]
    pub enabled: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct PlanDto {
    pub id: PlanId,
    pub name: String,
    pub slug: String,
    pub cpu_cores: u16,
    pub memory_mb: u32,
    pub disk_gb: u32,
    pub enabled: bool,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct UpdatePlanEnabledRequest {
    pub enabled: bool,
}

fn default_enabled() -> bool {
    true
}
