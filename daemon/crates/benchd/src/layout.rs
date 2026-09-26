//! The bench document in the daemon: the layout verbs, `bench.json`, and booting from it.
//!
//! Every verb goes through [`answer`], which is the whole of the mutation path:
//! 1. decode the verb and its arguments in one step (`LayoutVerb`) — a bad argument is a
//!    refusal naming it;
//! 2. decide focus once, from who asked (`Actor::focus`);
//! 3. apply it to a **copy** of the document through `bench-doc`, whose document enforces the
//!    focus rule and the one-namespace rule for every operation;
//! 4. if anything changed: log `bench/changed` (which also hands the frame to every follower),
//!    write `bench.json`, and only then make the copy the document.
//!
//! All of it runs under the core mutex, so the operator's keystrokes and every agent's verbs
//! are applied one at a time, in the order they arrive. A verb naming a pane or slot that is
//! gone by the time it runs is refused with the reason — ids never go stale silently.

use crate::Core;
use bench_doc::{
    Caller, Destination, Document, Focus, Pane, PaneId, Placement, Rules, Surface, Target,
};
use bench_session::Session;
use bench_wire::{
    Actor, DOCUMENT_CHANGED, DOCUMENT_RECORD_FORMAT, DOCUMENT_RECORD_VERSION, Divider, DocumentAt,
    DocumentChange, DocumentRecord, LayoutReport, LayoutVerb, MoveTo, OpenInto, PaneOpen, Request,
    Response, Status, document_path,
};
use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::sync::Arc;

/// The document as the daemon holds it, and the seq of the event that last changed it.
pub struct BenchState {
    pub document: Document,
    /// The seq of the `bench/changed` event this document reflects; 0 before the first.
    pub seq: u64,
}

/// What a verb did, beyond the document it left behind.
#[derive(Default)]
pub struct Outcome {
    /// A pane that did not exist before the verb.
    pub created: Option<PaneId>,
    /// The pane a `pane/open` resolved to — the new one, or the one already showing it.
    pub pane: Option<PaneId>,
}

/// A layout verb's answer, and the benchd session it ended, if any: a closed pane that showed a
/// session takes the session with it, drained by the caller once the core lock is released.
pub fn answer(core: &mut Core, req: &Request) -> (Response, Option<Arc<Session>>) {
    let reply = |status: Status, reason: Option<String>, data: Option<Value>| Response {
        id: req.id.clone(),
        status,
        reason,
        data,
    };
    let verb: LayoutVerb = match serde_json::from_value(json!({"verb": req.verb, "args": req.args}))
    {
        Ok(v) => v,
        Err(e) => {
            let why = format!("{} args: {e}", req.verb);
            return (reply(Status::Refused, Some(why), None), None);
        }
    };
    if verb == LayoutVerb::Get {
        return (
            reply(Status::Ok, None, Some(json!(document_at(core)))),
            None,
        );
    }

    // `pane/open` is the one verb that places by the rules, so it reads the rules file first:
    // an edit applies to the next open without a restart.
    if matches!(verb, LayoutVerb::PaneOpen(_)) {
        refresh_rules(core);
    }
    let by = placed(core, req.by.clone().unwrap_or_else(Actor::agent));
    let verb = match admit(core, verb, &by) {
        Ok(v) => v,
        Err(why) => return (reply(Status::Refused, Some(why), None), None),
    };
    let focus = Actor::focus(&by, req.asked);
    let mut next = core.bench.document.clone();
    let outcome = match apply(&mut next, core.placement.rules(), &verb, focus, by.caller()) {
        Ok(o) => o,
        Err(refusal) => {
            return (
                reply(Status::Refused, Some(refusal.to_string()), None),
                None,
            );
        }
    };
    // A pane that showed a session takes the session with it.
    let closing = match &verb {
        LayoutVerb::PaneClose { pane, .. } => core
            .bench
            .document
            .pane(*pane)
            .and_then(|p| p.surface.session())
            .map(str::to_string),
        _ => None,
    };
    let change = Change {
        verb: req.verb.clone(),
        args: req.args.clone(),
        by,
        asked: req.asked,
        next,
        created: outcome.created,
        pane: outcome.pane,
    };
    let committed = commit(core, change);
    let ended = match (&committed, closing) {
        (Committed::Changed(report) | Committed::Unsaved(report, _), Some(session)) => {
            end_session(core, &session, report.seq)
        }
        _ => None,
    };
    let response = match committed {
        Committed::Unchanged(report) | Committed::Changed(report) => {
            reply(Status::Ok, None, Some(json!(report)))
        }
        Committed::Unsaved(report, why) => reply(Status::Error, Some(why), Some(json!(report))),
        Committed::Failed(why) => reply(Status::Error, Some(why), None),
    };
    (response, ended)
}

