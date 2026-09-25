//! Claude Code's files: the live registry (`~/.claude/sessions/<pid>.json`), `--bg` jobs
//! (`~/.claude/jobs/<id>/state.json`), transcripts and subagent transcripts
//! (`~/.claude/projects/<mangled cwd>/…`).
//!
//! **Every one of these is internal and undocumented.** So each reader names the fields and
//! values it relies on, and anything else is an `Unreadable` — the row skipped and the file
//! reported — never a guess. Vocabulary was read from Claude Code 2.1.280–2.1.282.

use bench_wire::{Activity, Unreadable};
use serde_json::Value;
use std::collections::HashMap;
use std::fs;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

pub const REGISTRY: &str = "claude-registry";
pub const JOB: &str = "claude-job";
pub const SUBAGENT: &str = "claude-subagent";

/// A null `stop_reason` on a final text block is finished only after this long without a
/// write. Claude writes one content block per record, so a text block can be followed by a
/// tool call of the same message; over 400 transcripts the gap was 1.1 s median, 29.6 s p99,
/// and 3 of 2774 exceeded 60 s (spike Evidence 3).
pub const QUIET_MS: u64 = 60_000;

/// A subagent whose turn ended counts as waiting on its tasks only while it has written
/// within this long. A task can end without ever reporting back into the subagent's own
/// transcript — the same measurement still left 11 subagents waiting after the two closes
/// below, every one quiet for 5.2 h or more, while the waits that were real had written
/// within the last 0.1 h. A real wait longer than this drops out of the list until the
/// subagent wakes and writes again.
pub const WAITING_MS: u64 = 2 * 60 * 60 * 1000;

fn unreadable(source: &str, path: &Path, why: impl Into<String>) -> Unreadable {
    Unreadable {
        source: source.into(),
        path: path.display().to_string(),
        why: why.into(),
    }
}

/// Claude's project-directory name for a cwd: every character that is not ASCII
/// alphanumeric becomes `-`. Lossy, but forward-deterministic — so a transcript is found
/// from the exact cwd it was started in, never by matching directory names back to paths.
pub fn mangle(cwd: &str) -> String {
    cwd.chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

pub fn transcript(home: &Path, cwd: &str, session: &str) -> PathBuf {
    home.join(".claude/projects")
        .join(mangle(cwd))
        .join(format!("{session}.jsonl"))
}

pub fn subagents_dir(home: &Path, cwd: &str, session: &str) -> PathBuf {
    home.join(".claude/projects")
        .join(mangle(cwd))
        .join(session)
        .join("subagents")
}

// ---------------------------------------------------------------------------
// The live registry
// ---------------------------------------------------------------------------

/// One live Claude Code process, from its registry row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Registered {
    pub pid: u32,
    pub session: String,
    /// Where it was started — where its transcript lives.
    pub cwd: String,
    pub started_ms: u64,
    pub name: Option<String>,
    pub activity: Activity,
    pub status_updated_ms: Option<u64>,
}

/// Every registry row whose process is alive and started when the row says. Rows of dead
/// processes are stale files and are skipped quietly — they are a normal state, not a shape.
pub fn registry(
    home: &Path,
    alive: impl Fn(u32, u64) -> bool,
) -> (Vec<Registered>, Vec<Unreadable>) {
    let mut live = Vec::new();
    let mut problems = Vec::new();
    for entry in fs::read_dir(home.join(".claude/sessions"))
        .into_iter()
        .flatten()
        .flatten()
    {
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        match registered(&path) {
            Ok(r) if alive(r.pid, r.started_ms) => live.push(r),
            Ok(_) => {}
            Err(why) => problems.push(unreadable(REGISTRY, &path, why)),
        }
    }
    (live, problems)
}

