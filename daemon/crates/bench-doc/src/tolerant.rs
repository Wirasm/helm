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
//!   frame, and a shelved bench in that state is dropped.
//!
//! Nothing is lost silently. Every skip and repair comes back as a sentence, so the caller
//! (benchd's boot, the one-time import) can log it: bench-visible means logged.

use crate::bench::{Bench, Pane};
use crate::document::Document;
use crate::ids::PaneId;
use crate::surface::{PaneName, Surface};
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
    /// with today's one-terminal frame; its shelf, if unreadable, is dropped. What still
    /// refuses is a document no operation could have produced — a path open twice, a pane id
    /// in two places — because there is no telling which half to keep.
    pub fn read_tolerant(mut value: Value) -> Result<Recovered<Document>, String> {
        let mut notes = Vec::new();
        if let Some(workspaces) = value.get_mut("workspaces").and_then(Value::as_array_mut) {
            for workspace in workspaces {
                let path = workspace
                    .get("path")
                    .and_then(Value::as_str)
                    .unwrap_or("<no path>")
                    .to_string();
                let Some(fields) = workspace.as_object_mut() else {
                    continue;
                };
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
        let document = serde_json::from_value(value).map_err(|e| e.to_string())?;
        Ok(Recovered {
            value: document,
            notes,
        })
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
        && record.remove("agent").is_some()
    {
        notes.push(format!("pane {id}: an unreadable agent record was dropped"));
    }

    match serde_json::from_value::<Pane>(pane.clone()) {
        Ok(_) => Some(pane),
        Err(e) => {
            notes.push(format!("pane {id}: skipped — {e}"));
            None
        }
    }
}
