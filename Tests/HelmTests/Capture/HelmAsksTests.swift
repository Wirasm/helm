import Foundation
import HelmWire
import XCTest

@testable import Helm

/// benchd asking helm to draw itself (M3): each ask gets exactly one answer, carrying the
/// capturer's report or its reason, and an ask this build does not know is refused by name
/// rather than left to time out on the agent's side.
@MainActor
final class HelmAsksTests: XCTestCase {
    private final class Capturer: SpoolCapturing {
        var asked: [(String, String?)] = []
        var refusal: String?

        func capture(to path: String, window: String?) -> Result<CaptureReport, SpoolRefusal> {
            asked.append((path, window))
            if let refusal { return .failure(SpoolRefusal(refusal)) }
            return .success(
                CaptureReport(
                    path: path, pixelWidth: 200, pixelHeight: 100, scale: 2, window: "helm — m3",
                    windowVisible: true, terminalContent: .absent, terminalSurfaces: 0,
                    terminalSurfacesExcluded: 0))
        }
    }

    private final class Sent: @unchecked Sendable {
        var answers: [HelmAnswerRequest<CaptureReport>] = []
    }

    private func asks(_ capturer: Capturer) -> (HelmAsks, Sent) {
        let sent = Sent()
        return (HelmAsks(capturer: capturer) { sent.answers.append($0) }, sent)
    }

    func testACaptureIsAnsweredWithTheReport() throws {
        let capturer = Capturer()
        let (asks, sent) = asks(capturer)
        asks.answer(HelmAsked(ask: "a7", request: .capture(path: "/tmp/x.png", window: "m3")))

        XCTAssertEqual(capturer.asked.map(\.0), ["/tmp/x.png"])
        XCTAssertEqual(capturer.asked.map(\.1), ["m3"])
        let answer = try XCTUnwrap(sent.answers.first)
        XCTAssertEqual(sent.answers.count, 1)
        XCTAssertEqual(answer.ask, "a7")
        XCTAssertEqual(answer.status, .ok)
        XCTAssertEqual(answer.data?.path, "/tmp/x.png")
    }

    func testACaptureThatCannotDrawSaysWhy() throws {
        let capturer = Capturer()
        capturer.refusal = "two windows match \"helm\""
        let (asks, sent) = asks(capturer)
        asks.answer(HelmAsked(ask: "a8", request: .capture(path: "/tmp/x.png", window: nil)))

        let answer = try XCTUnwrap(sent.answers.first)
        XCTAssertEqual(answer.status, .error)
        XCTAssertEqual(answer.reason, "two windows match \"helm\"")
        XCTAssertNil(answer.data)
    }

    func testAnAskThisBuildDoesNotKnowIsRefusedByName() throws {
        let capturer = Capturer()
        let (asks, sent) = asks(capturer)
        asks.answer(HelmAsked(ask: "a9", request: .unknown(kind: "page")))

        let answer = try XCTUnwrap(sent.answers.first)
        XCTAssertEqual(answer.status, .refused)
        XCTAssertTrue(answer.reason?.contains("page") == true)
        XCTAssertTrue(capturer.asked.isEmpty)
    }
}
