//! A session's transcript as a readable log (#421): the prompts, the agent's replies, one line
//! per tool call, and errors. Tool results and thinking are left out. `bench log` prints it.
//!
//! Like every reader in this crate, it fails loudly on a shape it does not know. A record it
//! cannot read is skipped and named as a [`Problem`], never guessed at. Records outside the
//! conversation (Claude's `attachment`, `mode`, `pr-link`, … and pi's `model_change`, …) are
//! metadata by design and skipped without a report: the conversation is Claude's `user` and
//! `assistant` records, pi's `message` records and codex's `item_completed` events, and inside
//! those every field, block and item type is named below.
//!
//! A codex rollout is read from its typed items (codex 0.144 on), never from its
//! `response_item` messages: those put injected context (AGENTS.md, `<environment_context>`,
//! hook context) in the same `role: user` messages as the prompt, while a `UserMessage` item
//! holds only what was typed or sent as a turn.

use crate::{codex, pi};
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

/// What an entry is; its spelling is the wire's (`sessions/log`).
pub use bench_wire::EntryKind as Kind;

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
    /// A prompt another session sent (`peer`): the sender its envelope names. `text` is then the
    /// message alone, out of its envelope.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
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

/// Finds the transcript for `arg`: a session id as `bench sessions --all` shows it (a Claude
/// session or subagent id, a pi session id or a codex thread id), or a transcript path (it contains a `/`),
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
    if let Some(path) = codex::rollout(home, arg) {
        return Ok(Located {
            harness: Harness::Codex,
            id: arg.to_string(),
            path,
        });
    }
    Err(format!(
        "no transcript for {arg} under {}, {} or {}",
        claude_projects(home).display(),
        pi_sessions(home).display(),
        codex::sessions_dir(home).display()
    ))
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
    if path.starts_with(codex::sessions_dir(home)) {
        // `rollout-<local time>-<thread id>`, and a thread id is a 36-character UUID.
        let at = stem.len().saturating_sub(36);
        return Ok(Located {
            harness: Harness::Codex,
            id: stem.get(at..).unwrap_or(&stem).to_string(),
            path: path.to_path_buf(),
        });
    }
    Err(format!(
        "{} is not under {}, {} or {}, so bench log does not know whose transcript it is",
        path.display(),
        claude_projects(home).display(),
        pi_sessions(home).display(),
        codex::sessions_dir(home).display()
    ))
}

/// A harness's check of a transcript's first line against the id it was located by.
type HeaderCheck = fn(&str, &str) -> Result<(), String>;

/// Reads the whole file. `Err` only when the file cannot be read at all, or (pi, codex) its
/// header is not one this build reads; a bad line is a [`Problem`] and the rest still reads.
pub fn read(located: &Located) -> Result<Transcript, String> {
    let file = fs::File::open(&located.path)
        .map_err(|e| format!("cannot open {}: {e}", located.path.display()))?;
    let mut lines = BufReader::new(file).lines();
    let mut out = Transcript::default();
    let mut tools: HashMap<String, String> = HashMap::new();
    let mut n = 0;
    let header: Option<HeaderCheck> = match located.harness {
        Harness::Claude => None,
        Harness::Pi => Some(pi::header),
        Harness::Codex => Some(codex::header),
    };
    if let Some(header) = header {
        let first = lines
            .next()
            .transpose()
            .map_err(|e| format!("cannot read {}: {e}", located.path.display()))?
            .unwrap_or_default();
        n = 1;
        header(&first, &located.id).map_err(|why| format!("{}: {why}", located.path.display()))?;
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
                Harness::Codex => codex_record(&v),
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

/// A message sent while the agent worked that it took mid-turn (Claude Code 2.1.289): it is
/// recorded only as this attachment, never as a `user` record, as a message taken at the turn's
/// end is. His prompts and other sessions' messages are the conversation; a background task's
/// notice in the same envelope is not.
fn queued(record: &Value) -> Result<Option<Entry>, String> {
    let a = &record["attachment"];
    if a["type"] != "queued_command" || a["commandMode"] != "prompt" {
        return Ok(None);
    }
    let stamp = Stamp::of(record)?;
    let text = match &a["prompt"] {
        Value::String(s) => s.clone(),
        // The same blocks, read the same way, as a `user` record's.
        Value::Array(blocks) => blocks
            .iter()
            .map(|b| match b["type"].as_str() {
                Some("text") => b["text"]
                    .as_str()
                    .map(str::to_string)
                    .ok_or_else(|| "text block without text".to_string()),
                Some("image") => Ok("[image]".into()),
                Some("document") => Ok("[document]".into()),
                other => Err(format!("queued_command prompt block type {other:?}")),
            })
            .collect::<Result<Vec<_>, _>>()?
            .join("\n"),
        _ => return Err("queued_command prompt is neither text nor blocks".into()),
    };
    if let Some((from, message)) = peer(a, &text) {
        let mut entry = stamp.entry(Kind::User, None, message);
        entry.from = Some(from);
        return Ok(Some(entry));
    }
    // A prompt from anyone else is a shape this build does not know: said, not dropped, or his
    // message would go missing again.
    if a["origin"]["kind"] != "human" {
        return Err(format!(
            "queued_command prompt from origin {:?}",
            a["origin"]["kind"]
        ));
    }
    Ok((!text.trim().is_empty()).then(|| stamp.entry(Kind::User, None, text)))
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
            from: None,
        }
    }
}

