import Foundation
import HelmWire
import XCTest

@testable import Helm

/// Just enough of benchd for a test of helm's side to get a document back from a verb.
///
/// **Not benchd's rules, and not a spec of them.** Placement, the focus rule and `normalize()`
/// are `bench-doc`'s, in Rust, and tested there (`daemon/crates/bench-doc/tests`). The toy is
/// deliberately naive: an operator's pane is a tab in the focused slot, an agent's is a column of
/// its own, a split is a column or a row beside the focused slot, and every stack shares its
/// length equally. A helm test that asserts *where* a pane landed is testing this toy; assert
/// what helm sent (`FakeBenchd.verbs`) or what it drew from the document instead.
struct ToyBench {
    var document: BenchDocument

    struct Answer {
        var changed = false
        var created: UUID?
        var pane: UUID?
    }

    struct Refused: Error {
        let reason: String
    }

    mutating func apply(_ request: BenchRequest) throws -> Answer {
        let focus = request.by == .operatorGesture || request.asked
        switch request.verb {
        case .get, .paneOpenInDrawer, .drawerToggle, .paneMove:
            return Answer()
        case .workspaceOpen, .workspaceActivate, .workspaceClose, .workspaceReset,
            .workspaceUnshelve, .workspaceImport:
            return try applyWorkspace(request.verb, focus: focus)
        case let .paneOpen(workspace, surface):
            return try open(surface, in: workspace ?? document.active, focus: focus)
        case let .paneSplit(workspace, direction, surface):
            return try split(
                direction, surface ?? .terminal(agent: nil), in: workspace ?? document.active,
                focus: focus)
        case let .paneClose(pane):
            return try close(pane)
        case let .paneShow(pane):
            return try show(pane, focus: focus)
        case let .paneName(pane, name):
            try changePane(pane) { $0.name = name }
            return Answer(changed: true, pane: pane)
        case let .paneRecord(pane, agent):
            try changePane(pane) { $0.surface = .terminal(agent: agent) }
            return Answer(changed: true, pane: pane)
        case let .focusSlot(slot):
            guard let path = document.active else { return Answer() }
            try change(path) { $0.bench.focusedSlot = slot }
            return Answer(changed: true)
        case let .focusStep(workspace, direction):
            return try step(direction, in: workspace ?? document.active)
        case let .layoutResize(divider, fraction):
            return try resize(divider, to: fraction)
        }
    }

    private mutating func applyWorkspace(_ verb: BenchVerb, focus: Bool) throws -> Answer {
        switch verb {
        case let .workspaceOpen(path):
            return openWorkspace(path, focus: focus)
        case let .workspaceActivate(path):
            guard workspace(path) != nil else { throw Refused(reason: "no workspace \(path)") }
            document.active = path
        case let .workspaceClose(path):
            document.workspaces.removeAll { $0.path == path }
            if document.active == path { document.active = document.workspaces.first?.path }
        case let .workspaceReset(path):
            try change(path) { workspace in
                workspace.shelved = workspace.bench
                workspace.bench = Self.bench([Self.terminal()])
            }
        case let .workspaceUnshelve(path):
            try change(path) { workspace in
                guard let shelved = workspace.shelved else { return }
                workspace.bench = shelved
                workspace.shelved = nil
            }
        case let .workspaceImport(imported):
            guard document.workspaces.isEmpty else {
                throw Refused(reason: "the document is not empty")
            }
            document = imported
        default:
            return Answer()
        }
        return Answer(changed: true)
    }

    // MARK: - Building

    static func terminal(_ id: UUID = UUID()) -> BenchDocument.Pane {
        .init(id: id, surface: .terminal(agent: nil))
    }

    static func bench(_ panes: [BenchDocument.Pane]) -> BenchDocument.Bench {
        let slot = BenchDocument.Slot(id: UUID(), panes: panes, selected: panes[0].id, height: 1)
        return .init(columns: [.init(id: UUID(), slots: [slot], width: 1)], focusedSlot: slot.id)
    }

    // MARK: - Workspaces

    private func workspace(_ path: String) -> BenchDocument.Workspace? {
        document.workspaces.first { $0.path == path }
    }

