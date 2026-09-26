//! Where a new pane goes, as data.
//!
//! helm wrote each placement rule as a function (`WorkbenchPlacement.swift`); each was an
//! ordered list of "try this, else that". Written as that list, the rules are a value, and the
//! value is a TOML file (#356): the built-in table is `rules/placement.default.toml`, embedded at
//! build time, and the operator's `<bench root>/rules/placement.toml` replaces it whole. No
//! operation in `bench.rs` changes when a rule does.

use crate::bench::{Bench, Placement};
use crate::drawer::DrawerName;
use crate::surface::{Surface, SurfaceClass};
use serde::Deserialize;

/// Who is placing: the operator's own gesture, or anyone else. A class, not an identity —
/// placement never cares *which* agent.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Caller {
    Operator,
    Agent,
}

/// One way to find a destination. Tried in order; the first that resolves wins. Spelled in the
/// rules file as `"existing"`, `"tab-in-focused"`, `"new-column"`, or a one-key table for the
/// strategies that take an argument: `{ tab-in-focused-if-holds = "canvas" }`,
/// `{ tab-in-first-holding = "canvas" }`, `{ drawer = "browser" }`.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "kebab-case")]
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
    /// The named drawer, created if it has none. Always resolves. What arrives there follows
    /// the drawer's own rule: an agent's pane badges it, the operator's opens it.
    Drawer(DrawerName),
}

/// Where a rule sends a pane: somewhere on the bench, or into a drawer. Two kinds because only
/// the document can place into a drawer — a bench has none — so `Bench::place` never sees one.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Destination {
    Bench(Placement),
    Drawer(DrawerName),
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

/// The built-in table, as the file an operator would copy to start their own.
pub const DEFAULT_RULES: &str = include_str!("../rules/placement.default.toml");

/// The file's shape. Unknown keys are refused rather than ignored: a misspelt `tyr` silently
/// meaning "no strategies" is exactly the rule that would never do what the operator wrote.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RulesFile {
    #[serde(default)]
    place: Vec<RuleRow>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RuleRow {
    surface: SurfaceClass,
    #[serde(default)]
    by: By,
    #[serde(rename = "try")]
    strategies: Vec<Strategy>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "snake_case")]
enum By {
    Operator,
    Agent,
    #[default]
    Any,
}

impl Rules {
    /// The built-in table (`rules/placement.default.toml`). It is checked in and pinned by a
    /// test against a hand-built table, so a parse failure here is a build that never passed.
    pub fn defaults() -> Rules {
        Rules::parse(DEFAULT_RULES).expect("the embedded default placement rules parse")
    }

    /// Read a rules file. The whole file or nothing: a refusal names the line and why, and no
    /// caller ever holds half a table.
    pub fn parse(text: &str) -> Result<Rules, String> {
        let file: RulesFile = toml::from_str(text).map_err(|e| e.to_string().trim().to_string())?;
        Ok(Rules {
            rules: file
                .place
                .into_iter()
                .map(|row| Rule {
                    surface: row.surface,
                    caller: match row.by {
                        By::Operator => Some(Caller::Operator),
                        By::Agent => Some(Caller::Agent),
                        By::Any => None,
                    },
                    strategies: row.strategies,
                })
                .collect(),
        })
    }

    /// Where `surface` goes on `bench` when `caller` opens it.
    pub fn place(&self, bench: &Bench, surface: &Surface, caller: Caller) -> Destination {
        let class = surface.class();
        let fallback = Destination::Bench(Placement::Column);
        let Some(rule) = self
            .rules
            .iter()
            .find(|r| r.surface == class && r.caller.is_none_or(|c| c == caller))
        else {
            return fallback;
        };
        rule.strategies
            .iter()
            .find_map(|s| resolve(s, bench, surface))
            .unwrap_or(fallback)
    }
}

fn resolve(strategy: &Strategy, bench: &Bench, surface: &Surface) -> Option<Destination> {
    let holds = |slot: &crate::bench::Slot, class: SurfaceClass| {
        slot.panes.iter().any(|p| p.surface.class() == class)
    };
    let on_bench = match strategy {
        Strategy::Drawer(name) => return Some(Destination::Drawer(name.clone())),
        Strategy::Existing => bench.pane_showing(surface).map(Placement::Existing),
        Strategy::TabInFocusedIfHolds(class) => bench
            .slot(bench.focused_slot())
            .filter(|s| holds(s, *class))
            .map(|s| Placement::Tab(s.id)),
        Strategy::TabInFirstHolding(class) => bench
            .slots()
            .find(|s| holds(s, *class))
            .map(|s| Placement::Tab(s.id)),
        Strategy::TabInFocused => Some(Placement::Tab(bench.focused_slot())),
        Strategy::NewColumn => Some(Placement::Column),
    };
    on_bench.map(Destination::Bench)
}
