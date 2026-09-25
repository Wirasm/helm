//! The whole bench document: every open workspace, each with its bench, and which one the
//! operator is looking at.
//!
//! Every workspace is live here. helm kept a parked workspace as an inert value and needed a
//! second door to push onto one (#349, `ParkedBenches`); in the document "parked" means only
//! "not the active one", and a pane verb finds its workspace by the pane's id.
//!
//! **The focus rule is enforced here, once, for every operation** (bench-architecture.md):
//! focus moves only when the operator acted or an agent's verb says the operator asked. An
//! operation run with [`Focus::Leave`] is applied to a copy and kept only if the operator's
//! focus — the active workspace, its focused slot and that slot's selected pane — came out
//! exactly as it went in; otherwise it is refused and nothing changes. That makes the rule a
//! property of the document rather than a promise each operation has to keep: an operation
//! that would seize (closing the pane that holds the keyboard, showing a background tab of
//! the focused slot, moving the focused pane) is refused, and one that cannot is untouched.

use crate::bench::{Bench, Focus, Pane};
use crate::ids::{ColumnId, PaneId, SlotId, StandardPath};
use crate::refusal::Refusal;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

/// One open folder and its arrangement.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Workspace {
    pub path: StandardPath,
    pub bench: Bench,
    /// A bench the operator declined to restore (helm #85), kept so one wrong click cannot
    /// destroy a layout, and offered back while the live bench is still the fresh shell.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shelved: Option<Bench>,
}

/// Which bench an edit applies to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    Active,
    Workspace(StandardPath),
    /// The workspace whose live bench holds this pane.
    Pane(PaneId),
    Slot(SlotId),
    Column(ColumnId),
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(try_from = "EncodedDocument")]
pub struct Document {
    workspaces: Vec<Workspace>,
    /// The workspace on screen. `None` only when nothing is open.
    active: Option<StandardPath>,
}

/// The operator's focus, as far as the document can see it.
type FocusState = (Option<StandardPath>, Option<SlotId>, Option<PaneId>);

impl Document {
    // MARK: readers

    pub fn workspaces(&self) -> &[Workspace] {
        &self.workspaces
    }

    pub fn workspace(&self, path: &StandardPath) -> Option<&Workspace> {
        self.workspaces.iter().find(|w| &w.path == path)
    }

    pub fn active(&self) -> Option<&StandardPath> {
        self.active.as_ref()
    }

    pub fn active_workspace(&self) -> Option<&Workspace> {
        self.workspace(self.active.as_ref()?)
    }

    /// The workspace whose live bench holds `pane`.
    pub fn workspace_of(&self, pane: PaneId) -> Option<&Workspace> {
        self.workspaces
            .iter()
            .find(|w| w.bench.pane(pane).is_some())
    }

    // MARK: workspace operations

    /// Open a folder with `first` as its one pane — today's 1×1 frame. With `Take` it becomes
    /// the active workspace; opening one that is already open only activates it.
    pub fn open_workspace(
        &mut self,
        path: StandardPath,
        first: Pane,
        focus: Focus,
    ) -> Result<(), Refusal> {
        self.commit(focus, |doc| {
            if doc.workspace(&path).is_none() {
                let bench = Bench::of(vec![first], None).expect("one pane is a bench");
                doc.workspaces.push(Workspace {
                    path: path.clone(),
                    bench,
                    shelved: None,
                });
            }
            if focus == Focus::Take {
                doc.active = Some(path);
            }
            Ok(())
        })
    }

    /// Close a folder. Closing the active one activates the first that remains, as helm does
    /// (`RootView.closeWorkspace`); closing the last leaves nothing open.
    pub fn close_workspace(&mut self, path: &StandardPath, focus: Focus) -> Result<(), Refusal> {
        self.commit(focus, |doc| {
            let index = doc.index_of(path)?;
            doc.workspaces.remove(index);
            if doc.active.as_ref() == Some(path) {
                doc.active = doc.workspaces.first().map(|w| w.path.clone());
            }
            Ok(())
        })
    }

    /// Make a workspace the one on screen. It exists only to move focus, so with `Leave` the
    /// guard refuses it unless it is already active.
    pub fn activate(&mut self, path: &StandardPath, focus: Focus) -> Result<(), Refusal> {
        self.commit(focus, |doc| {
            doc.index_of(path)?;
            doc.active = Some(path.clone());
            Ok(())
        })
    }

    /// helm #85's "fresh": the bench is shelved and replaced by `fresh` alone.
    pub fn reset(&mut self, path: &StandardPath, fresh: Pane, focus: Focus) -> Result<(), Refusal> {
        self.commit(focus, |doc| {
            let index = doc.index_of(path)?;
            let bench = Bench::of(vec![fresh], None).expect("one pane is a bench");
            let workspace = &mut doc.workspaces[index];
            workspace.shelved = Some(std::mem::replace(&mut workspace.bench, bench));
            Ok(())
        })
    }