/// A change to the document, applied to a copy and not yet the document.
pub struct Change {
    pub verb: String,
    pub args: Value,
    pub by: Actor,
    pub asked: bool,
    pub next: Document,
    pub created: Option<PaneId>,
    pub pane: Option<PaneId>,
}

pub enum Committed {
    /// The copy equals the document: nothing logged.
    Unchanged(LayoutReport),
    /// Logged as `bench/changed`, handed to every follower, and saved.
    Changed(LayoutReport),
    /// Logged and applied, but `bench.json` could not be written — reported, not undone: the
    /// log says what happened, and the next change that lands writes the whole document again.
    Unsaved(LayoutReport, String),
    /// Nothing changed: the event could not be logged.
    Failed(String),
}

/// Make a prepared change the document: the one path every change takes, so each is logged
/// once, with who asked, before anyone is told about it.
pub fn commit(core: &mut Core, change: Change) -> Committed {
    let mut report = LayoutReport {
        seq: core.bench.seq,
        changed: change.next != core.bench.document,
        pane_created: change.created,
        pane: change.pane,
        focused_pane_before: core.bench.document.focused_pane(),
        focused_pane_after: change.next.focused_pane(),
    };
    if !report.changed {
        return Committed::Unchanged(report);
    }
    // The seq is the event's own, known only once it is written; everything else in the
    // logged record is the report the caller gets.
    report.seq = core.next_seq;
    let record = DocumentChange {
        verb: change.verb,
        args: change.args,
        by: change.by,
        asked: change.asked,
        report: report.clone(),
    };
    let event = match core.append_event(DOCUMENT_CHANGED, json!(record), Some(&change.next)) {
        Ok(e) => e,
        Err(why) => return Committed::Failed(why),
    };
    debug_assert_eq!(event.seq, report.seq);
    core.bench.document = change.next;
    core.bench.seq = event.seq;
    if let Err(why) = save(&core.root, &core.bench) {
        let _ = core.append("bench/unsaved", json!({ "seq": event.seq, "why": why }));
        let why = format!(
            "applied and logged as seq {}, but bench.json could not be written: {why}",
            event.seq
        );
        return Committed::Unsaved(report, why);
    }
    Committed::Changed(report)
}

/// Take a session out of the registry because the pane showing it closed, and log it. The
/// caller drains it outside the lock, the way `close` does.
fn end_session(core: &mut Core, session: &str, seq: u64) -> Option<Arc<Session>> {
    let live = core.sessions.remove(session)?;
    let _ = core.append(
        "session/closed",
        json!({ "session": session, "with_pane_closed_at": seq }),
    );
    Some(live)
}