fn registered(path: &Path) -> Result<Registered, String> {
    let v: Value = serde_json::from_slice(&fs::read(path).map_err(|e| e.to_string())?)
        .map_err(|e| format!("not JSON: {e}"))?;
    let num = |k: &str| {
        v.get(k)
            .and_then(Value::as_u64)
            .ok_or(format!("no numeric {k:?}"))
    };
    let text = |k: &str| v.get(k).and_then(Value::as_str).map(String::from);
    let pid = u32::try_from(num("pid")?).map_err(|_| "pid out of range".to_string())?;
    let status = text("status");
    let waiting_for = text("waitingFor");
    // A print-mode session publishes no status: absence, not a shape (helm #283's rule).
    let activity = match status.as_deref() {
        None => Activity::Unknown,
        Some("busy") => Activity::Busy,
        Some("shell") => Activity::Shell,
        Some("idle") => Activity::Idle,
        Some("waiting") => Activity::Waiting { waiting_for },
        Some(other) => return Err(format!("unknown status {other:?}")),
    };
    Ok(Registered {
        pid,
        session: text("sessionId").ok_or("no \"sessionId\"")?,
        cwd: text("cwd").ok_or("no \"cwd\"")?,
        started_ms: num("startedAt")?,
        name: text("name"),
        activity,
        status_updated_ms: v.get("statusUpdatedAt").and_then(Value::as_u64),
    })
}

// ---------------------------------------------------------------------------
// --bg jobs
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Job {
    pub job: String,
    pub session: String,
    pub cwd: String,
    pub name: Option<String>,
    pub activity: Activity,
    /// Its transcript, when the job names one and it exists.
    pub has_transcript: bool,
    pub updated_ms: u64,
}

/// Every job that is still running. Finished jobs (`done`, `failed`, `stopped`) are not
/// rows: finished rows come only from the hosted-sessions record.
pub fn jobs(home: &Path) -> (Vec<Job>, Vec<Unreadable>) {
    let mut running = Vec::new();
    let mut problems = Vec::new();
    for entry in fs::read_dir(home.join(".claude/jobs"))
        .into_iter()
        .flatten()
        .flatten()
    {
        let path = entry.path().join("state.json");
        if !path.is_file() {
            continue;
        }
        let job = entry.file_name().to_string_lossy().into_owned();
        match read_job(&path, job) {
            Ok(Some(j)) => running.push(j),
            Ok(None) => {}
            Err(why) => problems.push(unreadable(JOB, &path, why)),
        }
    }
    (running, problems)
}

fn read_job(path: &Path, job: String) -> Result<Option<Job>, String> {
    let v: Value = serde_json::from_slice(&fs::read(path).map_err(|e| e.to_string())?)
        .map_err(|e| format!("not JSON: {e}"))?;
    let text = |k: &str| v.get(k).and_then(Value::as_str).map(String::from);
    let state = text("state").ok_or("no \"state\"")?;
    let activity = match state.as_str() {
        "done" | "failed" | "stopped" => return Ok(None),
        "working" => Activity::Busy,
        "blocked" | "needs_approval" | "needs_reply" => Activity::Blocked {
            detail: text("needs").or_else(|| text("detail")),
            state,
        },
        other => return Err(format!("unknown state {other:?}")),
    };
    let has_transcript = text("linkScanPath").is_some_and(|p| Path::new(&p).is_file());
    Ok(Some(Job {
        job,
        session: text("sessionId").ok_or("no \"sessionId\"")?,
        cwd: text("cwd").ok_or("no \"cwd\"")?,
        name: text("name"),
        activity,
        has_transcript,
        updated_ms: mtime_ms(path),
    }))
}

// ---------------------------------------------------------------------------
// Subagents
// ---------------------------------------------------------------------------

/// A subagent's `.meta.json`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Meta {
    pub agent_type: Option<String>,
    pub description: Option<String>,
    pub parent_agent: Option<String>,
}

pub fn meta(path: &Path) -> Result<Meta, Unreadable> {
    let v: Value = fs::read(path)
        .map_err(|e| e.to_string())
        .and_then(|b| serde_json::from_slice(&b).map_err(|e| format!("not JSON: {e}")))
        .map_err(|why| unreadable(SUBAGENT, path, why))?;
    let text = |k: &str| v.get(k).and_then(Value::as_str).map(String::from);
    Ok(Meta {
        agent_type: text("agentType"),
        description: text("description"),
        parent_agent: text("parentAgentId"),
    })
}

/// What a subagent transcript's last conversational record says — a function of the
/// file's bytes alone, so it is cached by size and mtime. The quiet window is applied at
/// build time, because it depends on the clock.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Tail {
    /// A tool call in flight, or a user record (a tool result or a prompt) waiting for the
    /// assistant: running.
    Working,
    /// An assistant text block with an explicit end: the turn ended.
    Ended,
    /// An assistant block with no explicit end (null `stop_reason`, or a nothing-written-yet
    /// transcript): ended only once quiet for `QUIET_MS`.
    Open,
    Unreadable(String),
}

