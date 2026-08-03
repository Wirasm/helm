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

    /// Run panes group with other run panes, while repeated selection of the same run
    /// selects its existing persisted address instead of opening a duplicate.
    func placement(forOpening reference: ArchonRunRef) -> Placement {
        if let open = pane(showing: reference) { return .existing(open) }
        if let focused = slot(focusedSlot), focused.holdsArchonRun {
            return .tab(in: focused.id)
        }
        if let anyRun = slots.first(where: \.holdsArchonRun) { return .tab(in: anyRun.id) }
        return .column
    }

    /// A new terminal is a new tab in the focused slot — what ⌘N does today
    /// (`TerminalManager.newTerminal`: append, then select).
    func placementForNewTerminal() -> Placement {
        .tab(in: focusedSlot)
    }
}

extension Slot {
    /// Whether this slot is somewhere a canvas already lives. A slot mixing a terminal
    /// and a canvas counts: the operator put a canvas there, so that is where canvases go.
    fileprivate var holdsCanvas: Bool {
        panes.contains { if case .canvas = $0.content { true } else { false } }
    }

    fileprivate var holdsArchonRun: Bool {
        panes.contains { if case .archonRun = $0.content { true } else { false } }
    }
}
