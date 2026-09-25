//! One workspace's arrangement: N columns, each a vertical stack of slots, each slot tabbed.
//!
//! This is helm's `Workbench` (`Sources/Helm/Workbench/Workbench.swift`) moved to the owner
//! of the document, with its rules intact and its tests mirrored in `tests/`. Depth two — a
//! strict subset of a general split tree, so nothing is foreclosed and there is no "horizontal
//! or vertical?" decision at every insertion (helm #23).
//!
//! Invariants, re-established by `normalize()` after **every** mutation:
//! - `columns` is never empty; no column has zero slots; no slot has zero panes.
//! - `focused_slot` always names a slot that exists.
//! - every `Slot::selected` names a pane that slot holds.
//! - widths within the bench, and heights within a column, are positive and sum to 1.
//!
//! **What changed in the port, and why.** helm had twin methods — `insert`/`offer`,
//! `select(_:)`/`select(offering:)`, `splitRight(with:)`/`splitRight(offering:)` — because
//! each *caller* had to pick the non-seizing one. Behind benchd every verb says who asked,
//! and the daemon decides; so each twin pair is one operation taking a [`Focus`], and `move`
//! gains the agent form it could not have before (its single "focus follows the pane" block
//! runs only for [`Focus::Take`]). And helm's silent `guard … else { return }` no-ops are
//! [`Refusal`]s, because a caller behind a socket told "ok" about a pane that is gone
//! believes something false.

use crate::ids::{ColumnId, PaneId, SlotId};
use crate::refusal::Refusal;
use crate::surface::{PaneName, ResumableAgent, Surface};
use serde::{Deserialize, Serialize};

/// Whether an operation may move the operator's focus. Decided once, from who asked, by
/// whoever calls this crate — never by the operation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Focus {
    /// The operator acted, or an agent's verb says the operator asked: select what arrives,
    /// and move focus to it.
    Take,
    /// Anyone else: appear, don't seize. What a slot is showing and which slot has focus are
    /// left exactly where they were.
    Leave,
}

/// Which way a focus step or a pane move goes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Direction {
    Left,
    Right,
    Up,
    Down,
}

/// Which way a split opens: a new column right of the focused one, or a new row below it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Split {
    Right,
    Down,
}

/// Where a new pane goes. Carries a destination, never a pane. `Existing` is a placement
/// too, so "open this" is one call whether or not it is already here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Placement {
    Existing(PaneId),
    Tab(SlotId),
    Row(ColumnId),
    Column,
}

/// One tenant of a slot.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Pane {
    pub id: PaneId,
    pub surface: Surface,
    /// Beside the surface rather than inside it: a name means the same thing for every kind.
    #[serde(default, skip_serializing_if = "PaneName::is_unnamed")]
    pub name: PaneName,
}

impl Pane {
    pub fn new(surface: Surface) -> Pane {
        Pane {
            id: PaneId::mint(),
            surface,
            name: PaneName::Unnamed,
        }
    }

    pub fn with_id(id: PaneId, surface: Surface) -> Pane {
        Pane {
            id,
            surface,
            name: PaneName::Unnamed,
        }
    }
}

/// One tabbed cell of a column: the panes it holds, and which of them is on screen.
/// `selected` is per slot — N slots are visible at once, so no single id could say it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Slot {
    pub id: SlotId,
    pub panes: Vec<Pane>,
    pub selected: PaneId,
    /// Fraction of its column's height.
    pub height: f64,
}

impl Slot {
    fn new(panes: Vec<Pane>, selected: Option<PaneId>, height: f64) -> Slot {
        // A slot with no panes is not a state the bench keeps — `normalize()` drops it —
        // so the fallback only has to be a value, not a meaningful one.
        let selected = selected
            .or_else(|| panes.first().map(|p| p.id))
            .unwrap_or_else(PaneId::mint);
        Slot {
            id: SlotId::mint(),
            panes,
            selected,
            height,
        }
    }

