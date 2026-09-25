//! Mirrors `Tests/HelmTests/Workbench/WorkbenchTests.swift`, one test per Swift test, each
//! named after the one it came from. `insert` is `place(…, Focus::Take)`, `offer` is
//! `place(…, Focus::Leave)`, `select` is `show(…, Take)`, `move` is `move_pane(…, Take)`.
//!
//! Where Swift asserted a silent no-op, the port asserts a named refusal **and** an
//! unchanged bench: behind a socket, "ok" about a pane that is gone is a false answer.
//!
//! Not mirrored, deliberately: the four face tests (`testTogglingTheFace…`,
//! `testTheFaceToggleReadsTheSlotsSelectedPaneOnly`, `testAChatFaceDoesNotSurviveEncoding`).
//! The chat face was never persisted and is view state, so it stays in helm, keyed by pane id.

mod common;

use bench_doc::{
    Bench, Direction, Focus, MINIMUM_FRACTION, Pane, PaneId, Placement, Refusal, Slot, SlotId,
    Split, Surface,
};
use common::*;

fn slot_ids(bench: &Bench) -> Vec<SlotId> {
    bench.slots().map(|s| s.id).collect()
}

fn pane_ids(bench: &Bench) -> Vec<PaneId> {
    bench.panes().map(|p| p.id).collect()
}

fn first_slot(bench: &Bench, column: usize) -> &Slot {
    &bench.columns()[column].slots[0]
}

// MARK: - Construction

#[test]
fn the_one_column_one_slot_bench_is_todays_app() {
    let session = PaneId::mint();
    let bench = Bench::terminal(session);

    assert_eq!(bench.columns().len(), 1, "today's frame is one column");
    assert_eq!(bench.columns()[0].slots.len(), 1, "…one slot");
    assert_eq!(pane_ids(&bench), vec![session], "…holding the one terminal");
    assert_eq!(
        first_slot(&bench, 0).selected,
        session,
        "which is that slot's selection"
    );
    assert_eq!(
        bench.focused_slot(),
        first_slot(&bench, 0).id,
        "and the slot commands target"
    );
}

// MARK: - Close

#[test]
fn closing_the_selected_pane_selects_the_neighbour_at_its_position() {
    let panes = vec![terminal(), terminal(), terminal()];
    let id = ids(&panes);
    let mut bench = bench_of(panes, Some(id[1]));

    bench.close(id[1]).unwrap();

    assert_eq!(
        pane_ids(&bench),
        vec![id[0], id[2]],
        "the closed pane is removed"
    );
    assert_eq!(
        first_slot(&bench, 0).selected,
        id[2],
        "selection moves to the neighbour at the closed position"
    );
}

#[test]
fn closing_the_last_position_selects_the_new_last() {
    let panes = vec![terminal(), terminal()];
    let id = ids(&panes);
    let mut bench = bench_of(panes, Some(id[1]));

    bench.close(id[1]).unwrap();

    assert_eq!(first_slot(&bench, 0).selected, id[0]);
}

#[test]
fn closing_an_unselected_pane_keeps_the_selection() {
    let panes = vec![terminal(), terminal()];
    let id = ids(&panes);
    let mut bench = bench_of(panes, Some(id[1]));

    bench.close(id[0]).unwrap();

    assert_eq!(first_slot(&bench, 0).selected, id[1]);
}

#[test]
fn closing_the_last_pane_removes_its_slot() {
    let mut bench = Bench::terminal(PaneId::mint());
    let below = terminal();
    let below_id = below.id;
    bench.split(Split::Down, below, Focus::Take).unwrap();
    assert_eq!(
        bench.columns()[0].slots.len(),
        2,
        "the split gave the column two slots"
    );

    bench.close(below_id).unwrap();

    assert_eq!(
        bench.columns()[0].slots.len(),
        1,
        "emptying a slot removes the slot"
    );
    assert_eq!(bench.columns().len(), 1, "…and leaves its column alone");
}

#[test]
fn closing_the_last_slot_removes_its_column() {
    let mut bench = Bench::terminal(PaneId::mint());
    let right = terminal();
    let right_id = right.id;
    bench.split(Split::Right, right, Focus::Take).unwrap();
    assert_eq!(
        bench.columns().len(),
        2,
        "the split gave the bench two columns"
    );

    bench.close(right_id).unwrap();

    assert_eq!(
        bench.columns().len(),
        1,
        "emptying a column removes the column"
    );
    assert_invariants(&bench, "after a column collapse");
}

