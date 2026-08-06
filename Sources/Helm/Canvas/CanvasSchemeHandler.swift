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

    /// **Nothing served here may be cached, and a sibling is the reason (#228).**
    ///
    /// `CanvasFileViews` loads the document itself with `.reloadIgnoringLocalCacheData`, so an
    /// agent editing `report.html` always sees its own bytes — which is exactly why this went
    /// unnoticed. A **sibling** is a subresource the page fetches, not the navigation, so that
    /// policy never reaches it: `app.js` comes from WebKit's on-disk cache in the
    /// `WKWebsiteDataStore`, and that **survives quitting and relaunching helm**. Measured on
    /// #111's trackpad leg — an edited `spike.js` did not reach the page across a full relaunch,
    /// and only appeared once the import was rewritten to `./spike.js?v=2`.
    ///
    /// That is the worst shape a bug can take here. It is silent; it points the wrong way, since
    /// the natural reading is "my change did not work" and the next move is to edit a file that
    /// is not being executed; and the one remedy anyone would try — relaunching — rules out the
    /// real cause. It costs an agent more than a human: a human eventually opens the inspector,
    /// while an agent re-reads its own correct source and cannot see which bytes the page got.
    ///
    /// **`no-store` rather than revalidation or an mtime key**, because there is nothing here
    /// for caching to buy. Every response is a local file read inside one directory — no
    /// network, no latency to amortize, no server to spare. An ETag or an mtime-keyed cache
    /// would be a second mechanism that can itself be wrong, bought at the price of a `read(2)`.
    /// Siblings-are-served is the primitive the `helm-canvas` skill tells agents to build on —
    /// #200's whole conclusion is *put the library bytes beside the artifact* — so freshness
    /// there has to be unconditional rather than clever.
    ///
    /// **What is measured and what is not, because this file's other WebKit claims say which
    /// and this one must too.** The *bug* is measured — #111's relaunch, and the `?v=2` that
    /// worked. That WebKit honours `no-store` from a `WKURLSchemeHandler`'s `HTTPURLResponse`
    /// is **reasoned from HTTP semantics, not measured here**: the tests below assert the
    /// header is on the response, which is a different claim. `respond` and `refuse` above
    /// each say "measured with real, loadable JavaScript served twice" because their claims
    /// needed a live `WKWebView` to settle, and no unit test can settle this one either — it
    /// wants an edit-reload-refetch against a real page. Until someone runs that, this is a
    /// well-founded fix rather than a confirmed one, and #228 should be closed on the
    /// measurement rather than on the reasoning.
    private static let cacheControl = "no-store"

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
                    "Cache-Control": Self.cacheControl,
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
    /// **A refusal is no more cacheable than a success (#228).** A cached negative outlives the
    /// thing that caused it and reproduces this ticket's exact shape one status code over: the
    /// page keeps failing to load something that is now there, silently, and the natural reading
    /// is again "my change did not work".
    ///
    /// The 404 is the obvious one — an agent referencing a sibling it has not written yet is an
    /// ordinary sequence rather than an exotic one. **But only one of the two 403 routes is
    /// genuinely fixed.** A literal traversal is decided lexically by `standardizedFileURL`, so
    /// that path is refused every time whatever is on disk; `CanvasFileBoundary`'s symlink check
    /// resolves through `resolvingSymlinksInPath()`, so replacing an escaping symlink with a
    /// real file inside the directory flips the same path 403 → 200. That is the same drift the
    /// 404 has. Both statuses go through here and both get the header, so the code was already
    /// right — this note exists because the first version of it argued 403 was safe, and being
    /// right for a reason that is only half true is how the next person justifies removing it.
    private func refuse(_ task: any WKURLSchemeTask, url: URL, status: Int) {
        guard
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: Self.httpVersion,
                headerFields: [
                    "Content-Length": "0",
                    "Cache-Control": Self.cacheControl,
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
