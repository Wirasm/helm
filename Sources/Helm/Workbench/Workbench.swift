import Foundation

// MARK: - Workbench

/// The pane arrangement inside one workspace: N columns, each a vertical stack of
/// slots, each slot tabbed. Depth-2 — a strict subset of a general split tree, so
/// nothing is foreclosed, and there is no "horizontal or vertical?" decision at
/// every insertion (#23).
///
/// A value, not a tree of live objects: persistence, restore and equality come free,
/// and every rule below is exercisable without a window, a pty or a webview. The
/// live objects a pane *names* — a `TerminalSession` or a `CanvasModel` — are resolved
/// at the edge by `WorkbenchModel`, which is the only thing here that needs a runtime.
///
/// Invariants — re-established by `normalize()` after EVERY mutation:
/// - `columns` is never empty; no column has zero slots; no slot has zero panes.
/// - `focusedSlot` always names a slot that exists.
/// - every `Slot.selected` names a pane that slot holds.
/// - `width`/`height` fractions in a stack are positive and sum to 1.
///
/// `columns` and `focusedSlot` are `private(set)` on purpose. Every rule that changes
/// them is a method in **this file**; an extension elsewhere needing to mutate them is
/// the signal the rule was put in the wrong place (`AGENTS.md`), not a reason to widen
/// access. `WorkbenchPlacement.swift` reads and decides, and never writes.
struct Workbench: Codable, Equatable {
    private(set) var columns: [Column]
    /// The slot the operator's next command targets. A slot **id**, never an index:
    /// an index goes stale the moment anything is inserted before it.
    private(set) var focusedSlot: Slot.ID

    /// The smallest share of a stack any one member may be squeezed to. A divider
    /// dragged to the edge leaves a sliver you can grab again rather than a pane you
    /// cannot get back.
    static let minimumFraction = 0.05

    // MARK: - Construction

    private init(columns: [Column], focusedSlot: Slot.ID) {
        self.columns = columns
        self.focusedSlot = focusedSlot
        normalize()
    }

    /// The bench helm has always rendered: one column, one slot, one terminal. This is
    /// what a first-run workspace gets, and what `RootView` drew before there was a bench.
    init(terminal id: Pane.ID) {
        self.init(panes: [Pane(id: id, content: .terminal(face: .terminal))])
    }

    /// One column, one slot, these panes as tabs — today's frame with N terminals in it.
    /// An empty `panes` is a caller error rather than a state: it would violate the first
    /// invariant, and there is nothing here that could invent a pane to repair it.
    init(panes: [Pane], selecting selected: Pane.ID? = nil) {
        let slot = Slot(panes: panes, selected: selected)
        self.init(columns: [Column(slots: [slot])], focusedSlot: slot.id)
    }

    /// The bench a pre-bench context describes, so an operator relaunching onto the first
    /// bench build gets back exactly the frame they left:
    /// column 0 — one slot, the persisted terminals as tabs, `selectedTerminalID` selected;
    /// column 1 — one slot, one canvas on `openArtifactPath`, when there was one.
    ///
    /// Two columns rather than one, because that is what the operator SAW: the canvas was
    /// a right dock beside the terminal, never a tab on it.
    ///
    /// nil when there is nothing to migrate — `WorkbenchModel.activate` then builds the
    /// default 1×1 bench, and a first-run workspace behaves exactly as it always has.
    static func migrating(from context: WorkspaceContext) -> Workbench? {
        guard !context.terminalSessionIDs.isEmpty else { return nil }
        // Every migrated terminal pane is `.terminal(face: .terminal)`. Nothing ever wrote
        // a face, and a restored shell comes back empty anyway.
        let terminals = context.terminalSessionIDs.map {
            Pane(id: $0, content: .terminal(face: .terminal))
        }
        var bench = Workbench(panes: terminals, selecting: context.selectedTerminalID)
        // `openArtifactPath` is a FILE path only — that is the whole point of the field,
        // and the reason #38 persisted nothing for a URL canvas. There is no URL to
        // recover here, and inventing one would reintroduce exactly the bug it refused.
        if let path = context.openArtifactPath {
            bench.insert(
                Pane(content: .canvas(.file(path))), at: .column)
            // The operator was looking at their terminal, not at the dock.
            bench.focus(bench.columns[0].slots[0].id)
        }
        return bench
    }

    // MARK: - Readers

    /// Every pane in the bench, in column → slot → tab order.
    var panes: [Pane] { columns.flatMap { $0.slots.flatMap(\.panes) } }

    var slots: [Slot] { columns.flatMap(\.slots) }

    /// The pane the operator's next command acts on: the focused slot's selected pane.
    var focusedPane: Pane? {
        guard let slot = slot(focusedSlot) else { return nil }
        return slot.panes.first { $0.id == slot.selected }
    }

    /// Every terminal pane's id, in bench order — which is exactly what
    /// `TerminalManager.activate(restoring:)` wants, because a terminal pane's id **is**
    /// its session id.
    var terminalPaneIDs: [Pane.ID] {
        panes.compactMap { if case .terminal = $0.content { $0.id } else { nil } }
    }

    var canvasPanes: [Pane] {
        panes.filter { if case .canvas = $0.content { true } else { false } }
    }

    /// The panes actually on screen: one per slot. Several at once, which is the whole
    /// difference between a bench and a tab row, and why `TerminalSession.isVisible`
    /// replaced a single app-level `selectedID`.
    var visiblePaneIDs: Set<Pane.ID> { Set(slots.map(\.selected)) }

    func slot(_ id: Slot.ID) -> Slot? { slots.first { $0.id == id } }

    func pane(_ id: Pane.ID) -> Pane? { panes.first { $0.id == id } }