const ENDS: &[&str] = &["end_turn", "stop_sequence", "refusal"];
const OPEN: &[&str] = &["max_tokens", "pause_turn"];

fn classify(record: &Value) -> Option<Result<Tail, String>> {
    match record.get("type").and_then(Value::as_str)? {
        "user" => Some(Ok(Tail::Working)),
        "assistant" => {
            let message = &record["message"];
            let Some(content) = message.get("content").and_then(Value::as_array) else {
                return Some(Err("assistant record without a content array".into()));
            };
            let has = |kind: &str| content.iter().any(|c| c["type"] == kind);
            if has("tool_use") {
                return Some(Ok(Tail::Working));
            }
            Some(match message.get("stop_reason") {
                None | Some(Value::Null) => Ok(Tail::Open),
                Some(Value::String(s)) if s == "tool_use" => Ok(Tail::Working),
                Some(Value::String(s)) if ENDS.contains(&s.as_str()) => {
                    Ok(if has("text") { Tail::Ended } else { Tail::Open })
                }
                Some(Value::String(s)) if OPEN.contains(&s.as_str()) => Ok(Tail::Open),
                Some(other) => Err(format!("unknown stop_reason {other}")),
            })
        }
        // Summaries, attachments, system lines and the like say nothing about the turn.
        _ => None,
    }
}

/// Read backwards from the end, a growing window at a time, to the last conversational
/// record. A final line with no newline is a write in progress and is ignored.
fn read_tail(path: &Path) -> Tail {
    let Ok(mut file) = fs::File::open(path) else {
        return Tail::Unreadable("cannot open".into());
    };
    let Ok(len) = file.metadata().map(|m| m.len()) else {
        return Tail::Unreadable("cannot stat".into());
    };
    let mut window: u64 = 64 * 1024;
    loop {
        let start = len.saturating_sub(window);
        let mut buf = Vec::new();
        if file.seek(SeekFrom::Start(start)).is_err()
            || file
                .by_ref()
                .take(len - start)
                .read_to_end(&mut buf)
                .is_err()
        {
            return Tail::Unreadable("cannot read".into());
        }
        let complete = match buf.iter().rposition(|&b| b == b'\n') {
            Some(i) => &buf[..i],
            None if start == 0 => &buf[..0],
            None => {
                window *= 4;
                continue;
            }
        };
        let mut lines: Vec<&[u8]> = complete.split(|&b| b == b'\n').collect();
        if start > 0 {
            lines.remove(0); // the window cut it
        }
        for line in lines.iter().rev().filter(|l| !l.is_empty()) {
            let record: Value = match serde_json::from_slice(line) {
                Ok(v) => v,
                Err(e) => return Tail::Unreadable(format!("a line is not JSON: {e}")),
            };
            match classify(&record) {
                Some(Ok(tail)) => return tail,
                Some(Err(why)) => return Tail::Unreadable(why),
                None => {}
            }
        }
        if start == 0 {
            return Tail::Open;
        }
        window *= 4;
    }
}

/// What the scan of one transcript has learned so far. Transcripts are append-only, so the
/// scan resumes from `offset`; a file shorter than that was replaced and is rescanned.
#[derive(Debug, Default, Clone)]
struct Scan {
    offset: u64,
    /// Tasks this transcript started that have not reported back, oldest first.
    open: Vec<String>,
}

#[derive(Debug, Clone)]
struct Entry {
    len: u64,
    mtime_ms: u64,
    tail: Tail,
    scan: Scan,
}

/// The per-file cache a long-lived daemon keeps between builds (spike C5: 140–420 ms
/// uncached, 28–75 ms cached, on the same data). Entries for files no build asked about
/// are dropped at the end of each build.
#[derive(Debug, Default)]
pub struct Cache {
    entries: HashMap<PathBuf, Entry>,
    touched: Vec<PathBuf>,
    /// Transcript bytes the pending-task scan has read, ever. A warm build must add only
    /// what was appended since the last one — the regression check for a scan that starts
    /// over each time (the spike's naive search once read 193 MB per build).
    pub bytes_scanned: u64,
}

