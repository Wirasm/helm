//! The session list in the daemon (#384): `sessions/all`, `sessions/dismiss`, and the two
//! records benchd is the only writer of — `<root>/sessions/hosted.json` and
//! `<root>/sessions/dismissed.json`.
//!
//! `bench-sessions` reads the harness files and decides the rows; this module owns what the
//! daemon remembers. The harness files are read **without the core mutex** (a cold build
//! reads many files; no verb waits on that), under a cache mutex of their own. The record
//! changes a build produces are then applied under the core mutex: logged first, then
//! written, the same order as the layout verbs.

use crate::{Core, now_rfc3339};
use bench_doc::StandardPath;
use bench_sessions::{BenchSession, Cache, Inputs};
use bench_wire::{
    DISMISSED_RECORD_FORMAT, DISMISSED_RECORD_VERSION, Dismissal, DismissedRecord,
    HOSTED_RECORD_FORMAT, HOSTED_RECORD_VERSION, Harness, HostedRecord, HostedSession, HostedVia,
    MailAddress, SessionKey, SessionsArgs, Unreadable, dismissed_path, hosted_path,
};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::fs;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, LazyLock, Mutex};

/// The per-file cache, kept for the daemon's life. Its own mutex, never the core's: two
/// builds serialize on it, nothing else waits for either.
static CACHE: LazyLock<Mutex<Cache>> = LazyLock::new(|| Mutex::new(Cache::default()));

/// What the daemon remembers about sessions.
#[derive(Default)]
pub struct SessionRecords {
    pub hosted: Vec<HostedSession>,
    pub dismissed: Vec<Dismissal>,
    /// Unreadable files already logged, so a file that stays unreadable is one
    /// `sessions/unreadable` event rather than one per build. Every reply still lists it.
    reported: HashSet<(String, String, String)>,
}

// ---------------------------------------------------------------------------
// Verbs
// ---------------------------------------------------------------------------

pub fn answer_all(core: &Arc<Mutex<Core>>, args: &Value) -> Result<Value, Refusal> {
    let args: SessionsArgs = serde_json::from_value(args.clone())
        .map_err(|e| Refusal::Refused(format!("sessions/all args: {e}")))?;
    let workspace = StandardPath::new(&args.workspace)
        .map_err(|why| Refusal::Refused(format!("workspace: {why}")))?;

    let (home, root, pushable, bench, hosted, dismissed, hooked) = {
        let c = core.lock().unwrap();
        let bench: Vec<BenchSession> = c
            .sessions
            .values()
            .filter_map(|s| {
                Some(BenchSession {
                    session: s.id.clone(),
                    harness: Harness::parse(s.agent.name())?,
                    runtime_session: s.runtime_session.clone(),
                    cwd: s.cwd.clone(),
                    pid: s.pid,
                    live: s.is_live(),
                    spawned_ms: now_ms().saturating_sub(s.spawned_at.elapsed().as_millis() as u64),
                    handle: s.handle.clone(),
                })
            })
            .collect();
        (
            c.home.clone(),
            c.root.clone(),
            c.pushable_handles(),
            bench,
            c.session_records.hosted.clone(),
            c.session_records.dismissed.clone(),
            crate::hook::in_panes(&c),
        )
    };
    // Read during the build, outside the core mutex, like the harness files. `wakeable` is
    // `mail/send`'s own test for queueing a wake, taken from the same snapshot.
    let mailbox = |handle: &str| MailAddress {
        handle: handle.to_string(),
        wakeable: pushable.contains(handle),
        unread: bench_mail::unread(&root, handle),
    };
    let helm_bench_dir = helm_bench_dir(&home);
    let now = now_rfc3339();
    let built = {
        let mut cache = CACHE.lock().unwrap();
        bench_sessions::build(
            &Inputs {
                home: &home,
                helm_bench_dir: &helm_bench_dir,
                workspace: &workspace,
                bench: &bench,
                hosted: &hosted,
                hooked: &hooked,
                dismissed: &dismissed,
                mailbox: &mailbox,
                now_ms: now_ms(),
                now: &now,
                alive: &bench_sessions::process::alive,
            },
            &mut cache,
        )
    };

    let mut c = core.lock().unwrap();
    record_hosted(&mut c, built.newly_hosted).map_err(Refusal::Failed)?;
    for u in &built.list.unreadable {
        report(&mut c, u).map_err(Refusal::Failed)?;
    }
    Ok(json!(built.list))
}

