//! A session's transcript as a readable log (#421): the prompts, the agent's replies, one line
//! per tool call, and errors. Tool results and thinking are left out. `bench log` prints it.
//!
//! Like every reader in this crate, it fails loudly on a shape it does not know. A record it
//! cannot read is skipped and named as a [`Problem`], never guessed at. Records outside the
//! conversation (Claude's `attachment`, `mode`, `pr-link`, … and pi's `model_change`, …) are
//! metadata by design and skipped without a report: the conversation is Claude's `user` and
//! `assistant` records and pi's `message` records, and inside those every field and block
//! type is named below.
//!
//! Codex rollouts are found but not read. Current rollouts (0.157) put injected context
//! (AGENTS.md, `<environment_context>`, plugin lists) in the same `role: user` messages as the
//! real prompt, and telling them apart would take guesswork.

use crate::pi;
use bench_wire::Harness;
use serde::Serialize;
use serde_json::Value;
use std::collections::HashMap;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use time::OffsetDateTime;
use time::format_description::well_known::Rfc3339;

/// A tool call's argument is cut to this many characters.
const TOOL_ARG_CHARS: usize = 120;
/// An error is cut to this many characters.
const ERROR_CHARS: usize = 300;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    /// A prompt: the operator's, a spawner's, or a notice the harness delivered as a turn.
    User,
    /// The agent's text reply.
    Agent,
    /// A tool call: `tool` is its name and `text` a short argument.
    Tool,
    /// A failed tool call (`tool` names it) or an error the harness recorded.
    Error,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Entry {
    /// The record's own timestamp, as written.
    pub at: String,
    #[serde(skip)]
    pub at_ms: u64,
    pub kind: Kind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool: Option<String>,
    pub text: String,
}

/// A line the reader skipped because it did not know its shape. `line` is 1-based.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Problem {
    pub line: usize,
    pub why: String,
}

/// A transcript file and whose it is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Located {
    pub harness: Harness,
    pub id: String,
    pub path: PathBuf,
}

#[derive(Debug, Default)]
pub struct Transcript {
    pub entries: Vec<Entry>,
    pub unreadable: Vec<Problem>,
}

fn claude_projects(home: &Path) -> PathBuf {
    home.join(".claude/projects")
}

fn pi_sessions(home: &Path) -> PathBuf {
    home.join(".pi/agent/sessions")
}

fn codex_sessions(home: &Path) -> PathBuf {
    home.join(".codex/sessions")
}

fn codex_refusal(path: &Path) -> String {
    format!(
        "{} is a codex rollout, and bench log reads only Claude and pi transcripts: codex puts \
         injected context in the same user messages as the prompt, so its log would mislead",
        path.display()
    )
}