    private mutating func change(
        _ path: String, _ body: (inout BenchDocument.Workspace) throws -> Void
    ) throws {
        guard let index = document.workspaces.firstIndex(where: { $0.path == path }) else {
            throw Refused(reason: "no workspace \(path)")
        }
        try body(&document.workspaces[index])
    }

    private mutating func openWorkspace(_ path: String, focus: Bool) -> Answer {
        if workspace(path) == nil {
            document.workspaces.append(.init(path: path, bench: Self.bench([Self.terminal()])))
        }
        if focus || document.active == nil { document.active = path }
        return Answer(changed: true)
    }

    // MARK: - Panes

    private mutating func open(_ surface: Surface, in path: String?, focus: Bool) throws -> Answer {
        guard let path else { throw Refused(reason: "no workspace is open") }
        var answer = Answer(changed: true)
        try change(path) { workspace in
            let panes = workspace.bench.columns.flatMap(\.slots).flatMap(\.panes)
            let same: BenchDocument.Pane? =
                switch surface {
                case .canvas, .browser: panes.first { $0.surface == surface }
                default: nil
                }
            if let same {
                answer.pane = same.id
                if focus { Self.show(same.id, in: &workspace.bench, focus: true) }
                return
            }
            let pane = BenchDocument.Pane(id: UUID(), surface: surface)
            answer.created = pane.id
            if focus {
                let (c, s) = Self.address(ofSlot: workspace.bench.focusedSlot, in: workspace.bench)
                workspace.bench.columns[c].slots[s].panes.append(pane)
                workspace.bench.columns[c].slots[s].selected = pane.id
            } else {
                let slot = BenchDocument.Slot(
                    id: UUID(), panes: [pane], selected: pane.id, height: 1)
                workspace.bench.columns.append(.init(id: UUID(), slots: [slot], width: 1))
                Self.share(&workspace.bench)
            }
        }
        return answer
    }

    private mutating func split(
        _ direction: BenchSplit, _ surface: Surface, in path: String?, focus: Bool
    ) throws -> Answer {
        guard let path else { throw Refused(reason: "no workspace is open") }
        let pane = BenchDocument.Pane(id: UUID(), surface: surface)
        try change(path) { workspace in
            let (c, s) = Self.address(ofSlot: workspace.bench.focusedSlot, in: workspace.bench)
            let slot = BenchDocument.Slot(id: UUID(), panes: [pane], selected: pane.id, height: 1)
            switch direction {
            case .right:
                workspace.bench.columns.insert(
                    .init(id: UUID(), slots: [slot], width: 1), at: c + 1)
            case .down:
                workspace.bench.columns[c].slots.insert(slot, at: s + 1)
            }
            if focus { workspace.bench.focusedSlot = slot.id }
            Self.share(&workspace.bench)
        }
        return Answer(changed: true, created: pane.id)
    }

    private mutating func close(_ pane: UUID) throws -> Answer {
        let path = try path(holding: pane)
        try change(path) { workspace in
            guard workspace.bench.columns.flatMap(\.slots).flatMap(\.panes).count > 1 else {
                throw Refused(reason: "the last pane of a bench cannot close")
            }
            for c in workspace.bench.columns.indices {
                for s in workspace.bench.columns[c].slots.indices {
                    workspace.bench.columns[c].slots[s].panes.removeAll { $0.id == pane }
                    if let first = workspace.bench.columns[c].slots[s].panes.first,
                        workspace.bench.columns[c].slots[s].selected == pane
                    {
                        workspace.bench.columns[c].slots[s].selected = first.id
                    }
                }
                workspace.bench.columns[c].slots.removeAll { $0.panes.isEmpty }
            }
            workspace.bench.columns.removeAll { $0.slots.isEmpty }
            let slots = workspace.bench.columns.flatMap(\.slots)
            if !slots.contains(where: { $0.id == workspace.bench.focusedSlot }) {
                workspace.bench.focusedSlot = slots[0].id
            }
            Self.share(&workspace.bench)
        }
        return Answer(changed: true, pane: pane)
    }

    private mutating func show(_ pane: UUID, focus: Bool) throws -> Answer {
        let path = try path(holding: pane)
        try change(path) { Self.show(pane, in: &$0.bench, focus: focus) }
        return Answer(changed: true, pane: pane)
    }

