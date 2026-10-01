import AppKit
import HelmWire
import SwiftUI
import XCTest

@testable import Helm

/// **Does a click anywhere on a tab reach it.** The operator's report was that clicks on the
/// workspace bar and on a pane's × were unreliable: they were, because `.plain` buttons answered
/// only on their glyphs (`ChromeButtonStyle`'s header has the measurement).
///
/// Each test hosts the real view in a window and clicks a 2pt grid over it through
/// `NSWindow.sendEvent`, mouse down then up, recording which action each point reached. Nothing
/// here needs a terminal surface or a display: the clicks never leave the window.
@MainActor
final class ChromeHitTargetTests: XCTestCase {
    // MARK: - The workspace bar

    /// The tab you click to switch to is always an unselected one, and before the fix a third of
    /// it took the click: the padding, the gap between `⌃2` and the name, and the bands above and
    /// below the text were dead.
    func testEveryPointOfAnUnselectedWorkspaceTabSwitchesToIt() throws {
        let map = try workspaceBarMap()
        let tab = try XCTUnwrap(map.box(of: "b"), "no point reached the unselected tab\n\(map)")
        XCTAssertGreaterThanOrEqual(
            map.filled(tab, by: "b"), 0.95,
            "clicks inside the unselected workspace tab reached nothing\n\(map)")
        XCTAssertGreaterThanOrEqual(
            tab.height, 20, "the tab's padding bands take no click\n\(map)")
    }

    /// Passes before and after the fix: the selected tab always had a fill to hit. What it guards
    /// is overshoot — a hit region that grew past its own tab would take clicks meant for the
    /// neighbour.
    func testTheTwoTabsHitRegionsDoNotMeet() throws {
        let map = try workspaceBarMap()
        let selected = try XCTUnwrap(map.box(of: "a"), "no point reached the selected tab\n\(map)")
        let other = try XCTUnwrap(map.box(of: "b"), "no point reached the unselected tab\n\(map)")
        XCTAssertGreaterThanOrEqual(map.filled(selected, by: "a"), 0.95, "\(map)")
        XCTAssertFalse(selected.intersects(other), "one tab takes the other's clicks\n\(map)")
    }

    // MARK: - A pane tab's ×

    /// Before the fix the × took a click on its 8pt glyph alone, about 6×8pt, and a click beside
    /// it selected the pane instead: the report's "X-ing panes doesn't work".
    func testThePaneTabsCloseButtonTakesAClickAroundItsGlyph() throws {
        let map = try paneTabMap()
        let close = try XCTUnwrap(map.box(of: "X"), "no point reached the ×\n\(map)")
        XCTAssertGreaterThanOrEqual(close.width, 12, "the × is too narrow to hit\n\(map)")
        XCTAssertGreaterThanOrEqual(close.height, 12, "the × is too short to hit\n\(map)")
        XCTAssertGreaterThanOrEqual(map.filled(close, by: "X"), 0.95, "\(map)")
    }

    /// Passes before and after: the rest of the tab still selects, and the × sits inside it, so
    /// the close target did not swallow the tab.
    func testTheRestOfThePaneTabStillSelectsIt() throws {
        let map = try paneTabMap()
        let tab = try XCTUnwrap(map.box(of: "S"), "no point selected the pane\n\(map)")
        let close = try XCTUnwrap(map.box(of: "X"), "no point reached the ×\n\(map)")
        XCTAssertTrue(tab.contains(close), "the × lies outside its own tab\n\(map)")
        XCTAssertGreaterThan(map.count(of: "S"), 4 * map.count(of: "X"), "\(map)")
    }

    // MARK: - No button is glyph-only

    /// `.plain` is the style that made the tabs and the × glyph-only, and it looks harmless on
    /// the next button too. Every button in helm uses `.chrome`, and this keeps it that way.
    func testNoButtonInHelmUsesThePlainStyle() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Design/
            .deletingLastPathComponent()  // HelmTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/Helm")
        let walk = try XCTUnwrap(
            FileManager.default.enumerator(atPath: root.path),
            "could not read \(root.path) — this guard must fail loudly, not skip")
        var offenders: [String] = []
        var read = 0
        for case let relative as String in walk where relative.hasSuffix(".swift") {
            let text = try String(
                contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            read += 1
            for (index, line) in text.components(separatedBy: "\n").enumerated()
            where line.contains("buttonStyle(.plain)") || line.contains("PlainButtonStyle") {
                offenders.append("\(relative):\(index + 1)")
            }
        }
        XCTAssertGreaterThan(read, 50, "read too few sources to mean anything: \(root.path)")
        XCTAssertEqual(
            offenders, [], "use .buttonStyle(.chrome), which makes the whole label the target")
    }