/// A prompt another Claude session sent, as its envelope says: the sender and the message out of
/// the envelope; nil for any other prompt. Claude Code wrote two envelopes. Through 2.1.288 a
/// teammate's message is a plain prompt holding one or more `<teammate-message teammate_id=…>`
/// tags, the first opening the line after the prompt's header. From 2.1.289 a peer's message is `isMeta` with `origin.kind: "peer"`: `origin.name` and
/// `origin.body` when another session sent it directly, only `origin.from` when a hook delivered
/// it (bench mail), whose message is then the lines after the prompt's header up to the first
/// blank one, before Claude Code's own note.
fn peer(record: &Value, text: &str) -> Option<(String, String)> {
    let origin = &record["origin"];
    if origin["kind"] == "peer" {
        let from = origin["name"].as_str().or(origin["from"].as_str())?;
        let message = match origin["body"].as_str() {
            Some(body) => body.to_string(),
            None => text
                .lines()
                .skip(1)
                .take_while(|l| !l.trim().is_empty())
                .collect::<Vec<_>>()
                .join("\n"),
        };
        return Some((from.to_string(), message));
    }
    const OPEN: &str = "<teammate-message";
    const CLOSE: &str = "</teammate-message>";
    // The envelope opens the line after the header; a prompt that only mentions a tag is not one.
    if !text.lines().nth(1).is_some_and(|l| l.starts_with(OPEN)) {
        return None;
    }
    let (mut senders, mut bodies) = (Vec::<String>::new(), Vec::<&str>::new());
    let mut rest = text;
    while let Some(at) = rest.find(OPEN) {
        let tag = &rest[at..];
        let head_end = tag.find('>')?;
        let head = &tag[..head_end];
        // The body runs from the head's end to the end tag after it, or to the end of the text.
        let body = &tag[head_end + 1..];
        let body_end = body.find(CLOSE).unwrap_or(body.len());
        let sender = attribute(head, "teammate_id").unwrap_or("teammate");
        if !senders.iter().any(|s| s == sender) {
            senders.push(sender.to_string());
        }
        bodies.push(body[..body_end].trim());
        rest = &body[(body_end + CLOSE.len()).min(body.len())..];
    }
    (!senders.is_empty()).then(|| (senders.join(", "), bodies.join("\n\n")))
}

/// `name="value"` out of a tag's head.
fn attribute<'a>(head: &'a str, name: &str) -> Option<&'a str> {
    let start = head.find(&format!(" {name}=\""))? + name.len() + 3;
    let len = head[start..].find('"')?;
    Some(&head[start..start + len])
}

