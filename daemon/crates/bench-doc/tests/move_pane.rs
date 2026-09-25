//! Mirrors the value tests of `Tests/HelmTests/Workbench/WorkbenchMoveTests.swift` — the
//! pane move (#287), whose geometry is its own inverse and whose keyboard follows the pane
//! for the operator. The keystroke suite beside it (`MovePaneKeystrokeTests`) is helm's
//! keymap and stays in Swift.
//!
//! One test is new: `move_with_leave_keeps_focus_and_every_selection`. helm's `move` had no
//! agent form (its header explains why); the port gives it one, and this is its proof.

mod common;

use bench_doc::{Bench, Direction, Focus, PaneId, Refusal, Split};
use common::*;
use std::collections::HashSet;

type Shape = Vec<Vec<Vec<PaneId>>>;

fn position(pane: PaneId, bench: &Bench) -> Option<[usize; 2]> {
    for (c, column) in bench.columns().iter().enumerate() {
        for (d, slot) in column.slots.iter().enumerate() {
            if slot.panes.iter().any(|p| p.id == pane) {
                return Some([c, d]);
            }
        }
    }
    None
}

fn shape(bench: &Bench) -> Shape {
    bench
        .columns()
        .iter()
        .map(|c| {
            c.slots
                .iter()
                .map(|s| s.panes.iter().map(|p| p.id).collect())
                .collect()
        })
        .collect()
}

/// The operator's 2+1 bench: two rows on the left, one column on the right.
fn two_plus_one() -> (Bench, [PaneId; 2], PaneId) {
    let left = [terminal(), terminal()];
    let right = terminal();
    let ids = (left[0].id, left[1].id, right.id);
    let [l0, l1] = left;
    let mut bench = bench_of(vec![l0], None);
    bench.split(Split::Right, right, Focus::Take).unwrap();
    bench.focus_slot(bench.columns()[0].slots[0].id).unwrap();
    bench.split(Split::Down, l1, Focus::Take).unwrap();
    (bench, [ids.0, ids.1], ids.2)
}

fn mv(bench: &mut Bench, pane: PaneId, direction: Direction) -> bool {
    bench.move_pane(pane, direction, Focus::Take).unwrap()
}

#[test]
fn a_sole_occupant_carries_its_slot_to_the_adjacent_column_at_the_same_depth() {
    let (start, left, right) = two_plus_one();
    let mut bench = start.clone();
    assert_eq!(
        position(left[1], &bench),
        Some([0, 1]),
        "the lower-left pane"
    );

    assert!(
        mv(&mut bench, left[1], Direction::Right),
        "there is a column to the right"
    );

    assert_eq!(
        position(left[1], &bench),
        Some([1, 1]),
        "same depth, next column"
    );
    assert_eq!(
        shape(&bench),
        vec![vec![vec![left[0]]], vec![vec![right], vec![left[1]]]]
    );

    mv(&mut bench, left[1], Direction::Left);

    assert_eq!(shape(&bench), shape(&start), "a move is its own inverse");
}

#[test]
fn a_sole_occupant_moving_vertically_reorders_the_column() {
    let (start, left, _) = two_plus_one();
    let mut bench = start;

    assert!(mv(&mut bench, left[0], Direction::Down));

    assert_eq!(
        shape(&bench)[0],
        vec![vec![left[1]], vec![left[0]]],
        "the rows traded"
    );
    assert_eq!(
        bench.columns()[0].slots.len(),
        2,
        "…so the column still has two rows"
    );
}

#[test]
fn a_reorder_leaves_the_rows_the_heights_the_operator_dragged_them_to() {
    let (start, left, _) = two_plus_one();
    let mut bench = start;
    let slots: Vec<_> = bench.columns()[0].slots.iter().map(|s| s.id).collect();
    bench.resize_slot(slots[0], 0.8, slots[1]).unwrap();
    let dragged = heights(&bench, 0);
    assert!(close_to(dragged[0], 0.8, 1e-9), "the drag landed");

    mv(&mut bench, left[0], Direction::Down);

    assert_eq!(heights(&bench, 0), dragged, "positions keep their heights");
    assert_eq!(shape(&bench)[0][0], vec![left[1]]);
}

#[test]
fn a_tabbed_pane_joins_the_destination_slot_as_a_tab() {
    let tabs = [terminal(), terminal()];
    let t = [tabs[0].id, tabs[1].id];
    let right = terminal();
    let right_id = right.id;
    let mut bench = bench_of(tabs.into(), Some(t[0]));
    bench.split(Split::Right, right, Focus::Take).unwrap();

    assert!(mv(&mut bench, t[1], Direction::Right));

    assert_eq!(
        shape(&bench),
        vec![vec![vec![t[0]]], vec![vec![right_id, t[1]]]]
    );
}

