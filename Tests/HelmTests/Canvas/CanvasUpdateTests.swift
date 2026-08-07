import XCTest

@testable import Helm

/// The update channel's two values, and the model's half of the decision (#109).
///
/// **The join is `CanvasLiveUpdateTests`, and it is the one that matters.** What is here is the
/// part a live `WKWebView` cannot pin down cheaply: every answer this build understands, every
/// answer it does not, and what the pane does about each. #216's lesson is that both sides
/// passing on their own says nothing about the join — so these do not stand alone, and the file
/// beside them is the reason they are allowed to be this cheap.
final class CanvasUpdateTests: XCTestCase {

    // MARK: - The offer

    /// The page is handed real data, not a nudge — that is the whole difference between this and
    /// a reload, and the fields are what a handler branches on.
    func testTheOfferCarriesTheKindTheVersionAndWhatChanged() throws {
        let update = CanvasUpdate(
            artifact: URL(fileURLWithPath: "/Users/rasmus/plans/game.html"), generation: 7)

        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(update))
                as? [String: Any])

        XCTAssertEqual(payload["kind"] as? String, "canvas.update")
        XCTAssertEqual(payload["version"] as? Int, 1)
        XCTAssertEqual(payload["generation"] as? Int, 7)
        XCTAssertEqual(
            payload["artifact"] as? String, "game.html",
            "the file name, never the path — the page fetches siblings by relative URL, so the "
                + "path buys it nothing and puts the operator's home directory in its console")
    }

    /// A canvas can be opened from anywhere, including a directory whose name contains a quote.
    /// The payload crosses as a JSON *string* parsed in the page for exactly this reason.
    func testAnArtifactNameCannotEndTheScriptItTravelsIn() {
        let script = CanvasUpdate(
            artifact: URL(fileURLWithPath: #"/tmp/a"</script><script>evil()///x.html"#),
            generation: 1
        ).offerScript()

        XCTAssertFalse(script.contains("</script>"), "a filename must not close a script tag")
        XCTAssertFalse(
            script.contains(#""</script>"#),
            "nor appear unescaped anywhere the page would parse it as source")
        XCTAssertTrue(
            script.contains("JSON.parse("),
            "the payload is parsed as data in the page, never spliced in as an object literal")
    }

    /// The one name an artifact author has to know. If it drifts, every page that registered a
    /// handler silently goes back to being reloaded — which is the failure with no symptom.
    func testTheOfferAsksForTheGlobalTheContractDocuments() {
        let script = CanvasUpdate(artifact: URL(fileURLWithPath: "/tmp/x.html"), generation: 1)
            .offerScript()

        XCTAssertEqual(CanvasUpdate.handlerGlobal, "helmCanvasUpdate")
        XCTAssertTrue(script.contains("window.helmCanvasUpdate"))
    }

    // MARK: - The answer

    func testEveryAnswerThisBuildUnderstands() {
        func answer(_ verdict: String, detail: String? = nil) -> CanvasUpdateAnswer {
            var body: [String: Any] = ["kind": "canvas.update-answer", "answer": verdict]
            if let detail { body["detail"] = detail }
            return CanvasUpdateAnswer.decode(body)
        }

        XCTAssertEqual(answer("applied"), .applied)
        XCTAssertEqual(answer("declined"), .declined)
        XCTAssertEqual(answer("unhandled"), .unhandled)
        XCTAssertEqual(answer("failed", detail: "state is not JSON"), .failed("state is not JSON"))
        XCTAssertEqual(
            answer("failed"), .failed("no reason given"),
            "a throw with nothing readable on it is still a throw, and still keeps the page")
    }

    /// **The refusing half of the discriminator, on this channel** (#109). An answer helm cannot
    /// read is its own case — never rounded down to one it can, because every other case decides
    /// whether the operator keeps their page.
    func testAnAnswerThisBuildCannotReadIsRefusedRatherThanGuessedAt() {
        guard case .unreadable = CanvasUpdateAnswer.decode(["answer": "applied"]) else {
            return XCTFail(
                "an envelope with no `kind` is not this channel's answer — the wrapper always "
                    + "writes one, so a body without it came from somewhere else")
        }
        guard
            case .unreadable = CanvasUpdateAnswer.decode([
                "kind": "canvas.update-answer", "answer": "deferred",
            ])
        else {
            return XCTFail(
                "an `answer` this build does not know is drift between the wrapper and the "
                    + "decoder — reportable, not roundable")
        }
        guard case .unreadable = CanvasUpdateAnswer.decode(nil) else {
            return XCTFail("no answer at all is not an answer")
        }
        guard case .unreadable = CanvasUpdateAnswer.decode("applied") else {
            return XCTFail("a bare string is not the envelope")
        }
    }

    /// **The sentence the whole feature reduces to.** A page that took the offer, declined it, or
    /// broke on it is never reloaded by helm; a page with nothing to take it is, exactly as
    /// before this existed.
    func testOnlyAPageWithNoHandlerIsReloaded() {
        XCTAssertFalse(CanvasUpdateAnswer.applied.reloads)
        XCTAssertFalse(CanvasUpdateAnswer.declined.reloads, "the operator's game is not helm's")
        XCTAssertFalse(
            CanvasUpdateAnswer.failed("boom").reloads,
            "a broken update handler is still a page holding state — reloading it to tidy up "
                + "destroys exactly what the handler existed to protect")
        XCTAssertTrue(CanvasUpdateAnswer.unhandled.reloads)
        XCTAssertTrue(
            CanvasUpdateAnswer.unreadable("evaluation failed").reloads,
            "with no handler in evidence there is no state claimed, and reloading is the "
                + "behaviour that predates this channel")
    }

    /// What the operator is told, and — the half worth pinning — what they are *not*.
    func testTheStripAppearsOnlyWhenThereIsADecisionToMake() {
        XCTAssertNil(CanvasUpdateAnswer.applied.notice, "the page took it; there is nothing to say")
        XCTAssertNil(
            CanvasUpdateAnswer.unhandled.notice,
            "helm is reloading, and the reload IS the message — a strip over it would be a "
                + "button offering to do what already happened")
        XCTAssertNil(CanvasUpdateAnswer.unreadable("x").notice)
        XCTAssertNotNil(CanvasUpdateAnswer.declined.notice)
        XCTAssertTrue(
            try XCTUnwrap(CanvasUpdateAnswer.failed("state is not JSON").notice)
                .contains("state is not JSON"),
            "the page's own reason, or the operator is told only that something went wrong")
    }

    // MARK: - The pane

    @MainActor
    func testTheStripGoesUpOnADeclineAndComesDownWhenThePageTakesTheNextOne() {
        let model = CanvasModel()

        model.pageAnsweredUpdate(.declined)
        XCTAssertNotNil(model.updateNotice)

        model.pageAnsweredUpdate(.applied)
        XCTAssertNil(
            model.updateNotice,
            "a stale \"reload?\" over a page that has since taken an update is a button that "
                + "would throw away state for no reason at all")
    }

    @MainActor
    func testReloadIsACounterSoPressingItTwiceReloadsTwice() {
        let model = CanvasModel()
        model.pageAnsweredUpdate(.declined)

        model.reloadArtifact()
        XCTAssertEqual(model.reloadDemand, 1)
        XCTAssertNil(model.updateNotice, "the question has been answered")

        model.reloadArtifact()
        XCTAssertEqual(
            model.reloadDemand, 2,
            "a flag would be consumed once and the second press would do nothing — and the "
                + "second press is the ordinary case, because the first one is what the operator "
                + "does when they are not sure it worked")
    }

    @MainActor
    func testOpeningAnotherArtifactTakesTheStripWithIt() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-canvas-update-\(UUID().uuidString).md")
        try "# plan".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let model = CanvasModel()
        model.pageAnsweredUpdate(.declined)

        model.open(file)

        XCTAssertNil(
            model.updateNotice,
            "\"this page is holding its state\" is about the page that was here; carried onto "
                + "another artifact it is a true sentence about the wrong document")
    }
}
