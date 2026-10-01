import WebKit
import XCTest

@testable import Helm

@MainActor
final class CanvasNoteHoverTests: XCTestCase {
    func testHeadingRoundTripsBothWaysForEveryCurrentMarkKind() {
        let marks: [CanvasAnnotation.Mark] = [
            .selection(.element(id: "phase-2", text: "Ship `it` — \"today\"")),
            .selection(.quote("Quote with \"words\" and `ticks`")),
            .selection(.quote("first line\nsecond line\twith \\literal")),
            .selection(.element(id: "lines", text: "first\nsecond")),
        ]
        for mark in marks {
            let heading = CanvasNotes.describe(mark)
            XCTAssertEqual(CanvasNotes.mark(in: heading), mark)
            XCTAssertEqual(CanvasNotes.mark(in: heading).map(CanvasNotes.describe), heading)
        }
        for heading in ["`#ship` — \"Ship today\"", "\"Ship today\"", "text \"first\\nsecond\""] {
            XCTAssertEqual(CanvasNotes.mark(in: heading).map(CanvasNotes.describe), heading)
        }
        XCTAssertNil(CanvasNotes.mark(in: "circled `#phase2` — \"Ship\""))
        XCTAssertNil(CanvasNotes.mark(in: "\"\""))
        XCTAssertNil(CanvasNotes.mark(in: "`#bad id` — \"Ship\""))
        XCTAssertNil(CanvasNotes.mark(in: "`#phase2` — \"Ship"))
    }

    func testLegacyNoteAndPreambleOnlyOfferNeutralFeedbackOnHover() {
        let hover = CanvasNoteHover()
        let legacy = CanvasNotes.Note(id: 0, heading: "circled old", text: "old note")
        let preamble = CanvasNotes.Note(id: 1, heading: "", text: "introductory prose")
        XCTAssertTrue(hover.status.isEmpty)
        hover.hover(legacy, entered: true)
        XCTAssertEqual(hover.status[0], "This note cannot be highlighted.")
        hover.hover(preamble, entered: true)
        XCTAssertNil(hover.status[1], "A preamble does not claim to name a target")
    }

    func testMissingPageIsUnavailableRatherThanMissingAnchor() {
        let hover = CanvasNoteHover()
        let note = CanvasNotes.Note(id: 0, heading: "\"valid words\"", text: "note")
        hover.hover(note, entered: true)
        XCTAssertEqual(hover.status[0], "The canvas cannot highlight this note right now.")
    }