    fn holds(&self, pane: PaneId) -> bool {
        self.panes.iter().any(|p| p.id == pane)
    }
}

/// One vertical stack of slots, and the share of the bench's width it gets.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Column {
    pub id: ColumnId,
    pub slots: Vec<Slot>,
    /// Fraction of the bench's width. This is the layout, not a record of one: helm lays the
    /// bench out itself from these fractions (`SplitStack`).
    pub width: f64,
}

impl Column {
    fn new(slots: Vec<Slot>, width: f64) -> Column {
        Column {
            id: ColumnId::mint(),
            slots,
            width,
        }
    }
}

/// See the module header. Fields are private on purpose: every rule that changes them is a
/// method in this file, and a caller needing to write them directly is the signal the rule
/// is in the wrong place.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "EncodedBench")]
pub struct Bench {
    columns: Vec<Column>,
    /// The slot the operator's next command targets. An id, never an index.
    focused_slot: SlotId,
}

/// The smallest share any one member may be squeezed to: a divider dragged to the edge
/// leaves a sliver you can grab again rather than a pane you cannot get back.
pub const MINIMUM_FRACTION: f64 = 0.05;

/// Where a pane sits. Indices, deliberately — valid only inside one mutation; nothing stores
/// one.
#[derive(Debug, Clone, Copy)]
struct Address {
    column: usize,
    slot: usize,
    pane: usize,
}

impl Bench {
    // MARK: construction

    fn build(columns: Vec<Column>, focused_slot: SlotId) -> Bench {
        let mut bench = Bench {
            columns,
            focused_slot,
        };
        bench.normalize();
        bench
    }

    /// One column, one slot, one terminal — what a first-run workspace gets.
    pub fn terminal(id: PaneId) -> Bench {
        Bench::of(vec![Pane::with_id(id, Surface::terminal())], None)
            .expect("one pane is not an empty bench")
    }

    /// One column, one slot, these panes as tabs. `None` for no panes: that would break the
    /// first invariant, and there is nothing here that could invent a pane to repair it.
    pub fn of(panes: Vec<Pane>, selected: Option<PaneId>) -> Option<Bench> {
        if panes.is_empty() {
            return None;
        }
        let slot = Slot::new(panes, selected, 1.0);
        let focused = slot.id;
        Some(Bench::build(vec![Column::new(vec![slot], 1.0)], focused))
    }

    // MARK: readers

    pub fn columns(&self) -> &[Column] {
        &self.columns
    }

    pub fn focused_slot(&self) -> SlotId {
        self.focused_slot
    }

    /// Every pane, in column → slot → tab order.
    pub fn panes(&self) -> impl Iterator<Item = &Pane> {
        self.slots().flat_map(|s| s.panes.iter())
    }

    pub fn slots(&self) -> impl Iterator<Item = &Slot> {
        self.columns.iter().flat_map(|c| c.slots.iter())
    }

    /// The pane the operator's next command acts on: the focused slot's selected pane.
    pub fn focused_pane(&self) -> Option<&Pane> {
        let slot = self.slot(self.focused_slot)?;
        slot.panes.iter().find(|p| p.id == slot.selected)
    }

    /// The panes on screen: one per slot, several at once — the difference between a bench
    /// and a tab row.
    pub fn visible_pane_ids(&self) -> Vec<PaneId> {
        self.slots().map(|s| s.selected).collect()
    }

    pub fn slot(&self, id: SlotId) -> Option<&Slot> {
        self.slots().find(|s| s.id == id)
    }

    pub fn pane(&self, id: PaneId) -> Option<&Pane> {
        self.panes().find(|p| p.id == id)
    }

    /// The slot holding a pane.
    pub fn slot_for(&self, pane: PaneId) -> Option<&Slot> {
        self.slots().find(|s| s.holds(pane))
    }

