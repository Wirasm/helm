//! Drawers (#356): named tab holders beside the workspaces, shown over the bench.
//!
//! Two rules carry the feature, and most tests here pin one of them from both sides:
//! - **toggling a drawer never changes the layout under it** — every workspace compares equal
//!   before and after;
//! - **the focus rule covers drawers** — an agent (`Leave`) may put a pane in a drawer and badge
//!   it, and is refused anything that would open one or change what an open one shows. Each
//!   `Leave` refusal has a `Take` control beside it, so a guard that refused everything would
//!   fail.

mod common;

use bench_doc::{
    Document, DrawerName, Focus, Pane, PaneId, PaneName, Refusal, StandardPath, Surface, Workspace,
};
use common::*;
use serde_json::json;

fn name(raw: &str) -> DrawerName {
    DrawerName::new(raw).unwrap()
}

/// A document with two workspaces, the second active, its bench two columns wide with a tab.
fn working_document() -> Document {
    let mut doc = Document::default();
    for path in ["/tmp/kild", "/tmp/helm"] {
        doc.open_workspace(StandardPath::new(path).unwrap(), terminal(), Focus::Take)
            .unwrap();
    }
    doc.edit(bench_doc::Target::Active, Focus::Take, |b| {
        b.split(
            bench_doc::Split::Right,
            canvas("/tmp/helm/plan.md"),
            Focus::Take,
        )?;
        b.place(
            canvas("/tmp/helm/tasks.md"),
            bench_doc::Placement::Tab(b.focused_slot()),
            Focus::Leave,
        )
    })
    .unwrap();
    doc
}

fn workspaces(doc: &Document) -> Vec<Workspace> {
    doc.workspaces().to_vec()
}

// MARK: - The layout under a drawer never moves

#[test]
fn toggling_a_drawer_open_and_closed_leaves_every_workspace_as_it_was() {
    let mut doc = working_document();
    let before = workspaces(&doc);
    let bench_focus = doc.focused_pane();

    doc.toggle_drawer(&name("browser"), Some(Surface::Browser), Focus::Take)
        .unwrap();
    assert_eq!(workspaces(&doc), before, "opening re-laid-out nothing");
    assert_eq!(doc.open_drawer().unwrap().name, name("browser"));

    doc.toggle_drawer(&name("browser"), None, Focus::Take)
        .unwrap();
    assert_eq!(workspaces(&doc), before, "closing re-laid-out nothing");
    assert!(doc.open_drawer().is_none());
    assert_eq!(
        doc.focused_pane(),
        bench_focus,
        "closing hands the keyboard back to the bench pane that had it"
    );
}

#[test]
fn opening_one_drawer_closes_the_other() {
    let mut doc = working_document();
    doc.toggle_drawer(&name("browser"), Some(Surface::Browser), Focus::Take)
        .unwrap();
    doc.toggle_drawer(&name("notes"), Some(file("/tmp/n.md")), Focus::Take)
        .unwrap();
    assert_eq!(doc.open_drawer().unwrap().name, name("notes"));
    assert_eq!(doc.drawers().len(), 2, "the closed one keeps what it holds");
}

#[test]
fn a_drawer_that_holds_nothing_needs_a_surface_to_open() {
    let mut doc = working_document();
    let refused = doc.toggle_drawer(&name("notes"), None, Focus::Take);
    assert_eq!(refused, Err(Refusal::EmptyDrawer(name("notes"))));
    assert!(
        refused.unwrap_err().to_string().contains("name a surface"),
        "the refusal names the fix"
    );
    assert!(doc.drawers().is_empty());
}

// MARK: - The focus rule covers drawers

#[test]
fn an_agent_badges_a_closed_drawer_and_moves_nothing() {
    let mut doc = working_document();
    let before = workspaces(&doc);
    let focus = doc.focused_pane();

    let pane = canvas("/tmp/helm/drawers.md");
    let id = pane.id;
    let landed = doc
        .place_in_drawer(&name("notes"), pane, Focus::Leave)
        .unwrap();

    assert_eq!(landed, id);
    let drawer = doc.drawer(&name("notes")).unwrap();
    assert_eq!(
        drawer.selected, id,
        "a drawer's first pane is what it shows"
    );
    assert!(drawer.badged, "the operator is told something arrived");
    assert!(doc.open_drawer().is_none(), "and nothing opened");
    assert_eq!(doc.focused_pane(), focus, "the keyboard stayed");
    assert_eq!(workspaces(&doc), before, "the bench did not move");
}

