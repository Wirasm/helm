//! Subscription usage limits (#143): how close the operator's Claude and codex plans are to
//! their limits, as each harness publishes it. Nothing here asks a provider: Claude Code hands
//! its statusline command `rate_limits`, and codex writes `rate_limits` into its rollout. The
//! `bench` CLI reads those on benchd's machine and reports them; benchd keeps one figure per
//! harness ([`Usage::merge`]) and answers it in `sessions`, so helm reads no harness file.

use crate::Harness;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// What one harness says about its plan's limits.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Usage {
    pub harness: Harness,
    /// One per window length: Claude's five hours and seven days, codex's primary and
    /// secondary windows.
    pub windows: Vec<UsageWindow>,
}

/// One limit window.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct UsageWindow {
    /// The window's length in minutes (300 is five hours, 10080 seven days): what tells two
    /// windows of one harness apart.
    pub minutes: u32,
    /// How much of the window's allowance is used, 0-100.
    pub used_percent: f64,
    /// When the window resets, epoch ms; absent when the harness does not say.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resets_at_ms: Option<u64>,
    /// When the harness last showed this figure, epoch ms: what makes it stale.
    pub at_ms: u64,
}

/// Claude Code's statusline windows and their lengths (its statusline docs: `five_hour` and
/// `seven_day`, `used_percentage` 0-100, `resets_at` in epoch seconds).
const CLAUDE_WINDOWS: [(&str, u32); 2] = [("five_hour", 300), ("seven_day", 10080)];

/// codex's own plan limit. A rollout also carries per-model limits (`codex_bengalfox`, named
/// after one model) and a `premium` one with no windows; neither is the plan's figure.
const CODEX_PLAN_LIMIT: &str = "codex";

impl Usage {
    /// From the JSON Claude Code pipes to a statusline command. `None` when it carries no
    /// window: an API-key session, or one that has not had its first response yet. The payload
    /// says nothing about when Claude fetched the figure, so it is stamped `now_ms`.
    pub fn from_claude_statusline(payload: &Value, now_ms: u64) -> Option<Usage> {
        let limits = &payload["rate_limits"];
        let windows: Vec<UsageWindow> = CLAUDE_WINDOWS
            .iter()
            .filter_map(|(key, minutes)| {
                let window = &limits[key];
                Some(UsageWindow {
                    minutes: *minutes,
                    used_percent: window["used_percentage"].as_f64()?,
                    resets_at_ms: window["resets_at"].as_u64().map(|s| s * 1000),
                    at_ms: now_ms,
                })
            })
            .collect();
        (!windows.is_empty()).then_some(Usage {
            harness: Harness::Claude,
            windows,
        })
    }

    /// From one line of a codex rollout: a `token_count` event carrying the plan's
    /// `rate_limits`, stamped with the line's own time. `None` for any other line.
    pub fn from_codex_rollout_line(line: &str) -> Option<Usage> {
        if !line.contains("\"rate_limits\"") {
            return None;
        }
        let record: Value = serde_json::from_str(line).ok()?;
        let limits = &record["payload"]["rate_limits"];
        if limits["limit_id"] != CODEX_PLAN_LIMIT {
            return None;
        }
        let at_ms = rfc3339_ms(record["timestamp"].as_str()?)?;
        let windows: Vec<UsageWindow> = ["primary", "secondary"]
            .iter()
            .filter_map(|key| {
                let window = &limits[key];
                Some(UsageWindow {
                    minutes: u32::try_from(window["window_minutes"].as_u64()?).ok()?,
                    used_percent: window["used_percent"].as_f64()?,
                    resets_at_ms: window["resets_at"].as_u64().map(|s| s * 1000),
                    at_ms,
                })
            })
            .collect();
        (!windows.is_empty()).then_some(Usage {
            harness: Harness::Codex,
            windows,
        })
    }