/// A slash command the operator ran, as Claude Code records it in a prompt or a `local_command`
/// system record: the command and its arguments, tagged (`<command-name>`, `<command-args>`),
/// read as the prompt he typed; what it printed (`<local-command-stdout>`) as a result, and what
/// it printed to stderr as an error. None for any other text. Keyed on the tag that opens the
/// text, so a prompt that only mentions one is a prompt.
fn local_command(stamp: &Stamp, text: &str) -> Option<Vec<Entry>> {
    let text = text.trim_start();
    if text.starts_with("<command-name>") || text.starts_with("<command-message>") {
        let name = tag(text, "command-name")?.trim();
        let args = tag(text, "command-args").unwrap_or("").trim();
        let typed = if args.is_empty() {
            name.to_string()
        } else {
            format!("{name} {args}")
        };
        return Some(vec![stamp.entry(Kind::User, None, typed)]);
    }
    if text.starts_with("<local-command-stdout>") {
        let printed = without_escapes(tag(text, "local-command-stdout")?);
        return Some(vec![stamp.entry(
            Kind::Result,
            None,
            printed.trim().to_string(),
        )]);
    }
    if text.starts_with("<local-command-stderr>") {
        let printed = without_escapes(tag(text, "local-command-stderr")?);
        return Some(vec![stamp.entry(
            Kind::Error,
            None,
            one_line(&printed, ERROR_CHARS),
        )]);
    }
    None
}

/// What `<name>…</name>` holds in `text`.
fn tag<'a>(text: &'a str, name: &str) -> Option<&'a str> {
    let open = format!("<{name}>");
    let start = text.find(&open)? + open.len();
    let len = text[start..].find(&format!("</{name}>"))?;
    Some(&text[start..start + len])
}