#[test]
fn an_agent_cannot_open_or_close_a_drawer_and_the_operator_can() {
    let mut doc = working_document();
    doc.place_in_drawer(&name("notes"), canvas("/tmp/n.md"), Focus::Leave)
        .unwrap();
    let before = doc.clone();

    assert_eq!(
        doc.toggle_drawer(&name("notes"), None, Focus::Leave),
        Err(Refusal::WouldMoveFocus)
    );
    assert_eq!(
        doc, before,
        "a refused toggle changes nothing, badge included"
    );

    doc.toggle_drawer(&name("notes"), None, Focus::Take)
        .unwrap();
    assert_eq!(doc.open_drawer().unwrap().name, name("notes"));
    assert!(
        !doc.drawer(&name("notes")).unwrap().badged,
        "opening clears it"
    );

    assert_eq!(
        doc.toggle_drawer(&name("notes"), None, Focus::Leave),
        Err(Refusal::WouldMoveFocus),
        "closing is focus too"
    );
}

#[test]
fn an_agents_pane_in_an_open_drawer_does_not_change_what_it_shows() {
    let mut doc = working_document();
    doc.toggle_drawer(&name("notes"), Some(file("/tmp/n.md")), Focus::Take)
        .unwrap();
    let showing = doc.focused_pane();

    let pushed = canvas("/tmp/other.md");
    let pushed_id = pushed.id;
    doc.place_in_drawer(&name("notes"), pushed, Focus::Leave)
        .unwrap();

    let drawer = doc.open_drawer().unwrap();
    assert!(drawer.pane(pushed_id).is_some(), "it arrived as a tab");
    assert_eq!(doc.focused_pane(), showing, "behind the one being read");

    // Control: the operator's own open selects it.
    let asked = canvas("/tmp/asked.md");
    let asked_id = asked.id;
    doc.place_in_drawer(&name("notes"), asked, Focus::Take)
        .unwrap();
    assert_eq!(doc.focused_pane(), Some(asked_id));
}

#[test]
fn the_bench_under_an_open_drawer_is_still_guarded() {
    let mut doc = working_document();
    // The focused slot holds plan.md (selected) and tasks.md (a background tab).
    let tasks = doc
        .active_workspace()
        .unwrap()
        .bench
        .panes()
        .find(|p| p.surface == file("/tmp/helm/tasks.md"))
        .unwrap()
        .id;
    doc.toggle_drawer(&name("notes"), Some(file("/tmp/n.md")), Focus::Take)
        .unwrap();

    assert_eq!(
        doc.show_pane(tasks, Focus::Leave),
        Err(Refusal::WouldMoveFocus),
        "closing the drawer would land the keyboard on a pane the operator never chose"
    );
    doc.show_pane(tasks, Focus::Take).unwrap();
}

#[test]
fn reoffering_what_a_drawer_already_holds_badges_it_and_adds_nothing() {
    let mut doc = working_document();
    let first = canvas("/tmp/n.md");
    let first_id = first.id;
    doc.place_in_drawer(&name("notes"), first, Focus::Take)
        .unwrap();
    doc.toggle_drawer(&name("notes"), None, Focus::Take)
        .unwrap();

    let again = doc
        .place_in_drawer(&name("notes"), canvas("/tmp/n.md"), Focus::Leave)
        .unwrap();

    assert_eq!(again, first_id, "the pane already showing it is the answer");
    let drawer = doc.drawer(&name("notes")).unwrap();
    assert_eq!(drawer.panes.len(), 1);
    assert!(drawer.badged, "a rewritten artifact is worth a look");
}

#[test]
fn an_agent_shows_a_tab_of_a_closed_drawer_and_badges_it() {
    let mut doc = working_document();
    let a = canvas("/tmp/a.md");
    let a_id = a.id;
    let b = canvas("/tmp/b.md");
    let b_id = b.id;
    doc.place_in_drawer(&name("notes"), a, Focus::Leave)
        .unwrap();
    doc.place_in_drawer(&name("notes"), b, Focus::Leave)
        .unwrap();
    assert_eq!(doc.drawer(&name("notes")).unwrap().selected, a_id);

    doc.show_pane(b_id, Focus::Leave).unwrap();
    let drawer = doc.drawer(&name("notes")).unwrap();
    assert_eq!(drawer.selected, b_id);
    assert!(drawer.badged);
    assert!(doc.open_drawer().is_none());

    // With the drawer open, the same verb would change what the operator is reading.
    doc.toggle_drawer(&name("notes"), None, Focus::Take)
        .unwrap();
    assert_eq!(
        doc.show_pane(a_id, Focus::Leave),
        Err(Refusal::WouldMoveFocus)
    );
    doc.show_pane(a_id, Focus::Take).unwrap();
    assert_eq!(doc.focused_pane(), Some(a_id));
}