pub fn answer_dismiss(core: &Arc<Mutex<Core>>, args: &Value) -> Result<Value, Refusal> {
    let key: SessionKey = serde_json::from_value(args.clone())
        .map_err(|e| Refusal::Refused(format!("sessions/dismiss args: {e}")))?;
    let mut c = core.lock().unwrap();
    if !c.session_records.hosted.iter().any(|h| h.key() == key) {
        return Err(Refusal::Refused(format!(
            "{} session {:?} is not one benchd or helm hosted — only a row `bench sessions --all` lists as finished can be dismissed",
            key.harness.name(),
            key.id
        )));
    }
    let dismissal = Dismissal {
        harness: key.harness,
        id: key.id.clone(),
        at_ms: now_ms(),
    };
    c.append("sessions/dismissed", json!(dismissal))
        .map_err(Refusal::Failed)?;
    let records = &mut c.session_records;
    records.dismissed.retain(|d| d.key() != key);
    records.dismissed.push(dismissal.clone());
    save_dismissed(&c.root, &c.session_records.dismissed).map_err(Refusal::Failed)?;
    Ok(json!(dismissal))
}

pub enum Refusal {
    Refused(String),
    Failed(String),
}

/// A session benchd itself started: recorded at spawn, so it has a finished row even if the
/// daemon restarts before anyone asks for the list. Only a runtime whose id the bench minted
/// can be recorded — codex names its own sessions after the fact.
pub fn record_spawn(
    core: &mut Core,
    harness: Option<Harness>,
    id: Option<&str>,
    cwd: &str,
    session: &str,
    handle: &str,
) -> Result<(), String> {
    let (Some(harness), Some(id)) = (harness, id) else {
        return Ok(());
    };
    record_hosted(
        core,
        vec![HostedSession {
            harness,
            id: id.to_string(),
            cwd: cwd.to_string(),
            via: HostedVia::Bench {
                session: session.to_string(),
                handle: Some(handle.to_string()),
            },
            recorded_at: now_rfc3339(),
        }],
    )
}

/// A mailbox claimed through `bench hook` (#358): logged as `mail/claimed`, then written.
/// A session the record already holds keeps its entry and gains the handle; one it already
/// has an address for is left alone, so a claim never renames anybody.
pub fn record_claim(core: &mut Core, entry: HostedSession, pid: u32) -> Result<(), String> {
    let key = entry.key();
    let Some(handle) = entry.handle().map(str::to_string) else {
        return Err("a claim names a handle".into());
    };
    let existing = core
        .session_records
        .hosted
        .iter()
        .position(|h| h.key() == key);
    if existing.is_some_and(|i| core.session_records.hosted[i].handle().is_some()) {
        return Ok(());
    }
    core.append(
        "mail/claimed",
        json!({ "handle": handle, "pid": pid, "session": entry }),
    )?;
    match existing {
        Some(i) => core.session_records.hosted[i] = entry,
        None => core.session_records.hosted.push(entry),
    }
    save_hosted(&core.root, &core.session_records.hosted)
}

/// Add what the record does not hold yet: logged as one `sessions/hosted`, then written.
/// Another build may have recorded the same session meanwhile, so the check is repeated
/// here under the lock.
fn record_hosted(core: &mut Core, entries: Vec<HostedSession>) -> Result<(), String> {
    let fresh: Vec<HostedSession> = entries
        .into_iter()
        .filter(|e| {
            !core
                .session_records
                .hosted
                .iter()
                .any(|h| h.key() == e.key())
        })
        .collect();
    if fresh.is_empty() {
        return Ok(());
    }
    core.append("sessions/hosted", json!({ "sessions": fresh }))?;
    core.session_records.hosted.extend(fresh);
    save_hosted(&core.root, &core.session_records.hosted)
}

fn report(core: &mut Core, u: &Unreadable) -> Result<(), String> {
    let key = (u.source.clone(), u.path.clone(), u.why.clone());
    if core.session_records.reported.contains(&key) {
        return Ok(());
    }
    eprintln!("benchd: {} {} skipped: {}", u.source, u.path, u.why);
    core.append("sessions/unreadable", json!(u))?;
    core.session_records.reported.insert(key);
    Ok(())
}

