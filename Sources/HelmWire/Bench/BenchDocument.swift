import Foundation

// MARK: - BenchDocument

/// benchd's bench document, as helm reads it (#354). The Rust types in `daemon/crates/bench-doc`
/// are the one spelling; this is the conformance-pinned copy across the runtime boundary
/// (`AGENTS.md`: a duplicate is honest only when a runtime boundary makes sharing impossible, and
/// only when a test notices drift). `BenchWireConformanceTests` decodes the shared fixtures in
/// `daemon/fixtures/`, the same files the daemon gate pins byte for byte.
///
/// Nested rather than top-level because helm's own `Workspace`, `Column`, `Slot` and `Pane` are
/// the render values; these are what crosses the socket, and `BenchDocument+Helm.swift` converts
/// one into the other.
package struct BenchDocument: Codable, Equatable, Sendable {
    package var workspaces: [Workspace]
    /// The workspace on screen, by path. nil only when nothing is open.
    package var active: String?
    /// Named tab holders shown over the bench (#356), beside the workspaces rather than in
    /// one. Absent on the wire when there are none, as on the Rust side.
    package var drawers: [Drawer]
    /// The drawer shown over the bench, by name. One at a time.
    package var openDrawer: String?

    package init(
        workspaces: [Workspace], active: String?, drawers: [Drawer] = [], openDrawer: String? = nil
    ) {
        self.workspaces = workspaces
        self.active = active
        self.drawers = drawers
        self.openDrawer = openDrawer
    }

    private enum CodingKeys: String, CodingKey {
        case workspaces, active, drawers
        case openDrawer = "open_drawer"
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = try c.decode([Workspace].self, forKey: .workspaces)
        active = try c.decodeIfPresent(String.self, forKey: .active)
        drawers = try c.decodeIfPresent([Drawer].self, forKey: .drawers) ?? []
        openDrawer = try c.decodeIfPresent(String.self, forKey: .openDrawer)
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(workspaces, forKey: .workspaces)
        try c.encodeIfPresent(active, forKey: .active)
        if !drawers.isEmpty { try c.encode(drawers, forKey: .drawers) }
        try c.encodeIfPresent(openDrawer, forKey: .openDrawer)
    }

    /// A drawer: panes shown over the bench instead of in it. Never empty — benchd removes a
    /// drawer with its last pane — and `selected` is always a pane it holds.
    package struct Drawer: Codable, Equatable, Sendable {
        package var name: String
        package var panes: [Pane]
        package var selected: UUID
        /// An agent put or re-offered something here that the operator has not seen yet.
        package var badged: Bool

        package init(name: String, panes: [Pane], selected: UUID, badged: Bool = false) {
            self.name = name
            self.panes = panes
            self.selected = selected
            self.badged = badged
        }
    }

    package struct Workspace: Codable, Equatable, Sendable {
        package var path: String
        package var bench: Bench
        /// A bench the operator declined to restore (helm #85), kept so one click destroys
        /// nothing.
        package var shelved: Bench?

        package init(path: String, bench: Bench, shelved: Bench? = nil) {
            self.path = path
            self.bench = bench
            self.shelved = shelved
        }
    }

    package struct Bench: Codable, Equatable, Sendable {
        package var columns: [Column]
        package var focusedSlot: UUID

        package init(columns: [Column], focusedSlot: UUID) {
            self.columns = columns
            self.focusedSlot = focusedSlot
        }

        private enum CodingKeys: String, CodingKey {
            case columns
            case focusedSlot = "focused_slot"
        }
    }

    package struct Column: Codable, Equatable, Sendable {
        package var id: UUID
        package var slots: [Slot]
        package var width: Double

        package init(id: UUID, slots: [Slot], width: Double) {
            self.id = id
            self.slots = slots
            self.width = width
        }
    }

    package struct Slot: Codable, Equatable, Sendable {
        package var id: UUID
        package var panes: [Pane]
        package var selected: UUID
        package var height: Double

        package init(id: UUID, panes: [Pane], selected: UUID, height: Double) {
            self.id = id
            self.panes = panes
            self.selected = selected
            self.height = height
        }
    }

    package struct Pane: Codable, Equatable, Sendable {
        package var id: UUID
        package var surface: Surface
        /// Absent means unnamed: the key is omitted rather than written empty, as on the Rust
        /// side.
        package var name: PaneName

        package init(id: UUID, surface: Surface, name: PaneName = .unnamed) {
            self.id = id
            self.surface = surface
            self.name = name
        }

        private enum CodingKeys: String, CodingKey { case id, surface, name }

        package init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            surface = try c.decode(Surface.self, forKey: .surface)
            name = try c.decodeIfPresent(PaneName.self, forKey: .name) ?? .unnamed
        }

        package func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(surface, forKey: .surface)
            if name != .unnamed { try c.encode(name, forKey: .name) }
        }
    }

    /// Which agent a terminal pane held, recorded so a restart can offer to resume it.
    package struct Agent: Codable, Equatable, Sendable {
        package var command: String
        package var session: String
        package var cwd: String

        package init(command: String, session: String, cwd: String) {
            self.command = command
            self.session = session
            self.cwd = cwd
        }
    }
}

// MARK: - Surface

/// What a pane shows, named by a typed source (`bench-architecture.md`, primitive 2).
///
/// **`unsupported` is a kind this build does not know**, and it decodes rather than throws: the
/// daemon owns the pane, so helm renders a placeholder for it and keeps it (plan AC6). Dropping
/// it would make helm's picture of the bench disagree with benchd's.
package enum Surface: Codable, Equatable, Sendable {
    case terminal(agent: BenchDocument.Agent?)
    /// A canvas over a file, the only canvas source there is since #376.
    case canvas(path: String)
    case browser
    case unsupported(kind: String)

    private enum CodingKeys: String, CodingKey { case kind, agent, source }
    private enum SourceKeys: String, CodingKey { case kind, path }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "terminal":
            self = .terminal(agent: try c.decodeIfPresent(BenchDocument.Agent.self, forKey: .agent))
        case "canvas":
            let source = try c.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
            let sourceKind = try source.decode(String.self, forKey: .kind)
            guard sourceKind == "file" else {
                self = .unsupported(kind: "canvas/\(sourceKind)")
                return
            }
            self = .canvas(path: try source.decode(String.self, forKey: .path))
        case "browser":
            self = .browser
        default:
            self = .unsupported(kind: kind)
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .terminal(agent):
            try c.encode("terminal", forKey: .kind)
            try c.encodeIfPresent(agent, forKey: .agent)
        case let .canvas(path):
            try c.encode("canvas", forKey: .kind)
            var source = c.nestedContainer(keyedBy: SourceKeys.self, forKey: .source)
            try source.encode("file", forKey: .kind)
            try source.encode(path, forKey: .path)
        case .browser:
            try c.encode("browser", forKey: .kind)
        case let .unsupported(kind):
            // Never sent: helm only ever asks benchd for kinds it has. Encoded as its name so a
            // round trip of a document helm did not understand is still honest about it.
            try c.encode(kind, forKey: .kind)
        }
    }
}
