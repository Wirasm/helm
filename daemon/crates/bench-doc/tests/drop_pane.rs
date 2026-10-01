//! The two places a pane can be dropped (#178): into a slot as a tab (`move_pane_to_tab`), and
//! beside a slot (`move_pane_beside`). helm resolves where the pointer is; these are the rules
//! for what happens there, and a file dropped from Finder opening at one (`open_at`). The
//! keyboard's step move is `move_pane.rs`.

mod common;

use bench_doc::{Bench, Direction, Focus, PaneId, Place, Refusal, SlotId, Split};
use common::*;
use std::collections::HashSet;

type Shape = Vec<Vec<Vec<PaneId>>>;

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

fn slot(bench: &Bench, column: usize, depth: usize) -> SlotId {
    bench.columns()[column].slots[depth].id
}

/// Two columns: three tabs on the left, one pane on the right.
fn tabs_and_one() -> (Bench, [PaneId; 3], PaneId) {
    let tabs = [terminal(), terminal(), terminal()];
    let t = [tabs[0].id, tabs[1].id, tabs[2].id];
    let right = terminal();
    let r = right.id;
    let mut bench = bench_of(tabs.into(), Some(t[0]));
    bench.split(Split::Right, right, Focus::Take).unwrap();
    (bench, t, r)
}

// MARK: - As a tab

#[test]
fn a_tab_dropped_on_another_slot_joins_it_last_and_takes_the_keyboard() {
    let (mut bench, t, r) = tabs_and_one();
    let right = slot(&bench, 1, 0);

    assert!(
        bench
            .move_pane_to_tab(t[1], right, None, Focus::Take)
            .unwrap()
    );

    assert_eq!(
        shape(&bench),
        vec![vec![vec![t[0], t[2]]], vec![vec![r, t[1]]]]
    );
    assert_eq!(bench.focused_pane().map(|p| p.id), Some(t[1]));
    assert_invariants(&bench, "a tab into another slot");
}

#[test]
fn a_tab_dropped_before_a_tab_lands_in_that_gap() {
    let (mut bench, t, r) = tabs_and_one();
    let right = slot(&bench, 1, 0);

    assert!(
        bench
            .move_pane_to_tab(t[2], right, Some(r), Focus::Take)
            .unwrap()
    );

    assert_eq!(shape(&bench)[1], vec![vec![t[2], r]]);
}

#[test]
fn a_drop_inside_its_own_strip_reorders_and_keeps_what_the_slot_shows() {
    let (mut bench, t, _) = tabs_and_one();
    let left = slot(&bench, 0, 0);
    bench.show(t[1], Focus::Take).unwrap();

    assert!(
        bench
            .move_pane_to_tab(t[2], left, Some(t[0]), Focus::Leave)
            .unwrap()
    );
    assert_eq!(shape(&bench)[0], vec![vec![t[2], t[0], t[1]]]);
    assert_eq!(
        bench.columns()[0].slots[0].selected,
        t[1],
        "a reorder by someone else leaves the slot showing what it showed"
    );

    assert!(
        bench
            .move_pane_to_tab(t[2], left, None, Focus::Take)
            .unwrap()
    );
    assert_eq!(shape(&bench)[0], vec![vec![t[0], t[1], t[2]]], "to the end");
}

#[test]
fn a_drop_where_the_tab_already_is_changes_nothing() {
    let (start, t, _) = tabs_and_one();
    let left = slot(&start, 0, 0);
    for (label, before) in [
        ("before itself", Some(t[1])),
        ("before the tab after it", Some(t[2])),
    ] {
        let mut bench = start.clone();
        assert!(
            !bench
                .move_pane_to_tab(t[1], left, before, Focus::Take)
                .unwrap(),
            "{label}"
        );
        assert_eq!(bench, start, "{label}: untouched");
    }
    let mut bench = start.clone();
    assert!(
        !bench
            .move_pane_to_tab(t[2], left, None, Focus::Take)
            .unwrap(),
        "the last tab to the end"
    );
}

