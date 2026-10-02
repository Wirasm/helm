//! The verbs an agent drives the bench with (M3): open, split, show, focus, move, name and
//! close a pane, close a workspace, spawn an agent into a pane, read a pane or helm's window, and
//! read, follow and type into any terminal (M5b).
//!
//! Every one of them is the socket's own verb with its arguments built from the wire's types
//! (`LayoutVerb`, `SpawnArgs`, `HelmAsk`), so the CLI cannot spell what benchd does not read.
//! They carry who asked (the agent: `HELM_PANE`, `BENCH_HANDLE`) and `asked` only from
//! `--asked`. That flag is the whole of the focus rule on this side: without it a verb lands in
//! the background and benchd refuses one that would move the operator's focus; with it, it may
//! bring something forward. Pass it only when the operator asked (bench-architecture.md).

use crate::{Cli, exchange, fail, print_response, record_root, refuse};
use bench_doc::{Direction, Document, DrawerName, PaneId, PaneName, Place, SlotId, Split, Surface};
use bench_wire::{
    Activity, DocumentAt, EXIT_NO_DAEMON, HelmAsk, HelmAskArgs, LayoutVerb, LiveSessions, MoveTo,
    OpenInto, PaneOpen, Response, ScreenGetArgs, ScreenSendArgs, SessionEntry, SpawnArgs, Status,
};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, ErrorKind, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// The verbs this module answers, by their first word. `close` and `get` are shared with the
/// session and document verbs; [`owns`] decides by the word after them.
const VERBS: &[&str] = &[
    "open",
    "split",
    "show",
    "focus",
    "move",
    "name",
    "spawn",
    "send",
    "watch",
    "workspace",
];

/// Flags that take a value. The rest (`--asked`, `--force`, `--rename`) are switches.
const VALUED: &[&str] = &[
    "--suite",
    "--workspace",
    "--drawer",
    "--surface",
    "--agent",
    "--cwd",
    "--name",
    "--prompt-file",
    "--model",
    "--effort",
    "--rows",
    "--cols",
    "--resume",
    "--fork",
    "--arg",
    "--out",
    "--window",
    "--tab",
    "--before",
    "--beside",
    "--side",
    "--timeout",
    "--after",
];

/// Whether `raw` (the arguments after `bench`) is one of these verbs. `close <pane uuid>` is,
/// `close <session>` is the session verb; `get pane|screenshot|screen` is, bare `get` is the
/// document.
pub fn owns(raw: &[String]) -> bool {
    if raw.iter().any(|a| a == "--help" || a == "-h") {
        return false;
    }
    let words = words(raw);
    match words.first().map(String::as_str) {
        Some(verb) if VERBS.contains(&verb) => true,
        Some("close") => words.get(1).is_some_and(|w| PaneId::parse(w).is_ok()),
        Some("get") => matches!(
            words.get(1).map(String::as_str),
            Some("pane" | "screenshot" | "screen")
        ),
        _ => false,
    }
}

/// The non-flag words, skipping every flag's value.
fn words(raw: &[String]) -> Vec<String> {
    let mut out = Vec::new();
    let mut it = raw.iter();
    while let Some(arg) = it.next() {
        if VALUED.contains(&arg.as_str()) {
            it.next();
        } else if !arg.starts_with("--") {
            out.push(arg.clone());
        }
    }
    out
}

struct Parsed {
    words: Vec<String>,
    values: Vec<(String, String)>,
    asked: bool,
    force: bool,
    rename: bool,
    history: bool,
    enter: bool,
    keys: bool,
}

impl Parsed {
    fn value(&self, flag: &str) -> Option<String> {
        self.values
            .iter()
            .find(|(k, _)| k == flag)
            .map(|(_, v)| v.clone())
    }

    fn all(&self, flag: &str) -> Vec<String> {
        self.values
            .iter()
            .filter(|(k, _)| k == flag)
            .map(|(_, v)| v.clone())
            .collect()
    }
}

