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
use bench_doc::{Caller, Document, Focus, Pane, PaneId, Rules, Surface, Target};
use bench_wire::{
    Actor, DOCUMENT_CHANGED, DOCUMENT_RECORD_FORMAT, DOCUMENT_RECORD_VERSION, Divider,
    DocumentRecord, LayoutVerb, MoveTo, Request, Response, Status, document_path,
};
use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

/// The document as the daemon holds it, and the seq of the event that last changed it.
pub struct BenchState {
    pub document: Document,
    pub rules: Rules,
    /// The seq of the `bench/changed` event this document reflects; 0 before the first.
    pub seq: u64,
}

/// What a verb did, beyond the document it left behind.
#[derive(Default)]
struct Outcome {
    /// A pane that did not exist before the verb.
    created: Option<PaneId>,
    /// The pane a `pane/open` resolved to — the new one, or the one already showing it.
    pane: Option<PaneId>,
}

pub fn answer(core: &mut Core, req: &Request) -> Response {
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
            return reply(
                Status::Refused,
                Some(format!("{} args: {e}", req.verb)),
                None,
            );
        }
    };
    if verb == LayoutVerb::Get {
        let data = json!({ "seq": core.bench.seq, "document": core.bench.document });
        return reply(Status::Ok, None, Some(data));
    }

    let by = req.by.clone().unwrap_or_else(Actor::agent);
    let focus = Actor::focus(&by, req.asked);
    let mut next = core.bench.document.clone();
    let before = focused_pane(&next);
    let outcome = match apply(&mut next, &core.bench.rules, &verb, focus, by.caller()) {
        Ok(o) => o,
        Err(refusal) => return reply(Status::Refused, Some(refusal.to_string()), None),
    };
    let after = focused_pane(&next);
    let mut data = json!({
        "focused_pane_before": before,
        "focused_pane_after": after,
    });
    if let Some(pane) = outcome.created {
        data["pane_created"] = json!(pane);
    }
    if let Some(pane) = outcome.pane {
        data["pane"] = json!(pane);
    }

    if next == core.bench.document {
        data["changed"] = json!(false);
        data["seq"] = json!(core.bench.seq);
        return reply(Status::Ok, None, Some(data));
    }

    let mut logged = data.clone();
    logged["verb"] = json!(req.verb);
    logged["args"] = req.args.clone();
    logged["by"] = json!(by);
    logged["asked"] = json!(req.asked);
    let event = match core.append_event(DOCUMENT_CHANGED, logged, Some(&next)) {
        Ok(e) => e,
        Err(why) => return reply(Status::Error, Some(why), None),
    };
    // The change is now a fact: logged, and every follower has it. `bench.json` failing to
    // land is reported, not undone — the log says what happened, and the next change that
    // does land writes the whole document again.
    core.bench.document = next;
    core.bench.seq = event.seq;
    data["changed"] = json!(true);
    data["seq"] = json!(event.seq);
    if let Err(why) = save(&core.root, &core.bench) {
        let _ = core.append("bench/unsaved", json!({ "seq": event.seq, "why": why }));
        return reply(
            Status::Error,
            Some(format!(
                "applied and logged as seq {}, but bench.json could not be written: {why}",
                event.seq
            )),
            Some(data),
        );
    }
    reply(Status::Ok, None, Some(data))
}

/// The pane holding the operator's keyboard: the active workspace's focused pane.
fn focused_pane(document: &Document) -> Option<PaneId> {
    document
        .active_workspace()
        .and_then(|w| w.bench.focused_pane())
        .map(|p| p.id)
}

fn apply(
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
        LayoutVerb::PaneOpen { workspace, surface } => doc.edit(on(workspace), focus, |bench| {
            let placement = rules.place(bench, surface, caller);
            if let bench_doc::Placement::Existing(open) = placement {
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
        }),
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
        LayoutVerb::PaneClose { pane } => doc
            .edit(Target::Pane(*pane), focus, |b| b.close(*pane))
            .map(|()| Outcome::default()),
        LayoutVerb::PaneShow { pane } => doc
            .edit(Target::Pane(*pane), focus, |b| b.show(*pane, focus))
            .map(|()| Outcome::default()),
        LayoutVerb::PaneMove {
            pane,
            to: MoveTo::Step(direction),
        } => doc
            .edit(Target::Pane(*pane), focus, |b| {
                b.move_pane(*pane, *direction, focus)
            })
            .map(|_| Outcome::default()),
        LayoutVerb::PaneName { pane, name } => doc
            .edit(Target::Pane(*pane), focus, |b| b.name(*pane, name.clone()))
            .map(|_| Outcome::default()),
        LayoutVerb::PaneRepoint { pane, source } => doc
            .edit(Target::Pane(*pane), focus, |b| {
                b.repoint(*pane, source.clone())
            })
            .map(|()| Outcome::default()),
        LayoutVerb::PaneRecord { pane, agent } => doc
            .edit(Target::Pane(*pane), focus, |b| {
                b.record_agent(*pane, agent.clone())
            })
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
    }
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
        rules: Rules::defaults(),
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
            rules: Rules::defaults(),
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