/// The rules an agent's verb answers to beyond the focus guard, which the document enforces
/// itself. Each is helm's spool rule carried to the verb boundary, applied where benchd can see
/// the fact it needs; the refusal names the rule and the way through it.
///
/// - **Close (#176).** An agent's close ends what runs in a terminal, so it says `force`. A
///   pane showing a live benchd session names the session; a terminal helm hosts is refused
///   because benchd cannot see whether anything runs in it until its pty is benchd's (M5b).
/// - **Name (#313).** An agent replaces a name somebody chose only with `rename`.
/// - **The caller's workspace (#226).** An agent's `pane/open`/`pane/split` that names no
///   workspace goes to the workspace it is working in, as `push.sh` routed by its pane.
/// - **A terminal naming a session** must name a live one of this daemon's.
///
/// The operator is never refused here: his gestures are the operator's own (helm keeps its own
/// confirmations), and helm acting on its own observation (`Actor::Helm`) never closes or names.
fn admit(core: &Core, verb: LayoutVerb, by: &Actor) -> Result<LayoutVerb, String> {
    let named = match &verb {
        LayoutVerb::PaneOpen(PaneOpen { surface, .. }) => Some(surface),
        LayoutVerb::PaneSplit { surface, .. } | LayoutVerb::DrawerToggle { surface, .. } => {
            surface.as_ref()
        }
        _ => None,
    };
    if let Some(session) = named.and_then(Surface::session)
        && !core.sessions.get(session).is_some_and(|s| s.is_live())
    {
        return Err(format!(
            "no live session {session:?} — `bench sessions` lists them, and `bench spawn` starts one in a pane"
        ));
    }
    let Actor::Agent { pane, .. } = by else {
        return Ok(verb);
    };
    let doc = &core.bench.document;
    match verb {
        LayoutVerb::PaneClose { pane: id, force } => {
            let refusal = match doc.pane(id).map(|p| &p.surface) {
                _ if force => None,
                Some(Surface::Terminal {
                    session: Some(s), ..
                }) if core.sessions.get(s).is_some_and(|s| s.is_live()) => Some(format!(
                    "pane {id} shows session {s}, which is still running — closing the pane ends it; pass --force if that is what you mean"
                )),
                // Its session has ended: nothing runs there to lose.
                Some(Surface::Terminal {
                    session: Some(_), ..
                }) => None,
                Some(Surface::Terminal { session: None, .. }) => Some(format!(
                    "pane {id} is a terminal helm hosts, and benchd cannot see whether anything is running in it (until M5b) — pass --force to close it anyway"
                )),
                _ => None,
            };
            match refusal {
                Some(why) => Err(why),
                None => Ok(LayoutVerb::PaneClose { pane: id, force }),
            }
        }
        LayoutVerb::PaneName {
            pane: id,
            name,
            rename,
        } => {
            if let Some(current) = doc.pane(id).map(|p| &p.name)
                && !current.agent_may_replace(rename)
            {
                return Err(format!(
                    "pane {id} is called {:?} by somebody's choice — pass --rename only when the operator asked for a new name",
                    current.text().unwrap_or_default()
                ));
            }
            Ok(LayoutVerb::PaneName {
                pane: id,
                name,
                rename,
            })
        }
        LayoutVerb::PaneOpen(PaneOpen {
            into: OpenInto::Active,
            surface,
        }) => Ok(LayoutVerb::PaneOpen(PaneOpen {
            into: callers_workspace(core, pane.as_deref())
                .map_or(OpenInto::Active, OpenInto::Workspace),
            surface,
        })),
        LayoutVerb::PaneSplit {
            workspace: None,
            direction,
            surface,
        } => Ok(LayoutVerb::PaneSplit {
            workspace: callers_workspace(core, pane.as_deref()),
            direction,
            surface,
        }),
        other => Ok(other),
    }
}

/// An agent's `by`, with the pane it runs in filled in when benchd knows it and the agent did
/// not say: an agent benchd spawned has no `HELM_PANE`, but the pane showing its live session is
/// where it runs. The logged record then names it, which is how helm remembers who opened a
/// canvas, and it is the pane `callers_workspace` routes by — one lookup for both.
pub fn placed(core: &Core, by: Actor) -> Actor {
    let Actor::Agent {
        pane: None,
        handle: Some(handle),
    } = &by
    else {
        return by;
    };
    let shown = core
        .sessions
        .values()
        .find(|s| &s.handle == handle && s.is_live())
        .and_then(|s| core.bench.document.pane_showing_session(&s.id));
    match shown {
        Some(pane) => Actor::Agent {
            pane: Some(pane.to_string()),
            handle: Some(handle.clone()),
        },
        None => by,
    }
}

