//! Where a new pane goes, as data.
//!
//! helm wrote each placement rule as a function (`WorkbenchPlacement.swift`); each was an
//! ordered list of "try this, else that". Written as that list, the rules are a value: the
//! defaults below are today's rules verbatim, and the operator's rules file (#356) only has
//! to replace the table — no operation in `bench.rs` changes when a rule does.

use crate::bench::{Bench, Placement};
use crate::surface::{Surface, SurfaceClass};

/// Who is placing: the operator's own gesture, or anyone else. A class, not an identity —
/// placement never cares *which* agent.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Caller {
    Operator,
    Agent,
}

/// One way to find a destination. Tried in order; the first that resolves wins.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Strategy {
    /// A pane already showing this surface (`Bench::pane_showing`).
    Existing,
    /// A tab in the focused slot, if that slot already holds a surface of this class.
    TabInFocusedIfHolds(SurfaceClass),
    /// A tab in the first slot, in column order, holding a surface of this class.
    TabInFirstHolding(SurfaceClass),
    /// A tab in the focused slot, whatever it holds.
    TabInFocused,
    /// A new column at the right end. Always resolves.
    NewColumn,
}

/// The strategies for one class of surface, for one class of caller (`None`: any caller).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rule {
    pub surface: SurfaceClass,
    pub caller: Option<Caller>,
    pub strategies: Vec<Strategy>,
}

/// The table. The first rule matching the surface and caller decides; with none matching,
/// or none of its strategies resolving, a pane gets a new column — the one destination that
/// always exists and never hides what arrives.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rules {
    pub rules: Vec<Rule>,
}

impl Rules {
    /// helm's rules on 2026-09-25, one row each:
    /// - **A canvas** (`placement(forOpening:)`): the pane already showing it; else a tab in the
    ///   focused slot if it holds a canvas; else a tab in the first slot holding one; else a new
    ///   column. The tenth offered canvas must not create a tenth column.
    /// - **A terminal the operator asked for** (`placementForNewTerminal`, ⌘N): a tab in the
    ///   slot they are in.
    /// - **A terminal an agent spawned** (`placementForSpawnedTerminal`, #177): a new column —
    ///   decided by the bench, not by whatever was last clicked; a tab is hidden, and a spawn
    ///   nobody is watching must be visible.
    /// - **The browser** (`placementForBrowser`, #353): the pane already showing it, else a new
    ///   column.
    pub fn defaults() -> Rules {
        use Strategy::*;
        Rules {
            rules: vec![
                Rule {
                    surface: SurfaceClass::Canvas,
                    caller: None,
                    strategies: vec![
                        Existing,
                        TabInFocusedIfHolds(SurfaceClass::Canvas),
                        TabInFirstHolding(SurfaceClass::Canvas),
                        NewColumn,
                    ],
                },
                Rule {
                    surface: SurfaceClass::Terminal,
                    caller: Some(Caller::Operator),
                    strategies: vec![TabInFocused],
                },
                Rule {
                    surface: SurfaceClass::Terminal,
                    caller: Some(Caller::Agent),
                    strategies: vec![NewColumn],
                },
                Rule {
                    surface: SurfaceClass::Browser,
                    caller: None,
                    strategies: vec![Existing, NewColumn],
                },
            ],
        }
    }

    /// Where `surface` goes on `bench` when `caller` opens it.
    pub fn place(&self, bench: &Bench, surface: &Surface, caller: Caller) -> Placement {
        let class = surface.class();
        let Some(rule) = self
            .rules
            .iter()
            .find(|r| r.surface == class && r.caller.is_none_or(|c| c == caller))
        else {
            return Placement::Column;
        };
        rule.strategies
            .iter()
            .find_map(|s| resolve(*s, bench, surface))
            .unwrap_or(Placement::Column)
    }
}

fn resolve(strategy: Strategy, bench: &Bench, surface: &Surface) -> Option<Placement> {
    let holds = |slot: &crate::bench::Slot, class: SurfaceClass| {
        slot.panes.iter().any(|p| p.surface.class() == class)
    };
    match strategy {
        Strategy::Existing => bench.pane_showing(surface).map(Placement::Existing),
        Strategy::TabInFocusedIfHolds(class) => bench
            .slot(bench.focused_slot())
            .filter(|s| holds(s, class))
            .map(|s| Placement::Tab(s.id)),
        Strategy::TabInFirstHolding(class) => bench
            .slots()
            .find(|s| holds(s, class))
            .map(|s| Placement::Tab(s.id)),
        Strategy::TabInFocused => Some(Placement::Tab(bench.focused_slot())),
        Strategy::NewColumn => Some(Placement::Column),
    }
}