// MARK: - Closing, naming, and the verbs that stay on the bench

#[test]
fn closing_a_drawers_last_pane_removes_it_and_hands_focus_back() {
    let mut doc = working_document();
    let bench_focus = doc.focused_pane();
    let created = doc
        .toggle_drawer(&name("notes"), Some(file("/tmp/n.md")), Focus::Take)
        .unwrap()
        .expect("a new drawer answers the pane it was created with");
    assert_eq!(doc.focused_pane(), Some(created));

    assert_eq!(
        doc.close_pane(created, Focus::Leave),
        Err(Refusal::WouldMoveFocus),
        "the pane holding the keyboard is the operator's to close"
    );
    doc.close_pane(created, Focus::Take).unwrap();

    assert!(doc.drawers().is_empty(), "an empty drawer is not kept");
    assert!(doc.open_drawer().is_none());
    assert_eq!(doc.focused_pane(), bench_focus);
}

#[test]
fn closing_a_selected_tab_selects_its_neighbour() {
    let mut doc = working_document();
    let panes: Vec<Pane> = ["/tmp/a.md", "/tmp/b.md", "/tmp/c.md"]
        .into_iter()
        .map(canvas)
        .collect();
    let ids = ids(&panes);
    for pane in panes {
        doc.place_in_drawer(&name("notes"), pane, Focus::Leave)
            .unwrap();
    }
    doc.show_pane(ids[1], Focus::Leave).unwrap();

    doc.close_pane(ids[1], Focus::Leave).unwrap();
    assert_eq!(
        doc.drawer(&name("notes")).unwrap().selected,
        ids[2],
        "the neighbour at the closed position, as a slot does"
    );
}

#[test]
fn a_drawer_pane_is_named_and_recorded_like_any_other() {
    let mut doc = working_document();
    let id = doc
        .toggle_drawer(&name("scratch"), Some(Surface::terminal()), Focus::Take)
        .unwrap()
        .unwrap();

    let before = doc
        .name_pane(id, PaneName::Chosen("scratch".into()), Focus::Leave)
        .unwrap();
    assert_eq!(before, PaneName::Unnamed);
    let agent = bench_doc::ResumableAgent {
        command: "claude".into(),
        session: "s".into(),
        cwd: "/tmp".into(),
    };
    doc.record_agent(id, Some(agent.clone()), Focus::Leave)
        .unwrap();

    let pane = doc.drawer(&name("scratch")).unwrap().pane(id).unwrap();
    assert_eq!(pane.name, PaneName::Chosen("scratch".into()));
    assert_eq!(pane.surface, Surface::Terminal { agent: Some(agent) });
}

#[test]
fn a_bench_verb_naming_a_drawer_pane_is_refused_by_name() {
    let mut doc = working_document();
    let id = doc
        .place_in_drawer(&name("notes"), canvas("/tmp/n.md"), Focus::Leave)
        .unwrap();
    let refused = doc.edit(bench_doc::Target::Pane(id), Focus::Take, |b| {
        b.move_pane(id, bench_doc::Direction::Left, Focus::Take)
    });
    assert_eq!(
        refused,
        Err(Refusal::PaneInDrawer {
            pane: id,
            drawer: name("notes")
        })
    );
}

// MARK: - One namespace

#[test]
fn pane_ids_are_one_namespace_across_benches_and_drawers() {
    let mut doc = working_document();
    let on_bench = doc.focused_pane().unwrap();
    let copy = Pane::with_id(on_bench, file("/tmp/n.md"));
    assert_eq!(
        doc.place_in_drawer(&name("notes"), copy, Focus::Take),
        Err(Refusal::DuplicatePane(on_bench))
    );
    assert!(doc.drawers().is_empty());
}