    /// The slot holding a pane — what a tab strip needs to know to render it.
    func slot(for pane: Pane.ID) -> Slot? {
        slots.first { $0.panes.contains { $0.id == pane } }
    }

    /// A pane already showing this exact source, if there is one. The reason
    /// ⌘-clicking the same link twice selects the canvas you already have instead of
    /// opening a second copy of it.
    func pane(showing source: CanvasSource) -> Pane.ID? {
        panes.first { $0.content == .canvas(source) }?.id
    }

    /// Which face a slot's strip should offer, or nil when that slot's selected pane is a
    /// non-terminal and there is no face to offer. The strip renders `if let` on this rather
    /// than asking what kind of pane it is — that question is a decision, and decisions
    /// live here.
    func face(ofSelectedPaneIn slot: Slot.ID) -> TerminalFace? {
        guard let slot = self.slot(slot),
            let pane = slot.panes.first(where: { $0.id == slot.selected }),
            case let .terminal(face) = pane.content
        else { return nil }
        return face
    }

    /// The last pane of the bench cannot close — the generalisation of
    /// `TerminalManager.canClose`, which refused the last terminal for the same reason:
    /// a helm with nothing in it is not a state worth being able to reach.
    func canClose(_ pane: Pane.ID) -> Bool {
        panes.contains { $0.id == pane } && panes.count > 1
    }

    // MARK: - Mutations

    /// Put a pane where `Placement` says. Selecting an already-open pane is a placement
    /// too (`.existing`), so "open this" is one call whether or not it is already here.
    ///
    /// **Shares its shape with `offer(_:at:)` on purpose, not by oversight.** The two
    /// switches are deliberately parallel and independently auditable; read that method's
    /// doc comment and `WorkbenchOfferTests` before merging them behind a flag.
    mutating func insert(_ pane: Pane, at placement: Placement) {
        switch placement {
        case let .existing(id):
            select(id)
            return
        case let .tab(slotID):
            guard let address = address(ofSlot: slotID) else { return }
            columns[address.column].slots[address.slot].panes.append(pane)
            columns[address.column].slots[address.slot].selected = pane.id
            focusedSlot = slotID
        case let .row(columnID):
            guard let index = columns.firstIndex(where: { $0.id == columnID }) else { return }
            let slot = Slot(panes: [pane])
            columns[index].slots.append(slot)
            focusedSlot = slot.id
        case .column:
            let slot = Slot(panes: [pane])
            columns.append(Column(slots: [slot]))
            focusedSlot = slot.id
        }
        normalize()
    }

    /// Put a pane on the bench **without selecting it and without moving focus** — an
    /// agent's push (#125), as against `insert`, which is the operator asking.
    ///
    /// *Appear, don't seize.* #33 ruled against a control channel because *"it's not helm's
    /// job to decide for me how to organize"*, and the harm it names is real — but it is
    /// about **when**, not whether. taskade measured the same thing before they added
    /// presence: users called agent-driven change *"unsettling"*, and their rule is that
    /// human operations always process before agent operations. So a pushed artifact
    /// arrives as a tab you can reach, never as a pane that replaces what you were reading.
    ///
    /// The two things that must not move are `selected` — what a slot is showing — and
    /// `focusedSlot`, which is what every bench-level command acts on. Leaving both alone
    /// is also what keeps the keyboard where it was: `claimsKeyboard` only acts on a
    /// `false → true` edge, and nothing claims first responder for a canvas.
    ///
    /// Safe against `normalize()` by construction: it only repairs `selected` when the
    /// current value names no pane the slot holds, and never steers it toward a newly
    /// appended one.
    mutating func offer(_ pane: Pane, at placement: Placement) {
        switch placement {
        case .existing:
            // Already here, and it stays where it is: pulling it forward would be the seizing
            // this exists to avoid, and an agent re-offering the artifact it just rewrote is
            // the common case.
            //
            // **"Where it is" is arrangement, not content.** Re-rendering that pane is
            // `WorkbenchModel.offer`'s (#261) — this type holds values and cannot reach a
            // `CanvasModel` — so nothing here should be read as saying a re-push shows the
            // operator the same bytes.
            return
        case let .tab(slotID):
            guard let address = address(ofSlot: slotID) else { return }
            columns[address.column].slots[address.slot].panes.append(pane)
        case let .row(columnID):
            guard let index = columns.firstIndex(where: { $0.id == columnID }) else { return }
            // A brand-new slot shows its only pane, which displaces nothing.
            columns[index].slots.append(
                Slot(panes: [pane], height: Self.equalShare(joining: columns[index].slots.count)))
        case .column:
            columns.append(
                Column(
                    slots: [Slot(panes: [pane])],
                    width: Self.equalShare(joining: columns.count)))
        }
        normalize()
    }

    /// The fraction a newcomer arrives with so that `normalize()` lands an `n`-member stack
    /// on `1/(n+1)` each — every existing member keeping its proportion to the others, and
    /// none of them halved to make room.
    ///
    /// The `1` a `Slot` or `Column` is built with by default means *the whole stack*, which
    /// after rebalancing is **half** of whatever was there. That is right for the first
    /// canvas arriving beside a lone terminal — the dock, at 50/50 — and progressively wrong
    /// after it: the third pane offered into a column takes half of the column and squeezes
    /// the operator's two into a quarter each, the fourth leaves the oldest at an eighth.
    /// A spool spawn is a row (#177), so that is now something that happens repeatedly and
    /// unbidden, and shrinking the pane somebody is working in is its own kind of seizing.
    ///
    /// `insert` keeps the old sizing deliberately: it is the operator's own gesture, and a
    /// canvas they ⌘-clicked open landing at half the bench is what #125 measured and shipped.
    private static func equalShare(joining members: Int) -> Double {
        members > 0 ? 1 / Double(members) : 1
    }

