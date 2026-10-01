import AppKit
import HelmWire
import SwiftUI
import XCTest

@testable import Helm

/// The workspace bar's drag end to end, through real mouse events: the bar hosted in a window of
/// the test's own, as `RootView` composes it (the one drag space, the drop-zone overlay over it),
/// and events handed to that window and to `NSApp` directly. Nothing leaves the test process, so
/// no window comes forward and nothing reaches another app. `WorkspaceDropTests` holds the
/// resolver's rules; this proves the gesture, the frames it is resolved against, and Escape.
@MainActor
final class WorkspaceBarDragTests: XCTestCase {
    private let paths = ["/w/a", "/w/b", "/w/c"]

    @MainActor
    private struct Hosted {
        let rig: ToyRig
        let window: NSWindow
        let size: NSSize

        /// The middle of a workspace's tab, in the window's coordinates (origin bottom-left).
        func centre(of path: String) throws -> NSPoint {
            let tab = rig.model.drag.bar.tabs[WorkspacePath(path)]
            let frame = try XCTUnwrap(tab, "no frame for \(path)")
            return NSPoint(x: frame.midX, y: size.height - frame.midY)
        }

        func mouse(_ type: NSEvent.EventType, at point: NSPoint) throws {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            window.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }

        /// Down on `from`, then the pointer carried to `to` in steps, button still held.
        func drag(from: NSPoint, to: NSPoint) throws {
            try mouse(.leftMouseDown, at: from)
            for step in 1...8 {
                let t = CGFloat(step) / 8
                try mouse(
                    .leftMouseDragged,
                    at: NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
            }
        }
    }

    private func host() throws -> Hosted {
        let rig = try toyRig(
            paths[0],
            document: BenchDocument(
                workspaces: paths.map {
                    .init(
                        path: $0, bench: ToyBench.bench([ToyBench.terminal(), ToyBench.terminal()]))
                },
                active: paths[0]))
        let workspaces = WorkspaceModel(readBranch: { _ in nil })
        workspaces.follow(try XCTUnwrap(rig.model.document))
        let view = VStack(spacing: 0) {
            WorkspaceBar(model: workspaces, workbench: rig.model, select: { _ in }, close: { _ in })
            Spacer()
        }
        .overlay(alignment: .topLeading) { DropZoneOverlay(drag: rig.model.drag) }
        .coordinateSpace(name: BenchDrag.space)
        .frame(width: 600, height: 120)

        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view)
        let size = NSSize(width: 600, height: 120)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        addTeardownBlock { @MainActor in
            window.contentView = nil
            window.close()
        }
        XCTAssertTrue(
            Eventually.holds { rig.model.drag.bar.tabs.count == 3 },
            "the bar never reported its tabs")
        return Hosted(rig: rig, window: window, size: size)
    }

    /// Down on the last tab, carried left of the first, released: one `workspace/move` before the
    /// first, by the operator, with the zone drawn on the way.
    func testDraggingAWorkspaceTabAlongTheBarSendsOneMove() throws {
        let hosted = try host()
        let sent = hosted.rig.server.verbs.count
        let first = try hosted.centre(of: "/w/a")
        let end = NSPoint(x: first.x - 10, y: first.y)

        try hosted.drag(from: hosted.centre(of: "/w/c"), to: end)
        XCTAssertEqual(
            hosted.rig.model.drag.live?.target?.to, .bar(before: "/w/a"),
            "the zone is the gap before the first")
        try hosted.mouse(.leftMouseUp, at: end)

        XCTAssertEqual(hosted.rig.server.verbs.count, sent + 1)
        let verb = try XCTUnwrap(hosted.rig.server.verbs.last)
        XCTAssertEqual(verb["verb"] as? String, "workspace/move")
        XCTAssertEqual((verb["args"] as? [String: Any])?["before"] as? String, "/w/a")
        XCTAssertNil(hosted.rig.model.drag.live)
    }

    /// Escape while the button is held: the key goes through `NSApp`, where the drag's monitor
    /// takes it, the zone goes, and the release sends nothing.
    func testEscapeDuringADragCancelsIt() throws {
        let hosted = try host()
        let sent = hosted.rig.server.verbs.count
        let first = try hosted.centre(of: "/w/a")
        let end = NSPoint(x: first.x - 10, y: first.y)
        try hosted.drag(from: hosted.centre(of: "/w/c"), to: end)
        XCTAssertNotNil(hosted.rig.model.drag.live?.target)

        let escape = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: hosted.window.windowNumber, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        NSApplication.shared.sendEvent(escape)
        XCTAssertNil(hosted.rig.model.drag.live, "Escape takes the zone away")

        try hosted.mouse(.leftMouseDragged, at: NSPoint(x: end.x - 2, y: end.y))
        try hosted.mouse(.leftMouseUp, at: end)
        XCTAssertEqual(hosted.rig.server.verbs.count, sent, "a cancelled drag sends nothing")
    }
}
