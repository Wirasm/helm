import Foundation
import HelmWire
import XCTest

@testable import Helm

@MainActor
final class BrowserPendingPickerTests: XCTestCase {
    func testOwnedNavigationAndRemovalDuringEmptyDocumentCaptureDiscardOldInput() async throws {
        for method in ["Page.frameNavigated", "Page.frameDetached"] {
            for frame in ["owned", "ancestor"] {
                for failing in [true, false] {
                    try await discardedInput(
                        method: method, frame: frame, hit: .localControl, failing: failing)
                }
            }
        }
    }

    func testOOPIFBoundaryLossDuringOwnerAncestryCaptureDiscardsOldInput() async throws {
        for method in ["Page.frameNavigated", "Page.frameDetached"] {
            try await discardedInput(
                method: method, frame: "child", hit: .processFrameOwner, failing: true)
        }
    }

    func testUnrelatedNavigationAndRemovalDuringCapturePreserveQueuedChoice() async throws {
        for method in ["Page.frameNavigated", "Page.frameDetached"] {
            let fixture = try Capture()
            defer { fixture.close() }
            fixture.openPicker()
            try await eventually("document-root reply is held") { fixture.relay.waiting }
            fixture.key("ArrowDown", vk: 40)
            fixture.key("Enter", vk: 13)
            try fixture.relay.resume(method: method, frame: "sibling", failing: false)
            try await fixture.drain()
            XCTAssertEqual(
                fixture.relay.commits, [.init(object: "control", session: "root", index: 1)])
            XCTAssertEqual(fixture.relay.texts, [])
            XCTAssertNil(fixture.input.forms.current)
        }
    }

    private func discardedInput(
        method: String, frame: String, hit: PickerCaptureRelay.Hit, failing: Bool
    ) async throws {
        let fixture = try Capture(hit: hit)
        defer { fixture.close() }
        fixture.openPicker()
        try await eventually("document-root reply is held before frame ownership is complete") {
            fixture.relay.waiting
        }
        fixture.input.send(.text("old"), to: fixture.destination)
        try fixture.relay.resume(method: method, frame: frame, failing: failing)
        try await fixture.drain()
        XCTAssertEqual(
            fixture.relay.texts, [], "\(method) on \(frame) must discard replacement-bound input")
        XCTAssertNil(
            fixture.input.forms.current,
            "\(method) on \(frame) cancels capture even when its held reply succeeds: \(!failing)")
        fixture.input.send(.text("fresh"), to: fixture.destination)
        try await fixture.drain()
        XCTAssertEqual(fixture.relay.texts, ["fresh"], "the next generation must remain usable")
    }

    private func eventually(_ why: String, _ done: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !done() {
            if ContinuousClock.now >= deadline { XCTFail("never: \(why)"); throw Timeout() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct Timeout: Error {}

    @MainActor
    private final class Capture {
        let relay: PickerCaptureRelay
        let benchd: FakeBenchd
        let connection: CDPConnection
        let input = BrowserPageInput()
        var destination: BrowserPageInput.Destination {
            .init(connection: connection, session: "root")
        }

        init(hit: PickerCaptureRelay.Hit = .localControl) throws {
            relay = PickerCaptureRelay(hit: hit)
            benchd = try FakeBenchd(
                document: .init(seq: 1, document: .init(workspaces: [], active: nil)), tcp: true)
            benchd.answer = { ["id": $0["id"] ?? "", "status": "ok", "data": ["pid": 4242]] }
            benchd.relay = { [relay] fd in relay.serve(fd) }
            connection = CDPConnection(endpoint: benchd.endpoint)
            input.isCurrent = { $0.session == "root" }
            connection.onEvent = { [input] event in input.handle(event) }
            connection.open()
        }

        func close() {
            input.reset()
            connection.close()
            XCTAssertTrue(relay.stop(), "bounded relay shutdown completes")
            benchd.stop()
        }

        func openPicker() {
            input.send(
                .mouse(.init(type: "mousePressed", x: 20, y: 20, button: "left", clickCount: 1)),
                to: destination)
        }

        func key(_ key: String, vk: Int) {
            input.send(
                .key(
                    .init(
                        type: "rawKeyDown", modifiers: 0, key: key, code: key,
                        windowsVirtualKeyCode: vk)), to: destination)
        }

        func drain() async throws {
            _ = await input.caret(to: destination)
            // This reply follows every fire-and-forget input already written by the drain.
            try await connection.call("Page.enable", session: "root")
        }
    }
}