/// helm's bench directory: `HELM_BENCH_DIR` when set (helm's own override), else
/// `~/.helm/bench`.
fn helm_bench_dir(home: &Path) -> PathBuf {
    std::env::var("HELM_BENCH_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| home.join(".helm/bench"))
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

// ---------------------------------------------------------------------------
// The two records
// ---------------------------------------------------------------------------

fn save_hosted(root: &Path, sessions: &[HostedSession]) -> Result<(), String> {
    save(
        &hosted_path(root),
        &HostedRecord {
            format: HOSTED_RECORD_FORMAT.into(),
            version: HOSTED_RECORD_VERSION,
            sessions: sessions.to_vec(),
        },
    )
}

fn save_dismissed(root: &Path, dismissed: &[Dismissal]) -> Result<(), String> {
    save(
        &dismissed_path(root),
        &DismissedRecord {
            format: DISMISSED_RECORD_FORMAT.into(),
            version: DISMISSED_RECORD_VERSION,
            dismissed: dismissed.to_vec(),
        },
    )
}

/// Atomic replace, 0600 in a 0700 directory — `bench.json`'s rule.
fn save<T: Serialize>(path: &Path, record: &T) -> Result<(), String> {
    let dir = path.parent().ok_or("a record path has a directory")?;
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)
        .map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
    let tmp = path.with_extension("json.tmp");
    let text = serde_json::to_string_pretty(record).map_err(|e| e.to_string())? + "\n";
    fs::write(&tmp, text).map_err(|e| format!("cannot write {}: {e}", tmp.display()))?;
    let _ = fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600));
    fs::rename(&tmp, path).map_err(|e| format!("cannot replace {}: {e}", path.display()))
}

/// Boot: both records, and the events that say what it took to read them. Absent is empty.
/// A record this build cannot read is moved aside, never deleted, and the daemon starts
/// without it — `bench.json`'s posture.
pub fn load(root: &Path) -> (SessionRecords, Vec<(&'static str, Value)>) {
    let mut events = Vec::new();
    let hosted = read::<HostedRecord>(
        &hosted_path(root),
        HOSTED_RECORD_FORMAT,
        HOSTED_RECORD_VERSION,
    )
    .unwrap_or_else(|e| {
        events.push(e);
        None
    })
    .map(|r| r.sessions)
    .unwrap_or_default();
    let dismissed = read::<DismissedRecord>(
        &dismissed_path(root),
        DISMISSED_RECORD_FORMAT,
        DISMISSED_RECORD_VERSION,
    )
    .unwrap_or_else(|e| {
        events.push(e);
        None
    })
    .map(|r| r.dismissed)
    .unwrap_or_default();
    (
        SessionRecords {
            hosted,
            dismissed,
            reported: HashSet::new(),
        },
        events,
    )
}

fn read<T: DeserializeOwned>(
    path: &Path,
    format: &str,
    version: u64,
) -> Result<Option<T>, (&'static str, Value)> {
    let text = match fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(quarantine(path, &format!("unreadable: {e}"))),
    };
    let value: Value =
        serde_json::from_str(&text).map_err(|e| quarantine(path, &format!("not JSON: {e}")))?;
    let (f, v) = (value["format"].as_str(), value["version"].as_u64());
    if f != Some(format) || v.is_none_or(|v| v > version) {
        return Err(quarantine(
            path,
            &format!("format {f:?} version {v:?} — this build reads {format:?} version {version}"),
        ));
    }
    serde_json::from_value(value)
        .map(Some)
        .map_err(|e| quarantine(path, &e.to_string()))
}

fn quarantine(path: &Path, why: &str) -> (&'static str, Value) {
    let epoch = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let name = path.file_name().unwrap_or_default().to_string_lossy();
    let aside = path.with_file_name(format!("{name}.bad-{epoch}"));
    let moved = fs::rename(path, &aside).is_ok();
    eprintln!(
        "benchd: {} could not be read ({why}); moved to {} and starting without it",
        path.display(),
        aside.display()
    );
    (
        "sessions/quarantined",
        json!({
            "path": path.display().to_string(),
            "moved_to": aside.display().to_string(),
            "moved": moved,
            "why": why,
        }),
    )
}
