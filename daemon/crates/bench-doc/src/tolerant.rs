//! Reading a stored document without letting one bad pane cost every workspace.
//!
//! The derived `Deserialize` is strict, and that is right for anything a caller sends: a
//! malformed request earns a refusal naming the field. A **stored** document is different. It
//! may have been written by a newer build with a surface kind this one does not have, or by an
//! older one whose record this build reads differently, and helm learned what strictness costs
//! there: one `{"kind":"archonRun"}` pane would have failed the array, the slot, the bench and —
//! one level up — every workspace at once. `Workbench.swift`'s `Skippable<Pane>` contains the
//! loss to the pane, and this module is its port:
//!
//! - a pane that cannot be read is **skipped**, and `normalize()` repairs what referred to it —
//!   a `selected` that named it, a slot or column it leaves empty;
//! - a malformed `agent` costs the pane its resume record, not the pane;
//! - a malformed `name` costs the pane its name, not the pane;
//! - a bench left with no panes cannot be repaired: the workspace gets today's one-terminal
//!   frame, and a shelved bench in that state is dropped;
//! - a drawer keeps the panes it can read; one left with none, or with no readable name, is
//!   dropped, and an open drawer that did not survive is closed.
//!
//! Nothing is lost silently. Every skip and repair comes back as a sentence, so the caller
//! (benchd's boot, the one-time import) can log it: bench-visible means logged.

use crate::bench::{Bench, Pane};
use crate::document::Document;
use crate::drawer::DrawerName;
use crate::ids::{PaneId, StandardPath};
use crate::surface::{PaneName, ResumableAgent, Surface};
use serde_json::Value;

/// A document read tolerantly, and what it cost.
#[derive(Debug)]
pub struct Recovered<T> {
    pub value: T,
    /// One sentence per pane skipped or field dropped. Empty when the input was clean.
    pub notes: Vec<String>,
}

impl Bench {
    /// Read a stored bench, skipping and repairing as the module header says. Refuses only a
    /// bench with no readable pane at all — there is nothing to render and nothing to invent.
    pub fn read_tolerant(mut value: Value) -> Result<Recovered<Bench>, String> {
        let mut notes = Vec::new();
        if let Some(columns) = value.get_mut("columns").and_then(Value::as_array_mut) {
            for column in columns {
                let Some(slots) = column.get_mut("slots").and_then(Value::as_array_mut) else {
                    continue;
                };
                for slot in slots {
                    if let Some(panes) = slot.get_mut("panes").and_then(Value::as_array_mut) {
                        let taken = std::mem::take(panes);
                        *panes = taken
                            .into_iter()
                            .filter_map(|pane| repair(pane, &mut notes))
                            .collect();
                    }
                }
            }
        }
        // A refusal carries what was skipped on the way, so the caller's one sentence about a
        // lost bench still names the panes it lost.
        let bench = serde_json::from_value(value).map_err(|e| {
            std::iter::once(e.to_string())
                .chain(notes.iter().cloned())
                .collect::<Vec<_>>()
                .join("; ")
        })?;
        Ok(Recovered {
            value: bench,
            notes,
        })
    }
}

impl Document {
    /// Read a stored document. A workspace whose bench cannot be recovered keeps its place
    /// with today's one-terminal frame; its shelf, if unreadable, is dropped. A workspace with
    /// no readable path is dropped — the path is its identity, and there is nothing to show
    /// without one — and an `active` naming nothing that survived falls back to the first
    /// workspace. What still refuses is a document no operation could have produced — a path
    /// open twice, a pane id in two places — because there is no telling which half to keep.
    pub fn read_tolerant(mut value: Value) -> Result<Recovered<Document>, String> {
        let mut notes = Vec::new();
        let mut kept: Vec<String> = Vec::new();
        if let Some(workspaces) = value.get_mut("workspaces").and_then(Value::as_array_mut) {
            workspaces.retain(|workspace| match readable_path(workspace) {
                Ok(_) => true,
                Err(why) => {
                    notes.push(format!("a workspace was dropped: {why}"));
                    false
                }
            });
            for workspace in workspaces {
                let path = readable_path(workspace).expect("unreadable paths were dropped above");
                kept.push(path.clone());
                let fields = workspace.as_object_mut().expect("checked by readable_path");
                fields.insert("path".into(), Value::String(path.clone()));
                let bench = fields.remove("bench").unwrap_or(Value::Null);
                let recovered = match Bench::read_tolerant(bench) {
                    Ok(r) => r,
                    Err(e) => {
                        notes.push(format!(
                            "workspace {path}: its bench could not be read ({e}) — it opens as one terminal"
                        ));
                        Recovered {
                            value: Bench::terminal(PaneId::mint()),
                            notes: Vec::new(),
                        }
                    }
                };
                notes.extend(
                    recovered
                        .notes
                        .into_iter()
                        .map(|n| format!("workspace {path}: {n}")),
                );
                fields.insert("bench".into(), to_value(&recovered.value));

                if let Some(shelved) = fields.remove("shelved").filter(|v| !v.is_null()) {
                    match Bench::read_tolerant(shelved) {
                        Ok(r) => {
                            notes.extend(
                                r.notes.into_iter().map(|n| format!("workspace {path}, shelf: {n}")),
                            );
                            fields.insert("shelved".into(), to_value(&r.value));
                        }
                        Err(e) => notes.push(format!(
                            "workspace {path}: its shelved bench could not be read ({e}) and was dropped"
                        )),
                    }
                }
            }
        }
        repair_active(&mut value, &kept, &mut notes);
        repair_drawers(&mut value, &mut notes);
        let document = serde_json::from_value(value).map_err(|e| e.to_string())?;
        Ok(Recovered {
            value: document,
            notes,
        })
    }
}

