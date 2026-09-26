import Foundation

// MARK: - Actor

/// Who asked for a change (`bench-wire`'s `Actor`). benchd decides focus from it: focus moves
/// only when the operator acted, or when an agent's verb says the operator asked.
package enum BenchActor: Codable, Equatable, Sendable {
    /// The operator's own gesture: a key, a click, a drag.
    case operatorGesture
    /// An agent. `pane` is where it runs, when it is known; `handle` is its mailbox. Both are
    /// for the record only.
    case agent(pane: String? = nil, handle: String? = nil)
    /// helm acting on its own observation: recording an agent, importing its saved benches.
    case helm

    private enum CodingKeys: String, CodingKey { case kind, pane, handle }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "operator": self = .operatorGesture
        case "helm": self = .helm
        case "agent":
            self = .agent(
                pane: try c.decodeIfPresent(String.self, forKey: .pane),
                handle: try c.decodeIfPresent(String.self, forKey: .handle))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: c, debugDescription: "not an actor: \(other)")
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .operatorGesture: try c.encode("operator", forKey: .kind)
        case .helm: try c.encode("helm", forKey: .kind)
        case let .agent(pane, handle):
            try c.encode("agent", forKey: .kind)
            try c.encodeIfPresent(pane, forKey: .pane)
            try c.encodeIfPresent(handle, forKey: .handle)
        }
    }
}

// MARK: - The verbs

/// Which way a focus step or a pane move goes.
package enum BenchDirection: String, Codable, Equatable, Sendable, CaseIterable {
    case left, right, up, down
}

/// Which way a split opens.
package enum BenchSplit: String, Codable, Equatable, Sendable {
    case right, down
}

/// A divider: the member dragged and its neighbour across it.
package enum BenchDivider: Equatable, Sendable {
    case columns(member: UUID, against: UUID)
    case slots(member: UUID, against: UUID)
}

/// Every layout verb helm can send (`bench-wire`'s `LayoutVerb`), one case each. Its encoded
/// form is `{"verb": <name>, "args": {...}}` inside a request; `BenchRequest` does the framing,
/// and `BenchWireConformanceTests` pins every case against `daemon/fixtures/bench-verbs.json`.
package enum BenchVerb: Equatable, Sendable {
    case get
    case workspaceOpen(path: String)
    case workspaceClose(path: String)
    case workspaceActivate(path: String)
    case workspaceReset(path: String)
    case workspaceUnshelve(path: String)
    case workspaceImport(BenchDocument)
    /// A new pane showing `surface`, placed by benchd's rules; `workspace` nil means the active
    /// one.
    case paneOpen(workspace: String? = nil, surface: Surface)
    /// `pane/open` into a named drawer, outright: the rules are not asked, and an agent's pane
    /// badges the drawer instead of opening it. Its own case because benchd refuses a request
    /// naming both a workspace and a drawer, so helm cannot build one.
    case paneOpenInDrawer(String, surface: Surface)
    /// A terminal unless a surface is named.
    case paneSplit(workspace: String? = nil, direction: BenchSplit, surface: Surface? = nil)
    case paneClose(UUID)
    case paneShow(UUID)
    case paneMove(UUID, BenchDirection)
    case paneName(UUID, PaneName)
    /// `agent: nil` records that no agent is in the pane.
    case paneRecord(UUID, agent: BenchDocument.Agent?)
    case focusSlot(UUID)
    case focusStep(workspace: String? = nil, direction: BenchDirection)
    case layoutResize(BenchDivider, fraction: Double)
    /// Show a drawer over the bench, or hide it if it is the one shown. `surface` is what a
    /// drawer that does not exist yet starts with. Opening is the operator's focus.
    case drawerToggle(name: String, surface: Surface? = nil)

    /// The wire name, which is also the request's `verb`.
    package var name: String {
        switch self {
        case .get: "bench/get"
        case .workspaceOpen: "workspace/open"
        case .workspaceClose: "workspace/close"
        case .workspaceActivate: "workspace/activate"
        case .workspaceReset: "workspace/reset"
        case .workspaceUnshelve: "workspace/unshelve"
        case .workspaceImport: "workspace/import"
        case .paneOpen, .paneOpenInDrawer: "pane/open"
        case .paneSplit: "pane/split"
        case .paneClose: "pane/close"
        case .paneShow: "pane/show"
        case .paneMove: "pane/move"
        case .paneName: "pane/name"
        case .paneRecord: "pane/record"
        case .focusSlot: "focus/slot"
        case .focusStep: "focus/step"
        case .layoutResize: "layout/resize"
        case .drawerToggle: "drawer/toggle"
        }
    }
}

