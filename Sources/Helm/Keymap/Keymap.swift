import Foundation
import HelmWire

/// The key table in force: the built-in rows, overlaid by the operator's keymap file.
///
/// **One reader, and it never leaves the operator without keys.** The monitor, the menu and the
/// status bar's hints all read `table`. A file that does not parse, cannot be read or claims a
/// chord twice changes nothing: the last good table stays, `problem` says which line and why,
/// and the status bar shows it until a good save clears it. Only a missing file means the
/// built-in table.
///
/// **Polled, for the reason `BuildUpdateModel` gives.** An editor may rewrite the file in place,
/// which a directory source does not report, and the file may not exist yet, which a file source
/// cannot open. A read of a file this size once a second costs nothing, and comparing its text
/// rather than its timestamp sees every change.
@MainActor
final class Keymap: ObservableObject {
    static let shared = Keymap(file: operatorFile())

    @Published private(set) var table: [KeyBinding]
    @Published private(set) var problem: KeymapProblem?

    /// `<bench root>/rules/keymap.toml`, so an isolated helm has its own. nil when the root
    /// cannot be resolved, which leaves the built-in table.
    let file: URL?
    private let defaults: [KeyBinding]
    private var lastRead: FileRead?

    enum FileRead: Equatable, Sendable {
        case absent
        case text(String)
        case unreadable(String)
    }

    init(file: URL?, defaults: [KeyBinding] = KeyBindings.all) {
        self.file = file
        self.defaults = defaults
        table = defaults
    }

    /// Reads the file until cancelled. Started once, with the app.
    func watch(every interval: Duration = .seconds(1)) async {
        guard let file else { return }
        while !Task.isCancelled {
            apply(await Task.detached { Self.read(file) }.value)
            try? await Task.sleep(for: interval)
        }
    }

    /// Adopts what the file says now. The same read twice does nothing.
    func apply(_ read: FileRead) {
        guard read != lastRead else { return }
        lastRead = read
        switch read {
        case .absent:
            table = defaults
            problem = nil
        case let .unreadable(why):
            reject(KeymapProblem(line: nil, reason: why))
        case let .text(text):
            do {
                table = try KeymapFile.parse(text).overlay(on: defaults)
                problem = nil
            } catch {
                reject(error)
            }
        }
    }

    private func reject(_ problem: KeymapProblem) {
        self.problem = problem
        NSLog(
            "helm: %@ rejected, keeping the last good keymap: %@", file?.path ?? "keymap.toml",
            problem.sentence)
    }

    nonisolated static func read(_ file: URL) -> FileRead {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            return .absent
        } catch {
            return .unreadable("cannot be read: \(error.localizedDescription)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .unreadable("is not UTF-8")
        }
        return .text(text)
    }

    private static func operatorFile() -> URL? {
        switch BenchRoot.resolve() {
        case let .success(root):
            return root.appendingPathComponent("rules/keymap.toml", isDirectory: false)
        case let .failure(error):
            NSLog("helm: no keymap file, keeping the built-in keys: %@", error.sentence)
            return nil
        }
    }
}
