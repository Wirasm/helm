//! The plan limits each harness and account last reported (#143), held in memory and answered in
//! `sessions`. Two routes in: `usage/report` from `bench statusline` (Claude), and a codex
//! hook's `usage`. Nothing is logged or persisted: a restarted benchd shows nothing until the
//! next report, which a working agent sends within a turn.

use crate::Core;
use bench_wire::{Harness, Usage};
use serde_json::Value;

/// Take in one report: merged into what is held for its harness and account (`Usage::merge`),
/// the first one included, so a held figure always has one window per length, in order.
pub fn record(c: &mut Core, usage: Usage) {
    c.usage
        .entry((usage.harness, usage.account.clone()))
        .or_insert_with(|| Usage {
            harness: usage.harness,
            account: usage.account.clone(),
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
    if usage.account.is_some() && usage.harness != Harness::Claude {
        return Err("usage/report: only a Claude plan names an account".into());
    }
    record(c, usage);
    Ok(Value::Object(Default::default()))
}

/// What `sessions` answers: one per harness and account that has reported, in harness order,
/// the default account first.
pub fn held(c: &Core) -> Vec<Usage> {
    c.usage.values().cloned().collect()
}