#[test]
fn the_last_pane_out_of_a_slot_collapses_its_column() {
    let (mut bench, t, r) = tabs_and_one();
    let left = slot(&bench, 0, 0);

    assert!(
        bench
            .move_pane_to_tab(r, left, Some(t[1]), Focus::Take)
            .unwrap()
    );

    assert_eq!(shape(&bench), vec![vec![vec![t[0], r, t[1], t[2]]]]);
    assert_invariants(&bench, "a column emptied by a drop");
}

#[test]
fn a_tab_drop_naming_what_the_slot_does_not_hold_is_refused_untouched() {
    let (start, t, r) = tabs_and_one();
    let right = slot(&start, 1, 0);
    let mut bench = start.clone();

    assert_eq!(
        bench.move_pane_to_tab(t[0], right, Some(t[1]), Focus::Take),
        Err(Refusal::NotInSlot {
            pane: t[1],
            slot: right
        })
    );
    let nowhere = SlotId::mint();
    assert_eq!(
        bench.move_pane_to_tab(t[0], nowhere, None, Focus::Take),
        Err(Refusal::UnknownSlot(nowhere))
    );
    assert_eq!(
        bench.move_pane_beside(r, nowhere, Direction::Up, Focus::Take),
        Err(Refusal::UnknownSlot(nowhere))
    );
    assert_eq!(bench, start);
}

// MARK: - Beside a slot

#[test]
fn a_tab_dropped_on_its_own_slots_edges_becomes_a_pane_of_its_own() {
    let (start, t, r) = tabs_and_one();
    let left = slot(&start, 0, 0);
    let cases: [(Direction, Shape); 4] = [
        (
            Direction::Up,
            vec![vec![vec![t[1]], vec![t[0], t[2]]], vec![vec![r]]],
        ),
        (
            Direction::Down,
            vec![vec![vec![t[0], t[2]], vec![t[1]]], vec![vec![r]]],
        ),
        (
            Direction::Left,
            vec![vec![vec![t[1]]], vec![vec![t[0], t[2]]], vec![vec![r]]],
        ),
        (
            Direction::Right,
            vec![vec![vec![t[0], t[2]]], vec![vec![t[1]]], vec![vec![r]]],
        ),
    ];
    for (side, expected) in cases {
        let mut bench = start.clone();
        assert!(
            bench
                .move_pane_beside(t[1], left, side, Focus::Take)
                .unwrap()
        );
        assert_eq!(shape(&bench), expected, "{side:?}");
        assert_eq!(bench.focused_pane().map(|p| p.id), Some(t[1]), "{side:?}");
        assert_invariants(&bench, &format!("promoted {side:?}"));
    }
}

#[test]
fn a_pane_dropped_beside_another_slot_splits_beside_it() {
    let (start, t, r) = tabs_and_one();
    let right = slot(&start, 1, 0);

    let mut bench = start.clone();
    assert!(
        bench
            .move_pane_beside(t[0], right, Direction::Down, Focus::Take)
            .unwrap()
    );
    assert_eq!(shape(&bench)[1], vec![vec![r], vec![t[0]]]);
    assert!(
        close_to(heights(&bench, 1)[1], 0.5, 1e-9),
        "the newcomer takes an equal share"
    );

    let mut bench = start.clone();
    assert!(
        bench
            .move_pane_beside(r, slot(&start, 0, 0), Direction::Left, Focus::Take)
            .unwrap()
    );
    assert_eq!(
        shape(&bench),
        vec![vec![vec![r]], vec![vec![t[0], t[1], t[2]]]]
    );
}