/// A workspace entry's path in its one spelling, or why it has none.
fn readable_path(workspace: &Value) -> Result<String, String> {
    let fields = workspace
        .as_object()
        .ok_or_else(|| format!("an entry that is not a workspace ({workspace})"))?;
    let raw = fields
        .get("path")
        .and_then(Value::as_str)
        .ok_or("an entry with no path")?;
    StandardPath::new(raw).map(|p| p.as_str().to_string())
}

/// `active` must name a workspace that survived; otherwise the first one is shown — the rule
/// `Document::close_workspace` follows when the workspace on screen goes away.
fn repair_active(value: &mut Value, kept: &[String], notes: &mut Vec<String>) {
    let Some(fields) = value.as_object_mut() else {
        return;
    };
    let stored = fields.get("active").cloned().unwrap_or(Value::Null);
    let resolved = stored
        .as_str()
        .and_then(|raw| StandardPath::new(raw).ok())
        .map(|p| p.as_str().to_string())
        .filter(|p| kept.contains(p));
    let active = match (&stored, resolved) {
        // Nothing was active, which a document can say (a workspace opened in the background
        // while nothing was on screen); that is not a loss.
        (Value::Null, _) => Value::Null,
        (_, Some(path)) => Value::String(path),
        _ => {
            let fallback = kept.first().cloned();
            notes.push(format!(
                "the active workspace {stored} is not one that could be read — {} is shown instead",
                fallback.as_deref().unwrap_or("nothing")
            ));
            fallback.map(Value::String).unwrap_or(Value::Null)
        }
    };
    fields.insert("active".into(), active);
}

/// Each drawer's panes read as a bench's are; a drawer left with none, or with no readable name,
/// is dropped, and a selection naming a skipped pane moves to the first that survived. Duplicate
/// names are left for the strict decode to refuse, as duplicate workspace paths are.
fn repair_drawers(value: &mut Value, notes: &mut Vec<String>) {
    let Some(fields) = value.as_object_mut() else {
        return;
    };
    let mut kept: Vec<String> = Vec::new();
    if let Some(drawers) = fields.get_mut("drawers").and_then(Value::as_array_mut) {
        drawers.retain_mut(|drawer| {
            let name = drawer
                .get("name")
                .and_then(Value::as_str)
                .and_then(|raw| DrawerName::new(raw).ok())
                .map(|n| n.as_str().to_string());
            let Some(name) = name else {
                notes.push(format!(
                    "a drawer was dropped: it has no readable name ({drawer})"
                ));
                return false;
            };
            let Some(panes) = drawer.get_mut("panes").and_then(Value::as_array_mut) else {
                notes.push(format!("drawer {name}: dropped — it holds no panes"));
                return false;
            };
            let taken = std::mem::take(panes);
            *panes = taken
                .into_iter()
                .filter_map(|pane| repair(pane, notes))
                .collect();
            let ids: Vec<Value> = panes.iter().filter_map(|p| p.get("id").cloned()).collect();
            let Some(first) = ids.first().cloned() else {
                notes.push(format!(
                    "drawer {name}: dropped — none of its panes could be read"
                ));
                return false;
            };
            if !drawer.get("selected").is_some_and(|id| ids.contains(id)) {
                notes.push(format!(
                    "drawer {name}: its selected pane could not be read — it shows {first} instead"
                ));
                drawer["selected"] = first;
            }
            kept.push(name);
            true
        });
    }
    let open = fields.get("open_drawer").and_then(Value::as_str);
    if let Some(open) = open
        && !kept.iter().any(|k| k == open)
    {
        notes.push(format!(
            "the open drawer {open} is not one that could be read — no drawer is open"
        ));
        fields.remove("open_drawer");
    }
}

fn to_value(bench: &Bench) -> Value {
    serde_json::to_value(bench).expect("a bench always encodes")
}

/// One pane, read strictly first, then with its optional record and name dropped in turn;
/// `None` when even the bare pane cannot be read.
fn repair(mut pane: Value, notes: &mut Vec<String>) -> Option<Value> {
    if serde_json::from_value::<Pane>(pane.clone()).is_ok() {
        return Some(pane);
    }
    let id = pane
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or("<no id>")
        .to_string();
    let fields = pane.as_object_mut()?;

    if fields
        .get("name")
        .is_some_and(|n| serde_json::from_value::<PaneName>(n.clone()).is_err())
    {
        fields.remove("name");
        notes.push(format!("pane {id}: an unreadable name was dropped"));
    }
    let surface = fields.get_mut("surface");
    if let Some(surface) = surface
        && serde_json::from_value::<Surface>(surface.clone()).is_err()
        && surface.get("kind").and_then(Value::as_str) == Some("terminal")
        && let Some(record) = surface.as_object_mut()
    {
        // A terminal's two optional fields each cost only themselves.
        if record
            .get("agent")
            .is_some_and(|a| serde_json::from_value::<ResumableAgent>(a.clone()).is_err())
        {
            record.remove("agent");
            notes.push(format!("pane {id}: an unreadable agent record was dropped"));
        }
        if record.get("session").is_some_and(|s| !s.is_string()) {
            record.remove("session");
            notes.push(format!("pane {id}: an unreadable session was dropped"));
        }
    }

    match serde_json::from_value::<Pane>(pane.clone()) {
        Ok(_) => Some(pane),
        Err(e) => {
            notes.push(format!("pane {id}: skipped — {e}"));
            None
        }
    }
}
