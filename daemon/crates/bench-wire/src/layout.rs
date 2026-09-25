//! The bench document on the wire: who asked, the layout verbs, the follow frame, and the
//! record file. The document itself and its rules are `bench-doc`'s; this is only how they
//! travel and where they are kept.

use bench_doc::{
    CanvasSource, ColumnId, Direction, Document, PaneId, PaneName, ResumableAgent, SlotId, Split,
    StandardPath, Surface,
};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

use crate::Event;

/// Who asked for a change. Every verb carries one, and the daemon decides focus from it:
/// focus moves only when the operator acted, or when an agent's verb says the operator
/// asked (`Request::asked`). A request that says nothing is an agent's — the default that
/// cannot seize.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Actor {
    /// The operator's own gesture: a key, a click, a drag in helm.
    Operator,
    /// An agent. `pane` is where it is running when it knows (helm's `HELM_PANE`); `handle`
    /// is its mailbox. Both are for the record — no rule reads them.
    Agent {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        pane: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        handle: Option<String>,
    },
    /// helm acting on its own observation, never on a person's behalf — recording which
    /// agent is in a pane, importing its saved benches.
    Helm,
}

impl Actor {
    /// An agent that said nothing more about itself — what a request without `by` is.
    pub fn agent() -> Actor {
        Actor::Agent {
            pane: None,
            handle: None,
        }
    }

    /// The one place the focus rule is decided (bench-architecture.md, "The focus rule").
    pub fn focus(by: &Actor, asked: bool) -> bench_doc::Focus {
        if *by == Actor::Operator || asked {
            bench_doc::Focus::Take
        } else {
            bench_doc::Focus::Leave
        }
    }

    /// The class placement rules are written against.
    pub fn caller(&self) -> bench_doc::Caller {
        match self {
            Actor::Operator => bench_doc::Caller::Operator,
            Actor::Agent { .. } | Actor::Helm => bench_doc::Caller::Agent,
        }
    }
}

/// Every layout verb, as it arrives: the request's `verb` is the tag and its `args` the
/// content, so one decode both recognises the verb and validates its arguments — a missing
/// field is a refusal naming the field, and a surface kind this build does not know is a
/// refusal naming the kind. `workspace` defaults to the active one wherever it is optional.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "verb", content = "args")]
pub enum LayoutVerb {
    /// The document and the seq it reflects.
    #[serde(rename = "bench/get")]
    Get,
    #[serde(rename = "workspace/open")]
    WorkspaceOpen { path: StandardPath },
    #[serde(rename = "workspace/close")]
    WorkspaceClose { path: StandardPath },
    #[serde(rename = "workspace/activate")]
    WorkspaceActivate { path: StandardPath },
    /// helm #85's "fresh": the bench is shelved and replaced by one new terminal.
    #[serde(rename = "workspace/reset")]
    WorkspaceReset { path: StandardPath },
    #[serde(rename = "workspace/unshelve")]
    WorkspaceUnshelve { path: StandardPath },
    /// The one-time import of helm's saved benches, into an empty document only.
    #[serde(rename = "workspace/import")]
    WorkspaceImport { document: Document },
    /// A new pane showing `surface`, placed by the rules. A terminal gets a fresh id; a
    /// canvas or the browser already showing is brought forward (or, for an agent, left
    /// where it is).
    #[serde(rename = "pane/open")]
    PaneOpen {
        #[serde(default)]
        workspace: Option<StandardPath>,
        surface: Surface,
    },
    /// ⌘D / ⌘⇧D. A terminal unless a surface is named.
    #[serde(rename = "pane/split")]
    PaneSplit {
        #[serde(default)]
        workspace: Option<StandardPath>,
        direction: Split,
        #[serde(default)]
        surface: Option<Surface>,
    },
    #[serde(rename = "pane/close")]
    PaneClose { pane: PaneId },
    #[serde(rename = "pane/show")]
    PaneShow { pane: PaneId },
    #[serde(rename = "pane/move")]
    PaneMove { pane: PaneId, to: MoveTo },
    #[serde(rename = "pane/name")]
    PaneName { pane: PaneId, name: PaneName },
    #[serde(rename = "pane/repoint")]
    PaneRepoint { pane: PaneId, source: CanvasSource },
    /// Which agent is in a terminal pane — or, with `agent: null`, that none is.
    #[serde(rename = "pane/record")]
    PaneRecord {
        pane: PaneId,
        #[serde(default)]
        agent: Option<ResumableAgent>,
    },
    #[serde(rename = "focus/slot")]
    FocusSlot { slot: SlotId },
    #[serde(rename = "focus/step")]
    FocusStep {
        #[serde(default)]
        workspace: Option<StandardPath>,
        direction: Direction,
    },
    #[serde(rename = "layout/resize")]
    LayoutResize { divider: Divider, fraction: f64 },
}

