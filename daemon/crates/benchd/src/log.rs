//! `sessions/log` (#625): one session's transcript entries, for a client that cannot read the
//! machine's files, Pocket's chat on the operator's phone. The reader is `bench log`'s
//! (`bench_sessions::transcript`), against benchd's own HOME, so the two never disagree about a
//! record; this only pages it.
//!
//! The argument is a session id, never a path: the verb answers over TCP, and a path would let a
//! client read any transcript-shaped file it named. For the same reason a refusal names the id,
//! never the files looked in.

use crate::Core;
use crate::sessions::Refusal;
use bench_sessions::transcript::{self, Entry, Located, Transcript};
use bench_wire::{SessionLog, SessionLogArgs, SessionLogEntry};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs;
use std::ops::Range;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::SystemTime;

/// Entries in a page when the caller names no limit, and the most it may ask for.
const DEFAULT_LIMIT: usize = 50;
const MAX_LIMIT: usize = 200;

/// Transcripts kept read; past this the cache starts over.
const KEPT: usize = 64;

/// The last read of each transcript asked for, kept while the file's length and mtime hold.
/// Pocket asks every second and a half for an open chat and every two for each chat's preview,
/// and a long Claude transcript (60 MB measured) takes most of a second to parse.
struct Kept {
    len: u64,
    modified: SystemTime,
    transcript: Arc<Transcript>,
}

static READS: OnceLock<Mutex<HashMap<PathBuf, Kept>>> = OnceLock::new();

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
    let located = transcript::locate(&home, &args.id)
        .map_err(|_| Refusal::Refused(format!("no single transcript is {}", args.id)))?;
    let read = read(&located)?;
    let total = read.entries.len();
    let limit = args.limit.unwrap_or(DEFAULT_LIMIT).clamp(1, MAX_LIMIT);
    let range = page(total, args.before, args.after, limit);
    let entries = read.entries[range.clone()]
        .iter()
        .zip(range)
        .map(|(e, index)| entry(index, e))
        .collect();
    Ok(json!(SessionLog {
        harness: located.harness,
        id: located.id,
        total,
        entries,
        unreadable: read.unreadable.len(),
    }))
}

/// The transcript, from the cache while its file is unchanged. A file that grows during a read
/// is kept with the older length, so the next ask reads it again.
fn read(located: &Located) -> Result<Arc<Transcript>, Refusal> {
    let unreadable = || Refusal::Failed(format!("cannot read the transcript of {}", located.id));
    let meta = fs::metadata(&located.path).map_err(|_| unreadable())?;
    let (len, modified) = (meta.len(), meta.modified().map_err(|_| unreadable())?);
    let reads = READS.get_or_init(Default::default);
    if let Some(kept) = reads.lock().unwrap().get(&located.path)
        && kept.len == len
        && kept.modified == modified
    {
        return Ok(kept.transcript.clone());
    }
    let transcript = Arc::new(transcript::read(located).map_err(|_| unreadable())?);
    let mut reads = reads.lock().unwrap();
    if reads.len() >= KEPT {
        reads.clear();
    }
    reads.insert(
        located.path.clone(),
        Kept {
            len,
            modified,
            transcript: transcript.clone(),
        },
    );
    Ok(transcript)
}

/// Which entries a page holds: the last `limit`, the `limit` after `after`, or the `limit` before
/// `before`, inside `0..total`.
fn page(total: usize, before: Option<usize>, after: Option<usize>, limit: usize) -> Range<usize> {
    match (before, after) {
        (_, Some(after)) => {
            let start = after.saturating_add(1).min(total);
            start..(start + limit).min(total)
        }
        (Some(before), None) => {
            let end = before.min(total);
            end.saturating_sub(limit)..end
        }
        (None, None) => total.saturating_sub(limit)..total,
    }
}

fn entry(index: usize, e: &Entry) -> SessionLogEntry {
    SessionLogEntry {
        index,
        at_ms: e.at_ms,
        kind: e.kind,
        tool: e.tool.clone(),
        text: e.text.clone(),
        from: e.from.clone(),
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
        assert_eq!(
            page(120, None, Some(usize::MAX), 50),
            120..120,
            "no wrap to the start"
        );
        assert_eq!(page(120, Some(70), None, 50), 20..70);
        assert_eq!(page(120, Some(30), None, 50), 0..30);
        assert_eq!(page(120, Some(0), None, 50), 0..0, "nothing older");
    }
}
