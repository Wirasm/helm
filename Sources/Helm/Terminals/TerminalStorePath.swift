import Foundation
import GhosttyTerminal
import HelmWire

/// A ⌘-clicked path that may name a file in one of prp's stores, opened as a canvas pane the way
/// `bench open <file>` and the ⌘O drawer open one.
///
/// ghostty's link regex already finds the path under the click (absolute and `~/`, without the
/// backticks around it, across soft-wrapped rows) and hands it over without a scheme, which
/// `TerminalURLPolicy` drops. Terminal content is untrusted, so a path opens only when benchd says
/// it is a file under a root `prp/stores` names: helm reads neither `~/.prp` nor the path itself
/// (M5c). Everything else stays dropped.
///
/// **A hard-wrapped path.** Claude Code, codex and pi lay out their own lines, so a long path is
/// two rows with no soft-wrap between them, and ghostty's match is the half that was clicked.
/// `candidates` joins it with the words at the edges of the rows around it. A join is a guess;
/// benchd's existence check decides, and a wrong join names nothing.
enum TerminalStorePath {
    /// How many rows above and below the click a hard-wrapped path may continue into.
    static let reach = 2

    /// What the click may have meant, the clicked text alone first, then joined with its
    /// neighbouring rows: only absolute or `~/` paths to a file helm renders.
    static func candidates(_ clicked: String, around grid: TerminalHoveredRows?) -> [String] {
        let token = clicked.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return [] }
        var heads = [""]
        var tails = [""]
        if let grid, grid.rows.indices.contains(grid.hovered) {
            let own = words(grid.rows[grid.hovered])
            // The click's word starts its row: the rows above may end with the path's head.
            if let first = own.first, first.hasPrefix(token) || token.hasPrefix(first) {
                for row in grid.rows[..<grid.hovered].reversed() {
                    let above = words(row)
                    guard let last = above.last else { break }
                    heads.append(last + heads[heads.count - 1])
                    if above.count > 1 { break }
                }
            }
            // The click's word ends its row: the rows below may start with the path's tail.
            if let last = own.last, last.hasSuffix(token) || token.hasSuffix(last) {
                for row in grid.rows[(grid.hovered + 1)...] {
                    let below = words(row)
                    guard let first = below.first else { break }
                    tails.append(tails[tails.count - 1] + first)
                    if below.count > 1 { break }
                }
            }
        }
        var found: [String] = []
        for head in heads {
            for tail in tails {
                let path = trimmingSentencePunctuation(head + token + tail)
                if isRenderablePath(path), !found.contains(path) { found.append(path) }
            }
        }
        return found
    }

    /// The first of `candidates` that benchd resolves to a file under one of its store roots, as
    /// benchd spelled it. Blocking: one `prp/stores` and up to one `path/resolve` per candidate.
    static func storeFile(_ candidates: [String], prp: PrpStores) -> String? {
        guard !candidates.isEmpty, case let .success(answer) = prp.stores() else { return nil }
        let roots = answer.stores.compactMap { FilesystemPath.standardized($0.dir) }
        for candidate in candidates {
            guard case let .success(path) = prp.resolve(candidate, as: .file) else { continue }
            if roots.contains(where: { path.hasPrefix($0 + "/") }) { return path }
        }
        return nil
    }

    /// A row's words: runs between whitespace and the quotes and brackets a path sits in.
    private static func words(_ row: String) -> [String] {
        row.split(whereSeparator: { $0.isWhitespace || "`\"'<>()[]".contains($0) }).map(String.init)
    }

    /// `x.md.` at the end of a sentence: ghostty's path characters include the full stop.
    private static func trimmingSentencePunctuation(_ path: String) -> String {
        var path = Substring(path)
        while let last = path.last, ".,;:!?".contains(last) { path = path.dropLast() }
        return String(path)
    }

    private static func isRenderablePath(_ path: String) -> Bool {
        let rooted = (path.hasPrefix("/") && !path.hasPrefix("//")) || path.hasPrefix("~/")
        return rooted && RenderableFile.isRenderable(URL(fileURLWithPath: path))
    }
}

extension WorkbenchModel {
    /// Open the first of `candidates` that is a file in a prp store as a canvas pane, where
    /// benchd's placement rules put it. Sent as helm's, like `openLink`, so benchd moves no focus:
    /// the pane appears beside the terminal and the keyboard stays there. The pane, or nil when
    /// none of them is one.
    ///
    /// The questions go off the main actor, as `newNote`'s do: they are blocking round trips. A
    /// workspace switched meanwhile opens nothing, as a note does not: benchd would put the pane
    /// on the bench now showing, not beside the terminal that was clicked.
    @discardableResult
    func openStoreFile(_ candidates: [String]) async -> Pane.ID? {
        let clickedIn = workspacePath
        let prp = PrpStores(client: client)
        let found = await Task.detached { TerminalStorePath.storeFile(candidates, prp: prp) }.value
        guard let found, workspacePath == clickedIn else { return nil }
        return send(.paneOpen(surface: .canvas(path: found)), by: .helm)
    }
}