    /// A pane already showing this surface. A canvas matches by source, **by value** — why
    /// ⌘-clicking the same link twice selects the canvas you have instead of opening a second.
    /// The browser matches any browser pane: there is one browser, so a second pane onto it
    /// would be a second copy of the same tab. A terminal never matches: every one is its own.
    pub fn pane_showing(&self, surface: &Surface) -> Option<PaneId> {
        self.panes()
            .find(|p| match (surface, &p.surface) {
                (Surface::Canvas { source: a }, Surface::Canvas { source: b }) => a == b,
                (Surface::Browser, Surface::Browser) => true,
                _ => false,
            })
            .map(|p| p.id)
    }

    /// The last pane of the bench cannot close.
    pub fn can_close(&self, pane: PaneId) -> bool {
        self.pane(pane).is_some() && self.panes().count() > 1
    }

    // MARK: mutations

    /// Put a pane where `placement` says. `Existing` acts on the pane already there and
    /// ignores `pane`.
    ///
    /// With `Take` — the operator asking — the pane is selected and its slot focused, and a
    /// new row or column arrives at the whole-stack share (so it takes half: a canvas the
    /// operator ⌘-clicked open lands at half the bench, which is what helm #125 shipped).
    ///
    /// With `Leave` — an agent's push — `selected` and `focused_slot` are untouched, an
    /// `Existing` pane stays exactly where it is (re-offering the artifact you just rewrote
    /// is the common case), and a new row or column takes an **equal share**, so nobody
    /// already there is halved to make room: shrinking the columns somebody is working in is
    /// its own kind of seizing (helm #177).
    pub fn place(&mut self, pane: Pane, placement: Placement, focus: Focus) -> Result<(), Refusal> {
        if let Placement::Existing(id) = placement {
            return match focus {
                Focus::Take => self.show(id, Focus::Take),
                Focus::Leave if self.pane(id).is_some() => Ok(()),
                Focus::Leave => Err(Refusal::UnknownPane(id)),
            };
        }
        if self.pane(pane.id).is_some() {
            return Err(Refusal::DuplicatePane(pane.id));
        }
        let take = focus == Focus::Take;
        match placement {
            Placement::Existing(_) => unreachable!("handled above"),
            Placement::Tab(slot_id) => {
                let a = self
                    .address_of_slot(slot_id)
                    .ok_or(Refusal::UnknownSlot(slot_id))?;
                let id = pane.id;
                let slot = &mut self.columns[a.column].slots[a.slot];
                slot.panes.push(pane);
                if take {
                    slot.selected = id;
                    self.focused_slot = slot_id;
                }
            }
            Placement::Row(column_id) => {
                let index = self
                    .columns
                    .iter()
                    .position(|c| c.id == column_id)
                    .ok_or(Refusal::UnknownColumn(column_id))?;
                let height = if take {
                    1.0
                } else {
                    equal_share(self.columns[index].slots.len())
                };
                let slot = Slot::new(vec![pane], None, height);
                if take {
                    self.focused_slot = slot.id;
                }
                self.columns[index].slots.push(slot);
            }
            Placement::Column => {
                let width = if take {
                    1.0
                } else {
                    equal_share(self.columns.len())
                };
                let slot = Slot::new(vec![pane], None, 1.0);
                if take {
                    self.focused_slot = slot.id;
                }
                self.columns.push(Column::new(vec![slot], width));
            }
        }
        self.normalize();
        Ok(())
    }

