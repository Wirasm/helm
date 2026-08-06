import Foundation

/// An agent asking helm to put an artifact on screen, carried on the desktop-notification
/// sequence.
///
/// **Why this channel, and not an OSC of helm's own.** #125 proposed a helm-specific OSC
/// number, reasoning that helm already turns OSC 0/2, 9;4, 777 and 8 into app behaviour so
/// one more is the same shape. It is not the same shape. helm never sees OSC *sequences* —
/// it sees ghostty's *parsed actions*, and `ghostty_action_tag_e` is a closed enum with no
/// unknown/raw case. A sequence ghostty does not recognise dies inside the compiled Zig
/// core: no action, no callback, no delegate. Patching cannot reach it either, because
/// helm's patch applies to the Swift wrapper while the parser is a prebuilt binary.
///
/// So the available channels are exactly the ones ghostty already exposes, and of those
/// only the desktop notification both **fires on output** (rather than on a click, which is
/// #124's whole problem) and **carries arbitrary text**. Title is the discriminator, body
/// is the payload.
///
/// The trust question is the one #125 already answered: terminal output can raise a *system
/// notification* today, and a canvas tab is not a bigger deal than a banner.
///
/// **The wire format, read from ghostty's own parser** at the pinned commit
/// (`vendor/libghostty-spm/Ghostty.ref`, `src/terminal/osc/parsers/rxvt_extension.zig`) —
/// not inferred, because the parser is compiled into the binary and `swift test` cannot
/// reach a real surface:
///
/// ```
/// printf '\033]777;notify;helm.canvas;%s\033\\' "$ABSOLUTE_PATH"
/// ```
///
/// The parser splits on the **first two** semicolons only — `title` is between them and
/// `body` is everything after the second, to the end — so a path containing `;` survives
/// intact. A sequence with no second semicolon is rejected by ghostty as "missing the
/// title" and never reaches helm at all.
///
/// Pure on purpose, in the style of `TerminalURLPolicy` and `TerminalLinkRoute` — a ghostty
/// callback cannot be constructed in a test, so the decision lives where `swift test`
/// reaches it.
/// What travels on `HelmCommand.pushCanvasFile`.
///
/// The workspace is not decoration. A push fires from terminal **output**, so it can come
/// from a session in a workspace the operator parked hours ago — where a ⌘-click could only
/// ever come from a pane they were looking at. Without this, a background build in workspace
/// B lands its report on workspace A's bench.
struct CanvasPushRequest: Equatable {
    let artifact: URL
    let workspacePath: WorkspacePath
}

/// Collapses a burst of refusals to one.
///
/// The refusal path deliberately bypasses `TerminalNotificationGate`, which is otherwise the
/// only thing between a foreground visible pane and unlimited banners. `while true; do
/// printf '…helm.canvas;not-a-path…'; done` would otherwise flood Notification Center from a
/// pane the operator is actively looking at — something that was impossible before this
/// channel existed. One refusal per window per session is enough to tell an agent it is
/// doing something wrong.
struct RefusalThrottle {
    static let window: TimeInterval = 10
    private var lastDelivered: Date?

    mutating func allows(at now: Date) -> Bool {
        if let lastDelivered, now.timeIntervalSince(lastDelivered) < Self.window { return false }
        lastDelivered = now
        return true
    }
}

enum CanvasPush {
    /// The reserved notification title that means "this is not a notification".
    ///
    /// Dotted and namespaced so an ordinary notification cannot collide with it by
    /// accident — the cost of a collision is a banner silently becoming a pane.
    static let marker = "helm.canvas"

    enum Outcome: Equatable {
        /// An ordinary notification. Deliver it exactly as before.
        case notAPush
        /// Put this artifact on screen — without taking focus, per #125.
        case open(URL)
        /// A push helm will not honour, and why. **Never silent**: an agent that asked for
        /// a canvas and got nothing cannot tell the difference between a refusal and a
        /// channel that does not work, which is the failure #124 is made of.
        case refused(String)
    }

    /// Classify a desktop-notification request.
    ///
    /// Deliberately total: every input maps to one of the three outcomes, so a caller
    /// cannot forget the refusal case.
    static func classify(title: String, body: String) -> Outcome {
        guard title.trimmingCharacters(in: .whitespaces) == marker else { return .notAPush }

        let payload = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else {
            return .refused("\(marker) needs a path; the notification body was empty")
        }
        guard let url = fileURL(from: payload) else {
            return .refused(
                "\(marker) needs an absolute path or a file:// URL, got \"\(payload)\"")
        }
        guard RenderableFile.isRenderable(url) else {
            return .refused(
                "helm renders .md and .html; \"\(url.lastPathComponent)\" is neither")
        }
        return .open(url)
    }

    /// An absolute path or a `file://` URL, and nothing else.
    ///
    /// Relative is refused rather than resolved: the only cwd helm could resolve against is
    /// the pane's, which is not necessarily the cwd of the process that printed the
    /// sequence — a subshell, a `make` recipe or an agent that has since moved. Guessing
    /// wrong opens the wrong file, which is worse than refusing.
    private static func fileURL(from payload: String) -> URL? {
        if payload.lowercased().hasPrefix("file://") {
            guard let url = URL(string: payload), url.isFileURL, !url.path.isEmpty else {
                return nil
            }
            return url.standardizedFileURL
        }
        guard payload.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: payload).standardizedFileURL
    }
}