#[test]
fn an_import_keeps_the_drawers_already_here() {
    let mut doc = Document::default();
    let id = doc
        .place_in_drawer(&name("notes"), canvas("/tmp/n.md"), Focus::Leave)
        .unwrap();

    doc.import(working_document()).unwrap();

    assert_eq!(doc.workspaces().len(), 2);
    assert!(
        doc.drawer(&name("notes")).unwrap().pane(id).is_some(),
        "an agent's drawer made before helm's one-time import survives it"
    );
}

// MARK: - Decoding

fn stored(extra: serde_json::Value) -> serde_json::Value {
    let mut value = serde_json::to_value(working_document()).unwrap();
    for (k, v) in extra.as_object().unwrap() {
        value[k] = v.clone();
    }
    value
}

fn drawer_json(drawer: &str, pane: &str, selected: &str) -> serde_json::Value {
    json!({
        "name": drawer,
        "panes": [{ "id": pane, "surface": { "kind": "browser" } }],
        "selected": selected,
    })
}

const P: &str = "00000077-0000-4000-8000-000000000077";
const Q: &str = "00000078-0000-4000-8000-000000000078";

#[test]
fn a_document_written_before_drawers_reads_unchanged() {
    let doc = working_document();
    let text = serde_json::to_string(&doc).unwrap();
    assert!(!text.contains("drawers") && !text.contains("open_drawer"));
    assert_eq!(serde_json::from_str::<Document>(&text).unwrap(), doc);
}

#[test]
fn decoding_refuses_what_no_operation_produces() {
    for (why, value) in [
        (
            "two drawers with one name",
            stored(json!({ "drawers": [drawer_json("notes", P, P), drawer_json("notes", Q, Q)] })),
        ),
        (
            "an open drawer that is not held",
            stored(json!({ "drawers": [drawer_json("notes", P, P)], "open_drawer": "browser" })),
        ),
        (
            "a selection the drawer does not hold",
            stored(json!({ "drawers": [drawer_json("notes", P, Q)] })),
        ),
        (
            "an empty drawer",
            stored(json!({ "drawers": [{ "name": "notes", "panes": [], "selected": P }] })),
        ),
        (
            "a name that is not a drawer name",
            stored(json!({ "drawers": [drawer_json("My Notes", P, P)] })),
        ),
    ] {
        assert!(
            serde_json::from_value::<Document>(value).is_err(),
            "{why} should be refused"
        );
    }

    // Minted ids differ per document, so the clash is built on one document's own value.
    let doc = working_document();
    let on_bench = doc.focused_pane().unwrap().to_string();
    let mut twice = serde_json::to_value(&doc).unwrap();
    twice["drawers"] = json!([drawer_json("notes", &on_bench, &on_bench)]);
    assert!(
        serde_json::from_value::<Document>(twice).is_err(),
        "a pane id on a bench and in a drawer"
    );
}

#[test]
fn a_stored_drawer_loses_only_the_pane_this_build_cannot_read() {
    let value = stored(json!({
        "drawers": [
            {
                "name": "notes",
                "panes": [
                    { "id": P, "surface": { "kind": "whiteboard" } },
                    { "id": Q, "surface": { "kind": "browser" } },
                ],
                "selected": P,
                "badged": true,
            },
            {
                "name": "future",
                "panes": [{ "id": "00000079-0000-4000-8000-000000000079", "surface": { "kind": "whiteboard" } }],
                "selected": "00000079-0000-4000-8000-000000000079",
            },
        ],
        "open_drawer": "future",
    }));

    let recovered = Document::read_tolerant(value).unwrap();
    let doc = recovered.value;
    let notes = doc.drawer(&name("notes")).unwrap();
    assert_eq!(notes.panes.len(), 1, "the readable pane survived");
    assert_eq!(notes.selected, PaneId::parse(Q).unwrap(), "and is selected");
    assert!(notes.badged);
    assert!(
        doc.drawer(&name("future")).is_none(),
        "a drawer with nothing readable is dropped"
    );
    assert!(doc.open_drawer().is_none(), "so it is not open either");
    assert_eq!(doc.workspaces().len(), 2, "and no workspace paid for it");
    for expected in [
        "whiteboard",
        "drawer notes",
        "drawer future",
        "open drawer future",
    ] {
        assert!(
            recovered.notes.iter().any(|n| n.contains(expected)),
            "a note mentions {expected:?}: {:?}",
            recovered.notes
        );
    }
}
