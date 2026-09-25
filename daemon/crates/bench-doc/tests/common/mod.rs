//! Helpers shared by the mirrored suites — the Swift suites' own `terminal()`, `canvas()`
//! and `assertInvariants`, so each Rust test reads line for line against the one it mirrors.
#![allow(dead_code)]

use bench_doc::{Bench, CanvasSource, Pane, PaneId, Surface};

pub fn terminal() -> Pane {
    Pane::new(Surface::terminal())
}

pub fn canvas(path: &str) -> Pane {
    Pane::new(Surface::file(path).unwrap())
}

pub fn file(path: &str) -> Surface {
    Surface::file(path).unwrap()
}

pub fn url(url: &str) -> CanvasSource {
    CanvasSource::Url { url: url.into() }
}

pub fn bench_of(panes: Vec<Pane>, selecting: Option<PaneId>) -> Bench {
    Bench::of(panes, selecting).unwrap()
}

pub fn ids(panes: &[Pane]) -> Vec<PaneId> {
    panes.iter().map(|p| p.id).collect()
}

pub fn widths(bench: &Bench) -> Vec<f64> {
    bench.columns().iter().map(|c| c.width).collect()
}

pub fn heights(bench: &Bench, column: usize) -> Vec<f64> {
    bench.columns()[column]
        .slots
        .iter()
        .map(|s| s.height)
        .collect()
}

pub fn close_to(a: f64, b: f64, accuracy: f64) -> bool {
    (a - b).abs() <= accuracy
}

pub fn assert_fractions(actual: &[f64], expected: &[f64], message: &str) {
    assert_eq!(actual.len(), expected.len(), "{message}");
    for (i, (a, e)) in actual.iter().zip(expected).enumerate() {
        assert!(close_to(*a, *e, 1e-9), "{message} [{i}]: {a} != {e}");
    }
}

/// The four invariants, checked from outside — `WorkbenchTests.assertInvariants`.
pub fn assert_invariants(bench: &Bench, step: &str) {
    assert!(
        !bench.columns().is_empty(),
        "{step}: columns is never empty"
    );
    for column in bench.columns() {
        assert!(!column.slots.is_empty(), "{step}: no column has zero slots");
        let heights: Vec<f64> = column.slots.iter().map(|s| s.height).collect();
        assert!(
            heights.iter().all(|h| *h > 0.0),
            "{step}: every height is positive"
        );
        assert!(
            close_to(heights.iter().sum(), 1.0, 1e-9),
            "{step}: a column's heights sum to 1"
        );
        for slot in &column.slots {
            assert!(!slot.panes.is_empty(), "{step}: no slot has zero panes");
            assert!(
                slot.panes.iter().any(|p| p.id == slot.selected),
                "{step}: a slot's selection names a pane it holds"
            );
        }
    }
    let widths = widths(bench);
    assert!(
        widths.iter().all(|w| *w > 0.0),
        "{step}: every width is positive"
    );
    assert!(
        close_to(widths.iter().sum(), 1.0, 1e-9),
        "{step}: the widths sum to 1"
    );
    assert!(
        bench.slot(bench.focused_slot()).is_some(),
        "{step}: focus names a slot that exists"
    );
}
