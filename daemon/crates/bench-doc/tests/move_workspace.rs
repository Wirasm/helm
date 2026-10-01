//! The two moves that cross benches (#178): reordering the workspaces (`move_workspace`, a
//! workspace tab dropped in a gap of the bar) and moving a pane to another workspace
//! (`move_pane_to_workspace`, a pane tab dropped on a workspace tab). Both are the document's,
//! because no one bench can make them.

mod common;

use bench_doc::{Document, DrawerName, Focus, Refusal, Split, StandardPath, Surface, Target};
use common::*;

fn path(p: &str) -> StandardPath {
    StandardPath::new(p).unwrap()
}

/// `/w/a`, `/w/b` and `/w/c`, each with one terminal, opened in that order; `/w/a` active.
fn three() -> Document {
    let mut doc = Document::default();
    for p in ["/w/a", "/w/b", "/w/c"] {
        doc.open_workspace(path(p), terminal(), Focus::Leave)
            .unwrap();
    }
    doc.activate(&path("/w/a"), Focus::Take).unwrap();
    doc
}

fn order(doc: &Document) -> Vec<&str> {
    doc.workspaces().iter().map(|w| w.path.as_str()).collect()
}

// MARK: - Reordering the bar

#[test]
fn a_workspace_moves_before_another_or_to_the_end() {
    let mut doc = three();
    assert!(
        doc.move_workspace(&path("/w/c"), Some(&path("/w/a")), Focus::Take)
            .unwrap()
    );
    assert_eq!(order(&doc), ["/w/c", "/w/a", "/w/b"]);

    assert!(
        doc.move_workspace(&path("/w/c"), None, Focus::Take)
            .unwrap()
    );
    assert_eq!(order(&doc), ["/w/a", "/w/b", "/w/c"]);

    assert!(
        doc.move_workspace(&path("/w/a"), Some(&path("/w/c")), Focus::Take)
            .unwrap()
    );
    assert_eq!(order(&doc), ["/w/b", "/w/a", "/w/c"]);
}

#[test]
fn a_workspace_dropped_where_it_is_changes_nothing() {
    let mut doc = three();
    let before = doc.clone();
    let a = path("/w/a");
    assert!(
        !doc.move_workspace(&a, Some(&a), Focus::Take).unwrap(),
        "before itself"
    );
    assert!(
        !doc.move_workspace(&a, Some(&path("/w/b")), Focus::Take)
            .unwrap(),
        "before its right neighbour"
    );
    assert!(
        !doc.move_workspace(&path("/w/c"), None, Focus::Take)
            .unwrap(),
        "last, to the end"
    );
    assert_eq!(doc, before);
}

#[test]
fn reordering_moves_no_focus_so_an_agent_may() {
    let mut doc = three();
    assert!(
        doc.move_workspace(&path("/w/a"), None, Focus::Leave)
            .unwrap()
    );
    assert_eq!(order(&doc), ["/w/b", "/w/c", "/w/a"]);
    assert_eq!(
        doc.active(),
        Some(&path("/w/a")),
        "the bar's order is not its selection"
    );
}

#[test]
fn reordering_refuses_a_workspace_that_is_not_open() {
    let mut doc = three();
    let before = doc.clone();
    assert_eq!(
        doc.move_workspace(&path("/w/x"), None, Focus::Take),
        Err(Refusal::UnknownWorkspace(path("/w/x")))
    );
    assert_eq!(
        doc.move_workspace(&path("/w/a"), Some(&path("/w/x")), Focus::Take),
        Err(Refusal::UnknownWorkspace(path("/w/x")))
    );
    assert_eq!(doc, before);
}

// MARK: - A pane to another workspace

/// `three()`, with a second pane split right of `/w/a`'s terminal. Answers that pane.
fn with_a_second_pane(doc: &mut Document) -> bench_doc::PaneId {
    let pane = terminal();
    let id = pane.id;
    doc.edit(Target::Active, Focus::Take, |b| {
        b.split(Split::Right, pane, Focus::Take)
    })
    .unwrap();
    id
}

#[test]
fn a_pane_dropped_on_a_workspace_joins_its_focused_slot_and_takes_the_keyboard_there() {
    let mut doc = three();
    let moving = with_a_second_pane(&mut doc);
    let b = path("/w/b");
    let target_slot = doc.workspace(&b).unwrap().bench.focused_slot();

    assert!(doc.move_pane_to_workspace(moving, &b, Focus::Take).unwrap());

    let a = &doc.workspace(&path("/w/a")).unwrap().bench;
    assert!(a.pane(moving).is_none());
    assert_eq!(a.columns().len(), 1, "its emptied column collapses");
    let bench = &doc.workspace(&b).unwrap().bench;
    assert_eq!(bench.slot_for(moving).map(|s| s.id), Some(target_slot));
    assert_eq!(
        doc.active(),
        Some(&b),
        "focus follows the pane, as every move's does"
    );
    assert_eq!(doc.focused_pane(), Some(moving));
    assert_invariants(bench, "a pane into another workspace");
}