#[test]
fn the_last_pane_of_the_bench_refuses_to_close() {
    let only = terminal();
    let only_id = only.id;
    let mut bench = bench_of(vec![only], None);

    assert!(
        !bench.can_close(only_id),
        "the bench's last pane cannot close"
    );
    assert_eq!(
        bench.close(only_id),
        Err(Refusal::LastPane(only_id)),
        "and close says so rather than emptying the bench"
    );
    assert_eq!(
        pane_ids(&bench),
        vec![only_id],
        "…leaving it exactly where it was"
    );
}

#[test]
fn closing_the_focused_slot_moves_focus_to_a_live_neighbour() {
    let mut bench = Bench::terminal(PaneId::mint());
    let below = terminal();
    let below_id = below.id;
    bench.split(Split::Down, below, Focus::Take).unwrap();
    assert_eq!(
        bench.focused_slot(),
        bench.columns()[0].slots[1].id,
        "the split focused it"
    );

    bench.close(below_id).unwrap();

    assert!(
        bench.slot(bench.focused_slot()).is_some(),
        "focus never survives as a dead id"
    );
    assert_eq!(
        bench.focused_slot(),
        first_slot(&bench, 0).id,
        "it moves to the neighbour"
    );
}

// MARK: - Offered splits

#[test]
fn an_offered_split_right_adds_the_column_without_taking_focus() {
    let mut bench = Bench::terminal(PaneId::mint());
    let before = bench.focused_slot();

    bench.split(Split::Right, terminal(), Focus::Leave).unwrap();

    assert_eq!(
        bench.columns().len(),
        2,
        "the column is there — this is not a no-op"
    );
    assert_eq!(
        bench.focused_slot(),
        before,
        "an offered split leaves the keyboard where it was"
    );
    let w = widths(&bench);
    assert!(
        close_to(w[0], w[1], 1e-9),
        "…and still halves the focused column, like ⌘D"
    );
    assert_invariants(&bench, "after an offered split right");
}

#[test]
fn an_offered_split_down_adds_the_row_without_taking_focus() {
    let mut bench = Bench::terminal(PaneId::mint());
    let before = bench.focused_slot();

    bench.split(Split::Down, terminal(), Focus::Leave).unwrap();

    assert_eq!(bench.columns()[0].slots.len(), 2, "the row is there");
    assert_eq!(
        bench.focused_slot(),
        before,
        "and the keyboard did not follow it"
    );
    assert_invariants(&bench, "after an offered split down");
}

#[test]
fn the_operators_split_right_still_takes_focus() {
    let mut bench = Bench::terminal(PaneId::mint());
    let before = bench.focused_slot();

    bench.split(Split::Right, terminal(), Focus::Take).unwrap();

    assert_ne!(
        bench.focused_slot(),
        before,
        "⌘D still focuses the new column"
    );
    assert_eq!(
        bench.focused_slot(),
        first_slot(&bench, 1).id,
        "…the one just made"
    );
}

#[test]
fn the_operators_split_down_still_takes_focus() {
    let mut bench = Bench::terminal(PaneId::mint());
    let before = bench.focused_slot();

    bench.split(Split::Down, terminal(), Focus::Take).unwrap();

    assert_ne!(
        bench.focused_slot(),
        before,
        "⌘⇧D still focuses the new row"
    );
    assert_eq!(bench.focused_slot(), bench.columns()[0].slots[1].id);
}

// MARK: - Focus

#[test]
fn focus_survives_an_insertion_before_it() {
    let mut bench = Bench::terminal(PaneId::mint());
    bench.split(Split::Down, terminal(), Focus::Take).unwrap();
    let focused = bench.focused_slot();
    assert_eq!(slot_ids(&bench).iter().position(|s| *s == focused), Some(1));

    bench.focus_slot(slot_ids(&bench)[0]).unwrap();
    bench.split(Split::Down, terminal(), Focus::Take).unwrap();
    bench.focus_slot(focused).unwrap();

    assert_eq!(
        bench.focused_slot(),
        focused,
        "an id still names the same slot"
    );
    assert_eq!(
        slot_ids(&bench).iter().position(|s| *s == focused),
        Some(2),
        "…whose position has moved, which is exactly why focus is not an index"
    );
}

