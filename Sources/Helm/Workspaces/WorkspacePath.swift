import Foundation
import HelmWire

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
/// **Normalization is `HelmWire.FilesystemPath.normalized`'s, called directly rather than
/// through `Workspace.normalized`.** An earlier draft of this type called `Workspace
/// .normalized`, which itself only delegates to `FilesystemPath.normalized` (#221) — a working
/// chain, but an indirect one: it stated "this agrees with `Workspace`" where the thing that
/// actually has to agree is the spool's own `SpoolPolicy.accept`, which normalizes a spawn's
/// `cwd` through `FilesystemPath.normalized` directly and never touches `Workspace` at all.
/// Calling the shared layer directly says what is actually true — `WorkspacePath` is a thin
/// wrapper over the wire-layer normalizer, not a dependent of `Workspace`'s — and it is one
/// fewer link for a future edit to quietly break. `WorkspacePathSpoolAgreementTests` proves the
/// two call sites still agree, rather than leaving that as a fact about which functions happen
/// to call which other functions.
///
/// An even earlier draft built on `URL.standardizedFileURL`, which resolves `.`/`..` but does
/// NOT expand `~` — a different function from `FilesystemPath.normalized`'s
/// tilde-expand-plus-trailing-slash-trim, and one that would have silently changed a persisted
/// `~/Projects/foo` into a literal `~` directory on the next launch, and re-normalized every
/// `BenchSnapshot` and `WorkspaceContext` path to a different string. `FilesystemPath
/// .normalized` deliberately does NOT resolve symlinks either — the path the operator chose is
/// the path helm shows and filters on.
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
        value = FilesystemPath.normalized(path)
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
