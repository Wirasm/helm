import Foundation

/// Testability seams: launch arguments that put the app straight into a given state,
/// so the screenshot harness (tools/winshot.swift) can capture a view without
/// keystroke injection. Human usage is unaffected (no args → normal defaults).
///
///   Helm.app/Contents/MacOS/Helm --artifact ~/.prp/<key>/plans/foo.diagrams.md
///
/// An unknown flag is ignored rather than rejected — the honest failure for a testing
/// seam, since nothing opens and that is visible immediately.
enum LaunchOptions {
    static func value(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    /// File opened as a canvas pane at launch.
    static var artifactPath: String? { value("--artifact") }
}