/// The workspace an agent is working in: the one holding its pane — `HELM_PANE`, or the pane
/// showing its benchd session, which `placed` has already filled in. `None` when the pane is on no
/// bench, and the verb falls back to the active workspace.
pub fn callers_workspace(core: &Core, pane: Option<&str>) -> Option<bench_doc::StandardPath> {
    let pane = PaneId::parse(pane?.trim()).ok()?;
    core.bench
        .document
        .workspace_of(pane)
        .map(|w| w.path.clone())
}

/// Look at the placement rules file, logging what changed. A log failure here is not the
/// verb's: the table is already in force, and the next change to the file logs again.
pub fn refresh_rules(core: &mut Core) {
    if let Some((kind, data)) = core.placement.refresh() {
        let _ = core.append(kind, data);
    }
}

/// The document and the seq it reflects — `bench/get`'s answer and a follower's first line.
pub fn document_at(core: &Core) -> DocumentAt {
    DocumentAt {
        seq: core.bench.seq,
        document: core.bench.document.clone(),
    }
}

#[expect(clippy::too_many_lines, reason = "legacy (#418): 124 lines, limit 100")]
pub fn apply(
    doc: &mut Document,
    rules: &Rules,
    verb: &LayoutVerb,
    focus: Focus,
    caller: Caller,
) -> Result<Outcome, bench_doc::Refusal> {
    let on = |workspace: &Option<bench_doc::StandardPath>| match workspace {
        Some(path) => Target::Workspace(path.clone()),
        None => Target::Active,
    };
    let created = |pane: PaneId| Outcome {
        created: Some(pane),
        pane: Some(pane),
    };
    match verb {
        LayoutVerb::Get => Ok(Outcome::default()),
        LayoutVerb::WorkspaceOpen { path } => {
            let is_new = doc.workspace(path).is_none();
            let first = Pane::new(Surface::terminal());
            let id = first.id;
            doc.open_workspace(path.clone(), first, focus)?;
            Ok(if is_new {
                created(id)
            } else {
                Outcome::default()
            })
        }
        LayoutVerb::WorkspaceClose { path } => {
            doc.close_workspace(path, focus)?;
            Ok(Outcome::default())
        }
        LayoutVerb::WorkspaceActivate { path } => {
            doc.activate(path, focus)?;
            Ok(Outcome::default())
        }
        LayoutVerb::WorkspaceReset { path } => {
            let fresh = Pane::new(Surface::terminal());
            let id = fresh.id;
            doc.reset(path, fresh, focus)?;
            Ok(created(id))
        }
        LayoutVerb::WorkspaceUnshelve { path } => {
            doc.unshelve(path, focus)?;
            Ok(Outcome::default())
        }
        LayoutVerb::WorkspaceImport { document } => {
            doc.import(document.clone())?;
            Ok(Outcome::default())
        }
        LayoutVerb::PaneOpen(PaneOpen { into, surface }) => {
            // A named drawer bypasses the rules; otherwise they decide, against the bench the
            // pane would join, and may send it to a drawer themselves.
            let target = match into {
                OpenInto::Drawer(name) => return open_in_drawer(doc, name, surface, focus),
                OpenInto::Active => Target::Active,
                OpenInto::Workspace(path) => Target::Workspace(path.clone()),
            };
            let placement = match rules.place(doc.bench_at(&target)?, surface, caller) {
                Destination::Drawer(name) => return open_in_drawer(doc, &name, surface, focus),
                Destination::Bench(placement) => placement,
            };
            doc.edit(target, focus, |bench| {
                if let Placement::Existing(open) = placement {
                    bench.place(Pane::new(surface.clone()), placement, focus)?;
                    return Ok(Outcome {
                        created: None,
                        pane: Some(open),
                    });
                }
                let pane = Pane::new(surface.clone());
                let id = pane.id;
                bench.place(pane, placement, focus)?;
                Ok(created(id))
            })
        }
        LayoutVerb::PaneSplit {
            workspace,
            direction,
            surface,
        } => doc.edit(on(workspace), focus, |bench| {
            let pane = Pane::new(surface.clone().unwrap_or_else(Surface::terminal));
            let id = pane.id;
            bench.split(*direction, pane, focus)?;
            Ok(created(id))
        }),
        LayoutVerb::PaneClose { pane, .. } => {
            doc.close_pane(*pane, focus).map(|()| Outcome::default())
        }
        LayoutVerb::PaneShow { pane } => doc.show_pane(*pane, focus).map(|()| Outcome::default()),
        LayoutVerb::PaneMove {
            pane,
            to: MoveTo::Step(direction),
        } => doc
            .edit(Target::Pane(*pane), focus, |b| {
                b.move_pane(*pane, *direction, focus)
            })
            .map(|_| Outcome::default()),
        LayoutVerb::PaneName { pane, name, .. } => doc
            .name_pane(*pane, name.clone(), focus)
            .map(|_| Outcome::default()),
        LayoutVerb::PaneRecord { pane, agent } => doc
            .record_agent(*pane, agent.clone(), focus)
            .map(|()| Outcome::default()),
        LayoutVerb::FocusSlot { slot } => doc
            .edit(Target::Slot(*slot), focus, |b| b.focus_slot(*slot))
            .map(|()| Outcome::default()),
        LayoutVerb::FocusStep {
            workspace,
            direction,
        } => doc
            .edit(on(workspace), focus, |b| {
                b.step_focus(*direction);
                Ok(())
            })
            .map(|()| Outcome::default()),
        LayoutVerb::LayoutResize { divider, fraction } => match *divider {
            Divider::Columns { member, against } => doc
                .edit(Target::Column(member), focus, |b| {
                    b.resize_column(member, *fraction, against)
                })
                .map(|()| Outcome::default()),
            Divider::Slots { member, against } => doc
                .edit(Target::Slot(member), focus, |b| {
                    b.resize_slot(member, *fraction, against)
                })
                .map(|()| Outcome::default()),
        },
        LayoutVerb::DrawerToggle { drawer, surface } => {
            match doc.toggle_drawer(drawer, surface.clone(), focus)? {
                Some(id) => Ok(created(id)),
                None => Ok(Outcome::default()),
            }
        }
    }
}