    // MARK: - Harness

    private func workspaceBarMap() throws -> HitMap {
        let model = WorkspaceModel(readBranch: { _ in nil })
        let bench = ToyBench.bench([ToyBench.terminal()])
        model.follow(
            BenchDocument(
                workspaces: [
                    .init(path: "/tmp/alpha", bench: bench), .init(path: "/tmp/beta", bench: bench),
                ],
                active: "/tmp/alpha"))
        let hit = Hit()
        let rig = try toyRig("/tmp/alpha")
        let bar = WorkspaceBar(
            model: model, workbench: rig.model, select: { hit.value = $0.name.first },
            close: { _ in })
        return try HitMap(over: bar, width: 220, hit: hit)
    }

    private func paneTabMap() throws -> HitMap {
        let hit = Hit()
        let slot = SurfaceSlot(
            pane: Pane(content: .unsupported("probe")), holdsKeyboard: false, isSelected: false,
            canClose: true, select: { hit.value = "S" }, close: { hit.value = "X" })
        let tab = HStack {
            PaneTab(title: "claude · helm", truncation: .tail, closeHelp: "Close", slot: slot) {
                Image(systemName: "terminal")
            }
            Spacer()
        }
        .padding(4)
        return try HitMap(over: tab, width: 200, hit: hit)
    }
}

/// The last action a click reached, as one character.
@MainActor
private final class Hit {
    var value: Character?
}

/// Which action each point of a 2pt grid over a view reached, `.` for none. Row 0 is the top.
private struct HitMap: CustomStringConvertible {
    static let step: CGFloat = 2
    private let rows: [[Character]]

    @MainActor
    init<V: View>(over view: V, width: CGFloat, hit: Hit) throws {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view)
        let size = NSSize(width: width, height: hosting.fittingSize.height)
        XCTAssertGreaterThan(size.height, 0, "the view has no height")
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        Eventually.pump()

        var rows: [[Character]] = []
        for y in stride(from: size.height - 1, through: 0, by: -Self.step) {
            var row: [Character] = []
            for x in stride(from: 0, to: size.width, by: Self.step) {
                hit.value = nil
                let point = NSPoint(x: x + 0.5, y: y + 0.5)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    let event = try XCTUnwrap(
                        NSEvent.mouseEvent(
                            with: type, location: point, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                            clickCount: 1, pressure: 1))
                    window.sendEvent(event)
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.001))
                row.append(hit.value ?? ".")
            }
            rows.append(row)
        }
        self.rows = rows
    }

    /// The bounding box of every point that reached `mark`, in points.
    func box(of mark: Character) -> CGRect? {
        var box: CGRect?
        for (y, row) in rows.enumerated() {
            for (x, found) in row.enumerated() where found == mark {
                let cell = CGRect(
                    x: CGFloat(x) * Self.step, y: CGFloat(y) * Self.step,
                    width: Self.step, height: Self.step)
                box = box.map { $0.union(cell) } ?? cell
            }
        }
        return box
    }

    /// The share of the points in `box` that reached `mark`.
    func filled(_ box: CGRect, by mark: Character) -> Double {
        var inside = 0
        var matching = 0
        for (y, row) in rows.enumerated() {
            for (x, found) in row.enumerated() {
                let point = CGPoint(
                    x: (CGFloat(x) + 0.5) * Self.step, y: (CGFloat(y) + 0.5) * Self.step)
                guard box.contains(point) else { continue }
                inside += 1
                if found == mark { matching += 1 }
            }
        }
        return inside == 0 ? 0 : Double(matching) / Double(inside)
    }

    func count(of mark: Character) -> Int {
        rows.reduce(0) { $0 + $1.filter { $0 == mark }.count }
    }

    var description: String {
        rows.map { String($0) }.joined(separator: "\n")
    }
}