/// Where a moved pane goes. Tagged so drag and drop (#178) adds a destination rather than
/// a second verb.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MoveTo {
    Step(Direction),
}

/// A divider: the member being dragged and the neighbour across it, either two columns or
/// two slots of one column.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "between", rename_all = "snake_case")]
pub enum Divider {
    Columns { member: ColumnId, against: ColumnId },
    Slots { member: SlotId, against: SlotId },
}

/// Every layout verb's wire name. `KNOWN_VERBS` includes these; `Verb::parse` sends them all
/// to `Verb::Layout`, and `LayoutVerb`'s own decode is the authority on their arguments.
pub const LAYOUT_VERBS: &[&str] = &[
    "bench/get",
    "workspace/open",
    "workspace/close",
    "workspace/activate",
    "workspace/reset",
    "workspace/unshelve",
    "workspace/import",
    "pane/open",
    "pane/split",
    "pane/close",
    "pane/show",
    "pane/move",
    "pane/name",
    "pane/repoint",
    "pane/record",
    "focus/slot",
    "focus/step",
    "layout/resize",
];

/// The event every document change is logged as. One kind, so a follower that only wants
/// to redraw needs to know one word; `data.verb` says which change it was.
pub const DOCUMENT_CHANGED: &str = "bench/changed";

/// One line of `events --follow`: an event, with the whole document attached when the
/// event changed it. Whole rather than a diff: the document is small, a follower that falls
/// behind can be dropped safely because reconnecting returns everything, and nobody has to
/// maintain a patch engine in two languages.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Frame {
    pub event: Event,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub document: Option<Document>,
}

/// What `bench/get` answers, and the first line of `events --follow`: the document and the
/// seq of the event it reflects.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DocumentAt {
    pub seq: u64,
    pub document: Document,
}

/// What every other layout verb answers. The focused pane before and after are two readings
/// taken either side of the change, so a caller can check the focus promise itself rather
/// than trust it (helm's `CommandReport`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LayoutReport {
    /// The seq of the event this change was logged as — or, when nothing changed, of the
    /// event the unchanged document still reflects.
    pub seq: u64,
    pub changed: bool,
    /// A pane that did not exist before the verb.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane_created: Option<PaneId>,
    /// The pane a `pane/open` resolved to: the new one, or the one already showing it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane: Option<PaneId>,
    pub focused_pane_before: Option<PaneId>,
    pub focused_pane_after: Option<PaneId>,
}

/// The data of a `bench/changed` event: the report, plus what was asked and by whom.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DocumentChange {
    pub verb: String,
    pub args: serde_json::Value,
    pub by: Actor,
    pub asked: bool,
    #[serde(flatten)]
    pub report: LayoutReport,
}

pub const DOCUMENT_RECORD_FORMAT: &str = "bench.document";
pub const DOCUMENT_RECORD_VERSION: u64 = 0;

/// `<root>/bench.json`: the document as benchd last wrote it, stamped with the seq of the
/// event that produced it. The log says what happened; this file says where things are.
/// It is a stored projection written by its one writer — never rebuilt by replaying the
/// log, because replay would reproduce the document only if placement rules never changed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DocumentRecord {
    pub format: String,
    pub version: u64,
    pub seq: u64,
    pub document: Document,
}

