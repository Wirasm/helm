import AppKit
import BenchKit
import HelmWire

/// The files the operator chose for a page's file input (#549), as paths Chrome can open.
///
/// Chrome takes a file input's files as paths on its own machine (`DOM.setFileInputFiles`), and
/// Chrome runs on benchd's. **On one machine** (benchd's unix socket) those are the operator's own
/// paths, and nothing is copied. **On another** (`BENCH_URL=tcp://…`) each file crosses first:
/// `browser/upload` sends its bytes, and benchd answers where it put them.
///
/// The second route is capped by the request line benchd reads (`benchLargeRequestMaxBytes`, 16 MB
/// as base64, so about 12 MB of file); a larger file is refused here, before it is read, with the
/// reason.
enum BrowserFileChooser {
    enum Outcome: Equatable {
        case paths([String])
        case refused(String)
    }

    /// Blocking: one verb per file over TCP. Call it off the main actor.
    static func paths(for files: [URL], endpoint: BenchEndpoint) -> Outcome {
        if case .unix = endpoint { return .paths(files.map(\.path)) }
        var paths: [String] = []
        for file in files {
            switch upload(file, to: endpoint) {
            case let .success(path): paths.append(path)
            case let .failure(refusal): return .refused(refusal.reason)
            }
        }
        return .paths(paths)
    }

    private struct Refusal: Error {
        let reason: String
    }

    private static func upload(_ file: URL, to endpoint: BenchEndpoint) -> Result<String, Refusal> {
        let name = file.lastPathComponent
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        // base64 is 4 bytes for every 3, and the request around it is well under a kilobyte.
        if (size + 2) / 3 * 4 + 1024 > benchLargeRequestMaxBytes {
            let limit = benchLargeRequestMaxBytes / 4 * 3 / (1024 * 1024)
            return .failure(
                Refusal(
                    reason: "\(name) is \(size / (1024 * 1024)) MB; a file sent to benchd on "
                        + "another machine can be at most about \(limit) MB"))
        }
        do {
            let bytes = try Data(contentsOf: file)
            let answer = try BenchClient.request(
                BrowserUploadRequest(
                    id: "helm-upload-\(UUID().uuidString)", name: name, bytes: bytes),
                at: endpoint, answering: BrowserUploaded.self)
            guard answer.status == .ok, let uploaded = answer.data else {
                return .failure(
                    Refusal(
                        reason: "benchd did not take \(name): "
                            + (answer.reason ?? "refused without a reason")))
            }
            return .success(uploaded.path)
        } catch {
            return .failure(Refusal(reason: "could not send \(name) to benchd: \(error)"))
        }
    }
}

/// A page asking for a file (`Page.fileChooserOpened`), and the operator answering it.
///
/// **Only a chooser the operator opened is shown.** Chrome reports a file input clicked by an
/// agent's Playwright on the tab the pane shows too, and an open panel popping up over his work
/// because of it would seize him (#125). So a chooser counts as his only within `window` of his
/// own click or key reaching the page; any other is left to whoever opened it.
@MainActor
final class BrowserUploads {
    struct Chooser: Decodable, Equatable {
        let backendNodeId: Int
        /// `selectSingle` or `selectMultiple`.
        let mode: String
    }

    /// Asks the operator for files: an open panel in the app, a stand-in in a test. Called with
    /// whether several may be chosen; answers the chosen files, none when he cancelled.
    var ask: @MainActor (_ multiple: Bool, _ chosen: @escaping @MainActor ([URL]) -> Void) -> Void =
        BrowserUploads.openPanel

    static let window: Duration = .seconds(2)
    private var lastInput: ContinuousClock.Instant?

    /// The operator's click or key reached the page.
    func operatorActed() { lastInput = .now }

    /// Whether a chooser that opened now is his.
    var operatorAsked: Bool {
        lastInput.map { ContinuousClock.now - $0 < Self.window } ?? false
    }

    /// Asks for files, makes them paths on benchd's machine, and hands them to `deliver`; or says
    /// why it could not.
    func answer(
        _ chooser: Chooser, endpoint: BenchEndpoint,
        deliver: @escaping @MainActor ([String]) -> Void,
        failed: @escaping @MainActor (String) -> Void
    ) {
        lastInput = nil
        ask(chooser.mode == "selectMultiple") { files in
            guard !files.isEmpty else { return }
            Task {
                let outcome = await Task.detached {
                    BrowserFileChooser.paths(for: files, endpoint: endpoint)
                }.value
                switch outcome {
                case let .paths(paths): deliver(paths)
                case let .refused(why): failed(why)
                }
            }
        }
    }

    private static func openPanel(_ multiple: Bool, _ chosen: @escaping @MainActor ([URL]) -> Void)
    {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = multiple
        panel.message = "Choose a file for the page"
        panel.begin { response in
            MainActor.assumeIsolated { chosen(response == .OK ? panel.urls : []) }
        }
    }
}
