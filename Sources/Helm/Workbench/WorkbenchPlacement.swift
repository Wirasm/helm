import Foundation

// MARK: - Placement

/// Where a pane lands. #33 named the closed set of three — a new column, a new row in an
/// existing column, or a new tab in an existing slot — and this adds the zeroth answer
/// that keeps ⌘-clicking the same link twice from opening two copies.
///
/// Carries no pane, in the shape `TerminalLinkRoute` established: the destination is the
/// whole decision, and the pane that goes there is the one that was placed. That is what
/// lets `swift test` exercise every rule below without a session, a webview or a window.
enum Placement: Equatable {
    /// Already here — select it and open nothing.
    case existing(Pane.ID)
    case tab(in: Slot.ID)
    case row(in: Column.ID)
    case column
}

// MARK: - The rules

extension Workbench {
    /// Where an offered canvas goes, by rule and in this order:
    /// 1. a pane already showing this exact source — select it, open nothing;
    /// 2. the focused slot, if it already holds a canvas — a new tab there;
    /// 3. the first slot in column order that holds a canvas — a new tab there;
    /// 4. otherwise a new column at the right end.
    ///
    /// Rule 4 is what reproduces today's frame at 1×1: the canvas appears to the right of
    /// the terminal, exactly where the dock was. Rules 2 and 3 are what stop the tenth
    /// offered canvas from creating a tenth column.
    ///
    /// Rule 1 compares by value, which is why `CanvasSource.file(_:)` standardises the
    /// path in one place — `/a/b.md` and `/a/./b.md` are otherwise two canvases and the
    /// rule silently stops working.
    ///
    /// The rule the operator may want instead is *always a new column until N columns,
    /// then tab*. That is this function and its test, and nothing else.
    func placement(forOpening source: CanvasSource) -> Placement {
        if let open = pane(showing: source) { return .existing(open) }
        if let focused = slot(focusedSlot), focused.holdsCanvas { return .tab(in: focused.id) }
        if let anyCanvas = slots.first(where: \.holdsCanvas) { return .tab(in: anyCanvas.id) }
        return .column
    }

    /// A new terminal is a new tab in the focused slot — what ⌘N does today
    /// (`TerminalManager.newTerminal`: append, then select).
    func placementForNewTerminal() -> Placement {
        .tab(in: focusedSlot)
    }

    /// Where a **spawned** terminal goes — an agent helm was asked to start from outside the
    /// app (#177, the spool of #54), as against ⌘N above:
    /// 1. a new row under the first column that already holds a terminal — agents go where
    ///    agents already are, the mirror of `holdsCanvas` one level up;
    /// 2. otherwise a new column at the right end, for a bench that is all canvas and has no
    ///    column of agents to join.
    ///
    /// **A pane of its own, never a tab.** A tab is hidden behind whatever its slot is
    /// showing, so stacking a spawn as one means the spawn produces no visible change unless
    /// the operator goes looking — and for a capability whose whole premise is that *nobody
    /// is watching*, an invisible spawn is backwards. A row is the smallest thing that makes
    /// "an agent now exists" observable.
    ///
    /// **Focus is not consulted, and that is the fix.** `placementForNewTerminal` reads
    /// `focusedSlot` because an operator pressing ⌘N means *here*. A spool request means
    /// nothing of the kind: it arrives from outside, possibly while they are mid-sentence
    /// somewhere else, and inherits a focus that has nothing to do with it — which is how a
    /// spawned agent came to stack onto the canvas somebody was reading. The bench decides
    /// this, not whatever was last clicked.
    ///
    /// **A row rather than a new column**, which was the other candidate: a terminal loses
    /// more to width than to height — 80 columns is a floor below which lines wrap, where 20
    /// rows is merely cramped — and the benches the operator actually keeps are two and three
    /// columns wide by choice. A column per spawn spends the scarcer axis.
    ///
    /// Placing is only half of it: the pane must also *not* take the keyboard, which is
    /// `Workbench.offer(_:at:)`'s half (#125). `WorkbenchModel.spawnTerminal` is where the
    /// two meet.
    func placementForSpawnedTerminal() -> Placement {
        if let column = columns.first(where: \.holdsTerminal) { return .row(in: column.id) }
        return .column
    }
}

extension Slot {
    /// Whether this slot is somewhere a canvas already lives. A slot mixing a terminal
    /// and a canvas counts: the operator put a canvas there, so that is where canvases go.
    fileprivate var holdsCanvas: Bool {
        panes.contains { if case .canvas = $0.content { true } else { false } }
    }

    fileprivate var holdsTerminal: Bool {
        panes.contains { if case .terminal = $0.content { true } else { false } }
    }
}

extension Column {
    /// Whether this column is somewhere a terminal already lives. A column, not a slot,
    /// because a spawned terminal joins a column as a row of its own — the slot it would
    /// otherwise join is the tab this rule exists to refuse.
    fileprivate var holdsTerminal: Bool {
        slots.contains(where: \.holdsTerminal)
    }
}