    /// Closes a pane, and reports whether it did. Generalises `TerminalManager.close`
    /// one level: closing the selected pane selects the neighbour **at the closed
    /// position**, an emptied slot goes, an emptied column goes, and the bench's last
    /// pane refuses.
    @discardableResult
    mutating func close(_ pane: Pane.ID) -> Bool {
        guard canClose(pane), let address = address(of: pane) else { return false }
        let closedSlot = columns[address.column].slots[address.slot]
        columns[address.column].slots[address.slot].panes.remove(at: address.pane)

        let survivors = columns[address.column].slots[address.slot].panes
        if survivors.isEmpty {
            columns[address.column].slots.remove(at: address.slot)
            if columns[address.column].slots.isEmpty {
                columns.remove(at: address.column)
            }
            if focusedSlot == closedSlot.id { refocusNear(address) }
        } else if closedSlot.selected == pane {
            columns[address.column].slots[address.slot].selected =
                survivors[min(address.pane, survivors.count - 1)].id
        }
        normalize()
        return true
    }

    /// Select a pane, and focus the slot holding it — clicking a tab is also saying
    /// "this is the pane I mean now".
    mutating func select(_ pane: Pane.ID) {
        guard let address = address(of: pane) else { return }
        columns[address.column].slots[address.slot].selected = pane
        focusedSlot = columns[address.column].slots[address.slot].id
        normalize()
    }

    mutating func focus(_ slot: Slot.ID) {
        guard self.slot(slot) != nil else { return }
        focusedSlot = slot
        normalize()
    }

    /// ⌘D — a new column immediately right of the focused one, holding this pane, and
    /// focus follows it. The two halves share what the focused column had.
    ///
    /// It takes the pane rather than minting one: a bench is a pure value and cannot
    /// spawn a pty or open a file. `WorkbenchModel` creates the tenant and hands it here,
    /// which is what keeps "no slot has zero panes" true by construction instead of by
    /// a repair pass.
    mutating func splitRight(with pane: Pane) {
        splitRight(pane, movingFocus: true)
    }

    /// The same split, **without moving focus** — an agent asking (#269), as against
    /// `splitRight(with:)`, which is the operator pressing ⌘D.
    ///
    /// *Appear, don't seize*, exactly as `offer(_:at:)` is to `insert(_:at:)` and for the same
    /// reason: the operator may be mid-sentence in the column being split, and a new empty
    /// shell taking the keyboard sends their next keystrokes somewhere they did not look. The
    /// column still halves, which is a layout change around them rather than a focus change to
    /// them — see `SpoolCommandPolicy`, which is the only caller and argues that trade.
    mutating func splitRight(offering pane: Pane) {
        splitRight(pane, movingFocus: false)
    }

    /// One body for both, because the two differ in exactly one line and a second copy of the
    /// halving arithmetic is a drift waiting to happen. The flag is private; the difference is
    /// spelled at the two entry points, where a reader is.
    private mutating func splitRight(_ pane: Pane, movingFocus: Bool) {
        guard let address = address(ofSlot: focusedSlot) else { return }
        let width = columns[address.column].width / 2
        columns[address.column].width = width
        let slot = Slot(panes: [pane])
        columns.insert(Column(slots: [slot], width: width), at: address.column + 1)
        if movingFocus { focusedSlot = slot.id }
        normalize()
    }

    /// ⌘⇧D — a new row under the focused slot, in the same column. See `splitRight`
    /// for why the pane comes in rather than being made here.
    mutating func splitDown(with pane: Pane) {
        splitDown(pane, movingFocus: true)
    }

    /// The same row, without moving focus. See `splitRight(offering:)`.
    mutating func splitDown(offering pane: Pane) {
        splitDown(pane, movingFocus: false)
    }

    private mutating func splitDown(_ pane: Pane, movingFocus: Bool) {
        guard let address = address(ofSlot: focusedSlot) else { return }
        let height = columns[address.column].slots[address.slot].height / 2
        columns[address.column].slots[address.slot].height = height
        let slot = Slot(panes: [pane], height: height)
        columns[address.column].slots.insert(slot, at: address.slot + 1)
        if movingFocus { focusedSlot = slot.id }
        normalize()
    }

    /// ⌘⌥←↑↓→. Vertical movement walks the focused column's slots; horizontal movement
    /// steps to the adjacent column and lands at the same depth, clamped to what that
    /// column actually has. Movement off the edge is a no-op rather than a wrap: a wrap
    /// makes the far edge unreachable by holding the key down.
    mutating func moveFocus(_ direction: Direction) {
        guard let address = address(ofSlot: focusedSlot) else { return }
        switch direction {
        case .up, .down:
            let next = address.slot + (direction == .up ? -1 : 1)
            guard columns[address.column].slots.indices.contains(next) else { return }
            focusedSlot = columns[address.column].slots[next].id
        case .left, .right:
            let next = address.column + (direction == .left ? -1 : 1)
            guard columns.indices.contains(next) else { return }
            let slots = columns[next].slots
            focusedSlot = slots[min(address.slot, slots.count - 1)].id
        }
        normalize()
    }

