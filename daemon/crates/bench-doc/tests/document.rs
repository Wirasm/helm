//! The document: workspaces, the #85 shelf, import, and the focus rule enforced once for
//! every operation. The shelf tests mirror the data half of
//! `Tests/HelmTests/Workbench/BenchMountTests.swift`; *when* to ask the operator stays helm's.

mod common;

use bench_doc::{
    Direction, Document, Focus, Pane, PaneId, Placement, Refusal, Split, StandardPath, Surface,
    Target,
};
use common::*;

fn path(p: &str) -> StandardPath {
    StandardPath::new(p).unwrap()
}

/// One workspace, active, holding two tabs in the left slot and one pane on the right,
/// focus on the left slot showing `left[0]`.
fn one_workspace() -> (Document, [PaneId; 2], PaneId) {
    let mut doc = Document::default();
    let first = terminal();
    let l0 = first.id;
    doc.open_workspace(path("/work/a"), first, Focus::Take)
        .unwrap();
    let second = terminal();
    let l1 = second.id;
    let right = terminal();
    let r = right.id;
    doc.edit(Target::Active, Focus::Take, |b| {
        let slot = b.focused_slot();
        b.place(second, Placement::Tab(slot), Focus::Leave)?;
        b.split(Split::Right, right, Focus::Leave)
    })
    .unwrap();
    (doc, [l0, l1], r)
}

fn focused(doc: &Document) -> Option<PaneId> {
    doc.active_workspace()?.bench.focused_pane().map(|p| p.id)
}

// MARK: - The focus rule

#[test]
fn an_agent_may_rearrange_around_the_operator() {
    let (mut doc, left, right) = one_workspace();
    let before = focused(&doc);

    doc.edit(Target::Pane(right), Focus::Leave, |b| b.close(right))
        .unwrap();
    doc.edit(Target::Active, Focus::Leave, |b| {
        b.split(Split::Down, terminal(), Focus::Leave)
    })
    .unwrap();
    doc.edit(Target::Active, Focus::Leave, |b| {
        b.place(canvas("/tmp/plan.md"), Placement::Column, Focus::Leave)
    })
    .unwrap();

    assert_eq!(
        focused(&doc),
        before,
        "three changes, and the keyboard never moved"
    );
    assert_eq!(before, Some(left[0]));
}

#[test]
fn an_agent_may_not_close_the_pane_holding_the_keyboard() {
    let (mut doc, left, _) = one_workspace();
    let before = doc.clone();

    assert_eq!(
        doc.edit(Target::Pane(left[0]), Focus::Leave, |b| b.close(left[0])),
        Err(Refusal::WouldMoveFocus)
    );
    assert_eq!(doc, before, "a refused change leaves no trace");

    doc.edit(Target::Pane(left[0]), Focus::Take, |b| b.close(left[0]))
        .unwrap();
    assert_ne!(focused(&doc), Some(left[0]), "with --asked it may");
}

#[test]
fn an_agent_may_not_show_a_background_tab_of_the_focused_slot() {
    let (mut doc, left, right) = one_workspace();

    assert_eq!(
        doc.edit(Target::Pane(left[1]), Focus::Leave, |b| b
            .show(left[1], Focus::Leave)),
        Err(Refusal::WouldMoveFocus),
        "in the focused slot the selection IS the focused pane (#284)"
    );
    doc.edit(Target::Pane(right), Focus::Leave, |b| {
        b.show(right, Focus::Leave)
    })
    .unwrap();
    assert_eq!(
        focused(&doc),
        Some(left[0]),
        "showing a pane in another slot is fine"
    );
}

#[test]
fn an_agent_may_not_move_the_focused_pane_away() {
    let (mut doc, left, _) = one_workspace();

    assert_eq!(
        doc.edit(Target::Pane(left[0]), Focus::Leave, |b| {
            b.move_pane(left[0], Direction::Right, Focus::Leave)
        }),
        Err(Refusal::WouldMoveFocus)
    );
    doc.edit(Target::Pane(left[1]), Focus::Leave, |b| {
        b.move_pane(left[1], Direction::Right, Focus::Leave)
    })
    .unwrap();
    assert_eq!(focused(&doc), Some(left[0]), "a background tab may go");
}