#[test]
fn the_slot_a_pane_leaves_shows_the_neighbour_at_that_position() {
    let tabs = [terminal(), terminal(), terminal()];
    let t = [tabs[0].id, tabs[1].id, tabs[2].id];
    let mut bench = bench_of(tabs.into(), Some(t[1]));
    bench.split(Split::Right, terminal(), Focus::Take).unwrap();

    mv(&mut bench, t[1], Direction::Right);

    assert_eq!(
        bench.columns()[0].slots[0].selected,
        t[2],
        "what close would have shown"
    );
}

#[test]
fn a_column_emptied_by_a_move_goes_exactly_as_a_column_emptied_by_a_close_does() {
    let (start, left, right) = two_plus_one();
    let mut moved = start.clone();
    mv(&mut moved, right, Direction::Left);
    let mut closed = start;
    closed.close(right).unwrap();

    assert_eq!(
        moved.columns().len(),
        1,
        "the right column had one pane and it left"
    );
    assert_eq!(moved.columns().len(), closed.columns().len());
    assert_eq!(moved.columns()[0].width, closed.columns()[0].width);
    assert_eq!(
        moved.panes().map(|p| p.id).collect::<HashSet<_>>(),
        HashSet::from([left[0], left[1], right]),
        "nothing lost"
    );
}

#[test]
fn a_move_off_the_end_of_the_bench_gives_the_pane_a_column_of_its_own() {
    let (start, _, right) = two_plus_one();
    let mut bench = start.clone();
    mv(&mut bench, right, Direction::Left);
    assert_eq!(
        bench.columns().len(),
        1,
        "the bench collapsed to one column"
    );

    assert!(
        mv(&mut bench, right, Direction::Right),
        "and the move back is available"
    );

    assert_eq!(
        shape(&bench),
        shape(&start),
        "the edge rule is what makes it reversible"
    );
}

#[test]
fn a_tab_at_the_end_of_its_column_leaves_for_a_row_of_its_own() {
    let tabs = [terminal(), terminal()];
    let t = [tabs[0].id, tabs[1].id];
    let mut bench = bench_of(tabs.into(), Some(t[0]));

    assert!(mv(&mut bench, t[0], Direction::Down));

    assert_eq!(shape(&bench), vec![vec![vec![t[1]], vec![t[0]]]]);
}

#[test]
fn a_pane_alone_in_the_last_column_cannot_churn_its_way_sideways() {
    let only = PaneId::mint();
    let mut bench = Bench::terminal(only);
    let before = bench.clone();

    for direction in [
        Direction::Right,
        Direction::Left,
        Direction::Down,
        Direction::Up,
    ] {
        assert!(
            !mv(&mut bench, only, direction),
            "{direction:?}: nothing to leave"
        );
    }
    assert_eq!(bench, before, "and the bench is untouched, not rebuilt");
}

#[test]
fn the_last_columns_only_pane_stays_where_it_is() {
    let (start, _, right) = two_plus_one();
    let mut bench = start.clone();

    assert!(
        !mv(&mut bench, right, Direction::Right),
        "already a column at that end"
    );
    assert_eq!(bench, start);
}

#[test]
fn moving_a_pane_the_bench_does_not_hold_reports_that_it_did_not() {
    let mut bench = Bench::terminal(PaneId::mint());
    let before = bench.clone();
    let stranger = PaneId::mint();

    assert_eq!(
        bench.move_pane(stranger, Direction::Right, Focus::Take),
        Err(Refusal::UnknownPane(stranger))
    );
    assert_eq!(bench, before);
}

#[test]
fn every_direction_actually_relocates_the_pane_a_control() {
    let (start, left, right) = two_plus_one();
    for (direction, pane, from) in [
        (Direction::Right, left[1], [0, 1]),
        (Direction::Left, right, [1, 0]),
        (Direction::Up, left[1], [0, 1]),
        (Direction::Down, left[0], [0, 0]),
    ] {
        let mut bench = start.clone();
        assert_eq!(
            position(pane, &bench),
            Some(from),
            "{direction:?} starts here"
        );
        assert!(
            mv(&mut bench, pane, direction),
            "{direction:?} reported that it moved"
        );
        assert_ne!(position(pane, &bench), Some(from), "{direction:?} moved it");
        assert_ne!(
            shape(&bench),
            shape(&start),
            "…and the bench is a different bench"
        );
    }
}

#[test]
fn a_move_never_loses_or_duplicates_a_pane_a_control() {
    let (start, _, _) = two_plus_one();
    let expected: HashSet<_> = start.panes().map(|p| p.id).collect();
    for direction in [
        Direction::Left,
        Direction::Right,
        Direction::Up,
        Direction::Down,
    ] {
        for pane in &expected {
            let mut bench = start.clone();
            mv(&mut bench, *pane, direction);
            assert_eq!(
                bench.panes().map(|p| p.id).collect::<HashSet<_>>(),
                expected
            );
            assert_eq!(
                bench.panes().count(),
                expected.len(),
                "…or left a duplicate"
            );
        }
    }
}

