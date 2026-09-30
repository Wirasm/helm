import GhosttyTerminal

/// ghostty asks before a protected clipboard operation: a paste it considers unsafe
/// (`clipboard-paste-protection`, e.g. text with a newline into a program without bracketed
/// paste) and an `OSC 52` write under `clipboard-write = ask`. The wrapper denies every one of
/// them when the delegate has no answer, which would silently drop a multi-line ⌘V into `cat`.
///
/// helm has no confirmation UI, so it allows them, which is what the wrapper helm used before
/// answered. An `OSC 52` read never reaches this: helm runs ghostty with `clipboard-read =
/// deny` (`TerminalSession.sessionOverrides`, #337), because allowing it here handed the
/// operator's clipboard to any program in a pane.
extension TerminalSession: TerminalSurfaceClipboardConfirmationDelegate {
    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        request.respond(allow: true)
    }
}
