//! The verbs an agent drives the bench with (M3): open, split, show, focus, move, name and
//! close a pane, spawn an agent into one, and read a pane or helm's window.
//!
//! Every one of them is the socket's own verb with its arguments built from the wire's types
//! (`LayoutVerb`, `SpawnArgs`, `HelmAsk`), so the CLI cannot spell what benchd does not read.
//! They carry who asked (the agent: `HELM_PANE`, `BENCH_HANDLE`) and `asked` only from
//! `--asked`. That flag is the whole of the focus rule on this side: without it a verb lands in
//! the background and benchd refuses one that would move the operator's focus; with it, it may
//! bring something forward. Pass it only when the operator asked (bench-architecture.md).

use crate::{Cli, exchange, print_response, record_root, refuse};
use bench_doc::{Direction, Document, DrawerName, PaneId, PaneName, Split, Surface};
use bench_wire::{DocumentAt, HelmAsk, LayoutVerb, OpenInto, PaneOpen, SpawnArgs, Status};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

/// The verbs this module answers, by their first word. `close` and `get` are shared with the
/// session and document verbs; [`owns`] decides by the word after them.
const VERBS: &[&str] = &["open", "split", "show", "focus", "move", "name", "spawn"];

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
    "--arg",
    "--out",
    "--window",
];

/// Whether `raw` (the arguments after `bench`) is one of these verbs. `close <pane uuid>` is,
/// `close <session>` is the session verb; `get pane|screenshot` is, bare `get` is the document.
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
            Some("pane" | "screenshot")
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
    };
    let mut it = raw.iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--asked" => parsed.asked = true,
            "--force" => parsed.force = true,
            "--rename" => parsed.rename = true,
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
        "get" => screenshot(&parsed, &root),
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
            to: bench_wire::MoveTo::Step(direction(p.words.get(2))?),
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
        other => return Err(format!("{other} is not a pane verb")),
    };
    let encoded = serde_json::to_value(&typed).map_err(|e| e.to_string())?;
    Ok((
        encoded["verb"].as_str().unwrap_or_default().to_string(),
        encoded["args"].clone(),
    ))
}

/// `open <file|browser|terminal>`. A file is what an agent puts in front of the operator, so it
/// must be one helm renders, and it must exist — the checks `push.sh` made.
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

/// The extensions helm renders as a canvas (helm `RenderableFile.isRenderable`).
const RENDERABLE: &[&str] = &["md", "markdown", "mdown", "html", "htm"];

fn renderable_file(raw: &str) -> Result<Surface, String> {
    let path = std::env::current_dir()
        .unwrap_or_default()
        .join(raw)
        .components()
        .collect::<PathBuf>();
    if !path.is_file() {
        return Err(format!("no file at {}", path.display()));
    }
    let renderable = path
        .extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| RENDERABLE.contains(&e.to_ascii_lowercase().as_str()));
    if !renderable {
        return Err(format!(
            "{} is not a file helm renders — a canvas is one of: {}",
            path.display(),
            RENDERABLE.join(", ")
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
        model: p.value("--model"),
        effort: p.value("--effort"),
        rows: number("--rows")?,
        cols: number("--cols")?,
        resume: p.value("--resume"),
        args: p.all("--arg"),
    };
    Ok(("spawn".into(), json!(args)))
}

/// `get screenshot`: helm draws its window. benchd asks helm and hands back its report.
fn screenshot(p: &Parsed, root: &Path) -> Result<(String, Value), String> {
    let path = match p.value("--out") {
        Some(out) => std::env::current_dir().unwrap_or_default().join(out),
        None => {
            let dir = root.join("captures");
            std::fs::create_dir_all(&dir)
                .map_err(|e| format!("cannot make {}: {e}", dir.display()))?;
            let stamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_millis())
                .unwrap_or(0);
            dir.join(format!("capture-{stamp}.png"))
        }
    };
    if path.extension().and_then(|e| e.to_str()) != Some("png") {
        return Err(format!("--out names a .png, not {}", path.display()));
    }
    if !path.parent().is_some_and(Path::is_dir) {
        return Err(format!("no directory to write {} into", path.display()));
    }
    let ask = HelmAsk::Capture {
        path: path.display().to_string(),
        window: p.value("--window"),
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
}