#[test]
fn moving_focus_off_the_edge_is_a_no_op() {
    let mut bench = Bench::terminal(PaneId::mint());
    bench.split(Split::Right, terminal(), Focus::Take).unwrap();
    let rightmost = bench.focused_slot();

    bench.step_focus(Direction::Right);

    assert_eq!(
        bench.focused_slot(),
        rightmost,
        "nothing to the right; do not wrap"
    );
    bench.step_focus(Direction::Left);
    assert_eq!(
        bench.focused_slot(),
        first_slot(&bench, 0).id,
        "…but left still moves"
    );
}

#[test]
fn moving_focus_sideways_lands_at_the_same_depth_clamped() {
    let mut bench = Bench::terminal(PaneId::mint());
    bench.split(Split::Right, terminal(), Focus::Take).unwrap();
    bench.focus_slot(first_slot(&bench, 0).id).unwrap();
    bench.split(Split::Down, terminal(), Focus::Take).unwrap();
    bench.split(Split::Down, terminal(), Focus::Take).unwrap();

    bench.step_focus(Direction::Right);

    assert_eq!(
        bench.focused_slot(),
        first_slot(&bench, 1).id,
        "a shallower column clamps to its last slot rather than refusing the move"
    );

    bench.step_focus(Direction::Left);

    assert_eq!(
        bench.focused_slot(),
        first_slot(&bench, 0).id,
        "coming back lands at THAT depth — the bench remembers no desired column"
    );
}

// MARK: - Fractions

#[test]
fn column_fractions_stay_summing_to_one_across_insert_and_close() {
    let mut bench = Bench::terminal(PaneId::mint());
    let second = terminal();
    let second_id = second.id;
    bench.split(Split::Right, second, Focus::Take).unwrap();
    assert_eq!(widths(&bench), vec![0.5, 0.5], "a split halves the column");

    bench
        .place(terminal(), Placement::Column, Focus::Take)
        .unwrap();
    assert_invariants(&bench, "after appending a column");

    bench.close(second_id).unwrap();
    assert_invariants(&bench, "after closing a column");
}

#[test]
fn moving_a_divider_leaves_every_other_column_exactly_as_it_was() {
    let mut bench = Bench::terminal(PaneId::mint());
    bench.split(Split::Right, terminal(), Focus::Take).unwrap();
    bench.focus_slot(first_slot(&bench, 0).id).unwrap();
    bench.split(Split::Right, terminal(), Focus::Take).unwrap();
    assert_eq!(widths(&bench), vec![0.25, 0.25, 0.5]);
    let untouched = widths(&bench)[2];
    let c: Vec<_> = bench.columns().iter().map(|c| c.id).collect();

    bench.resize_column(c[0], 0.4, c[1]).unwrap();

    let w = widths(&bench);
    assert!(close_to(w[0], 0.4, 1e-9), "the dragged column obeys");
    assert!(
        close_to(w[1], 0.1, 1e-9),
        "its neighbour absorbs the whole difference"
    );
    assert!(
        close_to(w[2], untouched, 1e-12),
        "the column the divider does not touch is not touched"
    );
    assert!(close_to(w.iter().sum(), 1.0, 1e-9));
}

#[test]
fn a_divider_dragged_past_its_neighbour_leaves_a_sliver() {
    let mut bench = Bench::terminal(PaneId::mint());
    bench.split(Split::Right, terminal(), Focus::Take).unwrap();
    let c: Vec<_> = bench.columns().iter().map(|c| c.id).collect();

    bench.resize_column(c[0], 0.0, c[1]).unwrap();

    assert!(
        widths(&bench)[0] >= MINIMUM_FRACTION,
        "a sliver you can grab again"
    );
    assert_invariants(&bench, "after an extreme resize");
}