    /// Take in a newer report of the same harness. Per window, the one that resets later wins;
    /// in the same window the higher reading wins, because usage inside a window only rises.
    /// So an idle session repeating an older figure, or a resumed codex session's old record,
    /// never replaces a busier one's. An equal reading only moves `at_ms` forward.
    pub fn merge(&mut self, newer: Usage) {
        for window in newer.windows {
            match self
                .windows
                .iter_mut()
                .find(|w| w.minutes == window.minutes)
            {
                None => self.windows.push(window),
                Some(held) => match (window.resets_at_ms, window.used_percent)
                    .partial_cmp(&(held.resets_at_ms, held.used_percent))
                {
                    Some(std::cmp::Ordering::Greater) => *held = window,
                    Some(std::cmp::Ordering::Equal) => held.at_ms = held.at_ms.max(window.at_ms),
                    _ => {}
                },
            }
        }
        self.windows.sort_by_key(|w| w.minutes);
    }
}

fn rfc3339_ms(raw: &str) -> Option<u64> {
    let at =
        time::OffsetDateTime::parse(raw, &time::format_description::well_known::Rfc3339).ok()?;
    u64::try_from(at.unix_timestamp_nanos() / 1_000_000).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn fixture() -> Value {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/usage.json");
        serde_json::from_str(&std::fs::read_to_string(path).expect("the fixture is checked in"))
            .unwrap()
    }

    fn window(minutes: u32, used: f64, resets: u64, at: u64) -> UsageWindow {
        UsageWindow {
            minutes,
            used_percent: used,
            resets_at_ms: Some(resets),
            at_ms: at,
        }
    }

    /// `fixtures/usage.json` holds a real-shaped statusline payload, a rollout's lines and the
    /// usage each must give; benchd's `usage/report` request is the same value.
    #[test]
    fn the_fixture_payloads_give_the_fixture_usage() {
        let f = fixture();
        let claude =
            Usage::from_claude_statusline(&f["claude_statusline"], f["now_ms"].as_u64().unwrap())
                .unwrap();
        assert_eq!(serde_json::to_value(&claude).unwrap(), f["claude_usage"]);
        let report: crate::Request = serde_json::from_value(f["report"].clone()).unwrap();
        assert_eq!(
            crate::Verb::parse(&report.verb),
            Some(crate::Verb::UsageReport)
        );
        assert_eq!(report.args, f["claude_usage"]);

        let lines: Vec<String> = f["codex_rollout"]
            .as_array()
            .unwrap()
            .iter()
            .map(Value::to_string)
            .collect();
        let found: Vec<Usage> = lines
            .iter()
            .filter_map(|l| Usage::from_codex_rollout_line(l))
            .collect();
        assert_eq!(
            found.len(),
            1,
            "only the plan's limit counts; a per-model or windowless one is not it"
        );
        assert_eq!(serde_json::to_value(&found[0]).unwrap(), f["codex_usage"]);
    }

    #[test]
    fn a_statusline_with_no_limits_reports_nothing() {
        let payload = serde_json::json!({ "session_id": "s", "rate_limits": null });
        assert_eq!(Usage::from_claude_statusline(&payload, 1), None);
        assert_eq!(
            Usage::from_claude_statusline(&serde_json::json!({}), 1),
            None
        );
    }

    #[test]
    fn merge_keeps_the_newest_window_and_its_highest_reading() {
        let mut held = Usage {
            harness: Harness::Claude,
            windows: vec![window(300, 40.0, 1_000, 10)],
        };
        let report = |used: f64, resets: u64, at: u64| Usage {
            harness: Harness::Claude,
            windows: vec![window(300, used, resets, at)],
        };
        held.merge(report(30.0, 1_000, 20));
        assert_eq!(
            held.windows[0],
            window(300, 40.0, 1_000, 10),
            "a lower reading"
        );
        held.merge(report(90.0, 500, 30));
        assert_eq!(
            held.windows[0],
            window(300, 40.0, 1_000, 10),
            "an older window"
        );
        held.merge(report(40.0, 1_000, 40));
        assert_eq!(
            held.windows[0],
            window(300, 40.0, 1_000, 40),
            "a repeat is newer"
        );
        held.merge(report(45.0, 1_000, 50));
        assert_eq!(held.windows[0], window(300, 45.0, 1_000, 50), "a rise");
        held.merge(report(2.0, 2_000, 60));
        assert_eq!(held.windows[0], window(300, 2.0, 2_000, 60), "a new window");
        held.merge(Usage {
            harness: Harness::Claude,
            windows: vec![window(10080, 7.0, 9_000, 70)],
        });
        assert_eq!(
            held.windows.iter().map(|w| w.minutes).collect::<Vec<_>>(),
            [300, 10080]
        );
    }
}
