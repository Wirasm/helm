//! Mirrors `Tests/HelmTests/Workbench/WorkbenchOfferTests.swift` — *appear, don't seize*
//! (helm #125). Swift's `offer`/`select(offering:)` are `Focus::Leave` here, and its
//! `insert`/`select` controls are `Focus::Take`: the controls are what make the Leave tests
//! mean something, because a `place` that ignored its focus argument would pass half of
//! them and fail the other half.

mod common;

use bench_doc::{Bench, Focus, Pane, PaneId, Placement, Refusal, Surface};
use common::*;

fn plan() -> Pane {
    canvas("/tmp/plan.md")
}
fn tasks() -> Pane {
    canvas("/tmp/tasks.md")
}
fn focused_pane(bench: &Bench) -> Option<PaneId> {
    bench.focused_pane().map(|p| p.id)
}

// MARK: - Nothing moves

#[test]
fn a_push_does_not_change_what_the_slot_is_showing() {
    let mut bench = Bench::terminal(PaneId::mint());
    let reading = plan();
    let reading_id = reading.id;
    bench
        .place(reading, Placement::Column, Focus::Take)
        .unwrap();
    let slot = bench.focused_slot();

    bench
        .place(tasks(), Placement::Tab(slot), Focus::Leave)
        .unwrap();

    assert_eq!(
        focused_pane(&bench),
        Some(reading_id),
        "the operator was reading plan.md — a pushed artifact must not replace it"
    );
}

#[test]
fn a_push_does_not_move_bench_focus() {
    let mut bench = Bench::terminal(PaneId::mint());
    let terminal_slot = bench.focused_slot();

    bench
        .place(plan(), Placement::Column, Focus::Leave)
        .unwrap();

    assert_eq!(
        bench.focused_slot(),
        terminal_slot,
        "an agent may not take focus"
    );
}

#[test]
fn a_push_into_a_new_row_does_not_move_focus_either() {
    let mut bench = Bench::terminal(PaneId::mint());
    let terminal_slot = bench.focused_slot();
    let column = bench.columns()[0].id;

    bench
        .place(plan(), Placement::Row(column), Focus::Leave)
        .unwrap();

    assert_eq!(bench.focused_slot(), terminal_slot);
}

// MARK: - But it does appear

#[test]
fn a_pushed_artifact_is_actually_on_the_bench() {
    let mut bench = Bench::terminal(PaneId::mint());
    let pushed = plan();
    let pushed_id = pushed.id;

    bench
        .place(pushed, Placement::Column, Focus::Leave)
        .unwrap();

    assert!(
        bench.pane(pushed_id).is_some(),
        "appear, don't seize — not 'do not appear'"
    );
    assert_eq!(bench.pane_showing(&file("/tmp/plan.md")), Some(pushed_id));
}

#[test]
fn a_pushed_tab_is_reachable_in_the_slot_it_landed_in() {
    let mut bench = Bench::terminal(PaneId::mint());
    bench.place(plan(), Placement::Column, Focus::Take).unwrap();
    let slot = bench.focused_slot();
    let pushed = tasks();
    let pushed_id = pushed.id;

    bench
        .place(pushed, Placement::Tab(slot), Focus::Leave)
        .unwrap();

    assert!(
        bench.pane(pushed_id).is_some(),
        "a tab you cannot reach is hidden, not offered"
    );
}

// MARK: - Already here

#[test]
fn pushing_an_artifact_already_on_the_bench_changes_nothing() {
    let mut bench = Bench::terminal(PaneId::mint());
    bench.place(plan(), Placement::Column, Focus::Take).unwrap();
    let focused = bench.focused_slot();
    bench
        .place(tasks(), Placement::Tab(focused), Focus::Take)
        .unwrap();
    let before = bench.clone();
    let open = bench.pane_showing(&file("/tmp/plan.md")).unwrap();

    bench
        .place(plan(), Placement::Existing(open), Focus::Leave)
        .unwrap();

    assert_eq!(
        bench, before,
        "no second copy, and nothing selected or focused"
    );
}

// MARK: - Sizing

