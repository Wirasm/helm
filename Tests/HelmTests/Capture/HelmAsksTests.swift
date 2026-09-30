import Foundation
import HelmWire
import XCTest

@testable import Helm

/// benchd asking helm to draw itself (M3): each ask gets exactly one answer, carrying the
/// capturer's report or its reason, and an ask this build does not know is refused by name
/// rather than left to time out on the agent's side.
@MainActor
final class HelmAsksTests: XCTestCase {
    private final class Capturer: WindowCapturing {
        var asked: [String?] = []
        var refusal: String?
        var png = Data("\u{89}PNG".utf8)

        func capture(window: String?) -> Result<CaptureReport, CaptureRefusal> {
            asked.append(window)
            if let refusal { return .failure(CaptureRefusal(refusal)) }
            return .success(
                CaptureReport(
                    png: png, pixelWidth: 200, pixelHeight: 100, scale: 2, window: "helm — m3",
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

    /// The answer carries the PNG itself (M5c): benchd writes the file on its own machine, which
    /// helm may not share.
    func testACaptureIsAnsweredWithThePNG() throws {
        let capturer = Capturer()
        let (asks, sent) = asks(capturer)
        asks.answer(HelmAsked(ask: "a7", request: .capture(window: "m3")))

        XCTAssertEqual(capturer.asked, ["m3"])
        let answer = try XCTUnwrap(sent.answers.first)
        XCTAssertEqual(sent.answers.count, 1)
        XCTAssertEqual(answer.ask, "a7")
        XCTAssertEqual(answer.status, .ok)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(answer)) as? [String: Any])
        let data = try XCTUnwrap((json["args"] as? [String: Any])?["data"] as? [String: Any])
        XCTAssertEqual(data["png"] as? String, capturer.png.base64EncodedString())
        XCTAssertNil(data["path"], "helm names no path; benchd picks it")
    }

    /// A PNG benchd would refuse to read is refused here, with its size, instead of leaving the
    /// agent to wait out the ask.
    func testACaptureTooLargeToSendIsAnErrorNamingItsSize() throws {
        let capturer = Capturer()
        capturer.png = Data(count: benchLargeRequestMaxBytes)
        let (asks, sent) = asks(capturer)
        asks.answer(HelmAsked(ask: "a10", request: .capture(window: nil)))

        let answer = try XCTUnwrap(sent.answers.first)
        XCTAssertEqual(answer.status, .error)
        XCTAssertNil(answer.data)
        XCTAssertTrue(answer.reason?.contains("16 MB PNG") == true, answer.reason ?? "")
    }

    func testACaptureThatCannotDrawSaysWhy() throws {
        let capturer = Capturer()
        capturer.refusal = "two windows match \"helm\""
        let (asks, sent) = asks(capturer)
        asks.answer(HelmAsked(ask: "a8", request: .capture(window: nil)))

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
