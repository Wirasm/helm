import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves one artifact on its own `helm-canvas://<host>/` origin.
///
/// This exists to give the page an identity (`CanvasAddress`), not to add a capability:
/// what it serves is exactly what helm served before — a generated document page for a
/// markdown artifact, the file's own bytes for an `.html` one, and sibling files for the
/// relative references an `.html` artifact makes.
///
/// **The artifact's directory is the read boundary**, the same one
/// `loadFileURL(_:allowingReadAccessTo:)` enforced before. Deciding what is inside it is
/// `CanvasFileBoundary`'s job rather than this type's, so it can be tested without a live
/// `WKURLSchemeTask`.
///
/// **What a page sees when it asks for a file is a status** — 200 for bytes, 404 for a
/// sibling that is not there, 403 for one the boundary refuses — so `res.ok` and
/// `res.status` mean what a canvas author expects them to mean, and the three outcomes are
/// three outcomes. `respond` and `refuse` carry why that was not free (#201).
///
/// **It is also where a canvas's reach is decided.** Every response carries the
/// `Content-Security-Policy` below, which is what stops an artifact an agent wrote from
/// talking to the internet in the operator's window (#209).
///
/// **One path deliberately still fails instead: the document the closure cannot produce.**
/// That is normally the main-frame navigation, and failing it leaves the last good render
/// on screen where a 404 would blank the pane — which matters, because the way it happens
/// in practice is an agent deleting or rewriting the artifact under a canvas that is
/// already up. A `WKURLSchemeTask` carries no `isMainFrame`, so this handler *cannot* tell
/// that navigation from a page fetching its own address; a page that does the latter at
/// the moment the artifact is unreadable gets the bare `TypeError` this ticket otherwise
/// removed. Known, narrow, and worth the trade — but not a claim of completeness.
///
/// One handler per webview, holding one artifact. It never sees another canvas's path, so
/// "could canvas A read canvas B?" is not a policy question here — there is nothing to ask
/// with.
///
/// Deliberately **not** `@MainActor`. WebKit calls a scheme handler on the main thread —
/// the same fact `CanvasFileCoordinator` leans on for script messages — but a
/// `WKURLSchemeTask` is not `Sendable`, so hopping the task into a `MainActor` closure is
/// a data-race diagnostic rather than a safety win. The task therefore never leaves this
/// method, and the one genuinely main-actor thing (the staged document) is fetched as
/// plain `Data` across the boundary.
final class CanvasSchemeHandler: NSObject, WKURLSchemeHandler {
    /// Every artifact this handler serves as *the document* is HTML — either the page helm
    /// generates from markdown, or an `.html` artifact itself. Siblings are typed from
    /// their own extension, so this is not a per-instance value.
    private static let documentMIMEType = "text/html"

    /// HTTP's status codes, because `Response.ok` is defined in terms of them and a canvas
    /// author already knows what they mean.
    private static let ok = 200
    private static let forbidden = 403
    private static let notFound = 404
    /// Stamped on every `HTTPURLResponse` this type builds. Nothing speaks HTTP here — it
    /// is the string the initializer wants in order to hand WebKit a status.
    private static let httpVersion = "HTTP/1.1"

    /// **A canvas may not reach the internet.** Measured before this existed: the operator's
    /// own board map, rendered unmodified, completed a `fetch` to `https://example.com`. helm
    /// renders a pushed canvas with no click, so without this "an agent wrote a file" means
    /// "an agent is running JavaScript with network reach in the operator's window", and it
    /// keeps running after the agent is gone. That gap is the whole of #209.
    ///
    /// **`'unsafe-inline'` is deliberate, and it is not the risk here.** The strict policy —
    /// `script-src 'self'; style-src 'self'` — is what a *new* artifact can be written
    /// against, and it kills every artifact in the store today, all of which carry an inline
    /// `<style>` and an inline `<script>`. Measured twice against a copy of the real board
    /// map, and **the way it dies is worth knowing before anyone re-opens this**: the page
    /// keeps every one of its 591 DOM nodes and comes back unstyled and inert — computed
    /// font `-webkit-standard` on a transparent body, inline script never run, five
    /// violations (`style-src-elem`, `style-src-attr` ×2, `script-src-elem` ×2). A node
    /// count alone reports that as unchanged. With no host in the allowlist, `'unsafe-inline'` still
    /// forbids **remote** script, and `connect-src 'self'` still forbids remote `fetch`, XHR
    /// and WebSocket. That is the entire trust argument, bought at no cost to what exists.
    /// Tightening to the strict form is a decision about the artifacts in the store, not
    /// about this line.
    ///
    /// `style-src 'unsafe-inline'` is also what keeps mermaid alive: it builds `<style>`
    /// elements at runtime, and #200 measured the analogous htmx case failing under
    /// `style-src 'self'` as `CSP blocked style-src-elem: inline`. `img-src`/`font-src`
    /// carry `data:` because mermaid's own bundle ships `data:` images.
    ///
    /// **A header rather than a `<meta>` tag**, because a meta tag is author-supplied — a
    /// convention an agent can forget, and the agent is the party the policy is about. It
    /// could not live here until #203 traded the bare `URLResponse`, which carries no
    /// headers, for an `HTTPURLResponse`.
    ///
    /// **One value, and not `private`, because a CSP is a seam and both sides have to reach
    /// the same string.** The near side is the two response builders below — a literal
    /// repeated at each is two policies the day someone edits one. The far side is the test,
    /// which asserts *against this constant* rather than re-spelling the header: a test
    /// holding its own copy stays green while the copies drift, which is the failure the
    /// architecture rule names. What the constant cannot reach is the far-far side — the
    /// `helm-canvas` skill, where an agent reads what a canvas may do. Markdown cannot
    /// compile against a Swift `let`, so that half stays a duplicate; it is named in #209's
    /// PR rather than restated here.
    static let contentSecurityPolicy = """
        default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; \
        img-src 'self' data:; font-src 'self' data:; connect-src 'self'; \
        base-uri 'none'; form-action 'none'
        """