    func testEntriesKeepEveryByteOfTheSidecarAndLegacyProse() {
        let text =
            "## \"first\"\n\nA comment\n\n<sub>2026-10-01</sub>\n\n## circled old\n\nLegacy comment\n"
        let entries = CanvasNotes.entries(in: text)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.text).joined(separator: "\n"), text)
        XCTAssertNotNil(entries[0].mark)
        XCTAssertNil(entries[1].mark)
    }

    func testAuthoredIDIsVerifiedAndMismatchFallsThroughToUniqueQuote() async throws {
        let page = try await Page("<p id='ship'>Wrong now</p><p id='other'>Ship today</p>")
        defer { page.close() }
        check(try await page.hover(id: "ship", text: "Ship today"), "found")
        check(
            try await page.ask("CSS.highlights.get('helm-note').values().next().value.toString()"),
            "Ship today")
        check(try await page.hover(id: "ship", text: "Gone"), "not-found")
        check(try await page.ask("String(CSS.highlights.has('helm-note'))"), "false")
    }

    func testQuoteAcrossInlineMarkupAndAmbiguousQuoteRefused() async throws {
        let page = try await Page(
            "<p>Hello <strong>brave</strong> world</p><p>Duplicate</p><p>Duplicate</p><p>Repeated Repeated</p><p>Repeated</p>"
        )
        defer { page.close() }
        check(try await page.hover(text: "Hello brave world"), "found")
        check(
            try await page.ask("CSS.highlights.get('helm-note').values().next().value.toString()"),
            "Hello brave world")
        check(try await page.hover(text: "Duplicate"), "not-found")
        check(try await page.hover(text: "Repeated"), "not-found")
    }

    func testMermaidFamiliesDashesMovedCountersAndTwoDiagrams() async throws {
        for family in ["flowchart", "classId", "state", "entity"] {
            let page = try await Page(
                """
                <div class='mermaid'><svg><g id='mermaid-8-\(family)-phase-2-99'><text>Ship today</text></g></svg></div>
                <div class='mermaid'><svg><g id='mermaid-9-\(family)-phase-2-1'><text>Different label</text></g></svg></div>
                """)
            defer { page.close() }
            check(try await page.hover(id: "phase-2", text: "Ship today"), "found", family)
            check(try await page.hover(id: "phase-2", text: "Old label"), "not-found", family)
        }
    }

    func testUnsupportedDiagramsAndOwnedSurfacesCannotBeRecoveredByText() async throws {
        for role in ["mindmap", "sequenceDiagram", "gitGraph", "pie"] {
            let page = try await Page(
                "<div class='mermaid'><svg aria-roledescription='\(role)'><g id='actor0'><text>Ship today</text></g></svg></div>"
            )
            defer { page.close() }
            check(try await page.hover(id: "actor0", text: "Ship today"), "not-found")
            check(try await page.hover(text: "Ship today"), "not-found")
        }
        let page = try await Page("<div data-helm-surface><p id='game'>Ship today</p></div>")
        defer { page.close() }
        check(try await page.hover(id: "game", text: "Ship today"), "not-found")
    }

    func testCaptureAndLookupAgreeAndHoverDoesNotWipeSelection() async throws {
        let page = try await Page("<p id='ship'>Ship <b>today</b></p>")
        defer { page.close() }
        _ = try await page.ask(
            """
            window.__helmMarkTool = 'text';
            var range = document.createRange(); range.selectNodeContents(document.querySelector('b'));
            document.getSelection().addRange(range);
            document.querySelector('b').dispatchEvent(new MouseEvent('mouseup', {bubbles:true})); 'ok';
            """)
        let posted = try XCTUnwrap(page.posted)
        XCTAssertEqual(posted["id"] as? String, "ship")
        check(
            try await page.hover(
                id: posted["id"] as? String, text: try XCTUnwrap(posted["text"] as? String)),
            "found")
        _ = try await page.ask("window.__helmClearNote(); 'ok'")
        check(try await page.ask("String(CSS.highlights.has('helm-mark'))"), "true")
        check(try await page.ask("String(CSS.highlights.has('helm-note'))"), "false")
    }

    func testHiddenTextIsNotAVisibleAnchor() async throws {
        let page = try await Page(
            "<p id='hidden' style='display:none'>Ship today</p><div id='parent'><span hidden>Ship today</span>Different</div>"
        )
        defer { page.close() }
        check(try await page.hover(id: "hidden", text: "Ship today"), "not-found")
        check(try await page.hover(id: "parent", text: "Ship today"), "not-found")
    }

    func testHoverBridgeReportsMissingAndClearsPreviousHighlight() async throws {
        let page = try await Page("<p id='ship'>Ship today</p>")
        defer { page.close() }
        let hover = CanvasNoteHover()
        hover.webView = page.webView
        let found = CanvasNotes.Note(id: 0, heading: "`#ship` — \"Ship today\"", text: "a note")
        hover.hover(found, entered: true)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if (try await page.ask("String(CSS.highlights.has('helm-note'))")) == "true" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        check(try await page.ask("String(CSS.highlights.has('helm-note'))"), "true")
        let missing = CanvasNotes.Note(id: 1, heading: "legacy geometry", text: "old note")
        hover.hover(missing, entered: true)
        XCTAssertEqual(hover.status[1], "This note cannot be highlighted.")
        check(try await page.ask("String(CSS.highlights.has('helm-note'))"), "false")
        hover.clear()
    }

    func testOffscreenMatchScrollsIntoView() async throws {
        let page = try await Page("<div style='height:2000px'></div><p id='ship'>Ship today</p>")
        defer { page.close() }
        check(try await page.hover(id: "ship", text: "Ship today"), "found")
        check(
            try await page.ask(
                "String(document.getElementById('ship').getBoundingClientRect().top < innerHeight)"),
            "true")
    }

    private func check(
        _ actual: String, _ expected: String, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual, expected, message, file: file, line: line)
    }

    private final class Page: NSObject, WKScriptMessageHandler {
        let webView: WKWebView
        var posted: [String: Any]?

        init(_ html: String) async throws {
            let configuration = WKWebViewConfiguration()
            configuration.userContentController.addUserScript(
                WKUserScript(
                    source: CanvasHTML.annotationScript()
                        + CanvasHTML.setMarkTool(.read, theme: .light),
                    injectionTime: .atDocumentEnd, forMainFrameOnly: true,
                    in: CanvasFileCoordinator.bridgeWorld))
            webView = WKWebView(
                frame: CGRect(x: 0, y: 0, width: 800, height: 500), configuration: configuration)
            super.init()
            webView.configuration.userContentController.add(
                self, contentWorld: CanvasFileCoordinator.bridgeWorld, name: "helmCanvas")
            webView.loadHTMLString(html, baseURL: nil)
            let deadline = Date().addingTimeInterval(10)
            var observed = ""
            while Date() < deadline {
                observed = (try? await ask("typeof window.__helmHoverNote")) ?? "evaluation failed"
                if observed == "function" { return }
                // Lets a polling interval elapse; there is no sleep-inside-a-deadline assertion.
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("Annotation script did not load: \(observed)")
            close()
            throw NSError(domain: "CanvasNoteHoverTests", code: 1)
        }

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            posted = message.body as? [String: Any]
        }

        func ask(_ script: String) async throws -> String {
            try await withCheckedThrowingContinuation { continuation in
                webView.evaluateJavaScript(script, in: nil, in: CanvasFileCoordinator.bridgeWorld) {
                    result in
                    continuation.resume(
                        with: result.map { ($0 as? String) ?? String(describing: $0) })
                }
            }
        }

        func hover(id: String? = nil, text: String) async throws -> String {
            var anchor = ["anchorKind": id == nil ? "quote" : "element", "text": text]
            anchor["id"] = id
            return try await withCheckedThrowingContinuation { continuation in
                webView.callAsyncJavaScript(
                    "return window.__helmHoverNote(anchor);", arguments: ["anchor": anchor],
                    in: nil, in: CanvasFileCoordinator.bridgeWorld
                ) { result in
                    continuation.resume(
                        with: result.map { ($0 as? String) ?? String(describing: $0) })
                }
            }
        }

        func close() {
            webView.stopLoading()
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: "helmCanvas", contentWorld: CanvasFileCoordinator.bridgeWorld)
        }
    }
}