    /// Close a pane. Closing the selected pane selects the neighbour **at the closed
    /// position**; an emptied slot goes, an emptied column goes; the bench's last pane
    /// refuses.
    pub fn close(&mut self, pane: PaneId) -> Result<(), Refusal> {
        let a = self.address_of(pane).ok_or(Refusal::UnknownPane(pane))?;
        if !self.can_close(pane) {
            return Err(Refusal::LastPane(pane));
        }
        let closed_slot = self.columns[a.column].slots[a.slot].id;
        let was_selected = self.columns[a.column].slots[a.slot].selected == pane;
        self.columns[a.column].slots[a.slot].panes.remove(a.pane);

        let survivors = &self.columns[a.column].slots[a.slot].panes;
        if survivors.is_empty() {
            self.columns[a.column].slots.remove(a.slot);
            if self.columns[a.column].slots.is_empty() {
                self.columns.remove(a.column);
            }
            if self.focused_slot == closed_slot {
                self.refocus_near(a);
            }
        } else if was_selected {
            let next = survivors[a.pane.min(survivors.len() - 1)].id;
            self.columns[a.column].slots[a.slot].selected = next;
        }
        self.normalize();
        Ok(())
    }

    /// Make a pane its slot's selection. With `Take` its slot is focused too — clicking a tab
    /// is also saying "this is the pane I mean now". With `Leave` focus stays put, which is
    /// only non-seizing in a slot the operator is not in; the document's focus guard is what
    /// refuses the other case.
    pub fn show(&mut self, pane: PaneId, focus: Focus) -> Result<(), Refusal> {
        let a = self.address_of(pane).ok_or(Refusal::UnknownPane(pane))?;
        self.columns[a.column].slots[a.slot].selected = pane;
        if focus == Focus::Take {
            self.focused_slot = self.columns[a.column].slots[a.slot].id;
        }
        self.normalize();
        Ok(())
    }

    pub fn focus_slot(&mut self, slot: SlotId) -> Result<(), Refusal> {
        if self.slot(slot).is_none() {
            return Err(Refusal::UnknownSlot(slot));
        }
        self.focused_slot = slot;
        self.normalize();
        Ok(())
    }

    /// Call a pane something, and answer what it was called before. A name moves nothing, so
    /// there is no focus argument: both callers want the identical mutation. Whether a name
    /// may *replace* what is there is a policy above this type.
    pub fn name(&mut self, pane: PaneId, name: PaneName) -> Result<PaneName, Refusal> {
        let a = self.address_of(pane).ok_or(Refusal::UnknownPane(pane))?;
        let slot = &mut self.columns[a.column].slots[a.slot];
        Ok(std::mem::replace(&mut slot.panes[a.pane].name, name))
    }

    /// ⌘D / ⌘⇧D: a new column right of the focused one, or a new row under the focused slot,
    /// holding `pane`; the two halves share what the focused member had. It takes the pane
    /// rather than minting one — the bench cannot spawn a pty — which keeps "no slot has zero
    /// panes" true by construction. `Leave` still halves the column the operator is in: a
    /// layout change around them, not a focus change to them.
    pub fn split(&mut self, split: Split, pane: Pane, focus: Focus) -> Result<(), Refusal> {
        if self.pane(pane.id).is_some() {
            return Err(Refusal::DuplicatePane(pane.id));
        }
        // `normalize()` keeps `focused_slot` live, so this refusal is unreachable today — and a
        // refusal rather than a panic, because one bad gesture must not take benchd down.
        let a = self
            .address_of_slot(self.focused_slot)
            .ok_or(Refusal::UnknownSlot(self.focused_slot))?;
        let slot_id = match split {
            Split::Right => {
                let width = self.columns[a.column].width / 2.0;
                self.columns[a.column].width = width;
                let slot = Slot::new(vec![pane], None, 1.0);
                let id = slot.id;
                self.columns
                    .insert(a.column + 1, Column::new(vec![slot], width));
                id
            }
            Split::Down => {
                let height = self.columns[a.column].slots[a.slot].height / 2.0;
                self.columns[a.column].slots[a.slot].height = height;
                let slot = Slot::new(vec![pane], None, height);
                let id = slot.id;
                self.columns[a.column].slots.insert(a.slot + 1, slot);
                id
            }
        };
        if focus == Focus::Take {
            self.focused_slot = slot_id;
        }
        self.normalize();
        Ok(())
    }

