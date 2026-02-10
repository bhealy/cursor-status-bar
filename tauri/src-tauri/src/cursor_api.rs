use crate::models::*;
use chrono::{Datelike, DateTime, Duration, Local, NaiveDate, Utc};
use reqwest::Client;
use std::collections::HashMap;

pub struct CursorApi {
    client: Client,
    session_token: String,
    user_id: String,
}

impl CursorApi {
    pub fn new(session_token: String, user_id: String) -> Self {
        Self {
            client: Client::new(),
            session_token,
            user_id,
        }
    }

    /// Fetch the billing period start date from the legacy endpoint.
    async fn fetch_billing_period_start(&self) -> Result<DateTime<Utc>, Box<dyn std::error::Error + Send + Sync>> {
        let url = format!("https://cursor.com/api/usage?user={}", self.user_id);

        let resp = self
            .client
            .get(&url)
            .header("Cookie", format!("WorkosCursorSessionToken={}", self.session_token))
            .send()
            .await?;

        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(format!("HTTP {}: {}", status, body).into());
        }

        let legacy: LegacyUsageResponse = resp.json().await?;

        if let Some(start_str) = legacy.start_of_month() {
            if let Ok(dt) = DateTime::parse_from_rfc3339(start_str) {
                return Ok(dt.with_timezone(&Utc));
            }
            // Try parsing as ISO 8601 with fractional seconds
            if let Ok(dt) = chrono::DateTime::parse_from_str(start_str, "%Y-%m-%dT%H:%M:%S%.fZ") {
                return Ok(dt.with_timezone(&Utc));
            }
        }

        // Fallback: start of current calendar month
        let now = Local::now();
        let start = NaiveDate::from_ymd_opt(now.year(), now.month(), 1)
            .unwrap()
            .and_hms_opt(0, 0, 0)
            .unwrap();
        Ok(DateTime::from_naive_utc_and_offset(start, Utc))
    }

    /// Fetch usage events from the current API.
    async fn fetch_usage_events(
        &self,
        from: DateTime<Utc>,
        to: DateTime<Utc>,
    ) -> Result<Vec<UsageEvent>, Box<dyn std::error::Error + Send + Sync>> {
        let url = "https://cursor.com/api/dashboard/get-filtered-usage-events";

        let body = serde_json::json!({
            "teamId": 0,
            "startDate": from.timestamp_millis().to_string(),
            "endDate": to.timestamp_millis().to_string(),
            "page": 1,
            "pageSize": 1000
        });

        let resp = self
            .client
            .post(url)
            .header("Content-Type", "application/json")
            .header("Cookie", format!("WorkosCursorSessionToken={}", self.session_token))
            .header("Origin", "https://cursor.com")
            .header("Referer", "https://cursor.com/dashboard?tab=usage")
            .header("Sec-Fetch-Site", "same-origin")
            .header("Sec-Fetch-Mode", "cors")
            .header("Sec-Fetch-Dest", "empty")
            .header("Accept", "*/*")
            .header("Accept-Language", "en")
            .header("Cache-Control", "no-cache")
            .header("Pragma", "no-cache")
            .header(
                "User-Agent",
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            )
            .body(body.to_string())
            .send()
            .await?;

        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            return Err(format!("HTTP {}: {}", status, body).into());
        }

        let events_resp: UsageEventsResponse = resp.json().await?;
        Ok(events_resp.usage_events_display.unwrap_or_default())
    }

    /// Fetch all data and aggregate into display format.
    pub async fn fetch_display_data(&self) -> Result<UsageDisplayData, Box<dyn std::error::Error + Send + Sync>> {
        let billing_start = self.fetch_billing_period_start().await?;
        let now = Utc::now();

        // Fetch from the earlier of (billing start, 30 days ago)
        let thirty_days_ago = now - Duration::days(30);
        let fetch_start = billing_start.min(thirty_days_ago);

        let events = self.fetch_usage_events(fetch_start, now).await?;

        // Time boundaries
        let start_of_today = Local::now()
            .date_naive()
            .and_hms_opt(0, 0, 0)
            .unwrap()
            .and_local_timezone(Local)
            .unwrap()
            .with_timezone(&Utc);
        let seven_days_ago = now - Duration::days(7);

        // Aggregate by model (billing period) and by time buckets
        let mut by_model: HashMap<String, (i32, f64, i64)> = HashMap::new();
        let mut total_cents: f64 = 0.0;
        let mut total_tokens: i64 = 0;

        let mut today_cents: f64 = 0.0;
        let mut today_reqs: i32 = 0;
        let mut today_tokens: i64 = 0;

        let mut week7_cents: f64 = 0.0;
        let mut week7_reqs: i32 = 0;
        let mut week7_tokens: i64 = 0;

        let mut days30_cents: f64 = 0.0;
        let mut days30_reqs: i32 = 0;
        let mut days30_tokens: i64 = 0;

        for event in &events {
            let model = event.model.clone().unwrap_or_else(|| "unknown".to_string());
            let cents = event.cost_cents();
            let tokens = event
                .token_usage
                .as_ref()
                .map(|t| t.total_tokens())
                .unwrap_or(0);

            // Parse timestamp (milliseconds since epoch)
            let timestamp_ms: f64 = event.timestamp.parse().unwrap_or(0.0);
            let event_date = DateTime::from_timestamp_millis(timestamp_ms as i64)
                .unwrap_or(DateTime::UNIX_EPOCH);

            // Billing period totals
            if event_date >= billing_start {
                total_cents += cents;
                total_tokens += tokens;

                let entry = by_model.entry(model).or_insert((0, 0.0, 0));
                entry.0 += 1;
                entry.1 += cents;
                entry.2 += tokens;
            }

            // Time bucket aggregation
            if event_date >= start_of_today {
                today_cents += cents;
                today_reqs += 1;
                today_tokens += tokens;
            }
            if event_date >= seven_days_ago {
                week7_cents += cents;
                week7_reqs += 1;
                week7_tokens += tokens;
            }
            if event_date >= thirty_days_ago {
                days30_cents += cents;
                days30_reqs += 1;
                days30_tokens += tokens;
            }
        }

        // Build line items sorted by cost descending
        let mut line_items: Vec<LineItem> = by_model
            .into_iter()
            .map(|(model, (count, cents, tokens))| LineItem {
                model_name: model,
                request_count: count,
                cost_dollars: cents / 100.0,
                total_tokens: tokens,
            })
            .collect();
        line_items.sort_by(|a, b| b.cost_dollars.partial_cmp(&a.cost_dollars).unwrap());

        let billing_period_event_count: i32 = line_items.iter().map(|i| i.request_count).sum();

        Ok(UsageDisplayData {
            total_requests: billing_period_event_count,
            total_spend_dollars: total_cents / 100.0,
            total_tokens,
            line_items,
            billing_period_start: billing_start.to_rfc3339(),
            today: PeriodSummary {
                label: "Today".to_string(),
                requests: today_reqs,
                spend_dollars: today_cents / 100.0,
                tokens: today_tokens,
            },
            last7_days: PeriodSummary {
                label: "Last 7 Days".to_string(),
                requests: week7_reqs,
                spend_dollars: week7_cents / 100.0,
                tokens: week7_tokens,
            },
            last30_days: PeriodSummary {
                label: "Last 30 Days".to_string(),
                requests: days30_reqs,
                spend_dollars: days30_cents / 100.0,
                tokens: days30_tokens,
            },
        })
    }
}