fn parse(raw: &[String]) -> Result<Parsed, String> {
    let mut parsed = Parsed {
        words: Vec::new(),
        values: Vec::new(),
        asked: false,
        force: false,
        rename: false,
        history: false,
        enter: false,
        keys: false,
    };
    let mut it = raw.iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--asked" => parsed.asked = true,
            "--force" => parsed.force = true,
            "--rename" => parsed.rename = true,
            "--history" => parsed.history = true,
            "--enter" => parsed.enter = true,
            "--keys" => parsed.keys = true,
            flag if VALUED.contains(&flag) => match it.next() {
                Some(v) => parsed.values.push((flag.to_string(), v.clone())),
                None => return Err(format!("{flag} needs a value")),
            },
            flag if flag.starts_with("--") => return Err(format!("unknown flag {flag:?}")),
            word => parsed.words.push(word.to_string()),
        }
    }
    Ok(parsed)
}

pub fn run(raw: &[String]) -> i32 {
    let parsed = match parse(raw) {
        Ok(p) => p,
        Err(why) => return refuse(&why),
    };
    let root = match record_root(parsed.value("--suite")) {
        Ok(root) => root,
        Err(why) => return refuse(&why),
    };
    let verb = parsed.words[0].clone();
    let request = match verb.as_str() {
        "get" if parsed.words.get(1).map(String::as_str) == Some("pane") => {
            return get_pane(&parsed, root);
        }
        "get" if parsed.words.get(1).map(String::as_str) == Some("screen") => screen_get(&parsed),
        "watch" => return watch(&parsed, root),
        "get" => screenshot(&parsed),
        "send" => send(&parsed),
        "spawn" => spawn(&parsed),
        _ => layout(&verb, &parsed),
    };
    let (wire_verb, args) = match request {
        Ok(pair) => pair,
        Err(why) => return refuse(&why),
    };
    let cli = Cli {
        verb: wire_verb,
        args,
        root,
        asked: parsed.asked,
    };
    match exchange(&cli) {
        Ok(response) => print_response(&response),
        Err(code) => code,
    }
}

/// The layout verbs: the wire's `LayoutVerb`, encoded by its own serializer.
fn layout(verb: &str, p: &Parsed) -> Result<(String, Value), String> {
    let pane = || -> Result<PaneId, String> {
        let raw = p
            .words
            .get(1)
            .ok_or_else(|| format!("{verb} needs a pane id — `bench get` lists them"))?;
        PaneId::parse(raw)
    };
    let workspace = || p.value("--workspace").map(|w| absolute(&w)).transpose();
    let typed = match verb {
        "open" => open(p, workspace()?)?,
        "split" => LayoutVerb::PaneSplit {
            workspace: workspace()?,
            direction: match p.words.get(1).map(String::as_str) {
                Some("right") => Split::Right,
                Some("down") => Split::Down,
                _ => return Err("split needs a direction: right or down".into()),
            },
            surface: p.value("--surface").map(|s| surface(&s)).transpose()?,
        },
        "show" => LayoutVerb::PaneShow { pane: pane()? },
        "focus" if !p.asked => {
            return Err(
                "focus moves the operator's keyboard, so it needs --asked — pass it only when the operator asked; `bench show` brings a pane forward without it"
                    .into(),
            );
        }
        "focus" => LayoutVerb::PaneShow { pane: pane()? },
        "move" => LayoutVerb::PaneMove {
            pane: pane()?,
            to: move_to(p, workspace()?)?,
        },
        "name" => LayoutVerb::PaneName {
            pane: pane()?,
            name: PaneName::Chosen(
                p.words
                    .get(2..)
                    .filter(|w| !w.is_empty())
                    .ok_or("name needs the words to call the pane")?
                    .join(" "),
            ),
            rename: p.rename,
        },
        "close" => LayoutVerb::PaneClose {
            pane: pane()?,
            force: p.force,
        },
        "workspace" => match (p.words.get(1).map(String::as_str), p.words.get(2)) {
            (Some("close"), Some(path)) => LayoutVerb::WorkspaceClose {
                path: absolute(path)?,
                force: p.force,
            },
            _ => {
                return Err(
                    "workspace takes close <path> [--force] [--asked] — `bench get` lists the workspaces"
                        .into(),
                );
            }
        },
        other => return Err(format!("{other} is not a pane verb")),
    };
    let encoded = serde_json::to_value(&typed).map_err(|e| e.to_string())?;
    Ok((
        encoded["verb"].as_str().unwrap_or_default().to_string(),
        encoded["args"].clone(),
    ))
}

