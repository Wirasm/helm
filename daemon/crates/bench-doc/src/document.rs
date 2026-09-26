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
//!
//! **Drawers are part of that focus.** Which drawer is open, and what it shows, are where the
//! operator is looking, so an agent that would open one is refused by the same comparison; an
//! agent's pane landing in a drawer badges it instead. A drawer operation never touches a
//! workspace, so toggling one cannot re-lay-out the bench under it.

use crate::bench::{Bench, Focus, Pane};
use crate::drawer::{Drawer, DrawerName};
use crate::ids::{ColumnId, PaneId, SlotId, StandardPath};
use crate::refusal::Refusal;
use crate::surface::{PaneName, ResumableAgent, Surface};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

/// One open folder and its arrangement.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
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
    /// The workspace whose live bench holds this pane. A pane in a drawer is on no bench, and
    /// is refused as [`Refusal::PaneInDrawer`].
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
    /// Named tab holders shown over the bench. Absent from a document that has none, so a
    /// document written before drawers existed reads unchanged.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    drawers: Vec<Drawer>,
    /// The drawer shown over the bench, if any. One at a time.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    open_drawer: Option<DrawerName>,
}

/// The operator's focus, as far as the document can see it: the active workspace, its focused
/// slot and that slot's selected pane, and the pane the open drawer shows. That last one also
/// names the drawer, since pane ids are one namespace. The bench's half stays in the comparison
/// while a drawer is open, because closing the drawer hands the keyboard straight back to it.
type FocusState = (
    Option<StandardPath>,
    Option<SlotId>,
    Option<PaneId>,
    Option<PaneId>,
);

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

    /// The bench `target` names: what a placement rule is evaluated against before the edit
    /// that places.
    pub fn bench_at(&self, target: &Target) -> Result<&Bench, Refusal> {
        let index = self.resolve(target)?;
        Ok(&self.workspaces[index].bench)
    }

    pub fn drawers(&self) -> &[Drawer] {
        &self.drawers
    }

    pub fn drawer(&self, name: &DrawerName) -> Option<&Drawer> {
        self.drawers.iter().find(|d| &d.name == name)
    }

    /// The drawer shown over the bench.
    pub fn open_drawer(&self) -> Option<&Drawer> {
        self.drawer(self.open_drawer.as_ref()?)
    }

    /// The drawer holding `pane`.
    pub fn drawer_of(&self, pane: PaneId) -> Option<&Drawer> {
        self.drawers.iter().find(|d| d.pane(pane).is_some())
    }

    /// A pane wherever it lives: a workspace's live bench or a drawer. (A shelved bench is not
    /// on screen and answers no verb, so it is not searched.)
    pub fn pane(&self, id: PaneId) -> Option<&Pane> {
        self.workspaces
            .iter()
            .find_map(|w| w.bench.pane(id))
            .or_else(|| self.drawers.iter().find_map(|d| d.pane(id)))
    }

    /// The first pane showing benchd session `session`, wherever it lives.
    pub fn pane_showing_session(&self, session: &str) -> Option<PaneId> {
        let benches = self.workspaces.iter().flat_map(|w| w.bench.panes());
        let drawers = self.drawers.iter().flat_map(|d| d.panes.iter());
        benches
            .chain(drawers)
            .find(|p| p.surface.session() == Some(session))
            .map(|p| p.id)
    }

    /// Forget every benchd session a terminal pane names, answering the panes that named one.
    /// benchd calls this when it boots: no session outlives the daemon that ran it, and session
    /// ids restart with each daemon, so a name kept across a restart would attach a pane to
    /// somebody else's agent. The pane stays, with its `agent` record for the resume offer.
    pub fn end_sessions(&mut self) -> Vec<PaneId> {
        let mut ended = Vec::new();
        let benches = self.workspaces.iter_mut().flat_map(|w| {
            let shelf = w.shelved.as_mut().into_iter().flat_map(Bench::panes_mut);
            w.bench.panes_mut().chain(shelf)
        });
        let drawers = self.drawers.iter_mut().flat_map(|d| d.panes.iter_mut());
        for pane in benches.chain(drawers) {
            if let Surface::Terminal { session, .. } = &mut pane.surface
                && session.take().is_some()
            {
                ended.push(pane.id);
            }
        }
        ended
    }

    /// The pane holding the operator's keyboard: the open drawer's, else the active bench's
    /// focused pane.
    pub fn focused_pane(&self) -> Option<PaneId> {
        match self.open_drawer() {
            Some(drawer) => Some(drawer.selected),
            None => self
                .active_workspace()
                .and_then(|w| w.bench.focused_pane())
                .map(|p| p.id),
        }
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

    /// Close a folder. Closing the active one activates the first that remains; closing the
    /// last leaves nothing open. benchd is the only place this rule lives: helm draws whatever
    /// the document says is active.
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

    /// Adopt a whole document — the one-time import of helm's saved benches. Only into a
    /// document with no workspaces: an import over live state would be a second source of truth
    /// deciding which of two arrangements wins, and nobody asked it to. Drawers already here are
    /// kept: an agent can fill one before helm's import runs, and the import is about benches.
    pub fn import(&mut self, other: Document) -> Result<(), Refusal> {
        if !self.workspaces.is_empty() {
            return Err(Refusal::DocumentNotEmpty {
                workspaces: self.workspaces.len(),
            });
        }
        let mut next = other;
        next.drawers.splice(0..0, self.drawers.iter().cloned());
        if self.open_drawer.is_some() {
            next.open_drawer = self.open_drawer.clone();
        }
        next.check()?;
        *self = next;
        Ok(())
    }

    // MARK: drawer operations

    /// Open a drawer over the bench, or close it if it is the one open. Opening one closes any
    /// other, and clears its badge. A drawer that does not exist yet is created holding one pane
    /// of `surface`, and answers that pane; with no surface there is nothing to show, and it is
    /// refused. Opening is focus, so with `Leave` the guard refuses it either way.
    ///
    /// No workspace is touched: the bench under the drawer is exactly what it was.
    pub fn toggle_drawer(
        &mut self,
        name: &DrawerName,
        surface: Option<Surface>,
        focus: Focus,
    ) -> Result<Option<PaneId>, Refusal> {
        self.commit(focus, |doc| {
            if doc.open_drawer.as_ref() == Some(name) {
                doc.open_drawer = None;
                return Ok(None);
            }
            let created = match doc.drawer_index(name) {
                Some(_) => None,
                None => {
                    let pane =
                        Pane::new(surface.ok_or_else(|| Refusal::EmptyDrawer(name.clone()))?);
                    let id = pane.id;
                    doc.drawers.push(Drawer::of(name.clone(), pane));
                    Some(id)
                }
            };
            doc.reveal(name);
            Ok(created)
        })
    }

    /// Put `pane` in a drawer, creating the drawer if it has none, and answer the pane it
    /// resolved to. A pane already in that drawer showing the same surface is acted on instead
    /// (`Surface::already_shows`), and its id is answered rather than `pane`'s.
    ///
    /// With `Take` the pane is selected and the drawer opens. With `Leave` nothing the operator
    /// is looking at changes: a new pane arrives unselected (or selected, when it is the first,
    /// since a drawer shows something), and the drawer is badged.
    pub fn place_in_drawer(
        &mut self,
        name: &DrawerName,
        pane: Pane,
        focus: Focus,
    ) -> Result<PaneId, Refusal> {
        self.commit(focus, |doc| {
            let id = match doc.drawer_index(name) {
                None => {
                    let id = pane.id;
                    doc.drawers.push(Drawer::of(name.clone(), pane));
                    id
                }
                Some(d) => {
                    let drawer = &mut doc.drawers[d];
                    match drawer
                        .panes
                        .iter()
                        .find(|p| p.surface.already_shows(&pane.surface))
                    {
                        Some(existing) => existing.id,
                        None => {
                            let id = pane.id;
                            drawer.panes.push(pane);
                            id
                        }
                    }
                }
            };
            doc.arrive(name, id, focus);
            Ok(id)
        })
    }

    // MARK: pane operations that reach drawers
    //
    // Pane ids are one namespace, so a verb naming a pane finds it wherever it lives. These four
    // are the pane verbs that make sense in a tab holder; the rest (move, resize, focus) are
    // about the bench's geometry and refuse a drawer's pane by name.

    /// Close a pane. In a drawer, the neighbour at the closed position is selected, and closing
    /// the last pane removes the drawer — closing it, if it was open, which hands focus back to
    /// the bench under it.
    pub fn close_pane(&mut self, pane: PaneId, focus: Focus) -> Result<(), Refusal> {
        let Some((d, at)) = self.drawer_address(pane) else {
            return self.edit(Target::Pane(pane), focus, |b| b.close(pane));
        };
        self.commit(focus, |doc| {
            let drawer = &mut doc.drawers[d];
            drawer.panes.remove(at);
            if drawer.panes.is_empty() {
                let gone = doc.drawers.remove(d);
                if doc.open_drawer.as_ref() == Some(&gone.name) {
                    doc.open_drawer = None;
                }
            } else if drawer.selected == pane {
                drawer.selected = drawer.panes[at.min(drawer.panes.len() - 1)].id;
            }
            Ok(())
        })
    }

    /// Make a pane what its holder shows. In a drawer, `Take` also opens the drawer and clears
    /// its badge; `Leave` selects it and badges the drawer — refused by the guard when that
    /// drawer is open, because then it is what the operator is looking at.
    pub fn show_pane(&mut self, pane: PaneId, focus: Focus) -> Result<(), Refusal> {
        let Some((d, _)) = self.drawer_address(pane) else {
            return self.edit(Target::Pane(pane), focus, |b| b.show(pane, focus));
        };
        let name = self.drawers[d].name.clone();
        self.commit(focus, |doc| {
            doc.drawers[d].selected = pane;
            doc.arrive(&name, pane, focus);
            Ok(())
        })
    }

    /// Call a pane something, wherever it lives, and answer what it was called before.
    pub fn name_pane(
        &mut self,
        pane: PaneId,
        name: PaneName,
        focus: Focus,
    ) -> Result<PaneName, Refusal> {
        let Some((d, at)) = self.drawer_address(pane) else {
            return self.edit(Target::Pane(pane), focus, |b| b.name(pane, name));
        };
        self.commit(focus, |doc| {
            Ok(std::mem::replace(&mut doc.drawers[d].panes[at].name, name))
        })
    }

    /// Record which agent is in a terminal pane, wherever it lives (helm #63).
    pub fn record_agent(
        &mut self,
        pane: PaneId,
        agent: Option<ResumableAgent>,
        focus: Focus,
    ) -> Result<(), Refusal> {
        let Some((d, at)) = self.drawer_address(pane) else {
            return self.edit(Target::Pane(pane), focus, |b| b.record_agent(pane, agent));
        };
        self.commit(focus, |doc| match &mut doc.drawers[d].panes[at].surface {
            Surface::Terminal { agent: held, .. } => {
                *held = agent;
                Ok(())
            }
            _ => Err(Refusal::NotATerminal(pane)),
        })
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
        next.check()?;
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
            self.open_drawer().map(|d| d.selected),
        )
    }

    /// The rules an operation could break: pane ids are one namespace across every bench,
    /// shelf and drawer, and drawer names are one namespace too. (A drawer's own shape — never
    /// empty, its selection held — is kept by construction; only decoding has to check it.)
    fn check(&self) -> Result<(), Refusal> {
        let mut seen = HashSet::new();
        let benches = self
            .workspaces
            .iter()
            .flat_map(|w| std::iter::once(&w.bench).chain(w.shelved.as_ref()));
        let drawer_panes = self.drawers.iter().flat_map(|d| d.panes.iter());
        for pane in benches.flat_map(|b| b.panes()).chain(drawer_panes) {
            if !seen.insert(pane.id) {
                return Err(Refusal::DuplicatePane(pane.id));
            }
        }
        let mut names = HashSet::new();
        for drawer in &self.drawers {
            if !names.insert(&drawer.name) {
                return Err(Refusal::DuplicateDrawer(drawer.name.clone()));
            }
        }
        Ok(())
    }

    fn drawer_index(&self, name: &DrawerName) -> Option<usize> {
        self.drawers.iter().position(|d| &d.name == name)
    }

    /// Where a pane sits among the drawers: (drawer, pane) indices.
    fn drawer_address(&self, pane: PaneId) -> Option<(usize, usize)> {
        self.drawers.iter().enumerate().find_map(|(d, drawer)| {
            drawer
                .panes
                .iter()
                .position(|p| p.id == pane)
                .map(|at| (d, at))
        })
    }

    /// Open a drawer that exists: it is the one shown, and the operator is now seeing it.
    fn reveal(&mut self, name: &DrawerName) {
        if let Some(d) = self.drawer_index(name) {
            self.drawers[d].badged = false;
            self.open_drawer = Some(name.clone());
        }
    }

    /// Something arrived in a drawer, or was brought forward in it: with `Take` the operator
    /// sees it, and with `Leave` the drawer is badged and nothing else moves.
    fn arrive(&mut self, name: &DrawerName, pane: PaneId, focus: Focus) {
        let Some(d) = self.drawer_index(name) else {
            return;
        };
        match focus {
            Focus::Take => {
                self.drawers[d].selected = pane;
                self.reveal(name);
            }
            Focus::Leave => self.drawers[d].badged = true,
        }
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
            Target::Pane(id) => {
                find(&|b| b.pane(*id).is_some()).ok_or_else(|| match self.drawer_of(*id) {
                    Some(drawer) => Refusal::PaneInDrawer {
                        pane: *id,
                        drawer: drawer.name.clone(),
                    },
                    None => Refusal::UnknownPane(*id),
                })
            }
            Target::Slot(id) => find(&|b| b.slot(*id).is_some()).ok_or(Refusal::UnknownSlot(*id)),
            Target::Column(id) => find(&|b| b.columns().iter().any(|c| c.id == *id))
                .ok_or(Refusal::UnknownColumn(*id)),
        }
    }
}

/// A stored document before it is trusted. Decoding refuses what no operation can produce —
/// two workspaces with one path, a pane id in two places, an active workspace that is not
/// open, a drawer that is empty or selects a pane it does not hold, an open drawer that does
/// not exist — rather than guessing which half to keep.
#[derive(Deserialize)]
struct EncodedDocument {
    workspaces: Vec<Workspace>,
    active: Option<StandardPath>,
    #[serde(default)]
    drawers: Vec<Drawer>,
    #[serde(default)]
    open_drawer: Option<DrawerName>,
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
        if let Some(defect) = raw.drawers.iter().find_map(Drawer::defect) {
            return Err(defect);
        }
        if let Some(open) = &raw.open_drawer
            && !raw.drawers.iter().any(|d| &d.name == open)
        {
            return Err(format!(
                "the open drawer {open} is not one the document holds"
            ));
        }
        let doc = Document {
            workspaces: raw.workspaces,
            active: raw.active,
            drawers: raw.drawers,
            open_drawer: raw.open_drawer,
        };
        doc.check().map_err(|r| r.to_string())?;
        Ok(doc)
    }
}