#[test]
fn an_agent_may_move_a_background_pane_without_moving_the_operator() {
    let mut doc = three();
    let moving = with_a_second_pane(&mut doc);
    let a = path("/w/a");
    // Give the keyboard back to the first pane, so the moving one is in the background.
    let first = doc.workspace(&a).unwrap().bench.columns()[0].slots[0].id;
    doc.edit(Target::Active, Focus::Take, |bench| bench.focus_slot(first))
        .unwrap();
    let held = doc.focused_pane();

    assert!(
        doc.move_pane_to_workspace(moving, &path("/w/c"), Focus::Leave)
            .unwrap()
    );

    assert_eq!(doc.active(), Some(&a));
    assert_eq!(doc.focused_pane(), held);
    let c = &doc.workspace(&path("/w/c")).unwrap().bench;
    assert!(c.pane(moving).is_some());
    assert_ne!(
        c.focused_pane().map(|p| p.id),
        Some(moving),
        "it arrives unselected"
    );
}

#[test]
fn an_agent_may_not_move_the_pane_holding_the_keyboard_away() {
    let mut doc = three();
    let moving = with_a_second_pane(&mut doc);
    let before = doc.clone();
    assert_eq!(
        doc.move_pane_to_workspace(moving, &path("/w/b"), Focus::Leave),
        Err(Refusal::WouldMoveFocus)
    );
    assert_eq!(doc, before);
}

#[test]
fn a_pane_dropped_on_its_own_workspace_changes_nothing() {
    let mut doc = three();
    let moving = with_a_second_pane(&mut doc);
    let before = doc.clone();
    assert!(
        !doc.move_pane_to_workspace(moving, &path("/w/a"), Focus::Take)
            .unwrap()
    );
    assert_eq!(doc, before);
}

#[test]
fn a_workspaces_last_pane_cannot_leave_it() {
    let mut doc = three();
    let only = doc
        .workspace(&path("/w/b"))
        .unwrap()
        .bench
        .panes()
        .next()
        .unwrap()
        .id;
    let before = doc.clone();
    assert_eq!(
        doc.move_pane_to_workspace(only, &path("/w/a"), Focus::Take),
        Err(Refusal::LastPane(only))
    );
    assert_eq!(doc, before);
}

#[test]
fn moving_a_pane_refuses_what_is_not_on_a_bench_or_not_open() {
    let mut doc = three();
    let moving = with_a_second_pane(&mut doc);
    assert_eq!(
        doc.move_pane_to_workspace(moving, &path("/w/x"), Focus::Take),
        Err(Refusal::UnknownWorkspace(path("/w/x")))
    );
    let drawer = DrawerName::new("browser").unwrap();
    let shown = doc
        .toggle_drawer(&drawer, Some(Surface::Browser), Focus::Take)
        .unwrap()
        .unwrap();
    assert_eq!(
        doc.move_pane_to_workspace(shown, &path("/w/b"), Focus::Take),
        Err(Refusal::PaneInDrawer {
            pane: shown,
            drawer
        })
    );
    let stray = terminal().id;
    assert_eq!(
        doc.move_pane_to_workspace(stray, &path("/w/b"), Focus::Take),
        Err(Refusal::UnknownPane(stray))
    );
}

/// The placement is the target's focused slot even when that is not its first: a drop says
/// "put it there", and "there" is what that workspace shows when it comes forward.
#[test]
fn the_pane_lands_in_the_slot_that_workspace_has_focused() {
    let mut doc = three();
    let moving = with_a_second_pane(&mut doc);
    let b = path("/w/b");
    let second = terminal();
    doc.edit(Target::Workspace(b.clone()), Focus::Take, |bench| {
        bench.split(Split::Down, second, Focus::Take)
    })
    .unwrap();
    let focused = doc.workspace(&b).unwrap().bench.focused_slot();
    assert_ne!(
        focused,
        doc.workspace(&b).unwrap().bench.columns()[0].slots[0].id
    );

    doc.move_pane_to_workspace(moving, &b, Focus::Take).unwrap();

    let bench = &doc.workspace(&b).unwrap().bench;
    assert_eq!(bench.slot_for(moving).map(|s| s.id), Some(focused));
}
