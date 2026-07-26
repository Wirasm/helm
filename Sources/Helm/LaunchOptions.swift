import Foundation

/// Testability seams: launch arguments that put the app straight into a given state,
/// so the screenshot harness (tools/winshot.swift) can capture any view without
/// keystroke injection. Human usage is unaffected (no args → normal defaults).
///
///   Helm.app/Contents/MacOS/Helm --room <id>
///   Helm.app/Contents/MacOS/Helm --artifact ~/.prp/<key>/plans/foo.diagrams.md
///
/// `--room` and `--artifact` combine: the room wins the dock, the artifact
/// loads behind it and surfaces on deselection.
enum LaunchOptions {
    static func value(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    /// DEPRECATED, kept as a parsed no-op: `--view` selected a face of the old
    /// ⌘T two-faces model. Since the one-surface re-layout (slice 1a) both
    /// former faces are always visible, so there is nothing to select — old
    /// harness invocations still parse, and are ignored.
    static var initialView: String? { value("--view") }
    /// Artifact file opened in the dock at launch.
    static var artifactPath: String? { value("--artifact") }
    /// Room preselected in the sidebar at launch (its detail wins the dock).
    static var roomId: String? { value("--room") }
}
