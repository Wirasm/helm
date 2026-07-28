import Foundation

/// Testability seams: launch arguments that put the app straight into a given state,
/// so the screenshot harness (tools/winshot.swift) can capture any view without
/// keystroke injection. Human usage is unaffected (no args → normal defaults).
///
///   Helm.app/Contents/MacOS/Helm --kild <id>
///   Helm.app/Contents/MacOS/Helm --artifact ~/.prp/<key>/plans/foo.diagrams.md
///
/// `--kild` and `--artifact` combine: the kild wins the dock, the artifact
/// loads behind it and surfaces on deselection.
enum LaunchOptions {
    static func value(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    /// Artifact file opened in the dock at launch.
    static var artifactPath: String? { value("--artifact") }

    /// Kild preselected in the sidebar at launch (its detail wins the dock).
    ///
    /// `--room` is **not** accepted as an alias. A room id and a kild id are not the same
    /// identifier — the engine's archives moved and the vocabulary changed with them — so
    /// an alias would silently preselect nothing while looking like it worked. An unknown
    /// flag is simply ignored, which is the honest failure: nothing is selected, and that
    /// is visible immediately.
    static var kildId: String? { value("--kild") }
}