/// A running subagent's verdict.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    Running(Activity),
    Finished,
    Unreadable(String),
}

impl Cache {
    /// The three rules, in order: a transcript last written before its parent's process
    /// started died with an earlier process; a tool call in flight or a quiet-window-open
    /// turn is running; an ended turn is running only while tasks it started are pending,
    /// and only within `WAITING_MS` of its last write.
    pub fn subagent(&mut self, transcript: &Path, parent_started_ms: u64, now_ms: u64) -> Verdict {
        let Ok(md) = fs::metadata(transcript) else {
            return Verdict::Finished;
        };
        let (len, mtime) = (md.len(), system_ms(md.modified().ok()));
        if mtime < parent_started_ms {
            return Verdict::Finished;
        }
        self.touched.push(transcript.to_path_buf());
        let entry = self
            .entries
            .entry(transcript.to_path_buf())
            .or_insert_with(|| Entry {
                len: u64::MAX,
                mtime_ms: 0,
                tail: Tail::Open,
                scan: Scan::default(),
            });
        if entry.len != len || entry.mtime_ms != mtime {
            entry.tail = read_tail(transcript);
            entry.len = len;
            entry.mtime_ms = mtime;
        }
        let ended = match &entry.tail {
            Tail::Working => false,
            Tail::Ended => true,
            Tail::Open => now_ms.saturating_sub(mtime) >= QUIET_MS,
            Tail::Unreadable(why) => return Verdict::Unreadable(why.clone()),
        };
        if !ended {
            return Verdict::Running(Activity::Busy);
        }
        if now_ms.saturating_sub(mtime) >= WAITING_MS {
            return Verdict::Finished;
        }
        match scan_pending(transcript, &mut entry.scan, len) {
            Ok(read) => self.bytes_scanned += read,
            Err(why) => return Verdict::Unreadable(why),
        }
        match u32::try_from(entry.scan.open.len()).unwrap_or(u32::MAX) {
            0 => Verdict::Finished,
            count => Verdict::Running(Activity::WaitingOnTasks { count }),
        }
    }

    /// Drop every entry this build did not ask about.
    pub fn end_build(&mut self) {
        let touched: std::collections::HashSet<PathBuf> = self.touched.drain(..).collect();
        self.entries.retain(|p, _| touched.contains(p));
    }
}

// The task ledger's markers, as Claude Code 2.1.280 writes them into a transcript. A task
// is started by an async agent launch (`"status":"async_launched"` then the launched
// `"agentId"`), an agent resume (`"resumedAgentId"`) or a background shell
// (`"backgroundTaskId"`), and reports back with a `<task-id>…</task-id>` notification.
// Matched 14/14 against Claude's own launch/notification replay (spike Evidence 3).
// Two more closes were found against the operator's machine (2026-09-25), where the
// spike's scan held 28 subagents "waiting", most for more than a day: a task the agent
// stopped itself (`TaskStop`) never reports back, and a background shell marked
// `"backgroundEndsWithFinalResponse":true` ends with the subagent's own turn.
const BACKGROUND: &[u8] = b"\"backgroundTaskId\":\"";
const ASYNC: &[u8] = b"\"status\":\"async_launched\"";
const AGENT_ID: &[u8] = b"\"agentId\":\"";
const RESUMED: &[u8] = b"\"resumedAgentId\":\"";
const NOTIFIED: &[u8] = b"<task-id>";
const STOPPED: &[u8] = b"\"name\":\"TaskStop\"";
const ENDS_WITH_TURN: &[u8] = b"\"backgroundEndsWithFinalResponse\":true";

/// Scan from `scan.offset` to the last whole line, updating the open tasks. Returns the
/// bytes read.
#[derive(Debug, Clone, Copy)]
enum Mark {
    Background,
    Async,
    Resumed,
    Notified,
    Stopped,
}