    /// ⌘⌥⇧←↑↓→ — move a **pane** one step. `moveFocus` above moves the keyboard and leaves the
    /// bench alone; this moves the bench and, for the reason argued below, takes the keyboard
    /// with it. Reports whether anything moved, as `close` does.
    ///
    /// **Addressed, and that is what makes it different from every other bench command.** It
    /// names the pane it acts on rather than reading `focusedSlot`, so "which pane did you mean"
    /// is answered by the caller instead of by wherever the operator happens to be looking. The
    /// keyboard route passes `focusedPane`; #287's other caller — an agent — will pass a pane it
    /// owns, and that is only possible because the address is a parameter.
    ///
    /// **The geometry is `moveFocus`'s, deliberately.** Vertical steps within the pane's own
    /// column; horizontal steps to the adjacent column and land at the same depth, clamped to
    /// what that column has.
    ///
    /// **Inside the bench, the pane keeps the standing it had.**
    /// - A slot to itself, moving up or down — the two slots trade places, which is what a
    ///   reorder gesture means everywhere else. Merging it into the neighbour as a tab would
    ///   *hide* a pane the operator could see, on a keystroke that says "move".
    /// - A slot to itself, moving sideways — the whole slot leaves its column and is inserted
    ///   into the adjacent one at the depth it had. The pane stays visible, and the depth is
    ///   what makes the move its own inverse: sent right from depth 1 it arrives at depth 1, and
    ///   sent back it lands where it set off from.
    /// - Sharing its slot with tabs — the pane alone leaves and joins the destination slot as a
    ///   tab. It had no slot to itself, so it is not given one.
    ///
    /// **At the edge the pane leaves for a container of its own** — a column at the end of the
    /// bench, a row at the end of its column — **unless it is already the only thing in the
    /// container it would leave**, in which case there is nothing to leave and the move is a
    /// no-op.
    ///
    /// This is the one place the geometry departs from `moveFocus`, which has nothing to create
    /// and so simply stops. **It is what makes a move reversible, and reversibility is the whole
    /// argument.** Moving a two-column bench's right-hand pane left empties that column, and an
    /// emptied column goes — so without an edge rule the bench is a ratchet: every move can
    /// reduce the column count and no move can ever restore it, leaving the operator with
    /// exactly the "close it and make a new one" #287 is about. With it, ⌘⌥⇧← then ⌘⌥⇧→ returns
    /// the pane to the column it came from. The guard is what keeps that from being churn: a
    /// pane that is the only thing in the last column would be torn out of it and put back into
    /// an identical new one, which is a no-op with a rebuilt column id, so it refuses instead.
    /// The fixed point is one pane per column, and holding the key down reaches it and stops.
    ///
    /// **It is not a second ⌘D.** A split makes a *new terminal*; this only ever relocates a
    /// pane that already exists, and the bench's pane count never changes.
    ///
    /// **An emptied column goes the way `close` already sends one.** Moving a column's last pane
    /// out leaves a slotless column, and `normalize()` drops it and rebalances the widths —
    /// which is the same repair pass `close` leans on, not a second rule invented here.
    ///
    /// **Sizes: positions keep them within a column, and are not carried across one.** A
    /// reorder swaps who sits in each row and leaves the rows the size the operator dragged them
    /// to — a move reorders panes, it must not silently redraw proportions. Anywhere a pane
    /// arrives in a stack it was not in, there is nothing to keep: 0.5 *of the old column* is not
    /// a measurement of the new one, so the newcomer takes `equalShare(joining:)`, the same
    /// arithmetic `offer` uses so that nobody already there is halved to make room.
    ///
    /// ## Focus follows the pane, and that is a decision about **who asked**
    ///
    /// This caller is the operator, pressing a key, looking at the pane they just moved. Leaving
    /// their keyboard behind in the slot the pane vacated would mean their next keystroke goes
    /// to a pane they are no longer looking at — the wrong-terminal defect `AGENTS.md` bans
    /// hard-coded coordinates over, produced deliberately. So focus follows, in **one block at
    /// the end of this method** — it finds where the pane landed and puts the keyboard there,
    /// whichever branch above did the moving.
    ///
    /// **That block is the entire focus behaviour, and that is deliberate rather than tidy.**
    /// It began as three assignments inside the helpers, one per branch that hands the pane to a
    /// different slot, each carrying a comment saying an agent's version would drop it. Three
    /// sites is three things to find, and `detach` had *two* assigning lines under one of those
    /// comments — the shape where a later author ports two of three and the third is a focus
    /// change nobody meant. As one block the claim needs no comment to be true.
    ///
    /// **The agent caller needs the opposite, and must not inherit this by accident.** #269's
    /// rule is *rearranging the bench is fine, taking focus is not*: an agent moving a pane
    /// while the operator is mid-sentence must leave `focusedSlot` and every slot's `selected`
    /// exactly where they were. helm has drawn that distinction since #125 and names both halves
    /// — `insert`/`offer`, `splitRight(with:)`/`splitRight(offering:)`.
    ///
    /// **Why this is a block and not `splitRight`'s `movingFocus: Bool`.** That flag is right
    /// where there are *two* entry points, and `splitRight(with:)`/`splitRight(offering:)` each
    /// supply one. A move has one caller today, so the same flag would ship a `false` branch no
    /// test exercises and no caller reaches — an untested path that reads as a proven one, which
    /// is worse than none. When #287's follow-up adds the second entry point it can take the
    /// flag, and this block is what moves behind it; until then the twin is a deletion of one
    /// contiguous block rather than a hand-port of scattered lines.
    /// `SpoolCommandPolicy.verdict(for: .movePane)` is where an agent is refused today, and it
    /// says the same thing from the other side — together with the `helm-command` kind that
    /// would reach the twin and absolute `(column, slot)` addressing for a caller that computed
    /// a destination from `snapshot.json`.
    @discardableResult
    mutating func move(_ pane: Pane.ID, _ direction: Direction) -> Bool {
        guard let from = address(of: pane) else { return false }
        // The whole of the "keeps the standing it had" rule, asked before anything moves: the
        // source slot survives a pane leaving it only when it held more than one.
        let alone = columns[from.column].slots[from.slot].panes.count == 1

        switch direction {
        case .up, .down:
            let next = from.slot + (direction == .up ? -1 : 1)
            guard columns[from.column].slots.indices.contains(next) else {
                // The end of the column. A tab leaves for a row of its own; a pane that already
                // has a row there is at the end and stays.
                guard !alone else { return false }
                detachIntoNewSlot(pane, from: from, at: direction == .up ? from.slot : next)
                break
            }
            if alone {
                reorderSlots(in: from.column, from: from.slot, to: next)
            } else {
                detach(pane, from: from, intoSlot: next, of: from.column)
            }
        case .left, .right:
            let next = from.column + (direction == .left ? -1 : 1)
            guard columns.indices.contains(next) else {
                // The end of the bench. Same shape one level up, and the guard is about the
                // whole column rather than the slot: a pane alone in the last column would be
                // torn out and put back into an identical new one.
                guard columnHoldsMore(than: pane, at: from.column) else { return false }
                moveIntoNewColumn(
                    pane, from: from, at: direction == .left ? from.column : next)
                break
            }
            if alone {
                relocateSlot(from: from, toColumn: next)
            } else {
                detach(
                    pane, from: from,
                    intoSlot: min(from.slot, columns[next].slots.count - 1), of: next)
            }
        }
        normalize()

        // **The whole of "focus follows the pane", in one place — and the whole of what an
        // offering twin drops.** It was three assignments scattered across the helpers, each
        // carrying a comment saying so; a claim spread over three sites is a claim the next
        // author has to find all of, and `detach` had two assigning lines under one of those
        // comments. One block after the fact needs no marks: the twin is a deletion.
        //
        // *After* `normalize()`, because that is what drops an emptied slot or column — an
        // address computed before it can name a position that no longer exists. Nothing here
        // can break an invariant `normalize()` just established: the pane is in the slot being
        // selected, and the slot is one the bench holds.
        // Unreachable, and not an assertion for `normalize()`'s reason: `move` has already
        // returned `false` for a pane the bench does not hold, and every branch above relocates
        // that pane rather than removing it — `normalize()` drops empty slots and columns, never
        // a pane. The move still happened, so `true` is the honest answer if it ever were reached.
        guard let landed = address(of: pane) else { return true }
        columns[landed.column].slots[landed.slot].selected = pane
        focusedSlot = columns[landed.column].slots[landed.slot].id
        return true
    }

