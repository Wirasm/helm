import Foundation

/// Which of helm's two binaries this process is, for the one place it changes behaviour.
///
/// One source tree ships as a bare SPM executable (`swift run helm`) for iteration and as
/// `Helm.app` (`make app`) for real use, and AppKit treats them differently at launch.
enum LaunchContext {
    /// Whether the process is running from a real `.app` bundle.
    ///
    /// This was spelled `Bundle.main.bundleIdentifier == nil` until #45, which was the same
    /// question right up to the moment the SPM binary was given an identifier of its own so
    /// both launch paths would persist to one `UserDefaults` domain. The two facts had been
    /// conflated because one implied the other; only one of them is about activation.
    static var isAppBundle: Bool { isAppBundle(Bundle.main.bundleURL) }

    /// The bundle *path* is what still separates them. `Bundle.main` for a bare executable is
    /// the directory the binary sits in — `.build/arm64-apple-macosx/debug` — which cannot end
    /// in `.app`, with or without an embedded Info.plist.
    static func isAppBundle(_ bundleURL: URL) -> Bool { bundleURL.pathExtension == "app" }
}
