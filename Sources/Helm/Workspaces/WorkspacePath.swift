import Foundation

// MARK: - WorkspacePath

/// A workspace's identity, already normalized, and unable to hold anything else.
///
/// `workspacePath` was a raw `String` in 48 places across Archon, Worktrees, Terminals,
/// Workspaces, Board, Workbench, Spool and App, and it is the join key the whole app routes
/// on — `WorkbenchModel` compares a pushed artifact's `workspacePath` against its own **by
/// value** to decide whether the artifact lands on this bench:
///
/// ```swift
/// guard request.workspacePath == model.workspacePath else { return }
/// ```
///
/// A path that reaches that line un-normalized silently fails to match, and the push lands
/// nowhere. There was no error; the artifact simply never appeared. `AGENTS.md`'s rule is
/// exact: "an invariant with a comment explaining it wants a type carrying it" (#88,
/// `StandardizedPath`'s own header) — the same hazard, one vertical over, had only the
/// comment. `Workspace.path` was already normalized at construction, so it was never the
/// leak; the other ~47 sites passing a bare `String` between verticals — never routed
/// through `Workspace` at all — were.
///
/// **Normalization is `Workspace.normalized`'s, not reinvented here.** An earlier draft of
/// this type built on `URL.standardizedFileURL`, which resolves `.`/`..` but does NOT expand
/// `~` — a different function from `Workspace.normalized`'s tilde-expand-plus-trailing-slash-
/// trim, and one that would have silently changed a persisted `~/Projects/foo` into a
/// literal `~` directory on the next launch, and re-normalized every `BenchSnapshot` and
/// `WorkspaceContext` path to a different string. `Workspace.normalized` deliberately does
/// NOT resolve symlinks either — the path the operator chose is the path helm shows and
/// filters on. `WorkspacePath` delegates to it rather than copying its body, so there is one
/// spelling of "normalized" and not two that can drift apart. (`Workspace.normalized` stays
/// a free `String -> String` function rather than folding entirely into this type because
/// `Spool/SpoolRequest.swift` and `DefaultsDomain`'s migration call it directly and are out
/// of scope here — #221.) A later `HelmWire.FilesystemPath.normalized` (#225) is where this
/// logic is headed; until then, this is the one place outside `Workspace` itself that calls
/// `Workspace.normalized`, and it is meant to be the LAST such duplication, not a new one.
///
/// **A distinct type from `StandardizedPath`, deliberately not a reuse.** A workspace is a
/// directory and a canvas source is a file; keeping them apart means one cannot be passed
/// where the other belongs, and it keeps this change out of `Canvas/`, which has other work
/// in flight (#222).
///
/// The discipline is `StandardizedPath`'s, exactly: the explicit `init` suppresses the
/// synthesized memberwise one, so there is no `WorkspacePath(value:)` and no way to hold a
/// path that skipped normalization. Every route in normalizes — construction and decoding
/// both.
struct WorkspacePath: Equatable, Hashable, Codable, Sendable {
    let value: String

    init(_ path: String) {
        value = Workspace.normalized(path)
    }

    init(_ url: URL) {
        self.init(url.path)
    }

    /// Decoding is a route in like any other, so it normalizes too — a hand-edited defaults
    /// blob, or a `BenchSnapshot` read by an agent outside the process, cannot reintroduce an
    /// un-normalized value.
    init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    /// A single-value container, so the wire shape is a bare string — byte-identical to the
    /// `String` this type replaces. `BenchSnapshot.WorkspaceRecord.path` is read by agents
    /// outside the process and `WorkspaceContext` is restored across a relaunch; neither may
    /// change shape for this refactor to be safe.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}