    /// ⌘⌥+arrow. Vertical walks the focused column; horizontal steps to the adjacent column
    /// at the same depth, clamped to what it has. Off the edge is a no-op rather than a wrap:
    /// a wrap makes the far edge unreachable by holding the key down.
    pub fn step_focus(&mut self, direction: Direction) {
        // Unreachable while `normalize()` keeps `focused_slot` live; a no-op rather than a panic.
        let Some(a) = self.address_of_slot(self.focused_slot) else {
            return;
        };
        match direction {
            Direction::Up | Direction::Down => {
                let Some(next) = step(a.slot, direction == Direction::Up) else {
                    return;
                };
                if let Some(slot) = self.columns[a.column].slots.get(next) {
                    self.focused_slot = slot.id;
                }
            }
            Direction::Left | Direction::Right => {
                let Some(next) = step(a.column, direction == Direction::Left) else {
                    return;
                };
                if let Some(column) = self.columns.get(next) {
                    self.focused_slot = column.slots[a.slot.min(column.slots.len() - 1)].id;
                }
            }
        }
        self.normalize();
    }

    /// Move a **pane** one step, and answer whether anything moved.
    ///
    /// Addressed: it names the pane it acts on, so "which pane did you mean" is the caller's
    /// answer rather than wherever the operator happens to be looking.
    ///
    /// The geometry is `step_focus`'s. Inside the bench the pane keeps the standing it had:
    /// - a slot to itself, moving up or down — the two slots trade places;
    /// - a slot to itself, moving sideways — the whole slot moves to the adjacent column at
    ///   the depth it had, which is what makes a move its own inverse;
    /// - sharing its slot with tabs — the pane alone leaves and joins the destination slot as
    ///   a tab.
    ///
    /// At the edge the pane leaves for a container of its own (a column at the end of the
    /// bench, a row at the end of its column) **unless it is already the only thing in the
    /// container it would leave** — then the move is a no-op, `Ok(false)`. The edge rule is
    /// what keeps a move reversible: without it every move could reduce the column count and
    /// none could restore it. The guard is what keeps it from churning: the fixed point is one
    /// pane per column, and holding the key down reaches it and stops.
    ///
    /// Sizes: positions keep them within a column (a reorder must not redraw proportions),
    /// and a pane arriving in a stack it was not in takes an equal share.
    ///
    /// **Focus follows the pane only for `Take`,** in one block at the end — the operator
    /// pressing a key is looking at the pane they just moved, and leaving the keyboard in the
    /// vacated slot would send their next keystroke somewhere they are not looking. `Leave` —
    /// an agent moving a pane (#287) — skips that block and nothing else.
    pub fn move_pane(
        &mut self,
        pane: PaneId,
        direction: Direction,
        focus: Focus,
    ) -> Result<bool, Refusal> {
        let from = self.address_of(pane).ok_or(Refusal::UnknownPane(pane))?;
        let alone = self.columns[from.column].slots[from.slot].panes.len() == 1;

        match direction {
            Direction::Up | Direction::Down => {
                let up = direction == Direction::Up;
                match step(from.slot, up).filter(|n| *n < self.columns[from.column].slots.len()) {
                    None => {
                        // The end of the column: a tab leaves for a row of its own; a pane
                        // that already has a row there stays.
                        if alone {
                            return Ok(false);
                        }
                        let at = if up { from.slot } else { from.slot + 1 };
                        self.detach_into_new_slot(pane, from, at);
                    }
                    Some(next) if alone => self.reorder_slots(from.column, from.slot, next),
                    Some(next) => self.detach(pane, from, next, from.column),
                }
            }
            Direction::Left | Direction::Right => {
                let left = direction == Direction::Left;
                match step(from.column, left).filter(|n| *n < self.columns.len()) {
                    None => {
                        // The end of the bench: the same shape one level up, guarded on the
                        // whole column rather than the slot.
                        if !self.column_holds_more_than(pane, from.column) {
                            return Ok(false);
                        }
                        let at = if left { from.column } else { from.column + 1 };
                        self.move_into_new_column(pane, from, at);
                    }
                    Some(next) if alone => self.relocate_slot(from, next),
                    Some(next) => {
                        let depth = from.slot.min(self.columns[next].slots.len() - 1);
                        self.detach(pane, from, depth, next);
                    }
                }
            }
        }
        self.normalize();

        // The whole of "focus follows the pane", in one place, after `normalize()` (which is
        // what drops an emptied slot or column — an address computed before it can name a
        // position that no longer exists).
        if focus == Focus::Take
            && let Some(landed) = self.address_of(pane)
        {
            self.columns[landed.column].slots[landed.slot].selected = pane;
            self.focused_slot = self.columns[landed.column].slots[landed.slot].id;
        }
        Ok(true)
    }