/// `open <file|browser|terminal>`. A file is what an agent puts in front of the operator, so it
/// must be one helm renders; that it exists is benchd's to check, on its own disk (M5c: the CLI
/// may be on another machine).
fn open(p: &Parsed, workspace: Option<bench_doc::StandardPath>) -> Result<LayoutVerb, String> {
    let what = p
        .words
        .get(1)
        .ok_or("open needs what to open: a file path, browser or terminal")?;
    let surface = match what.as_str() {
        "browser" => Surface::Browser,
        "terminal" => Surface::terminal(),
        path => renderable_file(path)?,
    };
    let into = match (workspace, p.value("--drawer")) {
        (Some(_), Some(_)) => return Err("--workspace or --drawer, not both".into()),
        (Some(w), None) => OpenInto::Workspace(w),
        (None, Some(d)) => OpenInto::Drawer(DrawerName::new(&d)?),
        (None, None) => OpenInto::Active,
    };
    Ok(LayoutVerb::PaneOpen(PaneOpen { into, surface }))
}

fn renderable_file(raw: &str) -> Result<Surface, String> {
    let path = std::env::current_dir()
        .unwrap_or_default()
        .join(raw)
        .components()
        .collect::<PathBuf>();
    if !bench_wire::is_renderable(&path.to_string_lossy()) {
        return Err(format!(
            "{} is not a file helm renders — a canvas is one of: {}",
            path.display(),
            bench_wire::RENDERABLE.join(", ")
        ));
    }
    Surface::file(&path.display().to_string())
}

fn surface(raw: &str) -> Result<Surface, String> {
    match raw {
        "browser" => Ok(Surface::Browser),
        "terminal" => Ok(Surface::terminal()),
        path => renderable_file(path.strip_prefix("file:").unwrap_or(path)),
    }
}

/// `move`'s one destination: a step, a slot's tab strip, beside a slot, or another workspace —
/// every place a drag in helm can drop a pane (#178).
fn move_to(p: &Parsed, workspace: Option<bench_doc::StandardPath>) -> Result<MoveTo, String> {
    const FORMS: &str = "move takes one destination: <left|right|up|down>, --tab <slot> [--before <pane>], --beside <slot> --side <left|right|up|down>, or --workspace <path> — `bench get pane` names a pane's slot";
    let before = p.value("--before");
    let side = p.value("--side");
    if before.is_some() && p.value("--tab").is_none() {
        return Err(format!("--before goes with --tab; {FORMS}"));
    }
    if side.is_some() && p.value("--beside").is_none() {
        return Err(format!("--side goes with --beside; {FORMS}"));
    }
    match (
        p.words.get(2),
        p.value("--tab"),
        p.value("--beside"),
        workspace,
    ) {
        (Some(_), None, None, None) => Ok(MoveTo::Step(direction(p.words.get(2))?)),
        (None, Some(slot), None, None) => Ok(MoveTo::Place(Place::Tab {
            slot: SlotId::parse(&slot)?,
            before: before.as_deref().map(PaneId::parse).transpose()?,
        })),
        (None, None, Some(slot), None) => Ok(MoveTo::Place(Place::Beside {
            slot: SlotId::parse(&slot)?,
            side: direction(side.as_ref())
                .map_err(|_| format!("--beside needs --side; {FORMS}"))?,
        })),
        (None, None, None, Some(path)) => Ok(MoveTo::Workspace(path)),
        _ => Err(FORMS.into()),
    }
}

fn direction(raw: Option<&String>) -> Result<Direction, String> {
    match raw.map(String::as_str) {
        Some("left") => Ok(Direction::Left),
        Some("right") => Ok(Direction::Right),
        Some("up") => Ok(Direction::Up),
        Some("down") => Ok(Direction::Down),
        _ => Err("move needs a direction: left, right, up or down".into()),
    }
}