#[test]
fn the_operators_keyboard_travels_with_the_pane_it_moved() {
    let tabs = [terminal(), terminal()];
    let t = [tabs[0].id, tabs[1].id];
    let mut bench = bench_of(tabs.into(), Some(t[1]));
    bench.split(Split::Right, terminal(), Focus::Take).unwrap();
    bench.show(t[1], Focus::Take).unwrap();
    let vacated = bench.focused_slot();

    mv(&mut bench, t[1], Direction::Right);

    assert_ne!(
        bench.focused_slot(),
        vacated,
        "the keyboard did not stay behind"
    );
    assert_eq!(
        bench.focused_pane().map(|p| p.id),
        Some(t[1]),
        "it went with the pane"
    );
}

#[test]
fn focus_stays_with_the_slot_that_travelled() {
    let (start, _, right) = two_plus_one();
    let mut bench = start;
    bench.show(right, Focus::Take).unwrap();
    let slot = bench.focused_slot();

    mv(&mut bench, right, Direction::Left);

    assert_eq!(
        bench.focused_slot(),
        slot,
        "the same slot, now in the other column"
    );
    assert_eq!(bench.focused_pane().map(|p| p.id), Some(right));
}

#[test]
fn the_keyboard_lands_on_the_moved_pane_whichever_branch_ran() {
    let (start, left, right) = two_plus_one();
    for (label, pane, direction, anchor) in [
        (
            "a slot relocating sideways",
            left[1],
            Direction::Right,
            right,
        ),
        ("a slot reordering", left[0], Direction::Down, left[1]),
        (
            "a pane leaving for a column of its own",
            right,
            Direction::Left,
            left[0],
        ),
    ] {
        let mut bench = start.clone();
        assert_ne!(
            anchor, pane,
            "{label}: the anchor must not be the pane moved"
        );
        bench.show(anchor, Focus::Take).unwrap();
        mv(&mut bench, pane, direction);
        assert_eq!(bench.focused_pane().map(|p| p.id), Some(pane), "{label}");
    }
}

#[test]
fn every_branch_of_a_move_leaves_the_invariants_intact() {
    let (start, left, right) = two_plus_one();
    let mut bench = start;
    assert_invariants(&bench, "the starting bench");
    mv(&mut bench, left[1], Direction::Right);
    assert_invariants(&bench, "sideways, sole occupant");
    mv(&mut bench, left[0], Direction::Down);
    assert_invariants(&bench, "vertical, reorder");
    mv(&mut bench, right, Direction::Left);
    assert_invariants(&bench, "off the end of the bench");
    mv(&mut bench, right, Direction::Right);
    assert_invariants(&bench, "back off the end again");
    let tab = bench.columns()[0].slots[0].panes[0].id;
    mv(&mut bench, tab, Direction::Right);
    assert_invariants(&bench, "a tab out of its slot");
    let first = bench.panes().next().unwrap().id;
    mv(&mut bench, first, Direction::Down);
    assert_invariants(&bench, "off the end of a column");
    let first = bench.panes().next().unwrap().id;
    mv(&mut bench, first, Direction::Up);
    assert_invariants(&bench, "into a wall");
}

// MARK: - New: the agent's move

/// An agent moving a pane (#287) rearranges the bench and takes nothing: focus and every
/// slot's selection stay exactly where the operator left them, on every branch.
#[test]
fn move_with_leave_keeps_focus_and_every_selection() {
    let (start, left, right) = two_plus_one();
    for (label, pane, direction) in [
        ("sideways, sole occupant", left[1], Direction::Right),
        ("vertical, reorder", left[0], Direction::Down),
        ("off the end of the bench", right, Direction::Left),
    ] {
        let mut bench = start.clone();
        bench.show(left[0], Focus::Take).unwrap();
        let focused_slot = bench.focused_slot();
        let focused_pane = bench.focused_pane().map(|p| p.id);
        let selections: HashSet<_> = bench.visible_pane_ids().into_iter().collect();

        assert!(
            bench.move_pane(pane, direction, Focus::Leave).unwrap(),
            "{label}: moved"
        );

        assert_eq!(
            bench.focused_slot(),
            focused_slot,
            "{label}: focus did not move"
        );
        assert_eq!(
            bench.focused_pane().map(|p| p.id),
            focused_pane,
            "{label}: nor the keyboard"
        );
        assert_eq!(
            bench.visible_pane_ids().into_iter().collect::<HashSet<_>>(),
            selections,
            "{label}: every slot shows what it showed"
        );
        assert_invariants(&bench, label);
    }
}