/// Finds the transcript for `arg`: a session id as `bench sessions --all` shows it (a Claude
/// session or subagent id, or a pi session id), or a transcript path (it contains a `/`),
/// such as a subagent row's `open.path`. `Err` says why nothing can be read.
pub fn locate(home: &Path, arg: &str) -> Result<Located, String> {
    if arg.contains('/') {
        return located_path(home, Path::new(arg));
    }
    if arg.is_empty()
        || !arg
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err(format!(
            "{arg:?} is not a session id (letters, digits, - and _) or a transcript path"
        ));
    }
    let dirs = |p: PathBuf| -> Vec<PathBuf> {
        let mut v: Vec<PathBuf> = fs::read_dir(p)
            .into_iter()
            .flatten()
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.is_dir())
            .collect();
        v.sort();
        v
    };
    let one = |harness: Harness, found: Vec<PathBuf>| -> Option<Result<Located, String>> {
        match found.len() {
            0 => None,
            1 => Some(Ok(Located {
                harness,
                id: arg.to_string(),
                path: found.into_iter().next().unwrap(),
            })),
            _ => Some(Err(format!(
                "{arg} names {} transcripts; pass the path of the one you mean:\n  {}",
                found.len(),
                found
                    .iter()
                    .map(|p| p.display().to_string())
                    .collect::<Vec<_>>()
                    .join("\n  ")
            ))),
        }
    };

    let projects = dirs(claude_projects(home));
    let top: Vec<PathBuf> = projects
        .iter()
        .map(|d| d.join(format!("{arg}.jsonl")))
        .filter(|p| p.is_file())
        .collect();
    if let Some(r) = one(Harness::Claude, top) {
        return r;
    }
    let sub: Vec<PathBuf> = projects
        .iter()
        .flat_map(|d| dirs(d.clone()))
        .map(|s| s.join("subagents").join(format!("agent-{arg}.jsonl")))
        .filter(|p| p.is_file())
        .collect();
    if let Some(r) = one(Harness::Claude, sub) {
        return r;
    }
    let suffix = format!("_{arg}.jsonl");
    let pi_files: Vec<PathBuf> = dirs(pi_sessions(home))
        .into_iter()
        .flat_map(|d| fs::read_dir(d).into_iter().flatten().flatten())
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .is_some_and(|n| n.to_string_lossy().ends_with(&suffix))
        })
        .collect();
    if let Some(r) = one(Harness::Pi, pi_files) {
        return r;
    }
    if let Some(rollout) = find_codex(&codex_sessions(home), &format!("-{arg}.jsonl"), 4) {
        return Err(codex_refusal(&rollout));
    }
    Err(format!(
        "no transcript for {arg} under {}, {} or {}",
        claude_projects(home).display(),
        pi_sessions(home).display(),
        codex_sessions(home).display()
    ))
}

/// Codex keeps rollouts under `YYYY/MM/DD/`.
fn find_codex(dir: &Path, suffix: &str, depth: u8) -> Option<PathBuf> {
    for entry in fs::read_dir(dir).into_iter().flatten().flatten() {
        let path = entry.path();
        if path.is_dir() {
            if depth > 0
                && let Some(found) = find_codex(&path, suffix, depth - 1)
            {
                return Some(found);
            }
        } else if path
            .file_name()
            .is_some_and(|n| n.to_string_lossy().ends_with(suffix))
        {
            return Some(path);
        }
    }
    None
}

fn located_path(home: &Path, path: &Path) -> Result<Located, String> {
    if !path.is_file() {
        return Err(format!("no transcript at {}", path.display()));
    }
    let stem = path
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_default();
    if path.starts_with(claude_projects(home)) {
        let id = stem.strip_prefix("agent-").unwrap_or(&stem).to_string();
        return Ok(Located {
            harness: Harness::Claude,
            id,
            path: path.to_path_buf(),
        });
    }
    if path.starts_with(pi_sessions(home)) {
        let id = stem.rsplit('_').next().unwrap_or(&stem).to_string();
        return Ok(Located {
            harness: Harness::Pi,
            id,
            path: path.to_path_buf(),
        });
    }
    if path.starts_with(codex_sessions(home)) {
        return Err(codex_refusal(path));
    }
    Err(format!(
        "{} is not under {} or {}, so bench log does not know whose transcript it is",
        path.display(),
        claude_projects(home).display(),
        pi_sessions(home).display()
    ))
}

/// Reads the whole file. `Err` only when the file cannot be read at all, or (pi) its header
/// is a format this build does not read; a bad line is a [`Problem`] and the rest still reads.
pub fn read(located: &Located) -> Result<Transcript, String> {
    let file = fs::File::open(&located.path)
        .map_err(|e| format!("cannot open {}: {e}", located.path.display()))?;
    let mut lines = BufReader::new(file).lines();
    let mut out = Transcript::default();
    let mut tools: HashMap<String, String> = HashMap::new();
    let mut n = 0;
    if located.harness == Harness::Pi {
        let first = lines
            .next()
            .transpose()
            .map_err(|e| format!("cannot read {}: {e}", located.path.display()))?
            .unwrap_or_default();
        n = 1;
        pi::header(&first, &located.id)
            .map_err(|why| format!("{}: {why}", located.path.display()))?;
    }
    for line in lines {
        n += 1;
        let line = line.map_err(|e| format!("cannot read {}: {e}", located.path.display()))?;
        if line.trim().is_empty() {
            continue;
        }
        let parsed = serde_json::from_str::<Value>(&line)
            .map_err(|e| format!("not JSON: {e}"))
            .and_then(|v| match located.harness {
                Harness::Claude => claude(&v, &mut tools),
                Harness::Pi => pi_record(&v),
                Harness::Codex => Err("codex rollouts are not read".into()),
            });
        match parsed {
            Ok(entries) => out.entries.extend(entries),
            Err(why) => out.unreadable.push(Problem { line: n, why }),
        }
    }
    Ok(out)
}