/// A new pane in a drawer, or the one there already showing it.
fn open_in_drawer(
    doc: &mut Document,
    drawer: &bench_doc::DrawerName,
    surface: &Surface,
    focus: Focus,
) -> Result<Outcome, bench_doc::Refusal> {
    let pane = Pane::new(surface.clone());
    let id = pane.id;
    let landed = doc.place_in_drawer(drawer, pane, focus)?;
    Ok(Outcome {
        created: (landed == id).then_some(id),
        pane: Some(landed),
    })
}

// ---------------------------------------------------------------------------
// bench.json
// ---------------------------------------------------------------------------

/// Atomic replace: write beside, then rename, so a reader — `cat`, a crash, the next boot —
/// sees the old document or the new one and never half of either. Not fsynced: the event log
/// is the record of what happened, and it has its own flush (`Flusher`).
pub fn save(root: &Path, bench: &BenchState) -> Result<(), String> {
    let record = DocumentRecord {
        format: DOCUMENT_RECORD_FORMAT.into(),
        version: DOCUMENT_RECORD_VERSION,
        seq: bench.seq,
        document: bench.document.clone(),
    };
    let path = document_path(root);
    let tmp = path.with_extension("json.tmp");
    let text = serde_json::to_string_pretty(&record).map_err(|e| e.to_string())? + "\n";
    fs::write(&tmp, text).map_err(|e| format!("cannot write {}: {e}", tmp.display()))?;
    let _ = fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600));
    fs::rename(&tmp, &path).map_err(|e| format!("cannot replace {}: {e}", path.display()))
}