/// A path the caller named, made absolute against its own cwd — which only the caller knows.
fn absolute(raw: &str) -> Result<bench_doc::StandardPath, String> {
    let path = std::env::current_dir().unwrap_or_default().join(raw);
    bench_doc::StandardPath::new(&path.display().to_string())
}

/// `spawn`: an agent in a benchd pty, shown in a pane of `--cwd`'s workspace.
fn spawn(p: &Parsed) -> Result<(String, Value), String> {
    let cwd = std::env::current_dir().unwrap_or_default();
    let number = |flag: &str| -> Result<Option<u16>, String> {
        p.value(flag)
            .map(|v| v.parse().map_err(|_| format!("{flag} needs a number")))
            .transpose()
    };
    let args = SpawnArgs {
        agent: p
            .value("--agent")
            .ok_or("spawn needs --agent <claude|codex|pi>")?,
        cwd: cwd
            .join(p.value("--cwd").ok_or("spawn needs --cwd <dir>")?)
            .display()
            .to_string(),
        name: p.value("--name"),
        // Absolute: the agent reads it from its own cwd, which is not the caller's.
        prompt_file: p
            .value("--prompt-file")
            .map(|f| cwd.join(f).display().to_string()),
        prompt: None,
        model: p.value("--model"),
        effort: p.value("--effort"),
        rows: number("--rows")?,
        cols: number("--cols")?,
        resume: p.value("--resume"),
        fork: p.value("--fork"),
        args: p.all("--arg"),
    };
    Ok(("spawn".into(), json!(args)))
}

/// `get screen <pane|session> [--history]`: the terminal as its viewer shows it.
fn screen_get(p: &Parsed) -> Result<(String, Value), String> {
    let target = p.words.get(2).ok_or(
        "get screen needs a pane id or a session id — `bench get` and `bench sessions` list them",
    )?;
    Ok((
        "screen/get".into(),
        json!(ScreenGetArgs {
            target: target.clone(),
            history: p.history,
        }),
    ))
}

/// `send <pane|session> <text> [--enter] [--keys]`: typed into the terminal, Return after it on
/// its own. `--keys` writes the text as keys rather than a paste.
fn send(p: &Parsed) -> Result<(String, Value), String> {
    let target = p
        .words
        .get(1)
        .ok_or("send needs a pane id or a session id, then the text")?;
    let text = p.words.get(2..).unwrap_or_default().join(" ");
    if text.is_empty() && !p.enter {
        return Err("send needs the text to type, or --enter for Return alone".into());
    }
    Ok((
        "screen/send".into(),
        json!(ScreenSendArgs {
            target: target.clone(),
            text,
            enter: p.enter,
            keys: p.keys,
        }),
    ))
}