    /// The artifact's own directory — nothing outside it is served.
    private let directory: URL
    /// The artifact's file name, which is the one path that maps to `document`.
    private let documentName: String
    /// The main document's current bytes. A closure because a markdown canvas's page is
    /// generated per theme and per file change, and the handler must serve what the view
    /// would have loaded rather than a stale snapshot.
    private let document: @MainActor () -> Data?

    init(artifact: URL, document: @escaping @MainActor () -> Data?) {
        self.directory = artifact.deletingLastPathComponent()
        self.documentName = artifact.lastPathComponent
        self.document = document
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) { serve(task) }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    /// The whole of `start`, minus the `WKWebView` it never looks at — so a test can hand it
    /// a task double instead of standing up a live WebKit process to ask what status a
    /// sibling comes back with.
    ///
    /// Everything here completes synchronously — the bytes are already in memory or on
    /// local disk — so a task can never be stopped between `start` and its completion, and
    /// there is no live-task bookkeeping to get wrong.
    func serve(_ task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return fail(task, .badURL) }

        // The artifact itself.
        if url.path == "/" + documentName || url.path == "/" {
            guard let data = MainActor.assumeIsolated({ document() }) else {
                return fail(task, .cannotOpenFile)
            }
            return respond(task, url: url, data: data, mimeType: Self.documentMIMEType)
        }

        // A sibling it referenced.
        guard let file = CanvasFileBoundary.resolve(request: url.path, inDirectory: directory)
        else { return refuse(task, url: url, status: Self.forbidden) }
        guard let data = try? Data(contentsOf: file) else {
            return refuse(task, url: url, status: Self.notFound)
        }
        respond(
            task, url: url, data: data,
            mimeType: Self.mimeType(for: (url.path as NSString).lastPathComponent))
    }

    /// Bytes, and the status that says they are bytes.
    ///
    /// **`HTTPURLResponse` rather than `URLResponse`, and that is the whole of #201.** A
    /// plain `URLResponse` carries no status code, WebKit reports `status: 0` to page
    /// JavaScript, and `Response.ok` — defined as 200–299 — is therefore `false` for every
    /// sibling that loaded perfectly. Measured, before and after: the bytes were always
    /// right, which is why it survived. It carries no header fields either, so
    /// `res.headers.get('content-type')` was `null` on the same successful fetch.
    ///
    /// The charset on `Content-Type` is where `textEncodingName: "utf-8"` went —
    /// `HTTPURLResponse` derives the encoding from the header rather than taking it
    /// separately, and dropping it would leave WebKit guessing at a UTF-8 sibling. It goes
    /// on binary types too, exactly as the unconditional `textEncodingName` did, and that
    /// is measured rather than assumed: a real PNG sibling served as
    /// `image/png; charset=utf-8` decodes into an `<img>` at its true dimensions.
    private func respond(_ task: any WKURLSchemeTask, url: URL, data: Data, mimeType: String) {
        guard
            let response = HTTPURLResponse(
                url: url, statusCode: Self.ok, httpVersion: Self.httpVersion,
                headerFields: [
                    "Content-Type": "\(mimeType); charset=utf-8",
                    "Content-Length": String(data.count),
                    "Content-Security-Policy": Self.contentSecurityPolicy,
                ])
        else { return fail(task, .badServerResponse) }
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    /// A refusal the page can read, rather than one it can only catch.
    ///
    /// `didFailWithError` reaches JavaScript as a bare `TypeError: Load failed` with no
    /// status at all, so "the file is not there" and "the boundary refused it" arrive as
    /// the same event. A status tells them apart.
    ///
    /// **This does not soften a failure into a silent success**, which was the thing worth
    /// checking before trading an error for a response: WebKit honours the status for
    /// subresources over a custom scheme. Measured with real, loadable JavaScript served
    /// twice — 200 gives `onload` and runs it, 404 gives `onerror` and does not — and
    /// `import()` of a missing module still throws even when the 404 carries valid module
    /// source. The body is empty regardless; there is nothing to render or execute.
    ///
    /// It carries the policy too. An empty body has nothing to execute, so this is not where
    /// the enforcement happens — but a refusal *can* become the document, because a link to a
    /// sibling on this origin is a navigation the coordinator allows, and "every response
    /// carries it" is a rule with no edge to get wrong.
    private func refuse(_ task: any WKURLSchemeTask, url: URL, status: Int) {
        guard
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: Self.httpVersion,
                headerFields: [
                    "Content-Length": "0",
                    "Content-Security-Policy": Self.contentSecurityPolicy,
                ])
        else { return fail(task, .badServerResponse) }
        task.didReceive(response)
        task.didFinish()
    }

    /// No status to report, on any of its four call sites.
    ///
    /// Two are requests helm cannot answer *as a request*: one with no URL at all, and an
    /// artifact the document closure cannot produce — the deliberate asymmetry the type's
    /// header argues, where failing beats blanking a live pane.
    ///
    /// The other two are `respond` and `refuse` failing to build a response at all. That is
    /// helm not managing to say anything, which is exactly what a transport error means,
    /// and it must never be quietly dropped: a `WKURLSchemeTask` that is neither finished
    /// nor failed leaves the page waiting forever.
    private func fail(_ task: any WKURLSchemeTask, _ code: URLError.Code) {
        task.didFailWithError(URLError(code))
    }

    private static func mimeType(for name: String) -> String {
        let ext = (name as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}
