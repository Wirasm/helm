import Foundation

/// Testability seams: launch arguments that put the app straight into a given state,
/// so the screenshot harness (tools/winshot.swift) can capture any view without
/// keystroke injection. Human usage is unaffected (no args → normal defaults).
///
///   Helm.app/Contents/MacOS/Helm --view kild --room <id>
///   Helm.app/Contents/MacOS/Helm --artifact ~/.prp/<key>/plans/foo.diagrams.md
enum LaunchOptions {
    static func value(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    /// "kild" opens on the kild face; anything else (or absent) → terminal.
    static var initialView: String? { value("--view") }
    /// Artifact file opened in the pane at launch.
    static var artifactPath: String? { value("--artifact") }
    /// Room preselected in the kild view at launch.
    static var roomId: String? { value("--room") }
}