fn scan_pending(path: &Path, scan: &mut Scan, len: u64) -> Result<u64, String> {
    if len < scan.offset {
        *scan = Scan::default();
    }
    if len == scan.offset {
        return Ok(0);
    }
    let mut file = fs::File::open(path).map_err(|e| e.to_string())?;
    file.seek(SeekFrom::Start(scan.offset))
        .map_err(|e| e.to_string())?;
    let mut buf = Vec::new();
    file.take(len - scan.offset)
        .read_to_end(&mut buf)
        .map_err(|e| e.to_string())?;
    let read = buf.len() as u64;
    let Some(end) = memchr::memrchr(b'\n', &buf) else {
        return Ok(read);
    };
    // Each marker is searched for across the whole buffer (SIMD `memmem`), not line by line:
    // markers are rare and transcripts are large — one session's subagents held 193 MB.
    let hay = &buf[..end];
    let mut marks: Vec<(usize, Mark)> = Vec::new();
    for (needle, mark) in [
        (BACKGROUND, Mark::Background),
        (ASYNC, Mark::Async),
        (RESUMED, Mark::Resumed),
        (NOTIFIED, Mark::Notified),
        (STOPPED, Mark::Stopped),
    ] {
        marks.extend(memchr::memmem::find_iter(hay, needle).map(|at| (at, mark)));
    }
    marks.sort_unstable_by_key(|(at, _)| *at);
    let line_of = |at: usize| {
        let start = memchr::memrchr(b'\n', &hay[..at]).map_or(0, |i| i + 1);
        let stop = memchr::memchr(b'\n', &hay[at..]).map_or(hay.len(), |i| at + i);
        (start, &hay[start..stop])
    };
    let id_at = |at: usize, stops: &[u8]| {
        let rest = &hay[at..];
        let stop = rest
            .iter()
            .position(|b| stops.contains(b))
            .unwrap_or(rest.len());
        String::from_utf8_lossy(&rest[..stop]).into_owned()
    };
    let close = |open: &mut Vec<String>, id: &str| {
        if let Some(pos) = open.iter().rposition(|o| o == id) {
            open.remove(pos);
        }
    };
    // A line opens at most one task, and a stop line is parsed once.
    let mut opened_on: Option<usize> = None;
    let mut parsed_on: Option<usize> = None;
    for (at, mark) in marks {
        let (line_start, line) = line_of(at);
        match mark {
            Mark::Background | Mark::Async | Mark::Resumed if opened_on == Some(line_start) => {}
            Mark::Background => {
                opened_on = Some(line_start);
                // A shell Claude itself ends with the subagent's final response is not one
                // the subagent will wake for.
                if memchr::memmem::find(line, ENDS_WITH_TURN).is_none() {
                    scan.open.push(id_at(at + BACKGROUND.len(), b"\"<\\"));
                }
            }
            Mark::Async => {
                // The launched agent's id follows the status; the line's own agentId is the
                // writer's.
                if let Some(i) = memchr::memmem::find(&hay[at..line_start + line.len()], AGENT_ID) {
                    opened_on = Some(line_start);
                    scan.open.push(id_at(at + i + AGENT_ID.len(), b"\"<\\"));
                }
            }
            Mark::Resumed => {
                opened_on = Some(line_start);
                scan.open.push(id_at(at + RESUMED.len(), b"\"<\\"));
            }
            Mark::Notified => close(&mut scan.open, &id_at(at + NOTIFIED.len(), b"<")),
            Mark::Stopped if parsed_on == Some(line_start) => {}
            Mark::Stopped => {
                parsed_on = Some(line_start);
                // Rare lines, so the whole record is parsed: the stop's own typed input.
                let record: Value = serde_json::from_slice(line)
                    .map_err(|e| format!("a TaskStop line is not JSON: {e}"))?;
                for block in record["message"]["content"]
                    .as_array()
                    .into_iter()
                    .flatten()
                {
                    if block["type"] == "tool_use"
                        && block["name"] == "TaskStop"
                        && let Some(id) = block["input"]["task_id"].as_str()
                    {
                        close(&mut scan.open, id);
                    }
                }
            }
        }
    }
    scan.offset += end as u64 + 1;
    Ok(read)
}

pub fn mtime_ms(path: &Path) -> u64 {
    system_ms(fs::metadata(path).and_then(|m| m.modified()).ok())
}

fn system_ms(t: Option<std::time::SystemTime>) -> u64 {
    t.and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_project_dir_name_replaces_every_non_alphanumeric() {
        assert_eq!(
            mangle("/Users/r/sild/helm/.worktrees/ws_15"),
            "-Users-r-sild-helm--worktrees-ws-15"
        );
    }
}