#[test]
fn a_lone_pane_against_its_own_slot_moves_only_when_it_can_leave_its_column() {
    let (start, _, r) = tabs_and_one();
    let own = slot(&start, 1, 0);
    for side in [
        Direction::Up,
        Direction::Down,
        Direction::Left,
        Direction::Right,
    ] {
        let mut bench = start.clone();
        assert!(
            !bench.move_pane_beside(r, own, side, Focus::Take).unwrap(),
            "{side:?}: it is the only thing in its column"
        );
        assert_eq!(bench, start, "{side:?}: untouched");
    }

    // With a row above it, sideways takes the slot out into a column of its own.
    let (mut bench, t, r) = tabs_and_one();
    bench
        .move_pane_beside(t[0], slot(&bench, 1, 0), Direction::Up, Focus::Take)
        .unwrap();
    let own = bench.slot_for(r).unwrap().id;
    assert!(
        bench
            .move_pane_beside(r, own, Direction::Right, Focus::Take)
            .unwrap()
    );
    assert_eq!(
        shape(&bench),
        vec![vec![vec![t[1], t[2]]], vec![vec![t[0]]], vec![vec![r]]]
    );
}

#[test]
fn a_drop_by_someone_else_keeps_focus_and_every_selection() {
    let (start, t, r) = tabs_and_one();
    let right = slot(&start, 1, 0);
    let left = slot(&start, 0, 0);
    for (label, act) in [("as a tab", 0), ("beside", 1)] {
        let mut bench = start.clone();
        bench.show(r, Focus::Take).unwrap();
        let focused = bench.focused_pane().map(|p| p.id);
        let shown: HashSet<_> = bench.visible_pane_ids().into_iter().collect();

        let moved = if act == 0 {
            bench.move_pane_to_tab(t[2], right, Some(r), Focus::Leave)
        } else {
            bench.move_pane_beside(t[2], left, Direction::Down, Focus::Leave)
        };
        assert!(moved.unwrap(), "{label}: moved");

        assert_eq!(bench.focused_pane().map(|p| p.id), focused, "{label}");
        assert!(
            shown.is_subset(&bench.visible_pane_ids().into_iter().collect()),
            "{label}: every slot still shows what it showed"
        );
        assert_invariants(&bench, label);
    }
}

/// Review R1 on #555: a lone pane on the facing edge of its neighbour would land where it is,
/// and rebuilding the column there would only reset the heights the operator dragged.
#[test]
fn a_lone_pane_on_its_neighbours_facing_edge_stays_where_it_is() {
    let (mut start, t, r) = tabs_and_one();
    start
        .move_pane_beside(t[0], slot(&start, 1, 0), Direction::Down, Focus::Take)
        .unwrap();
    // Right column: r above t[0], both alone.
    for (label, pane, target, side) in [
        (
            "below onto the upper's bottom edge",
            t[0],
            slot(&start, 1, 0),
            Direction::Down,
        ),
        (
            "above onto the lower's top edge",
            r,
            slot(&start, 1, 1),
            Direction::Up,
        ),
    ] {
        let mut bench = start.clone();
        assert!(
            !bench
                .move_pane_beside(pane, target, side, Focus::Take)
                .unwrap(),
            "{label}"
        );
        assert_eq!(bench, start, "{label}: untouched");
    }

    let left = terminal();
    let right = terminal();
    let (l, rr) = (left.id, right.id);
    let mut pair = bench_of(vec![left], None);
    pair.split(Split::Right, right, Focus::Take).unwrap();
    let start = pair.clone();
    assert!(
        !pair
            .move_pane_beside(l, slot(&start, 1, 0), Direction::Left, Focus::Take)
            .unwrap()
    );
    assert!(
        !pair
            .move_pane_beside(rr, slot(&start, 0, 0), Direction::Right, Focus::Take)
            .unwrap()
    );
    assert_eq!(pair, start);
    assert!(
        pair.move_pane_beside(l, slot(&start, 1, 0), Direction::Right, Focus::Take)
            .unwrap(),
        "the far edge still moves it"
    );
    assert_eq!(shape(&pair), vec![vec![vec![rr]], vec![vec![l]]]);
}

// MARK: - A file opened at a place (Finder)