/// The entries at or after `since_ms`, and of those the last `n`. Also returns how many
/// passed the `since` cut, so a caller can say how many it left out.
pub fn tail(entries: Vec<Entry>, since_ms: Option<u64>, n: usize) -> (Vec<Entry>, usize) {
    let kept: Vec<Entry> = entries
        .into_iter()
        .filter(|e| since_ms.is_none_or(|s| e.at_ms >= s))
        .collect();
    let total = kept.len();
    let skip = total.saturating_sub(n);
    (kept.into_iter().skip(skip).collect(), total)
}

/// `--since`: a duration back from `now_ms` (`90s`, `30m`, `2h`, `1d`) or an RFC 3339 time.
pub fn parse_since(raw: &str, now_ms: u64) -> Result<u64, String> {
    let unit_ms = match raw.chars().last() {
        Some('s') => Some(1_000),
        Some('m') => Some(60_000),
        Some('h') => Some(3_600_000),
        Some('d') => Some(86_400_000),
        _ => None,
    };
    if let Some(unit) = unit_ms
        && let Ok(count) = raw[..raw.len() - 1].parse::<u64>()
    {
        return Ok(now_ms.saturating_sub(count.saturating_mul(unit)));
    }
    epoch_ms(raw).map_err(|_| {
        format!("--since {raw:?} is neither a duration (30m, 2h, 1d) nor an RFC 3339 time")
    })
}

fn epoch_ms(rfc3339: &str) -> Result<u64, String> {
    let t = OffsetDateTime::parse(rfc3339, &Rfc3339).map_err(|e| e.to_string())?;
    u64::try_from(t.unix_timestamp_nanos() / 1_000_000).map_err(|e| e.to_string())
}

/// `YYYY-MM-DD HH:MM:SS` in UTC.
pub fn display_time(at_ms: u64) -> String {
    let t = OffsetDateTime::from_unix_timestamp((at_ms / 1000) as i64)
        .unwrap_or(OffsetDateTime::UNIX_EPOCH);
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
        t.year(),
        t.month() as u8,
        t.day(),
        t.hour(),
        t.minute(),
        t.second()
    )
}

/// The first non-empty line, trimmed and cut to `max` characters.
fn one_line(text: &str, max: usize) -> String {
    let line = text
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .unwrap_or("");
    if line.chars().count() > max {
        format!("{}…", line.chars().take(max).collect::<String>())
    } else {
        line.to_string()
    }
}

/// A tool call's short argument: the key that says what it acts on, else its first string.
fn tool_arg(input: &Value) -> String {
    const KEYS: [&str; 9] = [
        "command",
        "file_path",
        "path",
        "pattern",
        "url",
        "query",
        "description",
        "skill",
        "prompt",
    ];
    let arg = KEYS
        .iter()
        .find_map(|k| input[*k].as_str())
        .or_else(|| input.as_object()?.values().find_map(Value::as_str))
        .unwrap_or("");
    one_line(arg, TOOL_ARG_CHARS)
}

