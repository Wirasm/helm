import Foundation

// MARK: - Workbench

/// The pane arrangement inside one workspace: N columns, each a vertical stack of
/// slots, each slot tabbed. Depth-2 — a strict subset of a general split tree, so
/// nothing is foreclosed, and there is no "horizontal or vertical?" decision at
/// every insertion (#23).
///
/// A value, not a tree of live objects: persistence, restore and equality come free,
/// and every rule below is exercisable without a window, a pty or a webview. The
/// live objects a pane *names* — a `TerminalSession`, `CanvasModel`, or
/// `ArchonRunPaneModel` — are resolved
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
                Pane(content: .canvas(.file(URL(fileURLWithPath: path)))), at: .column)
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

    func pane(showing reference: ArchonPaneRef) -> Pane.ID? {
        panes.first { $0.content == .archonRun(reference) }?.id
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
        guard let address = address(ofSlot: focusedSlot) else { return }
        let width = columns[address.column].width / 2
        columns[address.column].width = width
        let slot = Slot(panes: [pane])
        columns.insert(Column(slots: [slot], width: width), at: address.column + 1)
        focusedSlot = slot.id
        normalize()
    }

    /// ⌘⇧D — a new row under the focused slot, in the same column. See `splitRight`
    /// for why the pane comes in rather than being made here.
    mutating func splitDown(with pane: Pane) {
        guard let address = address(ofSlot: focusedSlot) else { return }
        let height = columns[address.column].slots[address.slot].height / 2
        columns[address.column].slots[address.slot].height = height
        let slot = Slot(panes: [pane], height: height)
        columns[address.column].slots.insert(slot, at: address.slot + 1)
        focusedSlot = slot.id
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
        case archonRun(ArchonPaneRef)
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
    private enum CodingKeys: String, CodingKey { case kind, source, run }
    private enum Kind: String, Codable { case terminal, canvas, archonRun }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        // The face is deliberately not read, because it is deliberately not written.
        case .terminal: self = .terminal(face: .terminal)
        case .canvas: self = .canvas(try container.decode(CanvasSource.self, forKey: .source))
        case .archonRun:
            self = .archonRun(try container.decode(ArchonPaneRef.self, forKey: .run))
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
        case let .archonRun(reference):
            try container.encode(Kind.archonRun, forKey: .kind)
            try container.encode(reference, forKey: .run)
        }
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
