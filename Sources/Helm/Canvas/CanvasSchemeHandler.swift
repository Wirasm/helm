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
/// **The directory is the read boundary**, the same one `loadFileURL(_:allowingReadAccessTo:)`
/// enforced before: a request resolving outside the artifact's own directory is refused
/// rather than served, so `../../.ssh/id_rsa` is not a path a page can ask for.
///
/// One handler per webview, holding one artifact. It never sees another canvas's path, so
/// "could canvas A read canvas B?" is not a policy question here — there is nothing to ask
/// with.
/// Deliberately **not** `@MainActor`. WebKit calls a scheme handler on the main thread —
/// the same fact `CanvasFileCoordinator` leans on for script messages — but a
/// `WKURLSchemeTask` is not `Sendable`, so hopping the task into a `MainActor` closure is
/// a data-race diagnostic rather than a safety win. The task therefore never leaves this
/// method, and the one genuinely main-actor thing (the staged document) is fetched as
/// plain `Data` across the boundary.
final class CanvasSchemeHandler: NSObject, WKURLSchemeHandler {
    /// The artifact's own directory — nothing outside it is served.
    private let directory: URL
    /// The artifact's file name, which is the one path that maps to `document`.
    private let documentName: String
    private let documentMIME: String
    /// The main document's current bytes. A closure because a markdown canvas's page is
    /// generated per theme and per file change, and the handler must serve what the view
    /// would have loaded rather than a stale snapshot.
    private let document: @MainActor () -> Data?

    init(artifact: URL, mimeType: String, document: @escaping @MainActor () -> Data?) {
        self.directory = artifact.deletingLastPathComponent().standardizedFileURL
        self.documentName = artifact.lastPathComponent
        self.documentMIME = mimeType
        self.document = document
    }

    /// Everything here completes synchronously — the bytes are already in memory or on
    /// local disk — so a task can never be stopped between `start` and its completion, and
    /// there is no live-task bookkeeping to get wrong.
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return fail(task, .badURL) }

        // The artifact itself.
        if url.path == "/" + documentName || url.path == "/" {
            guard let data = MainActor.assumeIsolated({ document() }) else {
                return fail(task, .cannotOpenFile)
            }
            return respond(task, url: url, data: data, mimeType: documentMIME)
        }

        // A sibling it referenced.
        guard let file = resolved(url) else { return fail(task, .noPermissionsToReadFile) }
        guard let data = try? Data(contentsOf: file) else { return fail(task, .fileDoesNotExist) }
        respond(
            task, url: url, data: data,
            mimeType: Self.mimeType(for: (url.path as NSString).lastPathComponent))
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    /// A sibling of the artifact, or nil. The standardized result must still be inside the
    /// artifact's directory — which is what refuses `..` traversal, and refuses it after
    /// resolution rather than by string-matching the request.
    private func resolved(_ url: URL) -> URL? {
        let relative = String(url.path.drop(while: { $0 == "/" }))
        guard !relative.isEmpty else { return nil }
        let candidate = directory.appendingPathComponent(relative).standardizedFileURL
        let root = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        guard candidate.path.hasPrefix(root) else { return nil }
        return candidate
    }

    private func respond(_ task: any WKURLSchemeTask, url: URL, data: Data, mimeType: String) {
        let response = URLResponse(
            url: url, mimeType: mimeType, expectedContentLength: data.count,
            textEncodingName: "utf-8")
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private func fail(_ task: any WKURLSchemeTask, _ code: URLError.Code) {
        task.didFailWithError(URLError(code))
    }

    private static func mimeType(for name: String) -> String {
        let ext = (name as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}
