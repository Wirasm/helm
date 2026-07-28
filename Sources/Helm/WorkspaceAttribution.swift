import Foundation

/// Which kilds belong to the folder you have open.
///
/// This replaces a capability that was deleted rather than renamed. A kild's worktree lives
/// under `$KILD_HOME`, not under your project folder, so a path-prefix test on the worktree
/// can never attribute one. The old client resolved this by asking `GET /api/worktrees` for
/// a project's worktree names and matching against them; **that endpoint is gone, and the
/// kild collection has no successor for it.**
///
/// What replaced it is better, because it needs no second call: `Kild.cwd` is the *project*
/// directory its agents run in — "the repo an orphan tree belongs to", in the engine's own
/// words — and it is persisted, so it survives into the archive and is present even on an
/// orphan whose record is otherwise gone. Attribution is a containment test on that one
/// field.
///
/// The care here is entirely in comparing paths, which is where this kind of code usually
/// goes quietly wrong.
enum WorkspaceAttribution {

    /// The kilds belonging to the workspace rooted at `workspace`.
    static func kilds(in workspace: String, from kilds: [Kild]) -> [Kild] {
        let root = normalise(workspace)
        return kilds.filter { contains(root: root, path: $0.cwd) }
    }

    /// Archived kilds belonging to the workspace.
    ///
    /// `cwd` is optional here: archives written before the field existed have none, and are
    /// deliberately **excluded** rather than guessed at. An archive that cannot state where
    /// it ran is not evidence that it ran here — attributing it to whichever folder happens
    /// to be open would be inventing provenance.
    static func archived(in workspace: String, from archive: [ArchivedKild]) -> [ArchivedKild] {
        let root = normalise(workspace)
        return archive.filter { archived in
            guard let cwd = archived.cwd else { return false }
            return contains(root: root, path: cwd)
        }
    }

    /// Is `path` the root itself, or inside it?
    ///
    /// The separator check is what makes this correct: a plain `hasPrefix` would attribute
    /// `/repo-backup` to `/repo`, silently showing another project's kilds as yours.
    static func contains(root: String, path: String) -> Bool {
        let candidate = normalise(path)
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    /// Reduce a path to a form two spellings of the same location share.
    ///
    /// Three normalisations, each for a failure seen in practice on macOS:
    ///
    /// - **Trailing slash.** `/repo/` and `/repo` are the same directory, and a user-typed
    ///   or panel-supplied path may carry either.
    /// - **`~` expansion.** A persisted workspace path may be stored tilde-abbreviated while
    ///   the engine always reports absolute paths.
    /// - **`/var` and `/tmp`.** macOS symlinks both under `/private`. `NSOpenPanel` hands
    ///   back `/private/var/…` while a config file or shell may say `/var/…`; they are one
    ///   directory, and comparing the two spellings as strings never matches.
    ///
    /// Deliberately *not* resolving arbitrary symlinks: that requires touching the
    /// filesystem, which makes attribution fail differently depending on whether a volume
    /// happens to be mounted. A pure function that is occasionally too strict beats one
    /// whose answer depends on disk state.
    static func normalise(_ path: String) -> String {
        var expanded = NSString(string: path).expandingTildeInPath
        for prefix in ["/var/", "/tmp/"] where expanded.hasPrefix(prefix) {
            expanded = "/private" + expanded
        }
        if expanded == "/var" || expanded == "/tmp" { expanded = "/private" + expanded }
        while expanded.count > 1 && expanded.hasSuffix("/") { expanded.removeLast() }
        return expanded
    }
}