    /// Whether this column holds anything besides that one pane — the edge rule's guard, and
    /// the reason a lone pane in the last column cannot churn its way sideways for ever.
    private func columnHoldsMore(than pane: Pane.ID, at column: Int) -> Bool {
        columns[column].slots.contains { $0.panes.contains { $0.id != pane } }
    }

    /// Two slots of one column trade places, and the **positions** keep their heights — see
    /// `move`, which is the only caller and holds the argument.
    private mutating func reorderSlots(in column: Int, from: Int, to: Int) {
        let heights = (columns[column].slots[from].height, columns[column].slots[to].height)
        columns[column].slots.swapAt(from, to)
        columns[column].slots[from].height = heights.0
        columns[column].slots[to].height = heights.1
    }

    /// A whole slot leaves its column for the adjacent one, at the depth it had.
    ///
    /// The source column is left slotless rather than removed here: `normalize()` drops it on
    /// the way out, which is the same repair `close` relies on, and removing it inline would
    /// shift `destination` under the insert below.
    private mutating func relocateSlot(from: Address, toColumn destination: Int) {
        var slot = columns[from.column].slots.remove(at: from.slot)
        slot.height = Self.equalShare(joining: columns[destination].slots.count)
        columns[destination].slots.insert(
            slot, at: min(from.slot, columns[destination].slots.count))
    }

    /// One pane leaves a shared slot and joins another as a tab.
    ///
    /// The source slot keeps at least one pane — `move` only routes here when it held more than
    /// one — so every index computed before the removal is still valid after it, including a
    /// destination in the same column.
    private mutating func detach(
        _ pane: Pane.ID, from: Address, intoSlot slot: Int, of column: Int
    ) {
        let moved = take(pane, from: from)
        columns[column].slots[slot].panes.append(moved)
    }

    /// One pane leaves a shared slot for a row of its own at the end of the same column.
    ///
    /// Only reached with a slot holding more than one pane, so the row count is unchanged by the
    /// removal and `equalShare` is measuring the stack this row is joining.
    private mutating func detachIntoNewSlot(_ pane: Pane.ID, from: Address, at index: Int) {
        let moved = take(pane, from: from)
        columns[from.column].slots.insert(
            Slot(
                panes: [moved],
                height: Self.equalShare(joining: columns[from.column].slots.count)),
            at: index)
    }

    /// One pane leaves for a column of its own at the end of the bench.
    ///
    /// The source column survives the removal — `columnHoldsMore` is exactly that guarantee —
    /// so inserting beside it cannot strand an index. Its slot may be left empty, which is
    /// `normalize()`'s to clear, as it is for `close`.
    private mutating func moveIntoNewColumn(_ pane: Pane.ID, from: Address, at index: Int) {
        let moved = take(pane, from: from)
        columns.insert(
            Column(slots: [Slot(panes: [moved])], width: Self.equalShare(joining: columns.count)),
            at: index)
    }

    /// Take a pane out of the slot holding it, leaving that slot showing what `close` would
    /// leave it showing — the neighbour at the position the pane left. A slot emptied this way
    /// is `normalize()`'s to remove, exactly as an emptied column is after a close.
    private mutating func take(_ pane: Pane.ID, from: Address) -> Pane {
        let moved = columns[from.column].slots[from.slot].panes.remove(at: from.pane)
        let survivors = columns[from.column].slots[from.slot].panes
        if columns[from.column].slots[from.slot].selected == pane, !survivors.isEmpty {
            columns[from.column].slots[from.slot].selected =
                survivors[min(from.pane, survivors.count - 1)].id
        }
        return moved
    }