#[test]
fn a_divider_dragged_the_other_way_leaves_its_neighbour_a_sliver() {
    let mut bench = Bench::terminal(PaneId::mint());
    bench.split(Split::Right, terminal(), Focus::Take).unwrap();
    let c: Vec<_> = bench.columns().iter().map(|c| c.id).collect();

    bench.resize_column(c[0], 1.0, c[1]).unwrap();

    assert!(
        widths(&bench)[1] >= MINIMUM_FRACTION,
        "the clamp holds at both ends"
    );
    assert_invariants(&bench, "after an extreme resize the other way");
}

#[test]
fn a_resize_against_an_id_nobody_holds_moves_nothing() {
    let mut bench = Bench::terminal(PaneId::mint());
    bench.split(Split::Right, terminal(), Focus::Take).unwrap();
    let before = bench.clone();
    let c: Vec<_> = bench.columns().iter().map(|c| c.id).collect();
    let stranger = bench_doc::ColumnId::mint();

    assert_eq!(
        bench.resize_column(c[0], 0.9, stranger),
        Err(Refusal::UnknownColumn(stranger))
    );
    assert_eq!(
        bench.resize_column(stranger, 0.9, c[1]),
        Err(Refusal::UnknownColumn(stranger))
    );
    assert_eq!(bench, before, "neither end of a dead pair moves");
}

#[test]
fn a_slot_resize_against_an_id_nobody_holds_moves_nothing() {
    let mut bench = Bench::terminal(PaneId::mint());
    bench.split(Split::Down, terminal(), Focus::Take).unwrap();
    let before = bench.clone();
    let stranger = SlotId::mint();

    assert_eq!(
        bench.resize_slot(first_slot(&bench, 0).id, 0.9, stranger),
        Err(Refusal::UnknownSlot(stranger))
    );
    assert_eq!(bench, before);
}

#[test]
fn columns_with_a_column_between_them_are_not_a_divider() {
    let mut bench = Bench::terminal(PaneId::mint());
    bench.split(Split::Right, terminal(), Focus::Take).unwrap();
    bench.focus_slot(first_slot(&bench, 0).id).unwrap();
    bench.split(Split::Right, terminal(), Focus::Take).unwrap();
    assert_eq!(bench.columns().len(), 3);
    let before = bench.clone();
    let c: Vec<_> = bench.columns().iter().map(|c| c.id).collect();

    assert_eq!(
        bench.resize_column(c[0], 0.6, c[2]),
        Err(Refusal::NotADivider)
    );
    assert_eq!(bench, before, "a gap is not a divider");
}

#[test]
fn slots_with_a_slot_between_them_are_not_a_divider() {
    let mut bench = Bench::terminal(PaneId::mint());
    bench.split(Split::Down, terminal(), Focus::Take).unwrap();
    bench.split(Split::Down, terminal(), Focus::Take).unwrap();
    assert_eq!(bench.columns()[0].slots.len(), 3);
    let before = bench.clone();
    let s = slot_ids(&bench);

    assert_eq!(
        bench.resize_slot(s[0], 0.6, s[2]),
        Err(Refusal::NotADivider)
    );
    assert_eq!(bench, before);
}

#[test]
fn a_member_cannot_trade_with_itself() {
    let mut bench = Bench::terminal(PaneId::mint());
    bench.split(Split::Right, terminal(), Focus::Take).unwrap();
    let before = bench.clone();
    let c = bench.columns()[0].id;

    assert_eq!(bench.resize_column(c, 0.9, c), Err(Refusal::NotADivider));
    assert_eq!(bench, before);
}

#[test]
fn a_slot_divider_refuses_a_pair_from_two_different_columns() {
    let mut bench = Bench::terminal(PaneId::mint());
    bench.split(Split::Down, terminal(), Focus::Take).unwrap();
    let elsewhere = terminal();
    let elsewhere_id = elsewhere.id;
    bench
        .place(elsewhere, Placement::Column, Focus::Take)
        .unwrap();
    let before = bench.clone();
    let stranger = bench.slot_for(elsewhere_id).unwrap().id;

    assert_eq!(
        bench.resize_slot(first_slot(&bench, 0).id, 0.9, stranger),
        Err(Refusal::NotADivider)
    );
    assert_eq!(bench, before, "nothing moved");
}

// MARK: - Select