/// `watch screen <pane|session>`: one JSON line per change of the screen, read at a finished
/// frame and at most ten times a second, until the session ends (exit 3) or benchd goes.
fn watch(p: &Parsed, root: PathBuf) -> i32 {
    let target = match (p.words.get(1).map(String::as_str), p.words.get(2)) {
        (Some("screen"), Some(t)) => t.clone(),
        (Some("screen"), None) | (None, _) => {
            return refuse("watch needs `screen <pane|session>` or `<handle>`");
        }
        (Some(handle), _) => return watch_agent(p, root, handle),
    };
    let cli = Cli {
        verb: "screen/get".into(),
        args: json!(ScreenGetArgs {
            target,
            history: false,
        }),
        root,
        asked: false,
    };
    let mut last: Option<Value> = None;
    loop {
        let response = match exchange(&cli) {
            Ok(r) => r,
            Err(code) => return code,
        };
        if response.status != Status::Ok {
            return print_response(&response);
        }
        if response.data != last {
            if let Some(data) = &response.data {
                println!("{data}");
            }
            last = response.data;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
}

/// `watch <handle>` (M1, #357): wait until the agent in the benchd session with that handle waits
/// on the operator, ends a turn, goes idle without ending one, or its session ends, then print
/// one line saying which, with the session as `sessions` gives it. It follows benchd's events
/// rather than polling, so it costs nothing while the agent works and misses no change, however
/// short the turn. A turn that had already ended counts, unless it ended at or before `--after`
/// (the `since_ms` of the done an earlier watch printed), so a watch right after mailing new work
/// is not answered with the turn before it. Exit 3 at `--timeout` (1800 s).
fn watch_agent(p: &Parsed, root: PathBuf, handle: &str) -> i32 {
    let number = |flag: &str| p.value(flag).map(|v| v.parse::<u64>());
    let timeout = match number("--timeout") {
        None => 1800,
        Some(Ok(secs)) => secs,
        Some(Err(_)) => return refuse("--timeout needs a number of seconds"),
    };
    let after = match number("--after") {
        None => None,
        Some(Ok(ms)) => Some(ms),
        Some(Err(_)) => return refuse("--after needs epoch ms: an earlier done's since_ms"),
    };
    let deadline = Instant::now() + Duration::from_secs(timeout);
    // Subscribed before the first look, so no change falls between the two.
    let mut feed = match Feed::open(root.clone()) {
        Ok(feed) => feed,
        Err(code) => return code,
    };
    let cli = Cli {
        verb: "sessions".into(),
        args: Value::Null,
        root,
        asked: false,
    };
    // Whether this watch has seen the agent at work: only then is idle without a done a turn that
    // ended without finishing, rather than a session that has not started one.
    let mut worked = false;
    // A closed session leaves the list: one this watch saw and cannot find again has ended.
    let mut last: Option<SessionEntry> = None;
    loop {
        let live = match live_sessions(&cli) {
            Ok(live) => live,
            Err(code) => return code,
        };
        let (entry, outcome) = match (session_of(&live.sessions, handle), last.take()) {
            (Some(entry), _) => {
                worked |= entry.report.as_ref().is_some_and(|r| working(&r.activity));
                (entry.clone(), watched(entry, after, worked))
            }
            (None, Some(gone)) => (gone, Some(Watched::Ended)),
            (None, None) => {
                return refuse(&format!(
                    "no bench session has the handle {handle:?} — `bench sessions` lists them"
                ));
            }
        };
        let outcome = match outcome {
            Some(outcome) => outcome,
            None => match feed.next_about(&entry, deadline) {
                Ok(Some(busy)) => {
                    worked |= busy;
                    last = Some(entry);
                    continue;
                }
                Ok(None) => Watched::Timeout,
                Err(code) => return code,
            },
        };
        println!(
            "{}",
            json!({ "handle": handle, "outcome": outcome.word(), "session": entry })
        );
        return match outcome {
            Watched::Timeout => Status::Refused.exit_code(),
            Watched::Waiting | Watched::Done | Watched::Idle | Watched::Ended => 0,
        };
    }
}

fn live_sessions(cli: &Cli) -> Result<LiveSessions, i32> {
    let response = exchange(cli)?;
    if response.status != Status::Ok {
        return Err(print_response(&response));
    }
    serde_json::from_value(response.data.unwrap_or_default()).map_err(|e| {
        fail(&format!(
            "sessions answered a shape this bench cannot read: {e}"
        ))
    })
}

fn working(activity: &Activity) -> bool {
    !matches!(activity, Activity::Idle | Activity::Unknown)
}

/// benchd's events as they happen (`events --follow`), for `watch <handle>`.
struct Feed {
    lines: BufReader<UnixStream>,
}

impl Feed {
    fn open(root: PathBuf) -> Result<Feed, i32> {
        let cli = Cli {
            verb: "events".into(),
            args: json!({ "follow": true }),
            root,
            asked: false,
        };
        let (stream, request) = crate::open(&cli)?;
        if (&stream).write_all(request.as_bytes()).is_err() {
            return Err(EXIT_NO_DAEMON);
        }
        let reply = crate::read_response_line(&stream).ok_or(EXIT_NO_DAEMON)?;
        let response: Response = serde_json::from_str(&reply)
            .map_err(|e| fail(&format!("unreadable response ({e}): {}", reply.trim())))?;
        if response.status != Status::Ok {
            return Err(print_response(&response));
        }
        Ok(Feed {
            lines: BufReader::new(stream),
        })
    }

    /// Block until an event about the agent in `entry`'s session (its handle or its session id),
    /// and say whether it was at work; `None` at the deadline.
    fn next_about(&mut self, entry: &SessionEntry, deadline: Instant) -> Result<Option<bool>, i32> {
        let mut line = String::new();
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Ok(None);
            }
            let _ = self.lines.get_ref().set_read_timeout(Some(left));
            line.clear();
            match self.lines.read_line(&mut line) {
                Ok(0) => return Err(fail("benchd ended the event stream")),
                Ok(_) => {}
                Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {
                    return Ok(None);
                }
                Err(e) => return Err(fail(&format!("the event stream broke: {e}"))),
            }
            let frame: Value = serde_json::from_str(&line).unwrap_or_default();
            let data = &frame["event"]["data"];
            if data["handle"] == entry.handle.as_str() || data["session"] == entry.session.as_str()
            {
                let busy = serde_json::from_value::<Activity>(data["activity"].clone())
                    .is_ok_and(|a| working(&a));
                return Ok(Some(busy));
            }
        }
    }
}