    /// A divider moved: the column takes the fraction it was dragged to, and `neighbour` —
    /// the column on the divider's other side — absorbs exactly the difference. Every other
    /// column keeps what it had, to the digit.
    ///
    /// **A divider is between two members and nothing else.** This used to give the dragged
    /// column its fraction and share the remainder over all the others in proportion, which
    /// is the right rule for a measurement of the whole stack and the wrong one for a drag:
    /// in the operator's 2+1+1 bench, moving one divider quietly moved the two columns
    /// nobody had touched.
    ///
    /// **Adjacent, and checked rather than assumed.** A pair with a column between them is
    /// not a divider, and trading across one would leave that column untouched while the two
    /// either side of it moved — the same defect this method exists to remove, reached
    /// through a different door. The only caller hands over `members[i]` and `members[i+1]`,
    /// so this cannot fire today; it is here because the sentence above is a claim about
    /// what the type permits, and a claim the guard did not enforce is just a comment.
    mutating func resizeColumn(_ id: Column.ID, to fraction: Double, against neighbour: Column.ID) {
        guard let index = columns.firstIndex(where: { $0.id == id }),
            let other = columns.firstIndex(where: { $0.id == neighbour }),
            abs(index - other) == 1
        else { return }
        let widths = Self.trading(columns.map(\.width), at: index, with: other, to: fraction)
        for (offset, width) in widths.enumerated() { columns[offset].width = width }
        normalize()
    }

    /// The same trade one level down, and adjacent for the same reason. Both slots must also
    /// be in the same column, because that is the only place a slot divider can sit.
    mutating func resizeSlot(_ id: Slot.ID, to fraction: Double, against neighbour: Slot.ID) {
        guard let other = address(ofSlot: neighbour), let address = address(ofSlot: id),
            address.column == other.column, abs(address.slot - other.slot) == 1
        else { return }
        let heights = Self.trading(
            columns[address.column].slots.map(\.height), at: address.slot, with: other.slot,
            to: fraction)
        for (offset, height) in heights.enumerated() {
            columns[address.column].slots[offset].height = height
        }
        normalize()
    }

    /// ⌘T — swap the **focused pane's** two faces.
    ///
    /// **A no-op when the focused pane is a canvas**, which is ⌘T's whole rule and is a
    /// line of `Workbench` rather than a line of a view. It was `Bool.toggle()` inside
    /// `TerminalWorkspace`: one flag for the whole vertical, carried along when the
    /// operator switched tabs, and unreachable from `swift test`.
    mutating func toggleFace() {
        guard let address = address(ofSlot: focusedSlot) else { return }
        let slot = columns[address.column].slots[address.slot]
        guard let index = slot.panes.firstIndex(where: { $0.id == slot.selected }),
            case let .terminal(face) = slot.panes[index].content
        else { return }
        columns[address.column].slots[address.slot].panes[index].content =
            .terminal(face: face == .terminal ? .chat : .terminal)
        normalize()
    }

    /// A canvas went somewhere: the address on a ⌘L pane was committed, or a page followed a
    /// link. The pane is what carries the source, so this is what the bench persists.
    ///
    /// **The bench used to learn a canvas's source once and never again**, which is fine for
    /// the two openings that know it before the pane exists — a file, and a ⌘-clicked link —
    /// and wrong for ⌘L, which opens `.empty` because at that moment there is no address.
    /// The URL that followed reached the live `CanvasModel` and nothing else, so the pane
    /// persisted `{"kind":"empty"}` while the canvas was displaying a page, and a relaunch
    /// gave back a blank one (#89).
    ///
    /// **A canvas pane only.** Nothing else can hold a source, and a terminal pane quietly
    /// becoming a canvas is not a repair — it is a pane whose pty has nowhere to render.
    ///
    /// **It does not defend `pane(showing:)`'s "one pane per source".** That rule is
    /// `placement(forOpening:)`'s, and it holds for every canvas that is *opened*; two panes
    /// can now reach the same source by navigation — ⌘-click a link into one canvas, then
    /// type that address into another. Nothing breaks (no invariant here is about content,
    /// and `normalize()` does not care), but `pane(showing:)` picks the first of the two, so
    /// a later ⌘-click on that URL selects whichever comes first in bench order. Deduping
    /// here instead would mean closing or merging a pane the operator is looking at, which
    /// is a worse answer than an arbitrary one.
    mutating func repoint(_ pane: Pane.ID, to source: CanvasSource) {
        guard let address = address(of: pane), case .canvas = self.pane(pane)?.content
        else { return }
        columns[address.column].slots[address.slot].panes[address.pane].content = .canvas(source)
        normalize()
    }

    // MARK: - Invariants

    /// Re-establishes all four invariants. Idempotent, and cheap enough to run after
    /// every mutation — which is the point: no mutation has to remember which rules it
    /// could have broken.
    private mutating func normalize() {
        for columnIndex in columns.indices.reversed() {
            for slotIndex in columns[columnIndex].slots.indices.reversed() {
                let slot = columns[columnIndex].slots[slotIndex]
                if slot.panes.isEmpty {
                    columns[columnIndex].slots.remove(at: slotIndex)
                } else if !slot.panes.contains(where: { $0.id == slot.selected }) {
                    columns[columnIndex].slots[slotIndex].selected = slot.panes[0].id
                }
            }
            if columns[columnIndex].slots.isEmpty { columns.remove(at: columnIndex) }
        }
        // Unreachable through any mutation — `close` refuses the last pane — but a
        // decoded bench is not built by a mutation, so this is not an assertion.
        guard !columns.isEmpty else { return }

        if !slots.contains(where: { $0.id == focusedSlot }) {
            focusedSlot = columns[0].slots[0].id
        }
        let widths = Self.balanced(columns.map(\.width))
        for (index, width) in widths.enumerated() { columns[index].width = width }
        for columnIndex in columns.indices {
            let heights = Self.balanced(columns[columnIndex].slots.map(\.height))
            for (index, height) in heights.enumerated() {
                columns[columnIndex].slots[index].height = height
            }
        }
    }