/// The text of a tool result or error: a string, or the `text` blocks of an array.
fn plain_text(content: &Value) -> String {
    match content {
        Value::String(s) => s.clone(),
        Value::Array(blocks) => blocks
            .iter()
            .filter_map(|b| b["text"].as_str())
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

struct Stamp {
    at: String,
    at_ms: u64,
}

impl Stamp {
    fn of(record: &Value) -> Result<Stamp, String> {
        let at = record["timestamp"]
            .as_str()
            .ok_or("no timestamp on a conversation record")?;
        let at_ms = epoch_ms(at).map_err(|e| format!("timestamp {at:?}: {e}"))?;
        Ok(Stamp {
            at: at.to_string(),
            at_ms,
        })
    }

    fn entry(&self, kind: Kind, tool: Option<String>, text: String) -> Entry {
        Entry {
            at: self.at.clone(),
            at_ms: self.at_ms,
            kind,
            tool,
            text,
        }
    }
}

/// One Claude Code transcript line. `tools` maps tool-use ids to names, so an error result
/// can say which call failed.
fn claude(record: &Value, tools: &mut HashMap<String, String>) -> Result<Vec<Entry>, String> {
    let kind = record["type"].as_str().ok_or("no \"type\"")?;
    if kind != "user" && kind != "assistant" {
        return Ok(Vec::new());
    }
    let stamp = Stamp::of(record)?;
    let content = &record["message"]["content"];
    let blocks: Vec<Value> = match content {
        Value::String(s) => vec![serde_json::json!({"type": "text", "text": s})],
        Value::Array(b) => b.clone(),
        _ => return Err(format!("{kind} message.content is neither text nor blocks")),
    };
    let mut out = Vec::new();
    if kind == "user" {
        // Injected context (a skill body, a command caveat) and the summary a compaction
        // writes are not prompts.
        if record["isMeta"] == true || record["isCompactSummary"] == true {
            return Ok(out);
        }
        let mut text: Vec<String> = Vec::new();
        for b in &blocks {
            match b["type"].as_str() {
                Some("text") => {
                    text.push(b["text"].as_str().ok_or("text block without text")?.into())
                }
                Some("image") => text.push("[image]".into()),
                Some("document") => text.push("[document]".into()),
                Some("tool_result") => {
                    if b["is_error"] == true {
                        let name = b["tool_use_id"]
                            .as_str()
                            .and_then(|id| tools.get(id))
                            .cloned();
                        let why = one_line(&plain_text(&b["content"]), ERROR_CHARS);
                        out.push(stamp.entry(Kind::Error, name, why));
                    }
                }
                other => return Err(format!("user block type {other:?}")),
            }
        }
        let text = text.join("\n");
        if !text.trim().is_empty() {
            out.insert(0, stamp.entry(Kind::User, None, text));
        }
        return Ok(out);
    }
    if record["isApiErrorMessage"] == true {
        let why = one_line(&plain_text(content), ERROR_CHARS);
        return Ok(vec![stamp.entry(Kind::Error, None, why)]);
    }
    for b in &blocks {
        match b["type"].as_str() {
            Some("text") => {
                let text = b["text"].as_str().ok_or("text block without text")?;
                if !text.trim().is_empty() {
                    out.push(stamp.entry(Kind::Agent, None, text.to_string()));
                }
            }
            Some("tool_use") | Some("server_tool_use") => {
                let name = b["name"].as_str().ok_or("tool_use without a name")?;
                if let Some(id) = b["id"].as_str() {
                    tools.insert(id.to_string(), name.to_string());
                }
                out.push(stamp.entry(Kind::Tool, Some(name.into()), tool_arg(&b["input"])));
            }
            // `fallback` records a switch to another model mid-turn: metadata, not a reply.
            Some("thinking")
            | Some("redacted_thinking")
            | Some("web_search_tool_result")
            | Some("fallback") => {}
            other => return Err(format!("assistant block type {other:?}")),
        }
    }
    Ok(out)
}

/// One pi session line after the header.
fn pi_record(record: &Value) -> Result<Vec<Entry>, String> {
    if record["type"].as_str().ok_or("no \"type\"")? != "message" {
        return Ok(Vec::new());
    }
    let stamp = Stamp::of(record)?;
    let message = &record["message"];
    let blocks: Vec<Value> = match &message["content"] {
        Value::String(s) => vec![serde_json::json!({"type": "text", "text": s})],
        Value::Array(b) => b.clone(),
        // An aborted turn can leave no content at all.
        Value::Null => Vec::new(),
        _ => return Err("message.content is neither text nor blocks".into()),
    };
    let role = message["role"].as_str().ok_or("message without a role")?;
    let mut out = Vec::new();
    match role {
        "user" => {
            let mut text: Vec<String> = Vec::new();
            for b in &blocks {
                match b["type"].as_str() {
                    Some("text") => {
                        text.push(b["text"].as_str().ok_or("text block without text")?.into())
                    }
                    Some("image") => text.push("[image]".into()),
                    other => return Err(format!("user block type {other:?}")),
                }
            }
            let text = text.join("\n");
            if !text.trim().is_empty() {
                out.push(stamp.entry(Kind::User, None, text));
            }
        }
        "assistant" => {
            for b in &blocks {
                match b["type"].as_str() {
                    Some("text") => {
                        let text = b["text"].as_str().ok_or("text block without text")?;
                        if !text.trim().is_empty() {
                            out.push(stamp.entry(Kind::Agent, None, text.to_string()));
                        }
                    }
                    Some("toolCall") => {
                        let name = b["name"].as_str().ok_or("toolCall without a name")?;
                        out.push(stamp.entry(
                            Kind::Tool,
                            Some(name.into()),
                            tool_arg(&b["arguments"]),
                        ));
                    }
                    Some("thinking") => {}
                    other => return Err(format!("assistant block type {other:?}")),
                }
            }
            match message["stopReason"].as_str() {
                Some("error") => {
                    let why = message["errorMessage"].as_str().unwrap_or("error");
                    out.push(stamp.entry(Kind::Error, None, one_line(why, ERROR_CHARS)));
                }
                Some("aborted") => out.push(stamp.entry(Kind::Error, None, "aborted".into())),
                _ => {}
            }
        }
        "toolResult" => {
            if message["isError"] == true {
                let name = message["toolName"].as_str().map(String::from);
                let why = one_line(&plain_text(&message["content"]), ERROR_CHARS);
                out.push(stamp.entry(Kind::Error, name, why));
            }
        }
        // A `!command` the operator ran, and a system prompt: not the conversation.
        "bashExecution" | "system" => {}
        other => return Err(format!("message role {other:?}")),
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::atomic::{AtomicU32, Ordering};

    struct Home(PathBuf);

    impl Home {
        fn new() -> Home {
            static N: AtomicU32 = AtomicU32::new(0);
            let dir = std::env::temp_dir().join(format!(
                "bench-transcript-{}-{}",
                std::process::id(),
                N.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&dir).unwrap();
            Home(dir)
        }

        fn write(&self, rel: &str, lines: &[Value]) -> PathBuf {
            let path = self.0.join(rel);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            let text: String = lines.iter().map(|l| format!("{l}\n")).collect();
            fs::write(&path, text).unwrap();
            path
        }
    }

    impl Drop for Home {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    const AT: &str = "2026-09-25T16:49:25.973Z";

    fn user(content: Value) -> Value {
        json!({"type": "user", "timestamp": AT, "message": {"role": "user", "content": content}})
    }

    fn assistant(blocks: Value) -> Value {
        json!({"type": "assistant", "timestamp": AT, "message": {"role": "assistant", "content": blocks}})
    }

    fn read_claude(lines: &[Value]) -> Transcript {
        let home = Home::new();
        let path = home.write(".claude/projects/-r/s1.jsonl", lines);
        read(&Located {
            harness: Harness::Claude,
            id: "s1".into(),
            path,
        })
        .unwrap()
    }

    fn shape(t: &Transcript) -> Vec<(Kind, Option<&str>, &str)> {
        t.entries
            .iter()
            .map(|e| (e.kind, e.tool.as_deref(), e.text.as_str()))
            .collect()
    }

    #[test]
    fn a_claude_transcript_reads_as_prompts_replies_tool_lines_and_errors() {
        let t = read_claude(&[
            json!({"type": "mode", "mode": "x"}),
            user(json!("fix the build")),
            json!({"type": "user", "isMeta": true, "timestamp": AT, "message": {"content": "caveat"}}),
            assistant(json!([{"type": "thinking", "thinking": "hmm"}])),
            assistant(json!([{"type": "fallback", "from": {"model": "a"}, "to": {"model": "b"}}])),
            assistant(json!([{"type": "text", "text": "Looking."}])),
            assistant(json!([{"type": "tool_use", "id": "t1", "name": "Bash",
                "input": {"command": "cargo build\n--release", "description": "build"}}])),
            user(json!([{"type": "tool_result", "tool_use_id": "t1", "content": "ok"}])),
            assistant(json!([{"type": "tool_use", "id": "t2", "name": "Read",
                "input": {"file_path": "/r/a.rs"}}])),
            user(
                json!([{"type": "tool_result", "tool_use_id": "t2", "is_error": true,
                "content": [{"type": "text", "text": "File does not exist."}]}]),
            ),
            json!({"type": "assistant", "timestamp": AT, "isApiErrorMessage": true,
                "message": {"content": [{"type": "text", "text": "Prompt is too long"}]}}),
        ]);
        assert_eq!(
            shape(&t),
            [
                (Kind::User, None, "fix the build"),
                (Kind::Agent, None, "Looking."),
                (Kind::Tool, Some("Bash"), "cargo build"),
                (Kind::Tool, Some("Read"), "/r/a.rs"),
                (Kind::Error, Some("Read"), "File does not exist."),
                (Kind::Error, None, "Prompt is too long"),
            ]
        );
        assert!(t.unreadable.is_empty(), "{:?}", t.unreadable);
    }

    #[test]
    fn an_unknown_shape_is_named_with_its_line_and_the_rest_still_reads() {
        let t = read_claude(&[
            user(json!("first")),
            assistant(json!([{"type": "hologram"}])),
            json!({"type": "user", "message": {"content": "no timestamp"}}),
            user(json!(42)),
            user(json!("last")),
        ]);
        assert_eq!(
            shape(&t),
            [(Kind::User, None, "first"), (Kind::User, None, "last")]
        );
        let lines: Vec<usize> = t.unreadable.iter().map(|p| p.line).collect();
        assert_eq!(lines, [2, 3, 4]);
        assert!(t.unreadable[0].why.contains("hologram"));
    }

    #[test]
    fn a_line_that_is_not_json_is_a_problem_not_a_failure() {
        let home = Home::new();
        let path = home.0.join("t.jsonl");
        fs::write(&path, format!("{{torn\n{}\n", user(json!("after")))).unwrap();
        let t = read(&Located {
            harness: Harness::Claude,
            id: "t".into(),
            path,
        })
        .unwrap();
        assert_eq!(shape(&t), [(Kind::User, None, "after")]);
        assert_eq!(t.unreadable[0].line, 1);
        assert!(t.unreadable[0].why.starts_with("not JSON"));
    }

    fn pi_message(message: Value) -> Value {
        json!({"type": "message", "id": "m", "parentId": null, "timestamp": AT, "message": message})
    }

    fn pi_header(id: &str) -> Value {
        json!({"type": "session", "version": 3, "id": id, "timestamp": AT, "cwd": "/r"})
    }

    #[test]
    fn a_pi_session_reads_the_same_way() {
        let home = Home::new();
        let path = home.write(
            ".pi/agent/sessions/--r--/2026_p1.jsonl",
            &[
                pi_header("p1"),
                json!({"type": "model_change", "timestamp": AT}),
                pi_message(json!({"role": "user", "content": [{"type": "text", "text": "go"}]})),
                pi_message(json!({"role": "assistant", "content": [
                    {"type": "thinking", "thinking": "x"},
                    {"type": "text", "text": "On it."},
                    {"type": "toolCall", "id": "c", "name": "bash", "arguments": {"command": "ls"}}
                ], "stopReason": "toolUse"})),
                pi_message(
                    json!({"role": "toolResult", "toolName": "bash", "isError": false,
                    "content": [{"type": "text", "text": "a b"}]}),
                ),
                pi_message(
                    json!({"role": "toolResult", "toolName": "bash", "isError": true,
                    "content": [{"type": "text", "text": "boom"}]}),
                ),
                pi_message(
                    json!({"role": "assistant", "content": [], "stopReason": "error",
                    "errorMessage": "403 forbidden"}),
                ),
                pi_message(json!({"role": "gremlin", "content": []})),
            ],
        );
        let located = locate(&home.0, "p1").unwrap();
        assert_eq!(located.path, path);
        let t = read(&located).unwrap();
        assert_eq!(
            shape(&t),
            [
                (Kind::User, None, "go"),
                (Kind::Agent, None, "On it."),
                (Kind::Tool, Some("bash"), "ls"),
                (Kind::Error, Some("bash"), "boom"),
                (Kind::Error, None, "403 forbidden"),
            ]
        );
        assert_eq!(t.unreadable.len(), 1);
        assert_eq!(t.unreadable[0].line, 8);
    }

    #[test]
    fn a_pi_session_in_a_format_this_build_does_not_read_is_refused_whole() {
        let home = Home::new();
        let mut header = pi_header("p2");
        header["version"] = json!(4);
        home.write(".pi/agent/sessions/--r--/2026_p2.jsonl", &[header]);
        let err = read(&locate(&home.0, "p2").unwrap()).unwrap_err();
        assert!(err.contains("version 3"), "{err}");
    }

    #[test]
    fn an_id_is_found_as_a_claude_session_a_subagent_or_refused() {
        let home = Home::new();
        let top = home.write(".claude/projects/-r/abc.jsonl", &[user(json!("x"))]);
        let sub = home.write(
            ".claude/projects/-r/abc/subagents/agent-a123.jsonl",
            &[user(json!("x"))],
        );
        let rollout = home.write(
            ".codex/sessions/2026/09/25/rollout-2026-09-25T19-49-25-c9.jsonl",
            &[json!({})],
        );
        assert_eq!(locate(&home.0, "abc").unwrap().path, top);
        let a = locate(&home.0, "a123").unwrap();
        assert_eq!((a.harness, a.path), (Harness::Claude, sub.clone()));
        let by_path = locate(&home.0, &sub.display().to_string()).unwrap();
        assert_eq!(by_path.id, "a123");

        let codex = locate(&home.0, "c9").unwrap_err();
        assert!(codex.contains("codex rollout"), "{codex}");
        let codex_path = locate(&home.0, &rollout.display().to_string()).unwrap_err();
        assert!(codex_path.contains("codex rollout"), "{codex_path}");
        assert!(
            locate(&home.0, "nope")
                .unwrap_err()
                .contains("no transcript")
        );
        assert!(
            locate(&home.0, "..")
                .unwrap_err()
                .contains("not a session id")
        );
    }

    #[test]
    fn two_transcripts_with_one_id_are_refused_naming_both() {
        let home = Home::new();
        home.write(".claude/projects/-a/dup.jsonl", &[user(json!("x"))]);
        home.write(".claude/projects/-b/dup.jsonl", &[user(json!("x"))]);
        let err = locate(&home.0, "dup").unwrap_err();
        assert!(
            err.contains("-a/dup.jsonl") && err.contains("-b/dup.jsonl"),
            "{err}"
        );
    }

    #[test]
    fn since_and_n_cut_from_the_old_end() {
        let e = |ms: u64| Entry {
            at: String::new(),
            at_ms: ms,
            kind: Kind::User,
            tool: None,
            text: ms.to_string(),
        };
        let (kept, total) = tail(vec![e(1), e(2), e(3), e(4)], Some(2), 2);
        assert_eq!(total, 3);
        assert_eq!(kept.iter().map(|e| e.at_ms).collect::<Vec<_>>(), [3, 4]);

        let now = epoch_ms(AT).unwrap();
        assert_eq!(parse_since("30m", now).unwrap(), now - 30 * 60_000);
        assert_eq!(parse_since("1d", now).unwrap(), now - 86_400_000);
        assert_eq!(parse_since(AT, 0).unwrap(), now);
        assert!(parse_since("yesterday", now).is_err());
        assert_eq!(display_time(now), "2026-09-25 16:49:25");
    }
}
