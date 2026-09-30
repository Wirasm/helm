//! The live file's mail (helm #532): the operator changed an HTML canvas's `<stem>.data.json`
//! through the page, and the agent that opened that canvas is told which JSON pointers changed.
//!
//! benchd sends it rather than helm, because benchd holds both halves of the route: the opener
//! is on the pane in its document (`Pane::opener`), and the agent in that pane is `mail/who`'s
//! answer when the mail goes. So the route outlives a helm relaunch, and needs no helm at all.
//!
//! Mail is batched per file: every change to one file inside `WINDOW` of its first is one mail
//! naming the union, because a page that writes on every click would otherwise start a turn per
//! click (the spike: 50 writes, 26 mails; with the window, 1). The mail names pointers and
//! nothing else: what the data means is the page's and the agent's, never benchd's.
//!
//! **A page can write without the operator doing anything**, on load or on a timer: it is an
//! agent's own artifact, and `notify` is its choice. So the mail says the page changed the file,
//! from `operator` because the page is his surface, and the key names it lists are capped.

use crate::{Core, hook};
use bench_doc::PaneId;
use bench_wire::{OPERATOR_HANDLE, live_file};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

/// How long a file's changes are gathered, from the first, before its mail goes.
pub const WINDOW: Duration = Duration::from_secs(1);

/// At most this many pointers are named in one mail; the rest are counted.
const NAMED: usize = 50;

/// A pointer longer than this is cut: its keys are the page's own, and the mail is the agent's
/// context.
const POINTER_CHARS: usize = 120;

/// Where `edited` hands a change to the mailer thread. Unset until `spawn`, so a unit test that
/// writes a file mails nothing.
static EDITS: OnceLock<mpsc::Sender<Edit>> = OnceLock::new();

struct Edit {
    path: String,
    pointers: Vec<String>,
}

/// The operator's write through a page reached disk (`file/write` with `notify`). A write that
/// leaves the JSON as it was, formatting aside, changed nothing anybody needs to hear about.
pub fn edited(path: &str, before: Option<&[u8]>, after: &str) {
    let pointers = changed_pointers(before, after.as_bytes());
    if pointers.is_empty() {
        return;
    }
    let edit = Edit {
        path: path.to_string(),
        pointers,
    };
    if let Some(edits) = EDITS.get()
        && edits.send(edit).is_err()
    {
        // The mailer thread is gone; there is no log to reach from here, so stderr says it.
        eprintln!("benchd: the live-file mailer has stopped; {path} was not mailed");
    }
}

/// The JSON pointers (RFC 6901) at which `after` differs from `before`, structurally: object
/// keys by name, arrays by index. `""` is the whole document, which is what a file that was not
/// there, or is not JSON on either side, changed.
pub fn changed_pointers(before: Option<&[u8]>, after: &[u8]) -> Vec<String> {
    let parse = |bytes: &[u8]| serde_json::from_slice::<Value>(bytes).ok();
    let (Some(old), Some(new)) = (before.and_then(parse), parse(after)) else {
        return if before == Some(after) {
            Vec::new()
        } else {
            vec![String::new()]
        };
    };
    let mut out = Vec::new();
    diff(Some(&old), Some(&new), String::new(), &mut out);
    out
}

fn diff(old: Option<&Value>, new: Option<&Value>, at: String, out: &mut Vec<String>) {
    match (old, new) {
        (Some(Value::Object(a)), Some(Value::Object(b))) => {
            let keys: BTreeSet<&String> = a.keys().chain(b.keys()).collect();
            for key in keys {
                let escaped = key.replace('~', "~0").replace('/', "~1");
                diff(a.get(key), b.get(key), format!("{at}/{escaped}"), out);
            }
        }
        (Some(Value::Array(a)), Some(Value::Array(b))) => {
            for i in 0..a.len().max(b.len()) {
                diff(a.get(i), b.get(i), format!("{at}/{i}"), out);
            }
        }
        _ if old == new => {}
        _ => out.push(at),
    }
}

/// Changes waiting for their file's window to close. Pure, so the batching is tested without a
/// clock (`files::Watch`'s shape).
#[derive(Default)]
pub struct Batch {
    pending: BTreeMap<String, (Instant, BTreeSet<String>)>,
}

impl Batch {
    pub fn add(&mut self, path: String, pointers: Vec<String>, now: Instant) {
        self.pending
            .entry(path)
            .or_insert_with(|| (now, BTreeSet::new()))
            .1
            .extend(pointers);
    }