/// `text` without terminal escapes (`ESC [`, parameters, then a final byte in `@`..=`~`), which a
/// command prints for its colours.
fn without_escapes(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' && chars.peek() == Some(&'[') {
            chars.next();
            for c in chars.by_ref() {
                if ('@'..='~').contains(&c) {
                    break;
                }
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// One Claude Code transcript line. `tools` maps tool-use ids to names, so an error result
/// can say which call failed.
fn claude(record: &Value, tools: &mut HashMap<String, String>) -> Result<Vec<Entry>, String> {
    let kind = record["type"].as_str().ok_or("no \"type\"")?;
    if kind == "system" {
        return match record["subtype"].as_str() {
            Some("compact_boundary") => {
                let trigger = record["compactMetadata"]["trigger"].as_str().unwrap_or("");
                Ok(vec![Stamp::of(record)?.entry(
                    Kind::Compacted,
                    None,
                    trigger.into(),
                )])
            }
            Some("local_command") => {
                let content = record["content"].as_str().unwrap_or("");
                Ok(local_command(&Stamp::of(record)?, content).unwrap_or_default())
            }
            // Hook summaries, API retries and the like: not the conversation.
            _ => Ok(Vec::new()),
        };
    }
    if kind == "attachment" {
        return queued(record).map(|e| e.into_iter().collect());
    }
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
        // A message from another session is a prompt, said once, out of its envelope.
        if let Some((from, message)) = peer(record, &plain_text(content)) {
            let mut entry = stamp.entry(Kind::User, None, message);
            entry.from = Some(from);
            return Ok(vec![entry]);
        }
        // A slash command he ran, and what it printed.
        if let Some(entries) = local_command(&stamp, &plain_text(content)) {
            return Ok(entries);
        }
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
    match record["type"].as_str().ok_or("no \"type\"")? {
        "message" => {}
        "compaction" => {
            return Ok(vec![Stamp::of(record)?.entry(
                Kind::Compacted,
                None,
                String::new(),
            )]);
        }
        _ => return Ok(Vec::new()),
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

/// One codex rollout line after `session_meta`. Its conversation is the `item_completed`
/// events, a turn the operator interrupted, and a message another codex agent sent this one
/// (a `response_item` with no item of its own); everything else (`turn_context`,
/// `token_count`, the other `response_item`s, …) is metadata or a second copy of an item.
fn codex_record(record: &Value) -> Result<Vec<Entry>, String> {
    let payload = &record["payload"];
    match record["type"].as_str().ok_or("no \"type\"")? {
        "event_msg" => {}
        "response_item" if payload["type"] == "agent_message" => {
            return codex_agent_message(&Stamp::of(record)?, payload);
        }
        "compacted" => {
            return Ok(vec![Stamp::of(record)?.entry(
                Kind::Compacted,
                None,
                String::new(),
            )]);
        }
        _ => return Ok(Vec::new()),
    }
    match payload["type"].as_str() {
        Some("item_completed") => codex_item(&Stamp::of(record)?, &payload["item"]),
        Some("turn_aborted") => Ok(vec![Stamp::of(record)?.entry(
            Kind::Error,
            None,
            "aborted".into(),
        )]),
        // Written by codex before it wrote items (0.116), never beside them.
        Some(old @ ("user_message" | "agent_message")) => Err(format!(
            "{old}: an event from a rollout older than codex's items; this build reads item_completed"
        )),
        _ => Ok(Vec::new()),
    }
}

/// One completed codex item: the prompt, a reply, or a tool call (an error when it failed).
fn codex_item(stamp: &Stamp, item: &Value) -> Result<Vec<Entry>, String> {
    let kind = item["type"].as_str().ok_or("item without a type")?;
    // `Extension` says so in `failure` rather than in `status`.
    let failed = item["status"] == "failed" || !item["failure"].is_null();
    let tool = |name: &str, arg: String| stamp.entry(Kind::Tool, Some(name.into()), arg);
    let call = match kind {
        "UserMessage" => return codex_prompt(stamp, &item["content"]),
        "AgentMessage" => return codex_reply(stamp, &item["content"]),
        // Thinking, and the marker a compaction leaves.
        "Reasoning" | "ContextCompaction" => return Ok(Vec::new()),
        "CommandExecution" => tool("shell", codex_command(&item["command"])),
        "FileChange" => {
            let paths = item["changes"]
                .as_object()
                .ok_or("FileChange without changes")?
                .keys()
                .cloned()
                .collect::<Vec<_>>()
                .join(" ");
            tool("apply_patch", one_line(&paths, TOOL_ARG_CHARS))
        }
        "McpToolCall" => {
            let (server, name) = (item["server"].as_str(), item["tool"].as_str());
            let (Some(server), Some(name)) = (server, name) else {
                return Err("McpToolCall without a server and tool".into());
            };
            tool(&format!("{server}.{name}"), tool_arg(&item["arguments"]))
        }
        "WebSearch" => tool("web_search", tool_arg(item)),
        "ImageView" => tool("view_image", tool_arg(item)),
        // A tool of codex's own (`web.search`, `clock.sleep`, `image_gen.generation`).
        "Extension" => {
            let name = item["kind"].as_str().ok_or("Extension without a kind")?;
            tool(name, tool_arg(&json_without(item, &["id", "type", "kind"])))
        }
        "CollabAgentToolCall" => {
            let name = item["tool"]
                .as_str()
                .ok_or("CollabAgentToolCall without a tool")?;
            tool(name, String::new())
        }
        // A subagent's lifecycle: only its start is a call the agent made.
        "SubAgentActivity" => match item["kind"].as_str() {
            Some("started") => tool("spawn_agent", tool_arg(&item["agent_path"])),
            Some(_) => return Ok(Vec::new()),
            None => return Err("SubAgentActivity without a kind".into()),
        },
        other => return Err(format!("item type {other:?}")),
    };
    Ok(with_failure(stamp, call, failed, item))
}

/// A tool call, then its failure as an error when it failed: what it printed, else its exit.
fn with_failure(stamp: &Stamp, call: Entry, failed: bool, item: &Value) -> Vec<Entry> {
    if !failed {
        return vec![call];
    }
    let said = ["stderr", "aggregated_output", "error", "failure"]
        .iter()
        .map(|k| match &item[*k] {
            Value::Object(o) => o.get("message").map(plain_text).unwrap_or_default(),
            other => plain_text(other),
        })
        .chain(std::iter::once(plain_text(&item["result"]["content"])))
        .find(|t| !t.trim().is_empty())
        .or_else(|| item["exit_code"].as_i64().map(|c| format!("exit {c}")))
        .unwrap_or_else(|| "failed".into());
    let error = stamp.entry(Kind::Error, call.tool.clone(), one_line(&said, ERROR_CHARS));
    vec![call, error]
}

fn json_without(item: &Value, keys: &[&str]) -> Value {
    let mut v = item.clone();
    if let Some(o) = v.as_object_mut() {
        o.retain(|k, _| !keys.contains(&k.as_str()));
    }
    v
}

/// A command codex ran: the script of `[shell, -lc, script]`, else the words joined.
fn codex_command(command: &Value) -> String {
    let words: Vec<&str> = command
        .as_array()
        .map(|a| a.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let line = match words.as_slice() {
        [_, flag, script] if flag.starts_with('-') => (*script).to_string(),
        _ => command
            .as_str()
            .map_or_else(|| words.join(" "), String::from),
    };
    one_line(&line, TOOL_ARG_CHARS)
}

fn codex_prompt(stamp: &Stamp, content: &Value) -> Result<Vec<Entry>, String> {
    let mut text: Vec<String> = Vec::new();
    for b in content
        .as_array()
        .ok_or("UserMessage content is not blocks")?
    {
        match b["type"].as_str() {
            Some("text") => text.push(b["text"].as_str().ok_or("text block without text")?.into()),
            Some("local_image" | "image") => text.push("[image]".into()),
            Some("skill") => text.push(format!("[skill {}]", b["name"].as_str().unwrap_or("?"))),
            other => return Err(format!("UserMessage block type {other:?}")),
        }
    }
    let text = text.join("\n");
    Ok(if text.trim().is_empty() {
        Vec::new()
    } else {
        vec![stamp.entry(Kind::User, None, text)]
    })
}

/// A message from another codex agent (a parent's task, a subagent's report), delivered to
/// this one as a turn. Its payload is mostly encrypted; the readable header names the sender.
fn codex_agent_message(stamp: &Stamp, payload: &Value) -> Result<Vec<Entry>, String> {
    let mut text: Vec<&str> = Vec::new();
    for b in payload["content"]
        .as_array()
        .ok_or("agent_message content is not blocks")?
    {
        match b["type"].as_str() {
            Some("input_text") => text.push(b["text"].as_str().ok_or("input_text without text")?),
            Some("encrypted_content") => text.push("[encrypted]"),
            other => return Err(format!("agent_message block type {other:?}")),
        }
    }
    Ok(vec![stamp.entry(Kind::User, None, text.join("\n"))])
}

fn codex_reply(stamp: &Stamp, content: &Value) -> Result<Vec<Entry>, String> {
    let mut out = Vec::new();
    for b in content
        .as_array()
        .ok_or("AgentMessage content is not blocks")?
    {
        match b["type"].as_str() {
            Some("Text") => {
                let text = b["text"].as_str().ok_or("Text block without text")?;
                if !text.trim().is_empty() {
                    out.push(stamp.entry(Kind::Agent, None, text.to_string()));
                }
            }
            other => return Err(format!("AgentMessage block type {other:?}")),
        }
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

    /// A message he sent while the agent worked, taken mid-turn, is recorded only as a
    /// `queued_command` attachment: it reads as his prompt, where it was taken, as does one from
    /// another session; a background task's notice in the same envelope does not.
    #[test]
    fn a_message_taken_mid_turn_is_his_prompt() {
        let queued = |mode: &str, origin: Value, prompt: Value| {
            json!({"type": "attachment", "timestamp": AT, "attachment": {
                "type": "queued_command", "commandMode": mode, "origin": origin,
                "prompt": prompt, "humanTurn": true}})
        };
        let t = read_claude(&[
            user(json!("run the gate")),
            json!({"type": "queue-operation", "operation": "enqueue", "timestamp": AT,
                "content": "and then push"}),
            assistant(json!([{"type": "text", "text": "Running."}])),
            queued("prompt", json!({"kind": "human"}), json!("and then push")),
            queued(
                "prompt",
                json!({"kind": "human"}),
                json!([{"type": "text", "text": "this one"}, {"type": "image", "source": {}}]),
            ),
            queued(
                "prompt",
                json!({"kind": "peer", "name": "lead", "body": "status?"}),
                json!("<agent-message from=\"lead\">status?</agent-message>"),
            ),
            queued(
                "task-notification",
                json!({"kind": "task-notification"}),
                json!("<task-notification>done</task-notification>"),
            ),
            json!({"type": "attachment", "timestamp": AT, "attachment": {"type": "model"}}),
        ]);
        assert_eq!(
            shape(&t),
            [
                (Kind::User, None, "run the gate"),
                (Kind::Agent, None, "Running."),
                (Kind::User, None, "and then push"),
                (Kind::User, None, "this one\n[image]"),
                (Kind::User, None, "status?"),
            ]
        );
        assert_eq!(t.entries[4].from.as_deref(), Some("lead"));
        assert!(t.unreadable.is_empty(), "{:?}", t.unreadable);
    }

    /// A queued prompt from an origin this build does not know is named as unreadable, never
    /// dropped: a message that silently disappears is the bug the attachment's reading fixes.
    #[test]
    fn a_queued_prompt_from_an_unknown_origin_is_unreadable() {
        let t = read_claude(&[
            json!({"type": "attachment", "timestamp": AT, "attachment": {
            "type": "queued_command", "commandMode": "prompt", "origin": {"kind": "robot"},
            "prompt": "hello"}}),
        ]);
        assert!(t.entries.is_empty());
        assert_eq!(t.unreadable.len(), 1, "{:?}", t.unreadable);
    }

    /// A message another session sent is one prompt from its sender, out of the envelope, in
    /// each envelope Claude Code wrote; an `isMeta` prompt from anyone else stays hidden.
    #[test]
    fn a_message_from_another_session_is_its_sender_and_message() {
        let note = "\n\nThis came from another Claude session, not typed by your user.";
        let peer = |origin: Value, text: &str| {
            json!({"type": "user", "isMeta": true, "timestamp": AT, "origin": origin,
                "message": {"content": text}})
        };
        let t = read_claude(&[
            user(json!(
                "Another Claude session sent a message:\n<teammate-message teammate_id=\"pr-1\" \
                 color=\"blue\" summary=\"Report\">\nPR 1 is green.\nDetails follow.\n\
                 </teammate-message>"
            )),
            user(json!([{"type": "text", "text":
                "Another Claude session sent a message:\n<teammate-message teammate_id=\"a\">\
                 \none\n</teammate-message>\n<teammate-message teammate_id=\"b\">two\
                 </teammate-message>\n<teammate-message teammate_id=\"a\">three</teammate-message>"}])),
            peer(
                json!({"kind": "peer", "from": "bench"}),
                &format!(
                    "Another Claude session sent a message:\nYou have mail from lead: /m/1.md{note}"
                ),
            ),
            peer(
                json!({"kind": "peer", "from": "uds:/s.sock", "name": "s5", "body": "I stop here."}),
                &format!("Another Claude session sent a message:\nI stop here.{note}"),
            ),
            json!({"type": "user", "isMeta": true, "timestamp": AT, "origin": {"kind": "human"},
                "message": {"content": "caveat"}}),
            user(json!(
                "what does <teammate-message teammate_id=\"x\"> mean?"
            )),
            // A tag whose head never closes before its end tag: read, never a panic.
            user(json!(
                "Another Claude session sent a message:\n<teammate-message </teammate-message> x"
            )),
        ]);
        let from: Vec<_> = t.entries.iter().map(|e| e.from.as_deref()).collect();
        assert_eq!(
            from,
            [
                Some("pr-1"),
                Some("a, b"),
                Some("bench"),
                Some("s5"),
                None,
                Some("teammate")
            ]
        );
        assert_eq!(
            shape(&t),
            [
                (Kind::User, None, "PR 1 is green.\nDetails follow."),
                (Kind::User, None, "one\n\ntwo\n\nthree"),
                (Kind::User, None, "You have mail from lead: /m/1.md"),
                (Kind::User, None, "I stop here."),
                (
                    Kind::User,
                    None,
                    "what does <teammate-message teammate_id=\"x\"> mean?"
                ),
                (Kind::User, None, "x"),
            ]
        );
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

    /// A slash command is the prompt he typed, and what it printed is a result line, as Claude
    /// Code writes both: tagged prompts or `local_command` system records. A compaction is a
    /// divider; any other system record is not the conversation.
    #[test]
    fn a_slash_command_reads_as_its_prompt_and_its_result_and_a_compaction_as_a_divider() {
        let system = |subtype: &str, content: &str| json!({"type": "system", "subtype": subtype, "timestamp": AT, "content": content});
        let t = read_claude(&[
            json!({"type": "system", "subtype": "compact_boundary", "timestamp": AT,
                "content": "Conversation compacted", "compactMetadata": {"trigger": "manual"}}),
            user(json!(
                "<command-name>/compact</command-name>\n            <command-message>compact\
                 </command-message>\n            <command-args>remember the plan</command-args>"
            )),
            user(json!(
                "<local-command-stdout>\u{1b}[2mCompacted (ctrl+o to see full summary)\u{1b}[22m\
                 </local-command-stdout>"
            )),
            system(
                "local_command",
                "<command-name>/remote-control</command-name>\n<command-message>remote-control\
                 </command-message>\n<command-args></command-args>",
            ),
            system(
                "local_command",
                "<local-command-stdout></local-command-stdout>",
            ),
            user(json!(
                "<local-command-stderr>\u{1b}[3~no such plugin</local-command-stderr>"
            )),
            system("stop_hook_summary", "hooks ran"),
            user(json!("what does <command-name> do?")),
        ]);
        assert_eq!(
            shape(&t),
            [
                (Kind::Compacted, None, "manual"),
                (Kind::User, None, "/compact remember the plan"),
                (Kind::Result, None, "Compacted (ctrl+o to see full summary)"),
                (Kind::User, None, "/remote-control"),
                (Kind::Result, None, ""),
                (Kind::Error, None, "no such plugin"),
                (Kind::User, None, "what does <command-name> do?"),
            ]
        );
        assert!(t.unreadable.is_empty(), "{:?}", t.unreadable);
    }

    /// Codex's `compacted` record and pi's `compaction` entry are the same divider.
    #[test]
    fn a_codex_or_pi_compaction_is_a_divider() {
        let home = Home::new();
        home.write(
            ".pi/agent/sessions/--r--/2026_p1.jsonl",
            &[
                pi_header("p1"),
                json!({"type": "compaction", "id": "c", "timestamp": AT, "summary": "## Goal"}),
            ],
        );
        let pi = read(&locate(&home.0, "p1").unwrap()).unwrap();
        assert_eq!(shape(&pi), [(Kind::Compacted, None, "")]);
        let id = "01a0f663-47f0-7d53-b41a-68f3a1f656ab";
        home.write(
            &format!(".codex/sessions/2026/10/01/rollout-2026-10-01T10-34-56-{id}.jsonl"),
            &[
                json!({"timestamp": AT, "type": "session_meta",
                    "payload": {"id": id, "cli_version": "0.157.0", "cwd": "/r"}}),
                json!({"timestamp": AT, "type": "compacted",
                    "payload": {"message": "", "replacement_history": []}}),
            ],
        );
        let codex = read(&locate(&home.0, id).unwrap()).unwrap();
        assert_eq!(shape(&codex), [(Kind::Compacted, None, "")]);
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
    fn an_id_is_found_as_a_claude_session_a_subagent_a_codex_thread_or_refused() {
        let home = Home::new();
        let top = home.write(".claude/projects/-r/abc.jsonl", &[user(json!("x"))]);
        let sub = home.write(
            ".claude/projects/-r/abc/subagents/agent-a123.jsonl",
            &[user(json!("x"))],
        );
        let rollout = home.write(
            ".codex/sessions/2026/09/25/rollout-2026-09-25T19-49-25-01a0c9aa-0000-7000-8000-000000000000.jsonl",
            &[json!({})],
        );
        assert_eq!(locate(&home.0, "abc").unwrap().path, top);
        let a = locate(&home.0, "a123").unwrap();
        assert_eq!((a.harness, a.path), (Harness::Claude, sub.clone()));
        let by_path = locate(&home.0, &sub.display().to_string()).unwrap();
        assert_eq!(by_path.id, "a123");

        let thread = "01a0c9aa-0000-7000-8000-000000000000";
        let codex = locate(&home.0, thread).unwrap();
        assert_eq!((codex.harness, &codex.path), (Harness::Codex, &rollout));
        let by_path = locate(&home.0, &rollout.display().to_string()).unwrap();
        assert_eq!(
            by_path.id, thread,
            "the id is the file name's last 36 characters"
        );
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

    fn codex_event(item: Value) -> Value {
        json!({"timestamp": AT, "type": "event_msg",
            "payload": {"type": "item_completed", "thread_id": "t1", "turn_id": "u", "item": item}})
    }

    /// Record shapes copied from real codex 0.157 rollouts, cut down.
    #[test]
    fn a_codex_rollout_reads_its_items_and_never_its_injected_context() {
        let home = Home::new();
        let id = "01a0f663-47f0-7d53-b41a-68f3a1f656ab";
        let rel = format!(".codex/sessions/2026/10/01/rollout-2026-10-01T10-34-56-{id}.jsonl");
        let meta = json!({"timestamp": AT, "type": "session_meta",
            "payload": {"id": id, "cli_version": "0.157.0", "cwd": "/r"}});
        let injected = json!({"timestamp": AT, "type": "response_item", "payload": {"type": "message",
            "role": "user", "content": [{"type": "input_text", "text": "# AGENTS.md instructions"}]}});
        let path = home.write(
            &rel,
            &[
                meta.clone(),
                json!({"timestamp": AT, "type": "event_msg", "payload": {"type": "task_started"}}),
                injected,
                json!({"timestamp": AT, "type": "turn_context", "payload": {}}),
                codex_event(json!({"type": "UserMessage", "id": "item-1", "content": [
                    {"type": "text", "text": "fix the build"},
                    {"type": "skill", "name": "prp-spike", "path": "/s/SKILL.md"}]})),
                codex_event(json!({"type": "Reasoning", "id": "r", "summary_text": [], "raw_content": []})),
                codex_event(json!({"type": "AgentMessage", "id": "a", "phase": "commentary",
                    "content": [{"type": "Text", "text": "Looking."}]})),
                codex_event(json!({"type": "CommandExecution", "id": "c1",
                    "command": ["/bin/zsh", "-lc", "cargo build\n--release"], "status": "completed", "exit_code": 0})),
                codex_event(json!({"type": "CommandExecution", "id": "c2",
                    "command": ["/bin/zsh", "-lc", "cargo test"], "status": "failed", "exit_code": 101,
                    "stderr": "", "aggregated_output": "error[E0425]: cannot find value"})),
                codex_event(json!({"type": "FileChange", "id": "f", "status": "completed",
                    "changes": {"/r/a.rs": {"type": "update", "unified_diff": "@@"}}})),
                codex_event(json!({"type": "McpToolCall", "id": "m", "server": "gh", "tool": "search",
                    "arguments": {"query": "is:open"}, "status": "failed",
                    "result": {"content": [{"type": "text", "text": "422 Validation Failed"}]}})),
                codex_event(json!({"type": "SubAgentActivity", "id": "s", "kind": "interacted",
                    "agent_thread_id": "t2", "agent_path": "/root/x"})),
                codex_event(json!({"type": "Hologram", "id": "h"})),
                json!({"timestamp": AT, "type": "event_msg", "payload": {"type": "turn_aborted", "reason": "interrupted"}}),
            ],
        );
        let located = locate(&home.0, id).unwrap();
        assert_eq!(located.path, path);
        let t = read(&located).unwrap();
        assert_eq!(
            shape(&t),
            [
                (Kind::User, None, "fix the build\n[skill prp-spike]"),
                (Kind::Agent, None, "Looking."),
                (Kind::Tool, Some("shell"), "cargo build"),
                (Kind::Tool, Some("shell"), "cargo test"),
                (
                    Kind::Error,
                    Some("shell"),
                    "error[E0425]: cannot find value"
                ),
                (Kind::Tool, Some("apply_patch"), "/r/a.rs"),
                (Kind::Tool, Some("gh.search"), "is:open"),
                (Kind::Error, Some("gh.search"), "422 Validation Failed"),
                (Kind::Error, None, "aborted"),
            ]
        );
        assert_eq!(t.unreadable.len(), 1);
        assert_eq!(t.unreadable[0].line, 13);
        assert!(t.unreadable[0].why.contains("Hologram"));

        // A rollout whose session_meta names another thread is refused whole.
        let mut other = meta;
        other["payload"]["id"] = json!("01a0f663-0000-7000-8000-000000000000");
        home.write(&rel, &[other]);
        let err = read(&located).unwrap_err();
        assert!(err.contains("session_meta id"), "{err}");
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
            from: None,
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