#[test]
fn selecting_a_pane_the_bench_does_not_hold_is_a_no_op() {
    let mut bench = Bench::terminal(PaneId::mint());
    let before = bench.clone();
    let stranger = PaneId::mint();

    assert_eq!(
        bench.show(stranger, Focus::Take),
        Err(Refusal::UnknownPane(stranger))
    );
    assert_eq!(bench, before, "an unknown pane id changes nothing");
}

#[test]
fn selecting_a_tab_also_focuses_its_slot() {
    let mut bench = Bench::terminal(PaneId::mint());
    bench.split(Split::Right, terminal(), Focus::Take).unwrap();
    let first_column_pane = first_slot(&bench, 0).panes[0].id;

    bench.show(first_column_pane, Focus::Take).unwrap();

    assert_eq!(
        bench.focused_slot(),
        first_slot(&bench, 0).id,
        "clicking a tab is also saying which pane commands mean now"
    );
}

#[test]
fn visible_panes_are_one_per_slot() {
    let tabs = vec![terminal(), terminal()];
    let t = ids(&tabs);
    let mut bench = bench_of(tabs, Some(t[0]));
    let other = terminal();
    let other_id = other.id;
    bench.split(Split::Right, other, Focus::Take).unwrap();

    assert_eq!(
        bench.visible_pane_ids(),
        vec![t[0], other_id],
        "several on screen at once"
    );
}

// MARK: - The invariants hold after everything

#[test]
fn every_mutation_leaves_the_invariants_intact() {
    let first = PaneId::mint();
    let mut bench = Bench::terminal(first);
    let (second, third, page, fourth) =
        (terminal(), terminal(), canvas("/tmp/notes.md"), terminal());
    let (second_id, third_id, page_id) = (second.id, third.id, page.id);

    assert_invariants(&bench, "the starting bench");
    bench.split(Split::Right, second, Focus::Take).unwrap();
    assert_invariants(&bench, "split right");
    bench.split(Split::Down, third, Focus::Take).unwrap();
    assert_invariants(&bench, "split down");
    let focused = bench.focused_slot();
    bench
        .place(page, Placement::Tab(focused), Focus::Take)
        .unwrap();
    assert_invariants(&bench, "insert tab");
    let column = bench.columns()[0].id;
    bench
        .place(fourth, Placement::Row(column), Focus::Take)
        .unwrap();
    assert_invariants(&bench, "insert row");
    bench
        .place(terminal(), Placement::Column, Focus::Take)
        .unwrap();
    assert_invariants(&bench, "insert column");
    bench.step_focus(Direction::Up);
    assert_invariants(&bench, "step focus up");
    bench.step_focus(Direction::Left);
    assert_invariants(&bench, "step focus left");
    bench.show(page_id, Focus::Take).unwrap();
    assert_invariants(&bench, "select");
    let c: Vec<_> = bench.columns().iter().map(|c| c.id).collect();
    bench.resize_column(c[0], 0.7, c[1]).unwrap();
    assert_invariants(&bench, "resize column");
    let s: Vec<_> = bench.columns()[0].slots.iter().map(|s| s.id).collect();
    if s.len() > 1 {
        bench.resize_slot(s[0], 0.9, s[1]).unwrap();
    }
    assert_invariants(&bench, "resize slot");
    for (name, id) in [
        ("close a canvas", page_id),
        ("close a terminal", third_id),
        ("close another", second_id),
        ("close the first", first),
    ] {
        bench.close(id).unwrap();
        assert_invariants(&bench, name);
    }
}

// MARK: - Codable

#[test]
fn codable_round_trips_every_pane_kind() {
    let mut bench = Bench::terminal(PaneId::mint());
    bench
        .place(canvas("/tmp/plan.md"), Placement::Column, Focus::Take)
        .unwrap();
    let focused = bench.focused_slot();
    bench
        .place(
            canvas("/tmp/tasks.md"),
            Placement::Tab(focused),
            Focus::Take,
        )
        .unwrap();
    let column = bench.columns()[0].id;
    bench
        .place(canvas("/tmp/notes.md"), Placement::Row(column), Focus::Take)
        .unwrap();
    bench
        .place(Pane::new(Surface::Browser), Placement::Column, Focus::Take)
        .unwrap();
    let c: Vec<_> = bench.columns().iter().map(|c| c.id).collect();
    bench.resize_column(c[0], 0.7, c[1]).unwrap();

    let restored: Bench = serde_json::from_str(&serde_json::to_string(&bench).unwrap()).unwrap();

    assert_eq!(restored, bench, "a bench round-trips whole, sizes and all");
}

