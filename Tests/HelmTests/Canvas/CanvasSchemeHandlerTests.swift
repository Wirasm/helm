import WebKit
import XCTest

@testable import Helm

/// What a canvas page can tell about what it just fetched.
///
/// **These assert the status, not the bytes.** The bytes were always right — a successful
/// sibling fetch returned the correct file while reporting `res.ok === false` and
/// `res.status === 0`, which is exactly why #201 survived until someone wrote a page with
/// real error handling. A test that only checked the payload would still pass with the bug
/// reinstated.
///
/// No live WebKit: `serve` takes the task rather than the webview, and `SchemeTask` below is a
/// `WKURLSchemeTask` double that records what the handler handed it. What is asserted is the
/// real response object WebKit would receive, so "someone built a `URLResponse` again" fails
/// here rather than in a canvas six months later.
@MainActor
final class CanvasSchemeHandlerTests: XCTestCase {
    /// The artifact's own bytes: written to disk in `setUp`, handed back by the default
    /// document closure, and asserted on. One name so the three cannot drift apart.
    private static let documentHTML = "<h1>plan</h1>"

    private var root: URL!
    private var directory: URL!
    private var artifact: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("helm-scheme-\(UUID().uuidString)")
        directory = root.appendingPathComponent("artifacts")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        artifact = directory.appendingPathComponent("plan.html")
        try Self.documentHTML.write(to: artifact, atomically: true, encoding: .utf8)
        try #"{"scene":"ok"}"#.write(
            to: directory.appendingPathComponent("scene.json"), atomically: true, encoding: .utf8)
        try "secret".write(
            to: root.appendingPathComponent("outside.txt"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Harness

    /// Records what the handler answered. `WKURLSchemeTask` is a plain protocol, so a live
    /// `WKWebView` — and the WebKit processes behind it — buys nothing here.
    private final class SchemeTask: NSObject, WKURLSchemeTask {
        let request: URLRequest
        private(set) var response: URLResponse?
        private(set) var body = Data()
        private(set) var error: (any Error)?
        private(set) var finished = false

        init(_ url: URL) {
            request = URLRequest(url: url)
            super.init()
        }

        func didReceive(_ response: URLResponse) { self.response = response }
        func didReceive(_ data: Data) { body.append(data) }
        func didFinish() { finished = true }
        func didFailWithError(_ error: any Error) { self.error = error }

        /// nil when the response is not an `HTTPURLResponse` — which is the bug, so the
        /// assertions say `404` rather than `not nil`.
        var status: Int? { (response as? HTTPURLResponse)?.statusCode }
        var contentType: String? {
            (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
        }
        var contentSecurityPolicy: String? {
            (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Security-Policy")
        }
    }

    private func handler(document: @escaping @MainActor () -> Data?) -> CanvasSchemeHandler {
        CanvasSchemeHandler(artifact: artifact, document: document)
    }

    /// Requests `path` on the canvas's own origin and returns what the handler answered.
    @discardableResult
    private func request(
        _ path: String,
        // Spelled out rather than `Self.` — a default argument cannot name a covariant
        // `Self`, even in a final class.
        document: @escaping @MainActor () -> Data? = {
            Data(CanvasSchemeHandlerTests.documentHTML.utf8)
        }
    ) throws -> SchemeTask {
        var components = URLComponents()
        components.scheme = CanvasAddress.scheme
        components.host = CanvasAddress.host(for: StandardizedPath(artifact))
        components.path = path
        let task = SchemeTask(try XCTUnwrap(components.url))
        handler(document: document).serve(task)
        return task
    }

    // MARK: - A sibling that exists

    func testASuccessfulSiblingFetchCarriesA200() throws {
        let task = try request("/scene.json")

        XCTAssertEqual(
            task.status, 200,
            "a bare URLResponse reports status 0, so `res.ok` is false for a fetch that worked")
        XCTAssertEqual(String(data: task.body, encoding: .utf8), #"{"scene":"ok"}"#)
        XCTAssertNil(task.error)
        XCTAssertTrue(task.finished)
    }

    func testASuccessfulFetchCanReadItsOwnContentType() throws {
        // `URLResponse` carries a MIME type but no header fields, so this was `null` on the
        // same successful fetch — the page could not tell what it had been handed either.
        let task = try request("/scene.json")

        XCTAssertEqual(task.contentType, "application/json; charset=utf-8")
    }

    func testABinarySiblingKeepsItsOwnType() throws {
        // The charset rides along on a binary type, exactly as the old unconditional
        // `textEncodingName: "utf-8"` did. Measured in a live WKWebView rather than reasoned
        // about: a real PNG served this way decodes into an `<img>` at its true dimensions,
        // because only the essence before the `;` decides how WebKit handles it.
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: directory.appendingPathComponent("x.png"))

        let task = try request("/x.png")

        XCTAssertEqual(task.status, 200)
        XCTAssertEqual(task.contentType, "image/png; charset=utf-8")
    }

    func testTheDocumentItselfCarriesA200() throws {
        let task = try request("/plan.html")

        XCTAssertEqual(task.status, 200)
        XCTAssertEqual(task.contentType, "text/html; charset=utf-8")
        XCTAssertEqual(String(data: task.body, encoding: .utf8), Self.documentHTML)
    }

    // MARK: - A sibling that does not

    func testAMissingSiblingIs404() throws {
        let task = try request("/missing.json")

        XCTAssertEqual(task.status, 404)
        XCTAssertNil(task.error, "a status is the answer, not a transport failure")
        XCTAssertTrue(task.finished)
        // Nothing to render and nothing to execute. Measured: WebKit honours the status for
        // subresources over a custom scheme, so an error body would never run anyway — but
        // shipping one to be ignored is a promise nobody should have to check.
        XCTAssertTrue(task.body.isEmpty)
    }

    // MARK: - A path the boundary refuses

    func testASymlinkOutOfTheDirectoryIs403() throws {
        // The refusal `CanvasFileBoundary` actually exists for. Distinct from 404 on purpose:
        // "helm will not serve this" is not "this is not there".
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("escape.txt"),
            withDestinationURL: root.appendingPathComponent("outside.txt"))

        let task = try request("/escape.txt")

        XCTAssertEqual(task.status, 403)
        XCTAssertTrue(task.body.isEmpty)
        XCTAssertNil(task.error)
    }

    func testATraversalNeverReachesTheBoundaryAndArrivesAsAMissingFile() throws {
        // Measured in a live WKWebView: `fetch('../../../etc/hosts')` from a canvas page
        // arrives here as the path `/etc/hosts`, because WebKit collapses `..` in the URL
        // before the handler is ever asked. That resolves *inside* the artifact directory —
        // `<artifact-dir>/etc/hosts` — and is simply not there, so what the page gets for the
        // traversal it wrote is a 404.
        //
        // Pinned because it is the case #201 named, and the answer is not the one the ticket
        // assumed. The traversal is still refused; it is refused a step earlier, by the URL,
        // and `/etc/hosts` is not served.
        let task = try request("/etc/hosts")

        XCTAssertEqual(task.status, 404)
        XCTAssertTrue(task.body.isEmpty)
    }

    func testALiteralTraversalWouldStillBeRefusedByTheBoundary() throws {
        // Belt to that brace: if a `..` ever did reach the handler — a client that is not
        // WebKit, or a WebKit that stops normalizing — the boundary refuses it.
        let task = try request("/../outside.txt")

        XCTAssertEqual(task.status, 403)
        XCTAssertTrue(task.body.isEmpty)
    }

    // MARK: - What the page is allowed to reach

    /// The policy is stamped by two separate `HTTPURLResponse` builders, and a canvas that
    /// got it on its document but not on a sibling — or the other way round — would be a
    /// policy with a hole in it. Asserted over all four response kinds for that reason.
    ///
    /// **Against the constant, never a copy of the header** — for the reason
    /// `contentSecurityPolicy`'s own doc comment gives for why it is not `private`.
    func testEveryResponseCarriesThePolicy() throws {
        let expected = CanvasSchemeHandler.contentSecurityPolicy

        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("escape.txt"),
            withDestinationURL: root.appendingPathComponent("outside.txt"))

        for path in ["/plan.html", "/scene.json", "/missing.json", "/escape.txt"] {
            let task = try request(path)

            XCTAssertEqual(
                task.contentSecurityPolicy, expected,
                "\(path) came back without the policy, so a canvas reaching it is unpoliced")
        }
    }

    /// What the policy has to *mean*, spelled as the properties #209 is about rather than as
    /// the header again — so widening `connect-src` to a CDN fails here with a sentence
    /// saying why, instead of as a string mismatch a reader has to diff.
    ///
    /// Why the strict policy was rejected, and why `'unsafe-inline'` is not the risk it
    /// reads as, are argued in full on `contentSecurityPolicy` itself. This only re-checks
    /// that the shape those measurements bought is still the shape helm ships.
    func testThePolicyForbidsTheNetworkWithoutKillingTheArtifactsThatExist() {
        let policy = CanvasSchemeHandler.contentSecurityPolicy

        XCTAssertTrue(
            policy.contains("connect-src 'self'"),
            "the measured hole: the board map completed a fetch to https://example.com")
        XCTAssertTrue(
            policy.contains("default-src 'none'"),
            "everything not named below has to fall to nothing, or the policy has a default")
        for remote in ["http:", "https:", "ws:", "wss:", "*"] {
            XCTAssertFalse(
                policy.contains(remote),
                "\(remote) in the policy is a remote origin a canvas may reach")
        }
        XCTAssertTrue(
            policy.contains("script-src 'self' 'unsafe-inline'"),
            "strict script-src kills the inline <script> every artifact in the store has")
        XCTAssertTrue(
            policy.contains("style-src 'self' 'unsafe-inline'"),
            "strict style-src kills inline <style>, and mermaid builds <style> at runtime")
        XCTAssertTrue(
            policy.contains("img-src 'self' data:"),
            "mermaid's own bundle ships data: images")
        XCTAssertTrue(
            policy.contains("font-src 'self' data:"),
            "a data: @font-face is how an artifact carries a font without a sibling file")
    }

    // MARK: - The canvas that cannot be served at all

    func testAnUnproducibleDocumentStillFailsTheNavigation() throws {
        // Deliberately *not* a status. This is the main-frame navigation, not a page's fetch:
        // there is no page yet to branch on a 404, and failing the navigation lets WebKit say
        // so rather than rendering a blank body of helm's invention.
        let task = try request("/plan.html", document: { nil })

        XCTAssertEqual((task.error as? URLError)?.code, .cannotOpenFile)
        XCTAssertNil(task.response)
        XCTAssertFalse(task.finished)
    }
}