    private static func show(_ pane: UUID, in bench: inout BenchDocument.Bench, focus: Bool) {
        for c in bench.columns.indices {
            for s in bench.columns[c].slots.indices
            where bench.columns[c].slots[s].panes.contains(where: { $0.id == pane }) {
                bench.columns[c].slots[s].selected = pane
                if focus { bench.focusedSlot = bench.columns[c].slots[s].id }
            }
        }
    }

    private mutating func changePane(
        _ pane: UUID, _ body: (inout BenchDocument.Pane) -> Void
    ) throws {
        let path = try path(holding: pane)
        try change(path) { workspace in
            for c in workspace.bench.columns.indices {
                for s in workspace.bench.columns[c].slots.indices {
                    for p in workspace.bench.columns[c].slots[s].panes.indices
                    where workspace.bench.columns[c].slots[s].panes[p].id == pane {
                        body(&workspace.bench.columns[c].slots[s].panes[p])
                    }
                }
            }
        }
    }

    // MARK: - Focus and sizes

    private mutating func step(_ direction: BenchDirection, in path: String?) throws -> Answer {
        guard let path else { return Answer() }
        try change(path) { workspace in
            let bench = workspace.bench
            let (c, s) = Self.address(ofSlot: bench.focusedSlot, in: bench)
            let target: (Int, Int)? =
                switch direction {
                case .up: s > 0 ? (c, s - 1) : nil
                case .down: s + 1 < bench.columns[c].slots.count ? (c, s + 1) : nil
                case .left: c > 0 ? (c - 1, min(s, bench.columns[c - 1].slots.count - 1)) : nil
                case .right:
                    c + 1 < bench.columns.count
                        ? (c + 1, min(s, bench.columns[c + 1].slots.count - 1)) : nil
                }
            if let (tc, ts) = target {
                workspace.bench.focusedSlot = bench.columns[tc].slots[ts].id
            }
        }
        return Answer(changed: true)
    }

    private mutating func resize(_ divider: BenchDivider, to fraction: Double) throws -> Answer {
        guard let path = document.active else { return Answer() }
        try change(path) { workspace in
            switch divider {
            case let .columns(member, against):
                guard let m = workspace.bench.columns.firstIndex(where: { $0.id == member }),
                    let a = workspace.bench.columns.firstIndex(where: { $0.id == against })
                else { return }
                let pair = workspace.bench.columns[m].width + workspace.bench.columns[a].width
                workspace.bench.columns[m].width = fraction
                workspace.bench.columns[a].width = pair - fraction
            case let .slots(member, against):
                let (c, m) = Self.address(ofSlot: member, in: workspace.bench)
                let (_, a) = Self.address(ofSlot: against, in: workspace.bench)
                let pair =
                    workspace.bench.columns[c].slots[m].height
                    + workspace.bench.columns[c].slots[a].height
                workspace.bench.columns[c].slots[m].height = fraction
                workspace.bench.columns[c].slots[a].height = pair - fraction
            }
        }
        return Answer(changed: true)
    }

    /// Every stack shares its length equally — the toy's whole sizing rule.
    private static func share(_ bench: inout BenchDocument.Bench) {
        for c in bench.columns.indices {
            bench.columns[c].width = 1 / Double(bench.columns.count)
            for s in bench.columns[c].slots.indices {
                bench.columns[c].slots[s].height = 1 / Double(bench.columns[c].slots.count)
            }
        }
    }

    private static func address(ofSlot slot: UUID, in bench: BenchDocument.Bench) -> (Int, Int) {
        for (c, column) in bench.columns.enumerated() {
            if let s = column.slots.firstIndex(where: { $0.id == slot }) { return (c, s) }
        }
        return (0, 0)
    }

    private func path(holding pane: UUID) throws -> String {
        guard
            let workspace = document.workspaces.first(where: {
                $0.bench.columns.flatMap(\.slots).flatMap(\.panes).contains { $0.id == pane }
            })
        else { throw Refused(reason: "no pane \(pane)") }
        return workspace.path
    }
}