/// Boot: the document from `bench.json`, and the events that say what it took to read it.
///
/// Absent is an empty document — a first boot, or a root that has never held a bench. A
/// document read with losses keeps what it could and logs each loss (`bench/repaired`). A
/// file that cannot be read as a document at all is moved aside, never deleted, and the
/// daemon starts empty (`bench/quarantined`) — the same posture as a torn event log: a
/// layout is worth a log line, not a daemon that will not start.
pub fn load(
    root: &Path,
    last_logged_change: Option<u64>,
) -> (BenchState, Vec<(&'static str, Value)>) {
    let path = document_path(root);
    let mut events = Vec::new();
    let empty = || BenchState {
        document: Document::default(),
        seq: 0,
    };
    let text = match fs::read_to_string(&path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return (empty(), events),
        Err(e) => {
            events.push(quarantine(&path, &format!("unreadable: {e}")));
            return (empty(), events);
        }
    };
    let state = match read_record(&text) {
        Ok((state, notes)) => {
            if !notes.is_empty() {
                events.push((
                    "bench/repaired",
                    json!({ "path": path.display().to_string(), "notes": notes }),
                ));
            }
            state
        }
        Err(why) => {
            events.push(quarantine(&path, &why));
            return (empty(), events);
        }
    };
    let mut state = state;
    // No session outlives the daemon that ran it, and ids restart with each daemon, so a pane
    // still naming one would attach to somebody else's agent. The pane stays, with its `agent`
    // record for the resume offer; the file is rewritten so a reader never sees the stale name.
    let ended = state.document.end_sessions();
    if !ended.is_empty() {
        let saved = save(root, &state).err();
        events.push((
            "bench/sessions-ended",
            json!({ "panes": ended, "why": "their daemon stopped", "unsaved": saved }),
        ));
    }
    if let Some(logged) = last_logged_change
        && logged > state.seq
    {
        // A crash between logging a change and writing the file. The file is still the
        // document; the log says what it is missing.
        events.push((
            "bench/behind",
            json!({ "log_seq": logged, "document_seq": state.seq }),
        ));
    }
    (state, events)
}

fn read_record(text: &str) -> Result<(BenchState, Vec<String>), String> {
    let mut value: Value = serde_json::from_str(text).map_err(|e| format!("not JSON: {e}"))?;
    let format = value.get("format").and_then(Value::as_str);
    if format != Some(DOCUMENT_RECORD_FORMAT) {
        return Err(format!(
            "format is {format:?}, not {DOCUMENT_RECORD_FORMAT:?}"
        ));
    }
    let version = value.get("version").and_then(Value::as_u64);
    if version.is_none_or(|v| v > DOCUMENT_RECORD_VERSION) {
        return Err(format!(
            "version {version:?} is newer than this build reads ({DOCUMENT_RECORD_VERSION})"
        ));
    }
    let seq = value.get("seq").and_then(Value::as_u64).ok_or("no seq")?;
    let document = value
        .get_mut("document")
        .map(Value::take)
        .ok_or("no document")?;
    let recovered = Document::read_tolerant(document)?;
    Ok((
        BenchState {
            document: recovered.value,
            seq,
        },
        recovered.notes,
    ))
}

fn quarantine(path: &Path, why: &str) -> (&'static str, Value) {
    let epoch = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let aside = path.with_file_name(format!("bench.json.bad-{epoch}"));
    let moved = fs::rename(path, &aside).map_err(|e| e.to_string());
    eprintln!(
        "benchd: {} could not be read as a document ({why}); moved to {} and starting empty",
        path.display(),
        aside.display()
    );
    (
        "bench/quarantined",
        json!({
            "path": path.display().to_string(),
            "moved_to": aside.display().to_string(),
            "moved": moved.is_ok(),
            "why": why,
        }),
    )
}