// MARK: - The request

/// One line on benchd's socket: `{id, verb, args, by, asked}`.
package struct BenchRequest: Codable, Equatable, Sendable {
    package var id: String
    package var verb: BenchVerb
    package var by: BenchActor?
    /// The caller says the operator asked for this.
    package var asked: Bool

    package init(id: String, verb: BenchVerb, by: BenchActor?, asked: Bool = false) {
        self.id = id
        self.verb = verb
        self.by = by
        self.asked = asked
    }

    private enum CodingKeys: String, CodingKey { case id, verb, args, by, asked }
    private enum ArgKeys: String, CodingKey {
        case path, document, workspace, surface, direction, pane, to, name, agent, slot, divider,
            fraction, drawer
    }
    private enum StepKeys: String, CodingKey { case step }
    private enum DividerKeys: String, CodingKey { case between, member, against }

    package func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(verb.name, forKey: .verb)
        try c.encodeIfPresent(by, forKey: .by)
        if asked { try c.encode(true, forKey: .asked) }
        if case .get = verb {
            try c.encodeNil(forKey: .args)
            return
        }
        var a = c.nestedContainer(keyedBy: ArgKeys.self, forKey: .args)
        switch verb {
        case .get: break
        case let .workspaceOpen(path), let .workspaceClose(path), let .workspaceActivate(path),
            let .workspaceReset(path), let .workspaceUnshelve(path):
            try a.encode(path, forKey: .path)
        case let .workspaceImport(document):
            try a.encode(document, forKey: .document)
        case let .paneOpen(workspace, surface):
            try a.encodeIfPresent(workspace, forKey: .workspace)
            try a.encode(surface, forKey: .surface)
        case let .paneOpenInDrawer(drawer, surface):
            try a.encode(drawer, forKey: .drawer)
            try a.encode(surface, forKey: .surface)
        case let .paneSplit(workspace, direction, surface):
            try a.encodeIfPresent(workspace, forKey: .workspace)
            try a.encode(direction, forKey: .direction)
            try a.encodeIfPresent(surface, forKey: .surface)
        case let .paneClose(pane), let .paneShow(pane):
            try a.encode(pane, forKey: .pane)
        case let .paneMove(pane, direction):
            try a.encode(pane, forKey: .pane)
            var to = a.nestedContainer(keyedBy: StepKeys.self, forKey: .to)
            try to.encode(direction, forKey: .step)
        case let .paneName(pane, name):
            try a.encode(pane, forKey: .pane)
            try a.encode(name, forKey: .name)
        case let .paneRecord(pane, agent):
            try a.encode(pane, forKey: .pane)
            // `null` is the message — "no agent is here" — so it is written, not omitted.
            try a.encode(agent, forKey: .agent)
        case let .focusSlot(slot):
            try a.encode(slot, forKey: .slot)
        case let .focusStep(workspace, direction):
            try a.encodeIfPresent(workspace, forKey: .workspace)
            try a.encode(direction, forKey: .direction)
        case let .layoutResize(divider, fraction):
            var d = a.nestedContainer(keyedBy: DividerKeys.self, forKey: .divider)
            switch divider {
            case let .columns(member, against):
                try d.encode("columns", forKey: .between)
                try d.encode(member, forKey: .member)
                try d.encode(against, forKey: .against)
            case let .slots(member, against):
                try d.encode("slots", forKey: .between)
                try d.encode(member, forKey: .member)
                try d.encode(against, forKey: .against)
            }
            try a.encode(fraction, forKey: .fraction)
        case let .drawerToggle(name, surface):
            try a.encode(name, forKey: .drawer)
            try a.encodeIfPresent(surface, forKey: .surface)
        }
    }

    /// Decoding exists for the conformance tests, which read the daemon's own sample requests
    /// back into this type; helm itself only ever sends.
    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        by = try c.decodeIfPresent(BenchActor.self, forKey: .by)
        asked = try c.decodeIfPresent(Bool.self, forKey: .asked) ?? false
        let name = try c.decode(String.self, forKey: .verb)
        if name == "bench/get" {
            verb = .get
            return
        }
        let a = try c.nestedContainer(keyedBy: ArgKeys.self, forKey: .args)
        func path() throws -> String { try a.decode(String.self, forKey: .path) }
        func pane() throws -> UUID { try a.decode(UUID.self, forKey: .pane) }
        switch name {
        case "workspace/open": verb = .workspaceOpen(path: try path())
        case "workspace/close": verb = .workspaceClose(path: try path())
        case "workspace/activate": verb = .workspaceActivate(path: try path())
        case "workspace/reset": verb = .workspaceReset(path: try path())
        case "workspace/unshelve": verb = .workspaceUnshelve(path: try path())
        case "workspace/import":
            verb = .workspaceImport(try a.decode(BenchDocument.self, forKey: .document))
        case "pane/open":
            let surface = try a.decode(Surface.self, forKey: .surface)
            if let drawer = try a.decodeIfPresent(String.self, forKey: .drawer) {
                guard try a.decodeIfPresent(String.self, forKey: .workspace) == nil else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .drawer, in: a,
                        debugDescription: "pane/open names a workspace and a drawer")
                }
                verb = .paneOpenInDrawer(drawer, surface: surface)
            } else {
                verb = .paneOpen(
                    workspace: try a.decodeIfPresent(String.self, forKey: .workspace),
                    surface: surface)
            }
        case "pane/split":
            verb = .paneSplit(
                workspace: try a.decodeIfPresent(String.self, forKey: .workspace),
                direction: try a.decode(BenchSplit.self, forKey: .direction),
                surface: try a.decodeIfPresent(Surface.self, forKey: .surface))
        case "pane/close": verb = .paneClose(try pane())
        case "pane/show": verb = .paneShow(try pane())
        case "pane/move":
            let to = try a.nestedContainer(keyedBy: StepKeys.self, forKey: .to)
            verb = .paneMove(try pane(), try to.decode(BenchDirection.self, forKey: .step))
        case "pane/name":
            verb = .paneName(try pane(), try a.decode(PaneName.self, forKey: .name))
        case "pane/record":
            verb = .paneRecord(
                try pane(), agent: try a.decodeIfPresent(BenchDocument.Agent.self, forKey: .agent))
        case "focus/slot": verb = .focusSlot(try a.decode(UUID.self, forKey: .slot))
        case "focus/step":
            verb = .focusStep(
                workspace: try a.decodeIfPresent(String.self, forKey: .workspace),
                direction: try a.decode(BenchDirection.self, forKey: .direction))
        case "layout/resize":
            let d = try a.nestedContainer(keyedBy: DividerKeys.self, forKey: .divider)
            let member = try d.decode(UUID.self, forKey: .member)
            let against = try d.decode(UUID.self, forKey: .against)
            let divider: BenchDivider =
                try d.decode(String.self, forKey: .between) == "slots"
                ? .slots(member: member, against: against)
                : .columns(member: member, against: against)
            verb = .layoutResize(divider, fraction: try a.decode(Double.self, forKey: .fraction))
        case "drawer/toggle":
            verb = .drawerToggle(
                name: try a.decode(String.self, forKey: .drawer),
                surface: try a.decodeIfPresent(Surface.self, forKey: .surface))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .verb, in: c, debugDescription: "not a layout verb: \(name)")
        }
    }
}

