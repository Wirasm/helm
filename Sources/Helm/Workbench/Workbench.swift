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
///
/// It is also still `Decodable` in helm's old saved shape, for one reader: `BenchImport`, which
/// moves the benches helm used to keep in its defaults into benchd once.
struct Workbench: Codable, Equatable {
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

    /// One column, one slot, one terminal: what a workspace helm never visited gets on import.
    init(terminal id: Pane.ID) {
        self.init(panes: [Pane(id: id, content: .terminal())])
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

    /// Every terminal pane that has an agent recorded against it, in bench order (#63). The
    /// input to both offers: `BenchRestoreOffer.agentCount` says what declining a restore
    /// costs, and `WorkbenchModel` turns each entry into one pane's resume offer.
    var resumableAgents: [(pane: Pane.ID, agent: ResumableAgent)] {
        panes.compactMap { pane in
            guard case let .terminal(agent) = pane.content, let agent else { return nil }
            return (pane.id, agent)
        }
    }

    /// Whether this bench is what `fresh` would build anyway: one terminal pane, nothing
    /// recorded in it.
    ///
    /// The one shape a restore offer must NOT be made about, because there is no decision
    /// under it — see `BenchMountPolicy.offer`. A pane carrying an agent fails this even
    /// alone, and that is the case it exists to catch: a single pane whose whole value is the
    /// conversation it held.
    var isOneEmptyShell: Bool {
        guard panes.count == 1, case let .terminal(agent) = panes[0].content else {
            return false
        }
        return agent == nil
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
struct Column: Codable, Equatable, Identifiable {
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
struct Slot: Codable, Equatable, Identifiable {
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
struct Pane: Codable, Equatable, Identifiable {
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
        /// A kind benchd's document holds and this build does not know, named. Kept rather than
        /// dropped: the daemon owns the pane, so helm shows a placeholder where it is.
        case unsupported(String)
    }
}

// MARK: - Codable

/// **Hand-written only because of `name`, and only because absence has to be tolerated (#313).**
/// The synthesized decoder calls `decode(_:forKey:)` for a non-optional property, which *throws*
/// on a bench written by any build before #313 — and `Slot.init(from:)` **skips a pane it cannot
/// read**. Synthesizing here would therefore have cost the operator every pane in every persisted
/// workspace on the first launch after upgrade, to save a word on a tab. `Pane.Content` makes the
/// same trade one type down for a malformed `agent`, and for the same reason.
///
/// `.unnamed` is not written at all, so an un-named bench's blob is byte-identical to what every
/// build before this one produced.
extension Pane {
    private enum CodingKeys: String, CodingKey { case id, content, name }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode(Content.self, forKey: .content)
        // Two different absences, and both mean `.unnamed`. `decodeIfPresent` returning nil is the
        // key missing entirely, which is every bench on disk today; the `try?` is `name` holding
        // something that is not a keyed container at all, which `PaneName`'s own decoder cannot
        // catch because it throws before it can look. Spelled as two branches rather than
        // `(try? …) ?? nil ?? .unnamed`, whose middle `nil` is a double-optional flatten that
        // reads like dead code.
        if let decoded = try? container.decodeIfPresent(PaneName.self, forKey: .name) {
            name = decoded ?? .unnamed
        } else {
            name = .unnamed
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(content, forKey: .content)
        if name != .unnamed { try container.encode(name, forKey: .name) }
    }
}

/// Hand-written with a string discriminator, for the reason `CanvasSource`'s encoder
/// gives: the synthesized shape uses positional `_0` keys, which break on any reordering
/// of the cases and are unreadable in the stored blob.
extension Pane.Content {
    /// The discriminator: which kind of pane this is, without its payload. It is the stored
    /// `kind` string, and it is what `SurfaceRegistry` looks a kind up by — the one switch over
    /// pane kinds that the rest of the app is spared.
    enum Kind: String, Codable, Hashable { case terminal, canvas, browser, sessions, unsupported }

    var kind: Kind {
        switch self {
        case .terminal: .terminal
        case .canvas: .canvas
        case .browser: .browser
        case .sessions: .sessions
        case .unsupported: .unsupported
        }
    }
}

extension Pane.Content: Codable {
    private enum CodingKeys: String, CodingKey { case kind, source, agent, named }

    /// **A `kind` this build does not know throws, and `Slot` skips the pane.** The build
    /// before this one had a third pane type and wrote `{"kind":"archonRun"}` into benches
    /// that are still on disk; there is nothing here that could turn one into a terminal or
    /// a canvas, and inventing one would be worse than losing it. What must NOT happen is
    /// the throw reaching `BenchImport`, which decodes one dictionary for every workspace —
    /// see `Slot.init(from:)`, which is where that is stopped.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        // **A `face` key is ignored.** No build ever wrote one (the chat face was never
        // persisted), and the key decoder skips keys it is not asked for, so a hand-edited
        // `{"kind":"terminal","face":"chat"}` loads as the terminal it always was.
        //
        // **The agent degrades to absence rather than throwing.** A malformed
        // `agent` costs this pane its resume offer; throwing would cost the pane, and
        // `Slot.init(from:)` skips a pane it cannot read. Losing a terminal because helm
        // could not read a hint about it is the wrong trade in a file this decoder exists
        // to be tolerant of.
        case .terminal:
            self = .terminal(
                agent: (try? container.decodeIfPresent(ResumableAgent.self, forKey: .agent))
                    ?? nil)
        case .canvas: self = .canvas(try container.decode(CanvasSource.self, forKey: .source))
        case .browser: self = .browser
        case .sessions: self = .sessions
        // Only a daemon's document makes one; read with its name all the same.
        case .unsupported:
            self = .unsupported(try container.decode(String.self, forKey: .named))
        }
    }

    /// **The agent is persisted.** A restored session is a fresh empty shell — position 1's
    /// ruling, *attach never own* (#27) — but `agent` is the id of a conversation that
    /// survives it: the pty died with helm's process and the transcript did not (#63 proved
    /// that by hand: `claude --resume` on a session whose process had been killed picked up
    /// 208 records). What comes
    /// back is still a plain empty shell; what is added is an *offer*, which the operator may
    /// decline, and which is the only form of resurrection that can be wrong safely.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .terminal(agent):
            try container.encode(Kind.terminal, forKey: .kind)
            try container.encodeIfPresent(agent, forKey: .agent)
        case let .canvas(source):
            try container.encode(Kind.canvas, forKey: .kind)
            try container.encode(source, forKey: .source)
        case .browser:
            try container.encode(Kind.browser, forKey: .kind)
        case .sessions:
            try container.encode(Kind.sessions, forKey: .kind)
        case let .unsupported(named):
            try container.encode(Kind.unsupported, forKey: .kind)
            try container.encode(named, forKey: .named)
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
    /// fails the `Slot`, the `Column`, the `Workbench` — and then, one level up, the import
    /// decodes every workspace's saved context in ONE call, so a single unreadable pane in a
    /// single workspace would lose **every** workspace's arrangement. `BenchImport.Saved`
    /// already stops the blast at one workspace; this stops it at one pane.
    ///
    /// The wrapper is what makes it element-wise. An unkeyed container does **not** advance
    /// its cursor when `decode` throws, so a hand-rolled `while !isAtEnd` loop with `try?`
    /// spins forever on the first bad element; a `Decodable` that swallows internally always
    /// succeeds, so the array decode advances normally and the failures come back as nils.
    ///
    /// What repairs the rest is benchd's: the import is decoded through `normalize()`, which
    /// re-points a `selected` that named the skipped pane and drops an emptied slot or column.
    /// A bench left with nothing at all throws from `Workbench.init(from:)`, which is that
    /// workspace imported as one fresh terminal rather than every workspace losing its bench.
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

    /// helm's old saved shape, read only by `BenchImport`. Nothing is repaired here: benchd
    /// normalizes what it imports. The one state nothing can repair — a bench with no panes —
    /// throws, and the import gives that workspace one fresh terminal instead.
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