/// The session a handle names: the live one, else the latest to have run under it.
fn session_of<'a>(sessions: &'a [SessionEntry], handle: &str) -> Option<&'a SessionEntry> {
    sessions
        .iter()
        .filter(|s| s.handle == handle)
        .min_by_key(|s| (!s.live, s.uptime_secs))
}

/// Why `watch <handle>` stopped: its `outcome`, the word a caller reads.
#[derive(Clone, Copy)]
enum Watched {
    Waiting,
    Done,
    /// Idle with no finished turn since the watch began: a turn that failed (`StopFailure`, a
    /// codex turn refused by its usage limit), was interrupted, or went quiet without a `Stop`.
    Idle,
    Ended,
    Timeout,
}

impl Watched {
    fn word(self) -> &'static str {
        match self {
            Watched::Waiting => "waiting",
            Watched::Done => "done",
            Watched::Idle => "idle",
            Watched::Ended => "ended",
            Watched::Timeout => "timeout",
        }
    }
}

/// What `watch <handle>` stops for, when anything: a done after `after`, else an agent idle
/// without one after the watch saw it `worked`. A session that has only started (`SessionStart`)
/// is idle with no turn, and is not an answer; a turn that starts and fails between two asks is
/// missed, and the timeout answers for it.
fn watched(s: &SessionEntry, after: Option<u64>, worked: bool) -> Option<Watched> {
    if !s.live {
        return Some(Watched::Ended);
    }
    if s.waiting.is_some() {
        return Some(Watched::Waiting);
    }
    if s.done
        .as_ref()
        .is_some_and(|d| after.is_none_or(|after| d.since_ms > after))
    {
        return Some(Watched::Done);
    }
    let idle = s
        .report
        .as_ref()
        .is_some_and(|r| r.activity == Activity::Idle);
    (worked && idle).then_some(Watched::Idle)
}

/// `get screenshot`: helm draws its window and sends the PNG back; benchd writes it at `--out`
/// (resolved against this directory) or under its own `captures/`, on benchd's machine, and hands
/// back helm's report with the path.
fn screenshot(p: &Parsed) -> Result<(String, Value), String> {
    let out = p
        .value("--out")
        .map(|out| std::env::current_dir().unwrap_or_default().join(out));
    if let Some(path) = &out
        && path.extension().and_then(|e| e.to_str()) != Some("png")
    {
        return Err(format!("--out names a .png, not {}", path.display()));
    }
    let ask = HelmAskArgs {
        ask: HelmAsk::Capture {
            window: p.value("--window"),
        },
        out: out.map(|path| path.display().to_string()),
    };
    Ok(("helm/ask".into(), json!(ask)))
}