#[test]
fn a_file_opens_as_a_tab_at_the_gap_it_was_dropped_in() {
    let (mut bench, t, r) = tabs_and_one();
    let left = slot(&bench, 0, 0);
    let plan = canvas("/tmp/plan.md");
    let p = plan.id;

    let landed = bench
        .open_at(
            plan,
            Place::Tab {
                slot: left,
                before: Some(t[1]),
            },
            Focus::Take,
        )
        .unwrap();

    assert_eq!(landed, p);
    assert_eq!(
        shape(&bench),
        vec![vec![vec![t[0], p, t[1], t[2]]], vec![vec![r]]]
    );
    assert_eq!(bench.focused_pane().map(|p| p.id), Some(p));
    assert_invariants(&bench, "a file into a gap");
}

#[test]
fn a_file_opens_last_when_no_tab_is_named_and_still_takes_the_keyboard() {
    let (mut bench, t, r) = tabs_and_one();
    let right = slot(&bench, 1, 0);
    let plan = canvas("/tmp/plan.md");
    let p = plan.id;

    bench
        .open_at(
            plan,
            Place::Tab {
                slot: right,
                before: None,
            },
            Focus::Take,
        )
        .unwrap();

    // The move to "last" is a no-op for a pane that was just put last; the show is not.
    assert_eq!(shape(&bench), vec![vec![t.to_vec()], vec![vec![r, p]]]);
    assert_eq!(bench.focused_pane().map(|p| p.id), Some(p));
}

#[test]
fn a_file_dropped_on_an_edge_opens_in_a_slot_of_its_own_on_that_side() {
    let (mut bench, t, r) = tabs_and_one();
    let right = slot(&bench, 1, 0);
    let plan = canvas("/tmp/plan.md");
    let p = plan.id;

    bench
        .open_at(
            plan,
            Place::Beside {
                slot: right,
                side: Direction::Up,
            },
            Focus::Take,
        )
        .unwrap();

    assert_eq!(
        shape(&bench),
        vec![vec![t.to_vec()], vec![vec![p], vec![r]]]
    );
    assert_eq!(bench.focused_pane().map(|p| p.id), Some(p));
    assert_invariants(&bench, "a file beside a slot");
}

#[test]
fn a_file_the_bench_already_shows_moves_there_rather_than_opening_twice() {
    let shown = canvas("/tmp/plan.md");
    let s = shown.id;
    let other = terminal();
    let o = other.id;
    let mut bench = bench_of(vec![other, shown], Some(o));
    let only = slot(&bench, 0, 0);

    let landed = bench
        .open_at(
            canvas("/tmp/plan.md"),
            Place::Beside {
                slot: only,
                side: Direction::Right,
            },
            Focus::Take,
        )
        .unwrap();

    assert_eq!(landed, s, "the pane already showing it");
    assert_eq!(shape(&bench), vec![vec![vec![o]], vec![vec![s]]]);
    assert_eq!(bench.panes().count(), 2, "nothing opened twice");
}

#[test]
fn an_agents_open_at_a_place_moves_no_focus() {
    let (mut bench, _, _) = tabs_and_one();
    let right = slot(&bench, 1, 0);
    let before = (bench.focused_slot(), bench.focused_pane().map(|p| p.id));

    bench
        .open_at(
            canvas("/tmp/plan.md"),
            Place::Beside {
                slot: right,
                side: Direction::Down,
            },
            Focus::Leave,
        )
        .unwrap();

    assert_eq!(
        (bench.focused_slot(), bench.focused_pane().map(|p| p.id)),
        before
    );
    assert_eq!(bench.panes().count(), 5, "opened all the same");
}

#[test]
fn a_file_opened_at_a_slot_that_is_not_there_is_refused() {
    let (mut bench, _, _) = tabs_and_one();
    let was = shape(&bench);
    let nowhere = SlotId::mint();

    let refused = bench.open_at(
        canvas("/tmp/plan.md"),
        Place::Tab {
            slot: nowhere,
            before: None,
        },
        Focus::Take,
    );

    assert_eq!(refused, Err(Refusal::UnknownSlot(nowhere)));
    assert_eq!(shape(&bench), was);
}
