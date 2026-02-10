use serde::{Deserialize, Serialize};
use std::collections::HashMap;

// ── API Response Models ──

/// Response from POST https://cursor.com/api/dashboard/get-filtered-usage-events
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageEventsResponse {
    pub usage_events_display: Option<Vec<UsageEvent>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageEvent {
    pub timestamp: String,
    pub model: Option<String>,
    pub kind: Option<String>,
    pub usage_based_costs: Option<String>,
    pub is_token_based_call: Option<bool>,
    pub token_usage: Option<TokenUsage>,
    pub is_chargeable: Option<bool>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenUsage {
    pub input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
    pub cache_write_tokens: Option<i64>,
    pub cache_read_tokens: Option<i64>,
    pub total_cents: Option<f64>,
}

impl TokenUsage {
    pub fn total_tokens(&self) -> i64 {
        self.input_tokens.unwrap_or(0)
            + self.output_tokens.unwrap_or(0)
            + self.cache_write_tokens.unwrap_or(0)
            + self.cache_read_tokens.unwrap_or(0)
    }
}

impl UsageEvent {
    pub fn cost_cents(&self) -> f64 {
        self.token_usage
            .as_ref()
            .and_then(|t| t.total_cents)
            .unwrap_or(0.0)
    }

    pub fn cost_dollars(&self) -> f64 {
        self.cost_cents() / 100.0
    }
}

/// Response from GET https://cursor.com/api/usage?user={userId}
/// Uses dynamic keys — we only care about startOfMonth.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LegacyUsageResponse {
    #[serde(flatten)]
    pub extra: HashMap<String, serde_json::Value>,
}

impl LegacyUsageResponse {
    pub fn start_of_month(&self) -> Option<&str> {
        self.extra
            .get("startOfMonth")
            .and_then(|v| v.as_str())
    }
}

// ── Display Models (sent to frontend) ──

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageDisplayData {
    pub total_requests: i32,
    pub total_spend_dollars: f64,
    pub total_tokens: i64,
    pub line_items: Vec<LineItem>,
    pub billing_period_start: String,
    pub today: PeriodSummary,
    pub last7_days: PeriodSummary,
    pub last30_days: PeriodSummary,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PeriodSummary {
    pub label: String,
    pub requests: i32,
    pub spend_dollars: f64,
    pub tokens: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LineItem {
    pub model_name: String,
    pub request_count: i32,
    pub cost_dollars: f64,
    pub total_tokens: i64,
}
