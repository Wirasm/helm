import AppKit
import HelmWire
import XCTest

@testable import Helm

/// Two real OOPIF boundaries, observed through connections independent of the pane.
/// Run with scripts/test-browser-oopif.sh, which owns the isolated benchd/browser fixture.
@MainActor
class BrowserOOPIFLiveCase: BrowserControlLiveCase {
    enum Level: Hashable { case main, middle, leaf }
    struct Frame {
        let connection: CDPConnection
        let session: String
        let target: String
    }

    private var frames: [Level: Frame] = [:]
    private var ownedTabs: [String] = []
    private var endpoint: BenchEndpoint!
    private(set) var fixtureURL: URL!

    override func setUp() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["HELM_BROWSER_OOPIF_URL"] else {
            throw XCTSkip("needs the isolated scripts/test-browser-oopif.sh HTTP fixture")
        }
        fixtureURL = try XCTUnwrap(URL(string: fixture + "?run=" + UUID().uuidString))
        try await super.setUp()
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["HELM_BROWSER_LIVE_BENCH_DIR"])
        endpoint = try BenchRoot.endpoint(environment: ["BENCH_DIR": root]).get()
        try await showFixture()
    }

    override func tearDown() async throws {
        for frame in frames.values where frame.connection !== observer { frame.connection.close() }
        for tab in ownedTabs {
            try? await observer?.call("Target.closeTarget", TargetID(targetId: tab))
        }
        frames.removeAll()
        try await super.tearDown()
    }

    private func showFixture() async throws {
        pane.open(fixtureURL)
        try await eventually("main fixture is shown") {
            self.pane.tabs.current?.url == self.fixtureURL.absoluteString
                && self.surface.layer?.contents != nil
        }
        let main = try XCTUnwrap(pane.tabs.showing)
        ownedTabs.append(main)
        observing = try await observer.call(
            "Target.attachToTarget", Attach(targetId: main), returning: Attached.self
        ).sessionId
        frames[.main] = Frame(connection: observer, session: observing, target: main)
        try await eventually("both actual iframe targets exist") {
            let targets = try await self.targets()
            return targets.filter { $0.type == "iframe" && self.isFixture($0.url) }.count == 2
        }
        for (level, path) in [(Level.middle, "/middle"), (.leaf, "/leaf")] {
            let available = try await targets()
            let target = try XCTUnwrap(
                available.first { $0.type == "iframe" && isFixture($0.url, path: path) })
            XCTAssertEqual(
                URL(string: target.url)?.host, level == .middle ? "127.0.0.1" : "localhost")
            try await observe(target.targetId, at: level)
        }
        for (level, offset) in [(Level.main, 45), (.middle, 55), (.leaf, 35)] {
            try await eventually("\(level) document loaded") {
                try await self.readFrame("document.readyState==='complete'", at: level)
            }
            let scrolled: Bool = try await readFrame("scrollTo(0,\(offset)); true", at: level)
            XCTAssertTrue(scrolled)
            try await eventually("\(level) viewport scrolled") {
                try await self.readFrame("scrollY===\(offset)", at: level)
            }
        }
        XCTAssertNotEqual(frames[.middle]?.target, frames[.leaf]?.target)
    }

    private func isFixture(_ value: String, path: String? = nil) -> Bool {
        guard let url = URL(string: value) else { return false }
        let token = URLComponents(url: fixtureURL, resolvingAgainstBaseURL: false)?.queryItems?
            .first?.value
        let candidate = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "run" }?.value
        return candidate == token && (path == nil || url.path == path)
    }

    func observeLeafAfterNavigation(replacement: Bool = false) async throws {
        try await eventually("replacement iframe target is available") {
            try await self.targets().contains {
                $0.type == "iframe" && self.isFixture($0.url, path: "/leaf")
                    && (!replacement || $0.url.contains("replacement=1"))
            }
        }
        let available = try await targets()
        let target = try XCTUnwrap(
            available.first { $0.type == "iframe" && isFixture($0.url, path: "/leaf") })
        frames[.leaf]?.connection.close()
        try await observe(target.targetId, at: .leaf)
        try await eventually("replacement leaf loaded") {
            try await self.readFrame(
                "document.readyState==='complete' && !!document.querySelector('#select')")
        }
    }

    private func observe(_ target: String, at level: Level) async throws {
        let connection = CDPConnection(endpoint: endpoint)
        connection.open()
        let session = try await connection.call(
            "Target.attachToTarget", Attach(targetId: target), returning: Attached.self
        ).sessionId
        frames[level] = Frame(connection: connection, session: session, target: target)
    }

    func readFrame<T: Decodable>(_ expression: String, at level: Level = .leaf) async throws -> T {
        let frame = try XCTUnwrap(frames[level])
        return try await frame.connection.call(
            "Runtime.evaluate", Evaluate(expression: expression), session: frame.session,
            returning: Evaluated<T>.self
        ).result.value
    }

    /// Map scale with DOM rectangles, and perspective with its forward DOMMatrix projection.
    /// Both are independent of production's CDP box quads and hit-test conversion.
    func clickLeaf(_ id: String, perspective: Bool = false) async throws {
        var point: [Double] = try await readFrame(
            "(() => { const r=document.getElementById('\(id)').getBoundingClientRect();"
                + "return [r.x+r.width/2,r.y+r.height/2] })()")
        for (level, owner) in [(Level.middle, "inner"), (.main, "outer")] {
            if perspective {
                point = try await readFrame(
                    "(() => { const e=document.getElementById('\(owner)'),r=e.getBoundingClientRect();"
                        + "const m=new DOMMatrix(getComputedStyle(e).transform);"
                        + "const p=m.transformPoint(new DOMPoint(\(point[0])+e.clientLeft,\(point[1])+e.clientTop));"
                        + "return [r.x+p.x/p.w,r.y+p.y/p.w] })()", at: level)
                continue
            }
            let box: [Double] = try await readFrame(
                "(() => { const e=document.getElementById('\(owner)'),r=e.getBoundingClientRect();"
                    + "return [r.x,r.y,r.width/e.offsetWidth,r.height/e.offsetHeight,e.clientLeft,e.clientTop] })()",
                at: level)
            point = [box[0] + box[2] * (box[4] + point[0]), box[1] + box[3] * (box[5] + point[1])]
        }
        for type in ["mousePressed", "mouseReleased"] {
            pane.mouse(.init(type: type, x: point[0], y: point[1], button: "left", clickCount: 1))
        }
    }

    func openSelect(perspective: Bool = false) async throws {
        try await clickLeaf("select", perspective: perspective)
        try await eventually("nested select picker is on the pane") {
            self.pane.pageInput.forms.current != nil
        }
        guard case .select = pane.pageInput.forms.current?.control else {
            return XCTFail("expected the nested select picker")
        }
    }

    func assertUnchanged(at level: Level = .leaf) async throws {
        let selected: Int = try await readFrame(
            "document.querySelector('#select').selectedIndex", at: level)
        let date: String = try await readFrame("document.querySelector('#date').value", at: level)
        let events: [String] = try await readFrame("events", at: level)
        XCTAssertEqual(selected, 0)
        XCTAssertEqual(date, "2026-10-02")
        XCTAssertEqual(events, [])
    }

    func barrier() async throws {
        let previous: Int = try await readFrame("barriers")
        key("F8", code: "F8", vk: 119)
        try await eventually("following key drains the picker input queue") {
            let count: Int = try await self.readFrame("barriers")
            return count == previous + 1
        }
    }

    func ownCurrentTab() throws { ownedTabs.append(try XCTUnwrap(pane.tabs.showing)) }

    /// Observe the affected frame independently, then drain its event on the pane's connection.
    func mutateFrame(
        _ owner: String, at level: Level, method: String, mutation: String
    ) async throws {
        let frame = try XCTUnwrap(frames[level])
        try await frame.connection.call("Page.enable", session: frame.session)
        let remote = try await frame.connection.call(
            "Runtime.evaluate", Evaluate(expression: owner, returnByValue: false),
            session: frame.session, returning: ObjectReply.self)
        let object = ObjectID(objectId: remote.result.objectId)
        defer { frame.connection.send("Runtime.releaseObject", object, session: frame.session) }
        let description = try await frame.connection.call(
            "DOM.describeNode", object, session: frame.session, returning: DescribedFrame.self)
        let affected = description.node.frameId
        var observed = false
        frame.connection.onEvent = { event in
            guard event.sessionId == frame.session, event.method == method else { return }
            let id =
                method == "Page.frameNavigated"
                ? event.params(NavigatedFrame.self)?.frame.id
                : event.params(DetachedFrame.self)?.frameId
            if id == affected { observed = true }
        }
        defer { frame.connection.onEvent = nil }
        let changed: Bool = try await readFrame(mutation, at: level)
        XCTAssertTrue(changed)
        try await eventually("observed \(method) for the affected frame") { observed }
        let drained = await pane.inputCall(
            "Runtime.evaluate", Evaluate(expression: "true"), returning: Evaluated<Bool>.self)
        XCTAssertEqual(drained?.result.value, true)
    }

    func closeChildObserversAndAssertNoAttachments() async throws {
        let children = [Level.middle, .leaf].compactMap { frames[$0] }
        let ids = Set(children.map(\.target))
        XCTAssertEqual(ids.count, 2)
        let attached = try await targets().filter { ids.contains($0.targetId) }
        XCTAssertEqual(attached.count, 2)
        XCTAssertTrue(
            attached.allSatisfy(\.attached), "getTargets observes the independent child attachments"
        )
        for child in children { child.connection.close() }
        try await eventually("dismissed picker leaves no child session attachments") {
            let remaining = try await self.targets().filter { ids.contains($0.targetId) }
            return remaining.count == 2 && remaining.allSatisfy { !$0.attached }
        }
    }

    private func targets() async throws -> [Target] {
        try await observer.call("Target.getTargets", returning: Targets.self).targetInfos
    }

    private struct TargetID: Encodable { let targetId: String }
    private struct ObjectID: Encodable { let objectId: String }
    private struct ObjectReply: Decodable {
        struct Remote: Decodable { let objectId: String }
        let result: Remote
    }
    private struct DescribedFrame: Decodable {
        struct Node: Decodable { let frameId: String }
        let node: Node
    }
    private struct NavigatedFrame: Decodable {
        struct Frame: Decodable { let id: String }
        let frame: Frame
    }
    private struct DetachedFrame: Decodable { let frameId: String }
    private struct Attach: Encodable { let targetId: String; var flatten = true }
    private struct Attached: Decodable { let sessionId: String }
    private struct Target: Decodable {
        let targetId: String
        let type: String
        let url: String
        let attached: Bool
    }
    private struct Targets: Decodable { let targetInfos: [Target] }
    private struct Evaluate: Encodable { let expression: String; var returnByValue = true }
    private struct Evaluated<T: Decodable>: Decodable {
        struct Remote: Decodable { let value: T }
        let result: Remote
    }
}