    /// A divider moved: the column takes the fraction it was dragged to, and `neighbour` —
    /// the column on the divider's other side — absorbs exactly the difference. Every other
    /// column keeps what it had, to the digit. Adjacent, and checked rather than assumed: a
    /// pair with a column between them is not a divider.
    pub fn resize_column(
        &mut self,
        id: ColumnId,
        fraction: f64,
        neighbour: ColumnId,
    ) -> Result<(), Refusal> {
        let index = self
            .columns
            .iter()
            .position(|c| c.id == id)
            .ok_or(Refusal::UnknownColumn(id))?;
        let other = self
            .columns
            .iter()
            .position(|c| c.id == neighbour)
            .ok_or(Refusal::UnknownColumn(neighbour))?;
        if index.abs_diff(other) != 1 {
            return Err(Refusal::NotADivider);
        }
        let widths = trading(
            &self.columns.iter().map(|c| c.width).collect::<Vec<_>>(),
            index,
            other,
            fraction,
        );
        for (column, width) in self.columns.iter_mut().zip(widths) {
            column.width = width;
        }
        self.normalize();
        Ok(())
    }

    /// The same trade one level down. Both slots must be in the same column, because that is
    /// the only place a slot divider can sit.
    pub fn resize_slot(
        &mut self,
        id: SlotId,
        fraction: f64,
        neighbour: SlotId,
    ) -> Result<(), Refusal> {
        let a = self.address_of_slot(id).ok_or(Refusal::UnknownSlot(id))?;
        let b = self
            .address_of_slot(neighbour)
            .ok_or(Refusal::UnknownSlot(neighbour))?;
        if a.column != b.column || a.slot.abs_diff(b.slot) != 1 {
            return Err(Refusal::NotADivider);
        }
        let slots = &mut self.columns[a.column].slots;
        let heights = trading(
            &slots.iter().map(|s| s.height).collect::<Vec<_>>(),
            a.slot,
            b.slot,
            fraction,
        );
        for (slot, height) in slots.iter_mut().zip(heights) {
            slot.height = height;
        }
        self.normalize();
        Ok(())
    }

    /// An agent started, stopped being offered, or was declined in a terminal pane (helm #63).
    /// `None` clears the record, which is what answering an offer does. A terminal only:
    /// nothing else can hold an agent.
    pub fn record_agent(
        &mut self,
        pane: PaneId,
        agent: Option<ResumableAgent>,
    ) -> Result<(), Refusal> {
        let a = self.address_of(pane).ok_or(Refusal::UnknownPane(pane))?;
        match &mut self.columns[a.column].slots[a.slot].panes[a.pane].surface {
            Surface::Terminal { agent: held } => {
                *held = agent;
                Ok(())
            }
            _ => Err(Refusal::NotATerminal(pane)),
        }
    }

    // MARK: move helpers

    fn column_holds_more_than(&self, pane: PaneId, column: usize) -> bool {
        self.columns[column]
            .slots
            .iter()
            .any(|s| s.panes.iter().any(|p| p.id != pane))
    }