pub fn document_path(root: &Path) -> PathBuf {
    root.join("bench.json")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{KNOWN_VERBS, Request, Verb};
    use serde_json::{Value, json};

    fn fixture(name: &str) -> (PathBuf, String) {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures")
            .join(name);
        let text = std::fs::read_to_string(&path).expect("the shared fixture is checked in");
        (path, text)
    }

    #[test]
    fn a_request_that_says_nothing_about_who_asked_is_an_agents() {
        let req: Request =
            serde_json::from_value(json!({"id": "a", "verb": "pane/close", "args": {}})).unwrap();
        assert_eq!(req.by, None);
        assert!(!req.asked);
        let by = req.by.unwrap_or_else(Actor::agent);
        assert_eq!(Actor::focus(&by, req.asked), bench_doc::Focus::Leave);
        assert_eq!(
            Actor::focus(&by, true),
            bench_doc::Focus::Take,
            "--asked takes"
        );
        assert_eq!(
            Actor::focus(&Actor::Operator, false),
            bench_doc::Focus::Take
        );
        assert_eq!(Actor::focus(&Actor::Helm, false), bench_doc::Focus::Leave);
    }

    #[test]
    fn every_layout_verb_is_known_and_routes_to_layout() {
        for verb in LAYOUT_VERBS {
            assert!(KNOWN_VERBS.contains(verb), "{verb} is not in KNOWN_VERBS");
            assert_eq!(Verb::parse(verb), Some(Verb::Layout), "{verb}");
        }
    }

    /// `fixtures/bench-verbs.json` holds one request per layout verb. It is the sample helm's
    /// Swift encoder (M4 PR 3) is pinned against, so here it must decode as a `Request` and
    /// as its `LayoutVerb`, cover every verb, and write back byte for byte.
    #[test]
    fn the_verbs_fixture_covers_every_verb_and_round_trips() {
        let (path, text) = fixture("bench-verbs.json");
        let requests: Vec<Request> = serde_json::from_str(&text).expect("the fixture decodes");
        let mut seen: Vec<&str> = Vec::new();
        for req in &requests {
            let verb: LayoutVerb =
                serde_json::from_value(json!({"verb": req.verb, "args": req.args}))
                    .unwrap_or_else(|e| panic!("{}: {e}", req.verb));
            let back = serde_json::to_value(&verb).unwrap();
            assert_eq!(back["verb"], Value::String(req.verb.clone()));
            seen.push(LAYOUT_VERBS.iter().find(|v| **v == req.verb).unwrap());
        }
        for verb in LAYOUT_VERBS {
            assert!(
                seen.contains(verb),
                "{} has no sample of {verb}",
                path.display()
            );
        }
        let written = serde_json::to_string_pretty(&requests).unwrap() + "\n";
        assert_eq!(
            written,
            text,
            "the request spelling drifted from {}",
            path.display()
        );
    }

    #[test]
    fn the_frame_fixture_round_trips() {
        let (path, text) = fixture("bench-frame.json");
        let frame: Frame = serde_json::from_str(&text).expect("the fixture decodes");
        assert_eq!(frame.event.kind, DOCUMENT_CHANGED);
        assert!(frame.document.is_some());
        let change: DocumentChange = serde_json::from_value(frame.event.data.clone())
            .expect("a bench/changed event's data is a DocumentChange");
        assert_eq!(serde_json::to_value(&change).unwrap(), frame.event.data);
        let written = serde_json::to_string_pretty(&frame).unwrap() + "\n";
        assert_eq!(
            written,
            text,
            "the frame spelling drifted from {}",
            path.display()
        );
    }

    /// `fixtures/bench-report.json` pins the answer to a layout verb and to `bench/get`, the
    /// two reply shapes helm's client (M4 PR 3) decodes.
    #[test]
    fn the_reply_fixture_round_trips() {
        let (path, text) = fixture("bench-report.json");
        let value: Value = serde_json::from_str(&text).unwrap();
        let report: LayoutReport = serde_json::from_value(value["report"].clone()).unwrap();
        let at: DocumentAt = serde_json::from_value(value["get"].clone()).unwrap();
        assert!(report.pane_created.is_some() && report.focused_pane_before.is_some());
        assert!(!at.document.workspaces().is_empty());
        let written =
            serde_json::to_string_pretty(&json!({ "get": at, "report": report })).unwrap() + "\n";
        assert_eq!(
            written,
            text,
            "the reply spelling drifted from {}",
            path.display()
        );
    }

    #[test]
    fn a_bad_argument_is_refused_naming_it() {
        let err = serde_json::from_value::<LayoutVerb>(
            json!({"verb": "pane/open", "args": {"surface": {"kind": "archonRun"}}}),
        )
        .unwrap_err()
        .to_string();
        assert!(err.contains("archonRun"), "{err}");
        let err = serde_json::from_value::<LayoutVerb>(json!({"verb": "pane/close", "args": {}}))
            .unwrap_err()
            .to_string();
        assert!(err.contains("pane"), "{err}");
    }
}
