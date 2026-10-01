import AppKit
import Foundation
import HelmWire

/// What the shared browser downloaded while this pane watched it (#549), and the way to get
/// each file onto the Mac.
///
/// **Where a download lands is unchanged**: Chrome's own default, `~/Downloads` on benchd's
/// machine. The pane only asks Chrome to report them (`Browser.setDownloadBehavior` with
/// `behavior: "default"`), and Chrome's `completed` report carries the file's path. An agent's
/// Playwright sets a behavior of its own while it is attached, and Chrome then reports to it
/// rather than here: the list shows what Chrome told the pane.
///
/// **Getting a file to the Mac** is the endpoint's question. On one machine the file is already
/// here and opens in place. With benchd on another machine it is read through `file/read` and
/// written into the Mac's own downloads folder under a free name.
@MainActor
final class BrowserDownloads: ObservableObject {
    struct Download: Identifiable, Equatable {
        /// Chrome's `guid`.
        let id: String
        let name: String
        var state: State
        var receivedBytes: Double = 0
        var totalBytes: Double = 0
        /// On benchd's machine, once completed.
        var path: String?
        /// Where it was copied on the Mac, once it has been.
        var copied: URL?
    }

    enum State: String, Equatable {
        case inProgress, completed, canceled
    }

    /// Newest first.
    @Published private(set) var items: [Download] = []

    /// Whether benchd shares this Mac's disk: its unix socket. nil: no benchd.
    let endpoint: BenchEndpoint?
    /// Where a file copied from another machine lands.
    var macFolder: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    init(endpoint: BenchEndpoint?) {
        self.endpoint = endpoint
    }

    var onOneMachine: Bool {
        if case .unix = endpoint { true } else { false }
    }

    /// `Browser.downloadWillBegin` and `Browser.downloadProgress`, from the browser connection.
    func handle(_ event: CDPConnection.Event) {
        switch event.method {
        case "Browser.downloadWillBegin":
            guard let begun = event.params(Begun.self) else { return }
            items.removeAll { $0.id == begun.guid }
            items.insert(
                Download(id: begun.guid, name: begun.suggestedFilename, state: .inProgress), at: 0)
        case "Browser.downloadProgress":
            guard let progress = event.params(Progress.self),
                let index = items.firstIndex(where: { $0.id == progress.guid })
            else { return }
            items[index].state = State(rawValue: progress.state) ?? .inProgress
            items[index].receivedBytes = progress.receivedBytes
            items[index].totalBytes = progress.totalBytes
            if let path = progress.filePath { items[index].path = path }
        default:
            break
        }
    }

    func clear() { items.removeAll { $0.state != .inProgress } }

    /// What Open does with a file already on the Mac. **Nothing an agent could have downloaded
    /// is run by it**: an agent drives the same browser, so a `.command` or an installer in the
    /// list may be its, and the operator's click must not execute it. Those, and any file with
    /// the exec bit, are shown in Finder; every other file opens in its app.
    enum OpenAction: Equatable {
        case open
        case reveal
    }

    nonisolated static let runnableExtensions: Set<String> = [
        "app", "command", "sh", "pkg", "mpkg", "dmg", "terminal", "tool", "workflow", "action",
        "jar", "scpt", "applescript",
    ]

    nonisolated static func openAction(for file: URL) -> OpenAction {
        if runnableExtensions.contains(file.pathExtension.lowercased()) { return .reveal }
        var isFolder: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder)
        if exists, isFolder.boolValue || FileManager.default.isExecutableFile(atPath: file.path) {
            return .reveal
        }
        return .open
    }

    /// The file on the Mac: in place on one machine, else copied into `macFolder` (once; a second
    /// ask answers the copy). A sentence when it cannot be had.
    func onMac(_ id: String) async -> Result<URL, DownloadFailure> {
        guard let index = items.firstIndex(where: { $0.id == id }), let path = items[index].path
        else { return .failure(DownloadFailure(reason: "that download has not finished")) }
        if onOneMachine { return .success(URL(fileURLWithPath: path)) }
        if let copied = items[index].copied { return .success(copied) }
        guard let endpoint else { return .failure(DownloadFailure(reason: "no benchd to ask")) }
        let name = items[index].name
        let folder = macFolder
        let result = await Task.detached {
            Self.copy(path, named: name, from: endpoint, into: folder)
        }
        .value
        if case let .success(url) = result, let now = items.firstIndex(where: { $0.id == id }) {
            items[now].copied = url
        }
        return result
    }

    struct DownloadFailure: Error, Equatable {
        let reason: String
    }

    nonisolated private static func copy(
        _ path: String, named name: String, from endpoint: BenchEndpoint, into folder: URL
    ) -> Result<URL, DownloadFailure> {
        let request = BenchFileReadRequest(id: "helm-download-\(UUID().uuidString)", path: path)
        let bytes: Data
        do {
            let answer = try BenchClient.request(
                request, at: endpoint, answering: BenchFileRead.self)
            switch answer.data {
            case let .bytes(data)? where answer.status == .ok: bytes = data
            case .absent?:
                return .failure(DownloadFailure(reason: "\(name) is no longer on benchd's machine"))
            default:
                return .failure(
                    DownloadFailure(
                        reason:
                            "benchd could not read \(name): \(answer.reason ?? "no reason given")"))
            }
        } catch {
            return .failure(DownloadFailure(reason: "could not ask benchd for \(name): \(error)"))
        }
        let target = freeName(name, in: folder)
        do {
            try bytes.write(to: target, options: .withoutOverwriting)
            return .success(target)
        } catch {
            return .failure(
                DownloadFailure(
                    reason: "could not write \(target.path): \(error.localizedDescription)"))
        }
    }

    /// `name` in `folder`, or `name (2)`, `name (3)`… — the first that is not taken, as Chrome and
    /// Safari name a second download of one file.
    nonisolated static func freeName(_ name: String, in folder: URL) -> URL {
        let files = FileManager.default
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while files.fileExists(atPath: candidate.path) {
            let numbered = "\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
            candidate = folder.appendingPathComponent(numbered)
            n += 1
        }
        return candidate
    }

    private struct Begun: Decodable {
        let guid: String
        let suggestedFilename: String
    }

    private struct Progress: Decodable {
        let guid: String
        let state: String
        let receivedBytes: Double
        let totalBytes: Double
        let filePath: String?
    }
}