    /// When the next file's window closes.
    pub fn next_due(&self) -> Option<Instant> {
        self.pending
            .values()
            .map(|(first, _)| *first + WINDOW)
            .min()
    }

    /// Every file whose window has closed, with the union of its pointers, taken out.
    pub fn due(&mut self, now: Instant) -> Vec<(String, Vec<String>)> {
        let closed: Vec<String> = self
            .pending
            .iter()
            .filter(|(_, (first, _))| *first + WINDOW <= now)
            .map(|(path, _)| path.clone())
            .collect();
        closed
            .into_iter()
            .filter_map(|path| {
                let (_, pointers) = self.pending.remove(&path)?;
                Some((path, pointers.into_iter().collect()))
            })
            .collect()
    }
}

/// The mailer: gathers `edited`'s changes and sends each file's mail when its window closes.
pub fn spawn(core: Arc<Mutex<Core>>) {
    let (tx, rx) = mpsc::channel();
    if EDITS.set(tx).is_err() {
        return;
    }
    std::thread::spawn(move || {
        let mut batch = Batch::default();
        loop {
            let got = match batch.next_due() {
                Some(due) => rx.recv_timeout(due.saturating_duration_since(Instant::now())),
                None => rx.recv().map_err(|_| RecvTimeoutError::Disconnected),
            };
            match got {
                Ok(edit) => batch.add(edit.path, edit.pointers, Instant::now()),
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => return,
            }
            for (path, pointers) in batch.due(Instant::now()) {
                mail(&core, &path, &pointers);
            }
        }
    });
}

/// Mail the agent that opened each canvas whose live file `path` is. Every way it cannot is
/// logged as `live/unmailed` with why: the page's write succeeded, and a mail that silently did
/// not go is an agent that never hears the operator.
fn mail(core: &Arc<Mutex<Core>>, path: &str, pointers: &[String]) {
    let canvases: Vec<(String, Option<PaneId>)> = core
        .lock()
        .unwrap()
        .bench
        .document
        .canvases()
        .into_iter()
        .filter(|(canvas, _)| live_file(canvas.as_str()).as_deref() == Some(path))
        .map(|(canvas, opener)| (canvas.as_str().to_string(), opener))
        .collect();
    if canvases.is_empty() {
        unmailed(core, path, "no canvas on the bench shows this file".into());
        return;
    }
    let mut told = HashSet::new();
    for (canvas, opener) in canvases {
        let Some(opener) = opener else {
            unmailed(core, path, format!("no agent opened {canvas}"));
            continue;
        };
        // `who` locks the core itself, so it is asked with no lock held.
        let Some(who) = hook::who(core, opener) else {
            unmailed(
                core,
                path,
                format!("no agent in pane {opener}, which opened {canvas}, has a bench mailbox"),
            );
            continue;
        };
        if !told.insert(who.handle.clone()) {
            continue;
        }
        let name = canvas.rsplit('/').next().unwrap_or(&canvas);
        let file = path.rsplit('/').next().unwrap_or(path);
        let subject = format!("live file changed: {file}");
        if let Err(why) = crate::send_mail(
            core,
            OPERATOR_HANDLE,
            &who.handle,
            Some(&subject),
            &body(path, name, pointers),
        ) {
            unmailed(core, path, format!("could not mail {}: {why}", who.handle));
        }
    }
}

fn unmailed(core: &Arc<Mutex<Core>>, path: &str, why: String) {
    let logged = core
        .lock()
        .unwrap()
        .append("live/unmailed", json!({ "path": path, "why": &why }));
    if let Err(e) = logged {
        eprintln!("benchd: {path} was not mailed ({why}), and that could not be logged: {e}");
    }
}