/// `get pane <id>`: the pane as the document holds it, where it is, and whether the operator
/// can see it or is typing in it. Read from `bench/get`, so it covers hidden and parked panes.
fn get_pane(p: &Parsed, root: PathBuf) -> i32 {
    let pane = match p.words.get(2).map(|w| PaneId::parse(w)) {
        Some(Ok(id)) => id,
        Some(Err(why)) => return refuse(&why),
        None => return refuse("get pane needs a pane id — `bench get` lists them"),
    };
    let cli = Cli {
        verb: "bench/get".into(),
        args: Value::Null,
        root,
        asked: false,
    };
    let response = match exchange(&cli) {
        Ok(r) => r,
        Err(code) => return code,
    };
    if response.status != Status::Ok {
        return print_response(&response);
    }
    let at: DocumentAt = match response.data.map(serde_json::from_value) {
        Some(Ok(at)) => at,
        _ => return crate::fail("bench/get answered something that is not a document"),
    };
    match describe(&at.document, pane) {
        Some(found) => {
            println!(
                "{}",
                serde_json::to_string_pretty(&found).unwrap_or_default()
            );
            0
        }
        None => refuse(&format!("no pane {pane} on the bench")),
    }
}

/// Where a pane is and what the operator sees of it.
fn describe(doc: &Document, id: PaneId) -> Option<Value> {
    let pane = doc.pane(id)?;
    let focused = doc.focused_pane() == Some(id);
    if let Some(drawer) = doc.drawer_of(id) {
        let open = doc.open_drawer().is_some_and(|d| d.name == drawer.name);
        return Some(json!({
            "pane": pane,
            "drawer": drawer.name,
            "visible": open && drawer.selected == id,
            "focused": focused,
        }));
    }
    let workspace = doc.workspace_of(id)?;
    let active = doc.active() == Some(&workspace.path);
    Some(json!({
        "pane": pane,
        "workspace": workspace.path,
        "slot": workspace.bench.slot_for(id).map(|s| s.id),
        "active_workspace": active,
        "visible": active && doc.open_drawer().is_none() && workspace.bench.visible_pane_ids().contains(&id),
        "focused": focused,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn raw(line: &str) -> Vec<String> {
        line.split_whitespace().map(str::to_string).collect()
    }

    #[test]
    fn close_is_a_pane_verb_for_a_uuid_and_the_session_verb_otherwise() {
        assert!(owns(&raw(
            "close 5d0f1c52-6c64-4f33-9f22-7d4f0c2d1a90 --force"
        )));
        assert!(!owns(&raw("close s3")));
        assert!(owns(&raw(
            "--suite t get pane 5d0f1c52-6c64-4f33-9f22-7d4f0c2d1a90"
        )));
        assert!(!owns(&raw("get")));
        assert!(owns(&raw("--suite t open plan.md")));
        assert!(!owns(&raw("mail send --to x --body open")));
    }

    #[test]
    fn a_name_is_chosen_and_the_words_after_the_pane_are_its_text() {
        let p = parse(&raw(
            "name 5d0f1c52-6c64-4f33-9f22-7d4f0c2d1a90 review of m3 --rename",
        ))
        .unwrap();
        let (verb, args) = layout("name", &p).unwrap();
        assert_eq!(verb, "pane/name");
        assert_eq!(
            args["name"],
            json!({"source": "chosen", "text": "review of m3"})
        );
        assert_eq!(args["rename"], json!(true));
    }

    /// The Swift side of `RENDERABLE`: every string literal in `RenderableFile.swift`'s
    /// extension lists, read from its source so a change there fails here.
    #[test]
    fn the_renderable_extensions_are_helms() {
        let swift = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../../Sources/Helm/Shared/RenderableFile.swift"),
        )
        .expect("helm's RenderableFile.swift is readable from the bench crate");
        let mut helms: Vec<String> = swift
            .lines()
            .filter(|l| l.contains(".contains(url.pathExtension"))
            .flat_map(|l| {
                let list = &l[l.find('[').unwrap() + 1..l.find(']').unwrap()];
                list.split(',')
                    .map(|e| e.trim().trim_matches('"').to_string())
                    .collect::<Vec<_>>()
            })
            .collect();
        helms.sort();
        let mut ours: Vec<String> = bench_wire::RENDERABLE
            .iter()
            .map(|e| e.to_string())
            .collect();
        ours.sort();
        assert_eq!(ours, helms);
    }
}
