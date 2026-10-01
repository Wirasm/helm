//! The plan limits each harness last reported (#143), held in memory and answered in
//! `sessions`. Two routes in: `usage/report` from `bench statusline` (Claude), and a codex
//! hook's `usage`. Nothing is logged or persisted: a restarted benchd shows nothing until the
//! next report, which a working agent sends within a turn.

use crate::Core;
use bench_wire::{Harness, Usage};
use serde_json::Value;

/// Take in one report: merged into what is held for its harness (`Usage::merge`), the first
/// one included, so a held figure always has one window per length, in order.
pub fn record(c: &mut Core, usage: Usage) {
    c.usage
        .entry(usage.harness)
        .or_insert_with(|| Usage {
            harness: usage.harness,
            windows: Vec::new(),
        })
        .merge(usage);
}

/// `usage/report`. Only Claude and codex publish plan limits; pi has none to report.
pub fn answer(c: &mut Core, args: &Value) -> Result<Value, String> {
    let usage: Usage =
        serde_json::from_value(args.clone()).map_err(|e| format!("usage/report args: {e}"))?;
    if usage.harness == Harness::Pi {
        return Err("usage/report: pi publishes no plan limits".into());
    }
    record(c, usage);
    Ok(Value::Object(Default::default()))
}

/// What `sessions` answers: one per harness that has reported, in harness order.
pub fn held(c: &Core) -> Vec<Usage> {
    c.usage.values().cloned().collect()
}
