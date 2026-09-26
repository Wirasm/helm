//! A drawer: a named tab holder beside the workspaces, shown over the bench rather than in it
//! (#356).
//!
//! One exists per name for the whole document, not per workspace: there is one shared browser
//! per bench root, so a per-workspace browser drawer would be the same browser N times. A drawer
//! holds panes, so anything a pane can show can live in one, and what it shows persists while it
//! is closed. It has no columns and no splits — a pile of tabs, not a second layout.
//!
//! A drawer exists only while it holds a pane: closing its last pane removes it, which is why
//! `selected` is a pane id and never optional. Every rule that changes one is a `Document`
//! method, because opening a drawer is the operator's focus and only the document can guard it.

use crate::bench::Pane;
use crate::ids::PaneId;
use serde::{Deserialize, Deserializer, Serialize};
use std::fmt;

/// A drawer's name: `[a-z0-9-]{1,32}`. It is typed into keymaps and CLI flags and shown on the
/// status bar, so it has one spelling, and a name that could not be typed back is refused where
/// it arrives rather than stored.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize)]
#[serde(transparent)]
pub struct DrawerName(String);

impl DrawerName {
    pub fn new(raw: &str) -> Result<Self, String> {
        let valid = (1..=32).contains(&raw.len())
            && raw
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-');
        if valid {
            Ok(DrawerName(raw.to_string()))
        } else {
            Err(format!(
                "not a drawer name: {raw:?} — a drawer name is 1-32 of [a-z0-9-]"
            ))
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl<'de> Deserialize<'de> for DrawerName {
    /// A decoded name goes through the same door as a constructed one.
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        let raw = String::deserialize(d)?;
        DrawerName::new(&raw).map_err(serde::de::Error::custom)
    }
}

impl fmt::Display for DrawerName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// One drawer. Fields are public like `Slot`'s: the document owns every rule that changes them
/// and hands drawers out only by shared reference.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Drawer {
    pub name: DrawerName,
    /// Never empty: a drawer with nothing in it is removed, not kept.
    pub panes: Vec<Pane>,
    /// The pane the drawer shows when it is open. Always one it holds.
    pub selected: PaneId,
    /// Something arrived that the operator has not seen: an agent put a pane here, or
    /// re-offered one already here. Opening the drawer clears it.
    #[serde(default)]
    pub badged: bool,
}

impl Drawer {
    pub(crate) fn of(name: DrawerName, pane: Pane) -> Drawer {
        Drawer {
            name,
            selected: pane.id,
            panes: vec![pane],
            badged: false,
        }
    }

    pub fn pane(&self, id: PaneId) -> Option<&Pane> {
        self.panes.iter().find(|p| p.id == id)
    }

    /// The pane on show when the drawer is open.
    pub fn selected_pane(&self) -> Option<&Pane> {
        self.pane(self.selected)
    }

    /// Why this drawer is not one any operation could leave behind, if it is not.
    pub(crate) fn defect(&self) -> Option<String> {
        if self.panes.is_empty() {
            return Some(format!("drawer {} holds no pane", self.name));
        }
        if self.pane(self.selected).is_none() {
            return Some(format!(
                "drawer {} selects {}, which it does not hold",
                self.name, self.selected
            ));
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_drawer_name_is_a_short_lowercase_slug() {
        for ok in ["browser", "sessions", "notes-2", "a", &"x".repeat(32)] {
            assert!(DrawerName::new(ok).is_ok(), "{ok:?}");
        }
        for bad in ["", "Browser", "my drawer", "a/b", "ä", &"x".repeat(33)] {
            assert!(DrawerName::new(bad).is_err(), "{bad:?} should be refused");
        }
        assert!(serde_json::from_str::<DrawerName>("\"Notes\"").is_err());
    }
}