#[test]
fn focus_verbs_need_the_operator_or_asked() {
    let (mut doc, _, right) = one_workspace();
    let right_slot = doc
        .active_workspace()
        .unwrap()
        .bench
        .slot_for(right)
        .unwrap()
        .id;

    for (label, result) in [
        (
            "focus a slot",
            doc.clone()
                .edit(Target::Slot(right_slot), Focus::Leave, |b| {
                    b.focus_slot(right_slot)
                }),
        ),
        (
            "step focus",
            doc.clone().edit(Target::Active, Focus::Leave, |b| {
                b.step_focus(Direction::Right);
                Ok(())
            }),
        ),
    ] {
        assert_eq!(result, Err(Refusal::WouldMoveFocus), "{label}");
    }

    doc.edit(Target::Slot(right_slot), Focus::Take, |b| {
        b.focus_slot(right_slot)
    })
    .unwrap();
    assert_eq!(focused(&doc), Some(right));
}

#[test]
fn a_focus_verb_that_changes_nothing_is_not_refused() {
    let (mut doc, _, _) = one_workspace();
    let focused_slot = doc.active_workspace().unwrap().bench.focused_slot();

    doc.edit(Target::Active, Focus::Leave, |b| b.focus_slot(focused_slot))
        .unwrap();
    doc.activate(&path("/work/a"), Focus::Leave).unwrap();
}

#[test]
fn a_parked_workspace_is_the_agents_to_rearrange() {
    let (mut doc, _, _) = one_workspace();
    let parked_first = terminal();
    let parked_id = parked_first.id;
    doc.open_workspace(path("/work/b"), parked_first, Focus::Leave)
        .unwrap();
    assert_eq!(
        doc.active(),
        Some(&path("/work/a")),
        "opening in the background keeps /work/a"
    );
    doc.edit(Target::Workspace(path("/work/b")), Focus::Leave, |b| {
        b.place(terminal(), Placement::Column, Focus::Leave)
    })
    .unwrap();

    doc.edit(Target::Pane(parked_id), Focus::Leave, |b| {
        b.close(parked_id)
    })
    .unwrap();

    assert!(
        doc.workspace(&path("/work/b"))
            .unwrap()
            .bench
            .pane(parked_id)
            .is_none(),
        "the operator is not looking at /work/b, so its focus is not the operator's"
    );
}

#[test]
fn switching_workspace_is_a_focus_verb() {
    let (mut doc, _, _) = one_workspace();
    doc.open_workspace(path("/work/b"), terminal(), Focus::Leave)
        .unwrap();

    assert_eq!(
        doc.activate(&path("/work/b"), Focus::Leave),
        Err(Refusal::WouldMoveFocus)
    );
    doc.activate(&path("/work/b"), Focus::Take).unwrap();
    assert_eq!(doc.active(), Some(&path("/work/b")));
}

// MARK: - One namespace for panes

#[test]
fn a_pane_id_lives_in_one_place_in_the_whole_document() {
    let (mut doc, left, _) = one_workspace();
    doc.open_workspace(path("/work/b"), terminal(), Focus::Leave)
        .unwrap();
    let before = doc.clone();

    assert_eq!(
        doc.edit(Target::Workspace(path("/work/b")), Focus::Leave, |b| {
            b.place(
                Pane::with_id(left[0], Surface::terminal()),
                Placement::Column,
                Focus::Leave,
            )
        }),
        Err(Refusal::DuplicatePane(left[0]))
    );
    assert_eq!(doc, before);
}

#[test]
fn a_pane_verb_finds_its_workspace_by_the_pane() {
    let (mut doc, left, _) = one_workspace();
    let stranger = PaneId::mint();

    assert_eq!(
        doc.edit(Target::Pane(stranger), Focus::Take, |b| b.close(stranger)),
        Err(Refusal::UnknownPane(stranger))
    );
    doc.edit(Target::Pane(left[1]), Focus::Take, |b| {
        b.name(left[1], bench_doc::PaneName::Chosen("x".into()))
    })
    .unwrap();
    assert_eq!(
        doc.workspace_of(left[1])
            .unwrap()
            .bench
            .pane(left[1])
            .unwrap()
            .name
            .text(),
        Some("x")
    );
}

// MARK: - Workspaces

#[test]
fn closing_the_active_workspace_activates_the_first_that_remains() {
    let (mut doc, _, _) = one_workspace();
    doc.open_workspace(path("/work/b"), terminal(), Focus::Leave)
        .unwrap();
    doc.open_workspace(path("/work/c"), terminal(), Focus::Leave)
        .unwrap();
    doc.activate(&path("/work/c"), Focus::Take).unwrap();

    doc.close_workspace(&path("/work/c"), Focus::Take).unwrap();
    assert_eq!(
        doc.active(),
        Some(&path("/work/a")),
        "closing the active workspace activates the first that remains"
    );

    doc.close_workspace(&path("/work/a"), Focus::Take).unwrap();
    doc.close_workspace(&path("/work/b"), Focus::Take).unwrap();
    assert_eq!(doc.active(), None, "closing the last leaves nothing open");
    assert!(doc.workspaces().is_empty());
}