    /// Fractions that are positive, finite and sum to 1. A member that arrives
    /// non-positive or non-finite — from a decoded blob, or from a divider dragged to
    /// nothing — is given the equal share rather than dropped, because dropping it would
    /// mean dropping the pane it sizes.
    private static func balanced(_ fractions: [Double]) -> [Double] {
        guard !fractions.isEmpty else { return [] }
        let equal = 1 / Double(fractions.count)
        let repaired = fractions.map { $0.isFinite && $0 > 0 ? $0 : equal }
        let total = repaired.reduce(0, +)
        guard total > 0 else { return Array(repeating: equal, count: fractions.count) }
        return repaired.map { $0 / total }
    }

    /// Two members trading what the two of them have, and nobody else touched. Clamped at
    /// `minimumFraction` on both sides — and at half the pair when the pair is smaller than
    /// two of those, so the clamp can never hand out more than there is.
    private static func trading(
        _ fractions: [Double], at index: Int, with neighbour: Int, to fraction: Double
    ) -> [Double] {
        let pair = max(fractions[index], 0) + max(fractions[neighbour], 0)
        let least = min(minimumFraction, pair / 2)
        var traded = fractions
        traded[index] = min(max(fraction, least), pair - least)
        traded[neighbour] = pair - traded[index]
        return traded
    }

    /// Where a pane sits. Indices, deliberately — they are valid only for the split
    /// second between being computed and being used, and every use is inside one
    /// mutation. Nothing stores one.
    private struct Address {
        let column: Int
        let slot: Int
        let pane: Int
    }

    private func address(of pane: Pane.ID) -> Address? {
        for (columnIndex, column) in columns.enumerated() {
            for (slotIndex, slot) in column.slots.enumerated() {
                if let paneIndex = slot.panes.firstIndex(where: { $0.id == pane }) {
                    return Address(column: columnIndex, slot: slotIndex, pane: paneIndex)
                }
            }
        }
        return nil
    }

    private func address(ofSlot slot: Slot.ID) -> Address? {
        for (columnIndex, column) in columns.enumerated() {
            if let slotIndex = column.slots.firstIndex(where: { $0.id == slot }) {
                return Address(column: columnIndex, slot: slotIndex, pane: 0)
            }
        }
        return nil
    }

    /// Focus after the focused slot was removed: the slot that took its place, else the
    /// one above it, else the same depth in the column that took its place. Never a dead
    /// id, and never all the way back to the first slot — the operator was looking here.
    private mutating func refocusNear(_ address: Address) {
        guard !columns.isEmpty else { return }
        let column = columns[min(address.column, columns.count - 1)]
        guard !column.slots.isEmpty else {
            focusedSlot = columns[0].slots[0].id
            return
        }
        focusedSlot = column.slots[min(address.slot, column.slots.count - 1)].id
    }
}

// MARK: - Direction

extension Workbench {
    /// Which way ⌘⌥+arrow moves focus.
    enum Direction: String, Codable, Equatable {
        case left, right, up, down
    }
}

// MARK: - Column

/// One vertical stack of slots, and the share of the bench's width it gets.
struct Column: Codable, Equatable, Identifiable {
    let id: UUID
    var slots: [Slot]
    /// Fraction of the bench's width. helm carries this itself because `HSplitView`
    /// exposes **no** divider API of any kind — one `ViewBuilder` initialiser and
    /// nothing else, verified against the macOS 26.2 SDK interface. There is no
    /// `autosaveName` and no position binding to persist instead — and, measured in #90,
    /// no ideal size it will honour either, which is why `SplitStack` lays the bench out
    /// itself and this fraction is the layout rather than a record of one.
    var width: Double

    init(id: UUID = UUID(), slots: [Slot], width: Double = 1) {
        self.id = id
        self.slots = slots
        self.width = width
    }
}

// MARK: - Slot

/// One tabbed cell of a column: the panes it holds, and which of them is on screen.
///
/// `selected` is per slot, which is the whole ownership move. `TerminalManager` had one
/// `selectedID` for the workspace; under a bench N slots each have a selection and all of
/// them are visible at once, so a single app-level id cannot express the state.
struct Slot: Codable, Equatable, Identifiable {
    let id: UUID
    var panes: [Pane]
    var selected: Pane.ID
    /// Fraction of its column's height. Same reason as `Column.width`.
    var height: Double

    init(id: UUID = UUID(), panes: [Pane], selected: Pane.ID? = nil, height: Double = 1) {
        self.id = id
        self.panes = panes
        // A slot with no panes is not a state the bench keeps — `normalize()` drops it —
        // so this only has to be a value, not a meaningful one.
        self.selected = selected ?? panes.first?.id ?? UUID()
        self.height = height
    }
}

// MARK: - Pane

/// One tenant of a slot.
struct Pane: Codable, Equatable, Identifiable {
    /// For a terminal this IS the `TerminalSession.ID`. The pane and the session are one
    /// tenant seen from two sides; a second id would be a second thing to keep in step,
    /// and `WorkspaceContext` already persists session ids — so the migration from a
    /// pre-bench context is a straight read.
    let id: UUID
    var content: Content

