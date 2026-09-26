import GhosttyTerminal

/// ghostty asks before a protected clipboard operation: a paste it considers unsafe
/// (`clipboard-paste-protection`, e.g. text with a newline into a program without bracketed
/// paste), an `OSC 52` read under `clipboard-read = ask` (ghostty's default), and an `OSC 52`
/// write under `clipboard-write = ask`. The wrapper denies every one of them when the delegate
/// has no answer, which would silently drop a multi-line ⌘V into `cat`.
///
/// helm has no confirmation UI, so it allows them, which is what the wrapper helm used before
/// answered for all three. The `OSC 52` read is the known limit this leaves: a program in a
/// pane can read the operator's clipboard without a prompt, as it could before. Asking needs a
/// prompt helm owns.
extension TerminalSession: TerminalSurfaceClipboardConfirmationDelegate {
    func terminalDidRequestClipboardConfirmation(_ request: TerminalClipboardConfirmationRequest) {
        request.respond(allow: true)
    }
}
