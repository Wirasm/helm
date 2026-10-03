//! `sessions/log` (#625): one session's transcript entries, for a client that cannot read the
//! machine's files, Pocket's chat on the operator's phone. The reader is `bench log`'s
//! (`bench_sessions::transcript`), against benchd's own HOME, so the two never disagree about a
//! record; this only pages it.
//!
//! The argument is a session id, never a path: the verb answers over TCP, and a path would let a
//! client read any transcript-shaped file it named.

use crate::Core;
use crate::sessions::Refusal;
use bench_sessions::transcript::{self, Entry, Kind};
use bench_wire::{SessionLog, SessionLogArgs, SessionLogEntry};
use serde_json::{Value, json};
use std::ops::Range;
use std::sync::{Arc, Mutex};

/// Entries in a page when the caller names no limit, and the most it may ask for.
const DEFAULT_LIMIT: usize = 50;
const MAX_LIMIT: usize = 200;

pub fn answer(core: &Arc<Mutex<Core>>, args: &Value) -> Result<Value, Refusal> {
    let args: SessionLogArgs = serde_json::from_value(args.clone())
        .map_err(|e| Refusal::Refused(format!("sessions/log args: {e}")))?;
    if args.id.contains('/') {
        return Err(Refusal::Refused(
            "sessions/log takes a session id as `bench sessions --all` lists it, not a path".into(),
        ));
    }
    if args.before.is_some() && args.after.is_some() {
        return Err(Refusal::Refused(
            "sessions/log pages one way: before or after, not both".into(),
        ));
    }
    let home = core.lock().unwrap().home.clone();
    // The file is read with no lock held: a long transcript is a long read.
    let located = transcript::locate(&home, &args.id).map_err(Refusal::Refused)?;
    let read = transcript::read(&located).map_err(Refusal::Failed)?;
    let total = read.entries.len();
    let limit = args.limit.unwrap_or(DEFAULT_LIMIT).clamp(1, MAX_LIMIT);
    let range = page(total, args.before, args.after, limit);
    let entries = read
        .entries
        .into_iter()
        .enumerate()
        .skip(range.start)
        .take(range.len())
        .map(|(index, e)| entry(index, e))
        .collect();
    Ok(json!(SessionLog {
        harness: located.harness,
        id: located.id,
        total,
        entries,
        unreadable: read.unreadable.len(),
    }))
}

/// Which entries a page holds: the last `limit`, the `limit` after `after`, or the `limit` before
/// `before`, inside `0..total`.
fn page(total: usize, before: Option<usize>, after: Option<usize>, limit: usize) -> Range<usize> {
    match (before, after) {
        (_, Some(after)) => {
            let start = (after + 1).min(total);
            start..(start + limit).min(total)
        }
        (Some(before), None) => {
            let end = before.min(total);
            end.saturating_sub(limit)..end
        }
        (None, None) => total.saturating_sub(limit)..total,
    }
}

fn entry(index: usize, e: Entry) -> SessionLogEntry {
    SessionLogEntry {
        index,
        at: e.at,
        kind: match e.kind {
            Kind::User => "user",
            Kind::Agent => "agent",
            Kind::Tool => "tool",
            Kind::Error => "error",
        }
        .into(),
        tool: e.tool,
        text: e.text,
    }
}

#[cfg(test)]
mod tests {
    use super::page;

    #[test]
    fn a_page_is_the_last_entries_or_the_ones_either_side_of_a_cursor() {
        assert_eq!(page(120, None, None, 50), 70..120);
        assert_eq!(page(10, None, None, 50), 0..10);
        assert_eq!(page(120, None, Some(99), 50), 100..120);
        assert_eq!(page(120, None, Some(119), 50), 120..120, "nothing new");
        assert_eq!(page(120, None, Some(500), 50), 120..120);
        assert_eq!(page(120, Some(70), None, 50), 20..70);
        assert_eq!(page(120, Some(30), None, 50), 0..30);
        assert_eq!(page(120, Some(0), None, 50), 0..0, "nothing older");
    }
}