#[test]
fn an_offered_row_takes_an_equal_share_rather_than_half_the_column() {
    let mut bench = Bench::terminal(PaneId::mint());
    let column = bench.columns()[0].id;
    bench
        .place(terminal(), Placement::Row(column), Focus::Leave)
        .unwrap();

    assert_fractions(
        &heights(&bench, 0),
        &[0.5, 0.5],
        "the first spawn splits the column",
    );

    bench
        .place(terminal(), Placement::Row(column), Focus::Leave)
        .unwrap();

    assert_fractions(
        &heights(&bench, 0),
        &[1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0],
        "the second takes a third, not half",
    );
}

#[test]
fn an_offered_column_takes_an_equal_share_too() {
    let mut bench = Bench::terminal(PaneId::mint());
    bench
        .place(plan(), Placement::Column, Focus::Leave)
        .unwrap();

    assert_fractions(
        &widths(&bench),
        &[0.5, 0.5],
        "the first canvas is the dock, at half",
    );

    bench
        .place(tasks(), Placement::Column, Focus::Leave)
        .unwrap();

    assert_fractions(
        &widths(&bench),
        &[1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0],
        "a third each",
    );
}

#[test]
fn an_offered_row_keeps_the_proportions_the_operator_dragged() {
    let mut bench = Bench::terminal(PaneId::mint());
    let column = bench.columns()[0].id;
    bench
        .place(terminal(), Placement::Row(column), Focus::Leave)
        .unwrap();
    let slots: Vec<_> = bench.columns()[0].slots.iter().map(|s| s.id).collect();
    bench.resize_slot(slots[0], 0.8, slots[1]).unwrap();

    bench
        .place(terminal(), Placement::Row(column), Focus::Leave)
        .unwrap();

    let h = heights(&bench, 0);
    assert!(close_to(h[0] / h[1], 4.0, 1e-9), "the two keep their 80/20");
    assert!(close_to(h[2], 1.0 / 3.0, 1e-9));
}

// MARK: - Offered select

#[test]
fn an_offered_select_shows_the_pane_without_moving_bench_focus() {
    let mut bench = Bench::terminal(PaneId::mint());
    let pushed = plan();
    let pushed_id = pushed.id;
    bench
        .place(pushed, Placement::Column, Focus::Leave)
        .unwrap();
    let operators_slot = bench.focused_slot();
    let operators_pane = focused_pane(&bench);

    bench.show(pushed_id, Focus::Leave).unwrap();

    assert!(
        bench.visible_pane_ids().contains(&pushed_id),
        "visible is what show means"
    );
    assert_eq!(
        bench.focused_slot(),
        operators_slot,
        "an agent may not take focus"
    );
    assert_eq!(
        focused_pane(&bench),
        operators_pane,
        "the keyboard stays where it was"
    );
}

#[test]
fn an_offered_select_of_a_pane_the_bench_does_not_have_changes_nothing() {
    let mut bench = Bench::terminal(PaneId::mint());
    let before = bench.clone();
    let stranger = PaneId::mint();

    assert_eq!(
        bench.show(stranger, Focus::Leave),
        Err(Refusal::UnknownPane(stranger))
    );
    assert_eq!(
        bench, before,
        "a uuid the bench does not hold is a refusal, not a repair"
    );
}

// MARK: - The controls

#[test]
fn the_operators_own_tab_click_still_selects_and_focuses() {
    let mut bench = Bench::terminal(PaneId::mint());
    let pushed = plan();
    let pushed_id = pushed.id;
    bench
        .place(pushed, Placement::Column, Focus::Leave)
        .unwrap();
    let operators_slot = bench.focused_slot();

    bench.show(pushed_id, Focus::Take).unwrap();

    assert_eq!(focused_pane(&bench), Some(pushed_id));
    assert_ne!(
        bench.focused_slot(),
        operators_slot,
        "when the operator asks, focus moves"
    );
}

#[test]
fn the_operators_own_open_still_selects_and_focuses() {
    let mut bench = Bench::terminal(PaneId::mint());
    bench.place(plan(), Placement::Column, Focus::Take).unwrap();
    let slot = bench.focused_slot();
    let opened = Pane::new(Surface::file("/tmp/report.md").unwrap());
    let opened_id = opened.id;

    bench
        .place(opened, Placement::Tab(slot), Focus::Take)
        .unwrap();

    assert_eq!(
        focused_pane(&bench),
        Some(opened_id),
        "when the operator asks, seizing is right"
    );
}