    /// Two slots of one column trade places; the **positions** keep their heights.
    fn reorder_slots(&mut self, column: usize, from: usize, to: usize) {
        let slots = &mut self.columns[column].slots;
        let heights = (slots[from].height, slots[to].height);
        slots.swap(from, to);
        slots[from].height = heights.0;
        slots[to].height = heights.1;
    }

    /// A whole slot leaves its column for the adjacent one, at the depth it had. The source
    /// column is left slotless for `normalize()` to drop, as `close` does.
    fn relocate_slot(&mut self, from: Address, destination: usize) {
        let mut slot = self.columns[from.column].slots.remove(from.slot);
        slot.height = equal_share(self.columns[destination].slots.len());
        let at = from.slot.min(self.columns[destination].slots.len());
        self.columns[destination].slots.insert(at, slot);
    }

    /// One pane leaves a shared slot and joins another as a tab.
    fn detach(&mut self, pane: PaneId, from: Address, slot: usize, column: usize) {
        let moved = self.take(pane, from);
        self.columns[column].slots[slot].panes.push(moved);
    }

    /// One pane leaves a shared slot for a row of its own in the same column.
    fn detach_into_new_slot(&mut self, pane: PaneId, from: Address, at: usize) {
        let moved = self.take(pane, from);
        let height = equal_share(self.columns[from.column].slots.len());
        self.columns[from.column]
            .slots
            .insert(at, Slot::new(vec![moved], None, height));
    }

    /// One pane leaves for a column of its own at the end of the bench.
    fn move_into_new_column(&mut self, pane: PaneId, from: Address, at: usize) {
        let moved = self.take(pane, from);
        let width = equal_share(self.columns.len());
        self.columns.insert(
            at,
            Column::new(vec![Slot::new(vec![moved], None, 1.0)], width),
        );
    }

    /// Take a pane out of its slot, leaving that slot showing what `close` would leave it
    /// showing — the neighbour at the position the pane left.
    fn take(&mut self, pane: PaneId, from: Address) -> Pane {
        let slot = &mut self.columns[from.column].slots[from.slot];
        let moved = slot.panes.remove(from.pane);
        if slot.selected == pane && !slot.panes.is_empty() {
            slot.selected = slot.panes[from.pane.min(slot.panes.len() - 1)].id;
        }
        moved
    }

    // MARK: invariants

    /// Re-establishes every invariant. Idempotent and cheap, which is the point: no mutation
    /// has to remember which rules it could have broken.
    fn normalize(&mut self) {
        for c in (0..self.columns.len()).rev() {
            for s in (0..self.columns[c].slots.len()).rev() {
                let slot = &mut self.columns[c].slots[s];
                if slot.panes.is_empty() {
                    self.columns[c].slots.remove(s);
                } else if !slot.holds(slot.selected) {
                    slot.selected = slot.panes[0].id;
                }
            }
            if self.columns[c].slots.is_empty() {
                self.columns.remove(c);
            }
        }
        // Unreachable through a mutation — `close` refuses the last pane — and a decoded
        // bench with no panes is refused before it gets here.
        if self.columns.is_empty() {
            return;
        }
        if self.slot(self.focused_slot).is_none() {
            self.focused_slot = self.columns[0].slots[0].id;
        }
        let widths = balanced(&self.columns.iter().map(|c| c.width).collect::<Vec<_>>());
        for (column, width) in self.columns.iter_mut().zip(widths) {
            column.width = width;
        }
        for column in &mut self.columns {
            let heights = balanced(&column.slots.iter().map(|s| s.height).collect::<Vec<_>>());
            for (slot, height) in column.slots.iter_mut().zip(heights) {
                slot.height = height;
            }
        }
    }

