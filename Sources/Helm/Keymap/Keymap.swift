import Foundation
import HelmWire

/// The key table in force: the built-in rows, overlaid by the operator's keymap file.
///
/// **One reader, and it never leaves the operator without keys.** The monitor, the menu and the
/// key pop-up all read `table`. A file that does not parse, cannot be read or claims a
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
    /// `[drawer.<name>]` from the last good file.
    @Published private(set) var drawerStyles: [String: DrawerStyle] = [:]
    /// The manage key in force (#498): the last good file's, else the built-in one. The key
    /// pop-up shows while it is held, and the status bar names it.
    @Published private(set) var manage: ManageKey = .builtIn

    /// `keymap.toml` in helm's own directory (`HelmBenchDirectory`), so an isolated helm has its
    /// own, and it stays on helm's machine when benchd is on another. nil only in a test that
    /// wants the built-in table.
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
            drawerStyles = [:]
            manage = .builtIn
            problem = nil
        case let .unreadable(why):
            reject(KeymapProblem(line: nil, reason: why))
        case let .text(text):
            do {
                let file = try KeymapFile.parse(text)
                table = try file.overlay(on: defaults)
                drawerStyles = file.drawers
                manage = file.manage
                problem = nil
            } catch {
                reject(error)
            }
        }
    }

    /// Where a drawer is drawn: the file's table for it, else the built-in one.
    func style(for drawer: String) -> DrawerStyle {
        drawerStyles[drawer] ?? .builtIn(for: drawer)
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
        let file = HelmBenchDirectory.resolve().keymap
        if case let .success(root) = BenchRoot.resolve() {
            moveOnce(from: root.appendingPathComponent("rules/keymap.toml"), to: file)
        }
        return file
    }

    /// Until M5c the keymap was `<bench root>/rules/keymap.toml`, which was only helm's own by
    /// accident: the bench root is on helm's machine. A file there, with none at `to` yet, is
    /// moved once, so the operator's keys come along. Delete this once no machine has the old
    /// file.
    nonisolated static func moveOnce(from old: URL, to new: URL) {
        let files = FileManager.default
        guard files.fileExists(atPath: old.path), !files.fileExists(atPath: new.path) else {
            return
        }
        do {
            try files.createDirectory(
                at: new.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try files.moveItem(at: old, to: new)
            NSLog("helm: moved the keymap from %@ to %@", old.path, new.path)
        } catch {
            NSLog(
                "helm: could not move the keymap from %@ to %@: %@", old.path, new.path,
                error.localizedDescription)
        }
    }
}