#[test]
fn opening_an_open_workspace_only_activates_it() {
    let (mut doc, _, _) = one_workspace();
    let before = doc.workspace(&path("/work/a")).unwrap().clone();

    doc.open_workspace(path("/work/a"), terminal(), Focus::Take)
        .unwrap();

    assert_eq!(doc.workspaces().len(), 1);
    assert_eq!(
        doc.workspace(&path("/work/a")).unwrap(),
        &before,
        "its bench is untouched"
    );
}

// MARK: - The shelf (helm #85), data half of BenchMountTests

#[test]
fn fresh_yields_one_shell_and_shelves_what_it_declined() {
    let (mut doc, _, _) = one_workspace();
    let declined = doc.workspace(&path("/work/a")).unwrap().bench.clone();
    let fresh = terminal();
    let fresh_id = fresh.id;

    doc.reset(&path("/work/a"), fresh, Focus::Take).unwrap();

    let workspace = doc.workspace(&path("/work/a")).unwrap();
    assert_eq!(
        workspace.bench.panes().map(|p| p.id).collect::<Vec<_>>(),
        vec![fresh_id]
    );
    assert_eq!(
        workspace.shelved.as_ref(),
        Some(&declined),
        "one wrong click destroys nothing"
    );
}

#[test]
fn restoring_the_shelf_is_what_stops_it_being_shelved() {
    let (mut doc, _, _) = one_workspace();
    let declined = doc.workspace(&path("/work/a")).unwrap().bench.clone();
    doc.reset(&path("/work/a"), terminal(), Focus::Take)
        .unwrap();

    doc.unshelve(&path("/work/a"), Focus::Take).unwrap();

    let workspace = doc.workspace(&path("/work/a")).unwrap();
    assert_eq!(workspace.bench, declined);
    assert_eq!(workspace.shelved, None);
    assert_eq!(
        doc.unshelve(&path("/work/a"), Focus::Take),
        Err(Refusal::NothingShelved(path("/work/a")))
    );
}

#[test]
fn an_agent_cannot_answer_the_restore_question_for_the_operator() {
    let (mut doc, _, _) = one_workspace();

    assert_eq!(
        doc.reset(&path("/work/a"), terminal(), Focus::Leave),
        Err(Refusal::WouldMoveFocus),
        "replacing the bench the operator is looking at moves the keyboard"
    );
}

// MARK: - Import and decoding

#[test]
fn an_import_lands_only_in_an_empty_document() {
    let (source, _, _) = one_workspace();
    let mut empty = Document::default();
    empty.import(source.clone()).unwrap();
    assert_eq!(empty, source);

    let (mut live, _, _) = one_workspace();
    assert_eq!(
        live.import(source),
        Err(Refusal::DocumentNotEmpty { workspaces: 1 })
    );
}

#[test]
fn a_document_round_trips_and_refuses_what_no_operation_produces() {
    let (doc, left, _) = one_workspace();
    let json = serde_json::to_value(&doc).unwrap();
    assert_eq!(
        serde_json::from_value::<Document>(json.clone()).unwrap(),
        doc
    );

    let mut twice = json.clone();
    let copy = twice["workspaces"][0].clone();
    twice["workspaces"].as_array_mut().unwrap().push(copy);
    let err = serde_json::from_value::<Document>(twice)
        .unwrap_err()
        .to_string();
    assert!(err.contains("appears twice"), "{err}");

    let mut stray = json.clone();
    stray["active"] = serde_json::json!("/nowhere");
    let err = serde_json::from_value::<Document>(stray)
        .unwrap_err()
        .to_string();
    assert!(err.contains("not open"), "{err}");

    let mut clash = json;
    let mut other = clash["workspaces"][0].clone();
    other["path"] = serde_json::json!("/work/b");
    clash["workspaces"].as_array_mut().unwrap().push(other);
    let err = serde_json::from_value::<Document>(clash)
        .unwrap_err()
        .to_string();
    assert!(
        err.contains(&left[0].to_string()),
        "the duplicated pane is named: {err}"
    );
}