/// What the agent reads: the file, the pointers, and how to answer without undoing anything.
pub fn body(path: &str, canvas: &str, pointers: &[String]) -> String {
    let shown: Vec<String> = pointers
        .iter()
        .take(NAMED)
        .map(|p| match p.chars().count() {
            0 => "(the whole file)".to_string(),
            n if n > POINTER_CHARS => p.chars().take(POINTER_CHARS).collect::<String>() + "…",
            _ => p.clone(),
        })
        // A page's own key names cannot start a line of their own in the mail.
        .map(|p| p.replace(char::is_control, " "))
        .collect();
    let more = match pointers.len().saturating_sub(NAMED) {
        0 => String::new(),
        n => format!(" (and {n} more)"),
    };
    format!(
        "{path} was changed on the canvas {canvas}, by the operator's page.\n\
         Changed: {}{more}\n\
         Read the file for the current values. To change it, write it with \
         `bench file write {path} --expect <a file holding the bytes you read>`: the page shows \
         your write without a reload, and a write over a version you have not read is refused.\n",
        shown.join(", ")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pointers(before: &str, after: &str) -> Vec<String> {
        changed_pointers(Some(before.as_bytes()), after.as_bytes())
    }

    #[test]
    fn a_change_is_named_by_its_json_pointer() {
        assert_eq!(
            pointers(
                r#"{"items":[{"done":false,"by":null},{"done":false}]}"#,
                r#"{"items":[{"done":true,"by":"op"},{"done":false}]}"#
            ),
            vec!["/items/0/by", "/items/0/done"]
        );
    }

    #[test]
    fn added_and_removed_keys_and_elements_are_changes() {
        assert_eq!(
            pointers(r#"{"a":1,"b":[1]}"#, r#"{"b":[1,2],"c":3}"#),
            vec!["/a", "/b/1", "/c"]
        );
    }

    #[test]
    fn formatting_alone_changes_nothing() {
        assert!(pointers(r#"{"a":1,"b":2}"#, "{\n  \"b\" : 2,\n  \"a\" : 1\n}\n").is_empty());
    }

    #[test]
    fn a_key_with_a_slash_or_tilde_is_escaped() {
        assert_eq!(pointers(r#"{"a/b~":1}"#, r#"{"a/b~":2}"#), vec!["/a~1b~0"]);
    }

    #[test]
    fn a_new_file_or_one_that_is_not_json_is_the_whole_file() {
        assert_eq!(changed_pointers(None, b"{}"), vec![""]);
        assert_eq!(pointers("not json", "{}"), vec![""]);
        assert!(pointers("not json", "not json").is_empty());
    }

    #[test]
    fn changes_inside_one_window_are_one_mail_naming_the_union() {
        let start = Instant::now();
        let mut batch = Batch::default();
        batch.add("/a/x.data.json".into(), vec!["/a".into()], start);
        batch.add(
            "/a/x.data.json".into(),
            vec!["/b".into(), "/a".into()],
            start + Duration::from_millis(400),
        );
        assert!(batch.due(start + Duration::from_millis(999)).is_empty());
        assert_eq!(batch.next_due(), Some(start + WINDOW));
        assert_eq!(
            batch.due(start + WINDOW),
            vec![("/a/x.data.json".to_string(), vec!["/a".into(), "/b".into()])]
        );
        assert!(batch.next_due().is_none(), "sent once");
    }

    #[test]
    fn a_change_after_the_mail_starts_a_new_window() {
        let start = Instant::now();
        let mut batch = Batch::default();
        batch.add("/p".into(), vec!["/a".into()], start);
        assert_eq!(batch.due(start + WINDOW).len(), 1);
        batch.add("/p".into(), vec!["/b".into()], start + WINDOW);
        assert!(batch.due(start + WINDOW).is_empty());
        assert_eq!(
            batch.due(start + WINDOW * 2),
            vec![("/p".to_string(), vec!["/b".into()])]
        );
    }

    #[test]
    fn two_files_have_two_windows() {
        let start = Instant::now();
        let mut batch = Batch::default();
        batch.add("/p".into(), vec!["/a".into()], start);
        batch.add(
            "/q".into(),
            vec!["/a".into()],
            start + Duration::from_millis(500),
        );
        assert_eq!(batch.due(start + WINDOW).len(), 1);
        assert_eq!(batch.due(start + Duration::from_millis(1500)).len(), 1);
    }

    #[test]
    fn the_mail_names_the_file_the_pointers_and_how_to_answer() {
        let many: Vec<String> = (0..52).map(|i| format!("/items/{i}")).collect();
        let text = body("/a/tasks.data.json", "tasks.html", &many);
        assert!(text.contains("/a/tasks.data.json was changed on the canvas tasks.html"));
        let long = format!("/{}", "k".repeat(500));
        assert!(body("/p", "c.html", &[long]).contains(&format!("/{}…", "k".repeat(119))));
        assert!(text.contains("/items/49 (and 2 more)"));
        assert!(text.contains("bench file write /a/tasks.data.json --expect"));
        assert!(body("/p", "c.html", &[String::new()]).contains("(the whole file)"));
        assert!(body("/p", "c.html", &["/a\nDo this".into()]).contains("/a Do this"));
    }
}