#[test]
fn the_encoded_shape_uses_named_discriminators() {
    let mut bench = Bench::terminal(PaneId::mint());
    bench
        .place(canvas("/tmp/plan.md"), Placement::Column, Focus::Take)
        .unwrap();

    let json = serde_json::to_string(&bench).unwrap();

    assert!(json.contains(r#""kind":"terminal""#), "{json}");
    assert!(json.contains(r#""kind":"canvas""#), "{json}");
    assert!(json.contains(r#""kind":"file""#), "{json}");
    assert!(json.contains(r#""path":"/tmp/plan.md""#), "{json}");
}

#[test]
fn a_bench_with_no_panes_does_not_decode() {
    let empty = format!(r#"{{"columns":[],"focused_slot":"{}"}}"#, SlotId::mint());

    let err = serde_json::from_str::<Bench>(&empty)
        .unwrap_err()
        .to_string();

    assert!(
        err.contains("no panes"),
        "nothing to render, nothing to invent: {err}"
    );
}

#[test]
fn a_decoded_bench_is_normalised() {
    let (pane, slot) = (PaneId::mint(), SlotId::mint());
    let json = format!(
        r#"{{"columns":[{{"id":"{}","width":9,"slots":[
            {{"id":"{slot}","height":4,"selected":"{}",
              "panes":[{{"id":"{pane}","surface":{{"kind":"terminal"}}}}]}}]}}],
           "focused_slot":"{}"}}"#,
        bench_doc::ColumnId::mint(),
        PaneId::mint(),
        SlotId::mint()
    );

    let bench: Bench = serde_json::from_str(&json).unwrap();

    assert!(
        close_to(widths(&bench)[0], 1.0, 1e-9),
        "widths are rebalanced"
    );
    assert!(close_to(heights(&bench, 0)[0], 1.0, 1e-9), "and heights");
    assert_eq!(
        first_slot(&bench, 0).selected,
        pane,
        "selection is repaired"
    );
    assert_eq!(bench.focused_slot(), slot, "so is focus");
}

// MARK: - WorkbenchRestoreTests, value half

/// `testTwoRelaunchesDoNotMoveASingleFraction`: a dragged bench survives two
/// encode/decode round trips with every fraction exactly as it went out — the file is the
/// layout, so `normalize()` on the way back in must be a fixed point.
#[test]
fn two_relaunches_do_not_move_a_single_fraction() {
    let mut bench = Bench::terminal(PaneId::mint());
    bench.split(Split::Right, terminal(), Focus::Take).unwrap();
    bench.focus_slot(first_slot(&bench, 0).id).unwrap();
    bench.split(Split::Down, terminal(), Focus::Take).unwrap();
    bench
        .place(terminal(), Placement::Column, Focus::Take)
        .unwrap();
    let c: Vec<_> = bench.columns().iter().map(|c| c.id).collect();
    bench.resize_column(c[0], 0.3349, c[1]).unwrap();
    bench.resize_column(c[2], 0.1901, c[1]).unwrap();
    let s: Vec<_> = bench.columns()[0].slots.iter().map(|s| s.id).collect();
    bench.resize_slot(s[0], 0.4986, s[1]).unwrap();
    let rounded = |v: Vec<f64>| v.iter().map(|f| (f * 10000.0).round()).collect::<Vec<_>>();
    assert_eq!(rounded(widths(&bench)), vec![3349.0, 4750.0, 1901.0]);
    assert_eq!(rounded(heights(&bench, 0)), vec![4986.0, 5014.0]);

    let mut restored = bench.clone();
    for launch in 1..=2 {
        restored = serde_json::from_str(&serde_json::to_string(&restored).unwrap()).unwrap();
        assert_eq!(
            widths(&restored),
            widths(&bench),
            "launch {launch}: widths exact"
        );
        assert_eq!(
            heights(&restored, 0),
            heights(&bench, 0),
            "launch {launch}: heights exact"
        );
    }
    assert_eq!(restored, bench, "the whole bench, not only its geometry");
}