extension FakeBenchd {
    /// Answer every verb from a `ToyBench` over the document this stand-in holds: apply it, push
    /// the frame, then answer — the order benchd keeps.
    func playToyBench() {
        answer = { [weak self] raw in
            let id = raw["id"] ?? ""
            guard let self,
                let data = try? JSONSerialization.data(withJSONObject: raw),
                let request = try? JSONDecoder().decode(BenchRequest.self, from: data)
            else { return ["id": id, "status": "error", "reason": "the toy could not read it"] }
            let current = self.current
            var toy = ToyBench(document: current.document)
            do {
                let answer = try toy.apply(request)
                guard answer.changed else {
                    return [
                        "id": id, "status": "ok", "data": ["seq": current.seq, "changed": false],
                    ]
                }
                let next = DocumentAt(seq: current.seq + 1, document: toy.document)
                var change: [String: Any] = [
                    "verb": raw["verb"] ?? "", "by": raw["by"] ?? ["kind": "agent"],
                ]
                if let pane = answer.pane ?? answer.created {
                    change["pane"] = pane.uuidString.lowercased()
                }
                push(next, data: change)
                var report: [String: Any] = ["seq": next.seq, "changed": true]
                if let created = answer.created {
                    report["pane_created"] = created.uuidString.lowercased()
                }
                if let pane = answer.pane { report["pane"] = pane.uuidString.lowercased() }
                return ["id": id, "status": "ok", "data": report]
            } catch let refused as ToyBench.Refused {
                return ["id": id, "status": "refused", "reason": refused.reason]
            } catch {
                return ["id": id, "status": "error", "reason": "\(error)"]
            }
        }
    }
}

// MARK: - A helm drawn from the toy

/// A `WorkbenchModel` drawn from a toy benchd, for a test of helm's side of the bench.
@MainActor
struct ToyRig {
    let server: FakeBenchd
    let client: BenchClient
    let model: WorkbenchModel
    let terminals: TerminalManager

    /// The workspace a single-workspace rig opened.
    var path: WorkspacePath? { model.workspacePath }
}

/// A stand-in benchd holding `document` and playing the toy bench, and a client for it. The
/// caller stops both; `XCTestCase.toyBenchd` does it at teardown.
@MainActor
func startToyBenchd(_ document: BenchDocument) throws -> (FakeBenchd, BenchClient) {
    let server = try FakeBenchd(document: DocumentAt(seq: 1, document: document))
    server.playToyBench()
    return (server, BenchClient(socketPath: server.path))
}

extension BenchDocument {
    /// One workspace at `path` holding `bench`, on screen.
    static func only(_ path: String, _ bench: BenchDocument.Bench) -> BenchDocument {
        BenchDocument(workspaces: [.init(path: path, bench: bench)], active: path)
    }
}

extension XCTestCase {
    /// A stand-in benchd holding `document` and playing the toy bench, and a client for it.
    /// Both stop at teardown.
    @MainActor
    func toyBenchd(_ document: BenchDocument) throws -> (FakeBenchd, BenchClient) {
        let (server, client) = try startToyBenchd(document)
        addTeardownBlock { @MainActor in
            client.stop()
            server.stop()
        }
        return (server, client)
    }

    /// helm drawn from a toy benchd holding `document` — by default one workspace at `path` with
    /// one terminal, which is what a first visit gets. `make` builds the model on the client, for
    /// a test that injects collaborators. Waits for the first document, and — unless `answering`
    /// is false — answers #85's question by restoring when the first bench is worth asking about.
    @MainActor
    func toyRig(
        _ path: String = "/tmp/helm-toy",
        document: BenchDocument? = nil,
        terminals: TerminalManager = TerminalManager(),
        answering: Bool = true,
        make: ((TerminalManager, BenchClient) -> WorkbenchModel)? = nil
    ) throws -> ToyRig {
        let document =
            document
            ?? BenchDocument(
                workspaces: [.init(path: path, bench: ToyBench.bench([ToyBench.terminal()]))],
                active: path)
        let (server, client) = try toyBenchd(document)
        let model =
            make?(terminals, client)
            ?? WorkbenchModel(terminals: terminals, agents: .blind, client: client)
        // Waited for on the follower's own condition rather than by pumping the run loop: an
        // `async` test runs on the main queue, which a nested run loop cannot drain.
        XCTAssertNotNil(
            client.document(atLeast: 1, within: 5), "the first document never came")
        if answering, model.restoreOffer != nil { model.answer(.restore) }
        return ToyRig(server: server, client: client, model: model, terminals: terminals)
    }
}