    /// Bring a shelved bench back. Restoring the shelf is what stops it being shelved.
    pub fn unshelve(&mut self, path: &StandardPath, focus: Focus) -> Result<(), Refusal> {
        self.commit(focus, |doc| {
            let index = doc.index_of(path)?;
            let workspace = &mut doc.workspaces[index];
            let shelved = workspace
                .shelved
                .take()
                .ok_or_else(|| Refusal::NothingShelved(path.clone()))?;
            workspace.bench = shelved;
            Ok(())
        })
    }

    /// Adopt a whole document — the one-time import of helm's saved benches. Only into an
    /// empty document: an import over live state would be a second source of truth deciding
    /// which of two arrangements wins, and nobody asked it to.
    pub fn import(&mut self, other: Document) -> Result<(), Refusal> {
        if !self.workspaces.is_empty() {
            return Err(Refusal::DocumentNotEmpty {
                workspaces: self.workspaces.len(),
            });
        }
        *self = other;
        Ok(())
    }

    // MARK: bench operations

    /// Run one bench operation against `target`'s bench, under the focus guard and the
    /// one-namespace rule for pane ids. Every pane verb goes through here, so neither rule
    /// can be forgotten by a verb.
    pub fn edit<T>(
        &mut self,
        target: Target,
        focus: Focus,
        operation: impl FnOnce(&mut Bench) -> Result<T, Refusal>,
    ) -> Result<T, Refusal> {
        self.commit(focus, |doc| {
            let index = doc.resolve(&target)?;
            operation(&mut doc.workspaces[index].bench)
        })
    }

    // MARK: internals

    /// Apply `change` to a copy; keep it only if pane ids are still unique and, for `Leave`,
    /// the operator's focus is exactly where it was. The document is small, so a copy is the
    /// simplest honest transaction: a refused change leaves no half-applied trace.
    fn commit<T>(
        &mut self,
        focus: Focus,
        change: impl FnOnce(&mut Document) -> Result<T, Refusal>,
    ) -> Result<T, Refusal> {
        let mut next = self.clone();
        let answer = change(&mut next)?;
        next.check_unique_panes()?;
        if focus == Focus::Leave && next.focus_state() != self.focus_state() {
            return Err(Refusal::WouldMoveFocus);
        }
        *self = next;
        Ok(answer)
    }

    fn focus_state(&self) -> FocusState {
        let bench = self.active_workspace().map(|w| &w.bench);
        (
            self.active.clone(),
            bench.map(|b| b.focused_slot()),
            bench.and_then(|b| b.focused_pane()).map(|p| p.id),
        )
    }

    fn check_unique_panes(&self) -> Result<(), Refusal> {
        let mut seen = HashSet::new();
        for workspace in &self.workspaces {
            let benches = std::iter::once(&workspace.bench).chain(workspace.shelved.as_ref());
            for pane in benches.flat_map(|b| b.panes()) {
                if !seen.insert(pane.id) {
                    return Err(Refusal::DuplicatePane(pane.id));
                }
            }
        }
        Ok(())
    }

    fn index_of(&self, path: &StandardPath) -> Result<usize, Refusal> {
        self.workspaces
            .iter()
            .position(|w| &w.path == path)
            .ok_or_else(|| Refusal::UnknownWorkspace(path.clone()))
    }

    fn resolve(&self, target: &Target) -> Result<usize, Refusal> {
        let find =
            |holds: &dyn Fn(&Bench) -> bool| self.workspaces.iter().position(|w| holds(&w.bench));
        match target {
            Target::Active => {
                let path = self.active.as_ref().ok_or(Refusal::NoActiveWorkspace)?;
                self.index_of(path)
            }
            Target::Workspace(path) => self.index_of(path),
            Target::Pane(id) => find(&|b| b.pane(*id).is_some()).ok_or(Refusal::UnknownPane(*id)),
            Target::Slot(id) => find(&|b| b.slot(*id).is_some()).ok_or(Refusal::UnknownSlot(*id)),
            Target::Column(id) => find(&|b| b.columns().iter().any(|c| c.id == *id))
                .ok_or(Refusal::UnknownColumn(*id)),
        }
    }
}

/// A stored document before it is trusted. Decoding refuses what no operation can produce —
/// two workspaces with one path, a pane id in two places, an active workspace that is not
/// open — rather than guessing which half to keep.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct EncodedDocument {
    workspaces: Vec<Workspace>,
    active: Option<StandardPath>,
}

impl TryFrom<EncodedDocument> for Document {
    type Error = String;

    fn try_from(raw: EncodedDocument) -> Result<Self, Self::Error> {
        let mut paths = HashSet::new();
        for w in &raw.workspaces {
            if !paths.insert(&w.path) {
                return Err(format!("workspace {} appears twice", w.path));
            }
        }
        if let Some(active) = &raw.active
            && !paths.contains(active)
        {
            return Err(format!("the active workspace {active} is not open"));
        }
        let doc = Document {
            workspaces: raw.workspaces,
            active: raw.active,
        };
        doc.check_unique_panes().map_err(|r| r.to_string())?;
        Ok(doc)
    }
}
