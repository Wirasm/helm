import Foundation
import HelmWire

// MARK: - Workbench

/// The pane arrangement inside one workspace, as helm draws it: N columns, each a vertical
/// stack of slots, each slot tabbed. Depth-2 — a strict subset of a general split tree (#23).
///
/// **A value helm reads and never changes.** benchd owns the bench (#354): every change is a
/// verb, and what comes back is a document, converted to this by `init?(document:)`. The rules
/// that change a bench — placement, the focus rule, `normalize()` — are `bench-doc`'s, in Rust,
/// with the Swift suites that used to pin them mirrored there. So every field is a `let`: a Swift
/// code path that mutates a bench does not compile.
///
/// Invariants, which benchd's `normalize()` holds for every document it sends:
/// - `columns` is never empty; no column has zero slots; no slot has zero panes.
/// - `focusedSlot` always names a slot that exists.
/// - every `Slot.selected` names a pane that slot holds.
/// - `width`/`height` fractions in a stack are positive and sum to 1.
struct Workbench: Equatable {
    let columns: [Column]
    /// The slot the operator's next command targets. A slot **id**, never an index.
    let focusedSlot: Slot.ID

    // MARK: - Construction

    private init(columns: [Column], focusedSlot: Slot.ID) {
        self.columns = columns
        self.focusedSlot = focusedSlot
    }

    /// A bench built from parts decoded elsewhere — benchd's document (#354). nil when the parts
    /// hold no pane at all, which no bench may be.
    static func assembled(columns: [Column], focusedSlot: Slot.ID) -> Workbench? {
        guard columns.contains(where: { $0.slots.contains { !$0.panes.isEmpty } }) else {
            return nil
        }
        return Workbench(columns: columns, focusedSlot: focusedSlot)
    }

    /// One column, one slot, these panes as tabs. An empty `panes` is a caller error rather than
    /// a state: it would violate the first invariant.
    init(panes: [Pane], selecting selected: Pane.ID? = nil) {
        let slot = Slot(panes: panes, selected: selected)
        self.init(columns: [Column(slots: [slot])], focusedSlot: slot.id)
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
    /// `TerminalManager.adopt(terminals:in:)` wants, because a terminal pane's id **is**
    /// its session id.
    var terminalPaneIDs: [Pane.ID] {
        panes.compactMap { if case .terminal = $0.content { $0.id } else { nil } }
    }

    var canvasPanes: [Pane] {
        panes.filter { if case .canvas = $0.content { true } else { false } }
    }

    /// Every terminal pane that has an agent recorded against it, in bench order (#63): what
    /// `bench restore` would resume.
    var resumableAgents: [(pane: Pane.ID, agent: ResumableAgent)] {
        panes.compactMap { pane in
            guard case let .terminal(agent) = pane.content, let agent else { return nil }
            return (pane.id, agent)
        }
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

    /// The last pane of the bench cannot close — the generalisation of
    /// `TerminalManager.canClose`, which refused the last terminal for the same reason:
    /// a helm with nothing in it is not a state worth being able to reach.
    func canClose(_ pane: Pane.ID) -> Bool {
        panes.contains { $0.id == pane } && panes.count > 1
    }
}

// MARK: - Column

/// One vertical stack of slots, and the share of the bench's width it gets.
struct Column: Equatable, Identifiable {
    let id: UUID
    let slots: [Slot]
    /// Fraction of the bench's width. helm carries this itself because `HSplitView`
    /// exposes **no** divider API of any kind — one `ViewBuilder` initialiser and
    /// nothing else, verified against the macOS 26.2 SDK interface. There is no
    /// `autosaveName` and no position binding to persist instead — and, measured in #90,
    /// no ideal size it will honour either, which is why `SplitStack` lays the bench out
    /// itself and this fraction is the layout rather than a record of one.
    let width: Double

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
struct Slot: Equatable, Identifiable {
    let id: UUID
    let panes: [Pane]
    let selected: Pane.ID
    /// Fraction of its column's height. Same reason as `Column.width`.
    let height: Double

    init(id: UUID = UUID(), panes: [Pane], selected: Pane.ID? = nil, height: Double = 1) {
        self.id = id
        self.panes = panes
        // A slot with no panes is not a state a bench keeps — benchd's `normalize()` drops
        // it — so this only has to be a value, not a meaningful one.
        self.selected = selected ?? panes.first?.id ?? UUID()
        self.height = height
    }
}

// MARK: - Pane

/// One tenant of a slot.
struct Pane: Equatable, Identifiable {
    /// For a terminal this IS the `TerminalSession.ID`. The pane and the session are one
    /// tenant seen from two sides; a second id would be a second thing to keep in step.
    let id: UUID
    let content: Content
    /// What this pane is called, and who called it that (#313).
    ///
    /// **Beside `content` rather than inside it**, unlike `agent`: a name means the same thing
    /// for a terminal and for a canvas, and `Pane.id` is already one namespace across both
    /// (#284). A canvas has no agent, so asking one for its agent must not compile, where a
    /// canvas plainly can be called something.
    let name: PaneName

    init(id: UUID = UUID(), content: Content, name: PaneName = .unnamed) {
        self.id = id
        self.content = content
        self.name = name
    }

    enum Content: Equatable {
        /// `agent` is what was running in this terminal when helm last looked, and the whole
        /// of what #63 adds to a persisted bench — see `ResumableAgent`, which argues why it
        /// lives on `.terminal` rather than beside `Pane`. Defaulted, so every construction
        /// site that has nothing to say about an agent reads `.terminal()` and says nothing.
        case terminal(agent: ResumableAgent? = nil)
        case canvas(CanvasSource)
        /// A view onto the shared browser benchd runs (#350). No payload: there is one
        /// browser per bench root, and which tab it shows is live state, not arrangement.
        case browser
        /// The active workspace's agent sessions (#384), in the `sessions` drawer.
        case sessions
        /// The active workspace's Archon runs (#382), in the `archon` drawer.
        case archon
        /// A kind benchd's document holds and this build does not know, named. Kept rather than
        /// dropped: the daemon owns the pane, so helm shows a placeholder where it is.
        case unsupported(String)
    }
}

// MARK: - Kind

extension Pane.Content {
    /// Which kind of pane this is, without its payload: what `SurfaceRegistry` looks a kind up
    /// by — the one switch over pane kinds that the rest of the app is spared.
    enum Kind: String, Hashable { case terminal, canvas, browser, sessions, archon, unsupported }

    var kind: Kind {
        switch self {
        case .terminal: .terminal
        case .canvas: .canvas
        case .browser: .browser
        case .sessions: .sessions
        case .archon: .archon
        case .unsupported: .unsupported
        }
    }
}