// MARK: - The replies

/// What every layout verb but `bench/get` answers (`bench-wire`'s `LayoutReport`). The focused
/// pane before and after are two readings either side of the change, so a caller checks the
/// focus rule rather than trusting it.
package struct LayoutReport: Codable, Equatable, Sendable {
    package var seq: UInt64
    package var changed: Bool
    package var paneCreated: UUID?
    package var pane: UUID?
    package var focusedPaneBefore: UUID?
    package var focusedPaneAfter: UUID?

    private enum CodingKeys: String, CodingKey {
        case seq, changed, pane
        case paneCreated = "pane_created"
        case focusedPaneBefore = "focused_pane_before"
        case focusedPaneAfter = "focused_pane_after"
    }
}

/// `bench/get`'s answer, and the first line of `events --follow`.
package struct DocumentAt: Codable, Equatable, Sendable {
    package var seq: UInt64
    package var document: BenchDocument
}

/// One line of `events --follow`: the event's identity, and the whole document when the event
/// changed it. The event's `data` is not read here — a follower that renders needs only the
/// document, and each event kind's data is that kind's own shape.
package struct BenchFrame: Codable, Equatable, Sendable {
    package var event: Event
    package var document: BenchDocument?

    package struct Event: Codable, Equatable, Sendable {
        package var seq: UInt64
        package var at: String
        package var kind: String
    }
}