    init(id: UUID = UUID(), content: Content) {
        self.id = id
        self.content = content
    }

    enum Content: Equatable {
        case terminal(face: TerminalFace)
        case canvas(CanvasSource)
    }
}

// MARK: - TerminalFace

/// Which face a terminal pane is showing: the terminal, or the agent's writing drawn
/// over it (#37). An associated value on `.terminal` rather than a field on `Pane`,
/// because a canvas has no face and the type should say so — asking one for its face
/// must not compile.
///
/// It was `@State private var chat` on `TerminalWorkspace`: ONE flag for the whole
/// vertical, carried along when the operator switched tabs. Per pane is both the truthful
/// shape under a bench — two terminals side by side, one being read and one being watched
/// — and the only one that survives `TerminalWorkspace` being deleted.
enum TerminalFace: String, Codable, Equatable {
    case terminal, chat
}

// MARK: - Codable

/// Hand-written with a string discriminator, for the reason `CanvasSource`'s encoder
/// gives: the synthesized shape uses positional `_0` keys, which break on any reordering
/// of the cases and are unreadable in the stored blob.
extension Pane.Content: Codable {
    private enum CodingKeys: String, CodingKey { case kind, source }
    private enum Kind: String, Codable { case terminal, canvas }

    /// **A `kind` this build does not know throws, and `Slot` skips the pane.** The build
    /// before this one had a third pane type and wrote `{"kind":"archonRun"}` into benches
    /// that are still on disk; there is nothing here that could turn one into a terminal or
    /// a canvas, and inventing one would be worse than losing it. What must NOT happen is
    /// the throw reaching `WorkspaceContextStore.load`, which decodes one dictionary for the
    /// whole app — see `Slot.init(from:)`, which is where that is stopped.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        // The face is deliberately not read, because it is deliberately not written.
        case .terminal: self = .terminal(face: .terminal)
        case .canvas: self = .canvas(try container.decode(CanvasSource.self, forKey: .source))
        }
    }

    /// **The face is deliberately NOT persisted.** A restored session is a fresh empty
    /// shell — position 1's ruling, *attach never own* (#27) — so the agent whose prose
    /// made the chat face worth reading is gone. Restoring into it would greet the
    /// operator with *"No Claude Code session is running in this terminal"* where a shell
    /// should be, and cost a keystroke to leave. ⌘T is one keystroke to get back **in**.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .terminal:
            try container.encode(Kind.terminal, forKey: .kind)
        case let .canvas(source):
            try container.encode(Kind.canvas, forKey: .kind)
            try container.encode(source, forKey: .source)
        }
    }
}

extension Slot {
    private enum CodingKeys: String, CodingKey { case id, panes, selected, height }

    /// **A pane this build cannot read is SKIPPED, and the rest of the slot survives.**
    ///
    /// Removing a pane type is not a hypothetical: the build before this one had three and
    /// wrote `{"kind":"archonRun"}` panes into benches that are still on disk. The
    /// synthesized decoder would fail the whole `[Pane]` array on the first of them, which
    /// fails the `Slot`, the `Column`, the `Workbench` — and then, one level up,
    /// `WorkspaceContextStore.load` decodes `[String: WorkspaceContext]` in ONE call, so a
    /// single unreadable pane in a single workspace would wipe **every** workspace's
    /// arrangement. `WorkspaceContext` already stops the blast at one workspace; this stops
    /// it at one pane.
    ///
    /// The wrapper is what makes it element-wise. An unkeyed container does **not** advance
    /// its cursor when `decode` throws, so a hand-rolled `while !isAtEnd` loop with `try?`
    /// spins forever on the first bad element; a `Decodable` that swallows internally always
    /// succeeds, so the array decode advances normally and the failures come back as nils.
    ///
    /// What repairs the rest is already here: `normalize()` re-points a `selected` that named
    /// the skipped pane, drops a slot left with none, and drops a column left with no slots.
    /// A bench left with nothing at all throws from `Workbench.init(from:)`, which is that
    /// workspace falling back to its terminals rather than every workspace losing its bench.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decode([Skippable<Pane>].self, forKey: .panes)
        let skipped = stored.count { $0.value == nil }
        if skipped > 0 {
            NSLog(
                "helm: %d pane(s) of a saved slot were written by a build with pane types this "
                    + "one does not have, and were skipped", skipped)
        }
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            panes: stored.compactMap(\.value),
            selected: try container.decodeIfPresent(Pane.ID.self, forKey: .selected),
            height: try container.decodeIfPresent(Double.self, forKey: .height) ?? 1)
    }
}

/// One element of an array that is allowed to be unreadable, so the array is not.
///
/// Deliberately general and deliberately tiny: it holds no policy about *why* an element
/// failed. The one caller decides that, and says so where it decides it.
private struct Skippable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

extension Workbench {
    private enum CodingKeys: String, CodingKey { case columns, focusedSlot }

    /// Decoding runs `normalize()`, so a blob that was hand-edited into something the
    /// invariants forbid comes back repaired rather than half-broken — except for the one
    /// state nothing can repair. A bench with no panes at all has nothing to render and
    /// nothing to invent, so it throws, and `WorkspaceContext`'s tolerant decoder turns
    /// that into `workbench == nil` for that workspace alone.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let columns = try container.decode([Column].self, forKey: .columns)
        let focusedSlot = try container.decode(Slot.ID.self, forKey: .focusedSlot)
        guard columns.contains(where: { $0.slots.contains { !$0.panes.isEmpty } }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .columns, in: container,
                debugDescription: "a workbench with no panes is not a workbench")
        }
        self.init(columns: columns, focusedSlot: focusedSlot)
    }
}