    fn address_of(&self, pane: PaneId) -> Option<Address> {
        for (ci, column) in self.columns.iter().enumerate() {
            for (si, slot) in column.slots.iter().enumerate() {
                if let Some(pi) = slot.panes.iter().position(|p| p.id == pane) {
                    return Some(Address {
                        column: ci,
                        slot: si,
                        pane: pi,
                    });
                }
            }
        }
        None
    }

    fn address_of_slot(&self, slot: SlotId) -> Option<Address> {
        for (ci, column) in self.columns.iter().enumerate() {
            if let Some(si) = column.slots.iter().position(|s| s.id == slot) {
                return Some(Address {
                    column: ci,
                    slot: si,
                    pane: 0,
                });
            }
        }
        None
    }

    /// Focus after the focused slot was removed: the slot that took its place, else the one
    /// above it, else the same depth in the column that took its place. Never a dead id, and
    /// never all the way back to the first slot — the operator was looking here.
    fn refocus_near(&mut self, a: Address) {
        if self.columns.is_empty() {
            return;
        }
        let column = &self.columns[a.column.min(self.columns.len() - 1)];
        self.focused_slot = if column.slots.is_empty() {
            self.columns[0].slots[0].id
        } else {
            column.slots[a.slot.min(column.slots.len() - 1)].id
        };
    }
}

/// One step from `index` toward the start (`back`) or the end; `None` off the start. The end
/// is the caller's to bound, because only it knows the length.
fn step(index: usize, back: bool) -> Option<usize> {
    if back {
        index.checked_sub(1)
    } else {
        Some(index + 1)
    }
}

/// The share a newcomer arrives with so that `normalize()` lands an `n`-member stack on
/// `1/(n+1)` each — every member already there keeping its proportion to the others.
fn equal_share(members: usize) -> f64 {
    if members > 0 {
        1.0 / members as f64
    } else {
        1.0
    }
}

/// Fractions that are positive, finite and sum to 1. A member arriving non-positive or
/// non-finite is given the equal share rather than dropped, because dropping it would mean
/// dropping the pane it sizes.
fn balanced(fractions: &[f64]) -> Vec<f64> {
    if fractions.is_empty() {
        return Vec::new();
    }
    let equal = 1.0 / fractions.len() as f64;
    let repaired: Vec<f64> = fractions
        .iter()
        .map(|f| if f.is_finite() && *f > 0.0 { *f } else { equal })
        .collect();
    let total: f64 = repaired.iter().sum();
    if total <= 0.0 {
        return vec![equal; fractions.len()];
    }
    repaired.iter().map(|f| f / total).collect()
}

/// Two members trading what the two of them have, and nobody else touched. Clamped at
/// `MINIMUM_FRACTION` on both sides — and at half the pair when the pair is smaller than two
/// of those, so the clamp can never hand out more than there is.
fn trading(fractions: &[f64], index: usize, neighbour: usize, fraction: f64) -> Vec<f64> {
    let pair = fractions[index].max(0.0) + fractions[neighbour].max(0.0);
    let least = MINIMUM_FRACTION.min(pair / 2.0);
    let mut traded = fractions.to_vec();
    traded[index] = fraction.max(least).min(pair - least);
    traded[neighbour] = pair - traded[index];
    traded
}

/// What a stored bench looks like before `normalize()` has seen it. Decoding goes through
/// here so a hand-edited `bench.json` comes back repaired rather than half-broken — except
/// for the one state nothing can repair: a bench with no panes has nothing to render and
/// nothing to invent, so it is refused.
#[derive(Deserialize)]
struct EncodedBench {
    columns: Vec<Column>,
    focused_slot: SlotId,
}

impl TryFrom<EncodedBench> for Bench {
    type Error = String;

    fn try_from(raw: EncodedBench) -> Result<Self, Self::Error> {
        if !raw
            .columns
            .iter()
            .any(|c| c.slots.iter().any(|s| !s.panes.is_empty()))
        {
            return Err("a bench with no panes is not a bench".into());
        }
        Ok(Bench::build(raw.columns, raw.focused_slot))
    }
}
