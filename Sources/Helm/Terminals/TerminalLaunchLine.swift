import Foundation

/// Putting a composed command line into a pane's own pty and running it.
///
/// **Two steps, because one does not work — and this is the second caller of that
/// measurement, which is why it is a type rather than a method on each.** libghostty wraps
/// *every* text paste in bracketed-paste markers whenever the shell has enabled mode 2004
/// (the wrapper says so on `AppTerminalView.paste(text:)`, and fish, zsh and bash all
/// enable it). So a line ending in `\r` arrives as a **paste**: the shell puts it on
/// the command line, including the newline, and waits. From outside that is indistinguishable
/// from nothing having happened, which is exactly how it presented the first time — a
/// terminal opened, a shell running, and no agent ever.
///
/// So the line is pasted and the Return is a separate binding action, which writes to the pty
/// without the markers. It is the human gesture — paste, then Enter — and it is right in both
/// directions: pasting is what makes an arbitrary line safe to put on a command line, and if
/// the shell had *not* enabled mode 2004 the extra newline is a harmless empty Enter at a
/// prompt.
///
/// **Still no synthesised keystroke.** Nothing here goes near CGEvent, focus, or the display —
/// it is an in-process call against one named surface, so it cannot land in whatever pane
/// happens to hold the keyboard (#96).
@MainActor
enum TerminalLaunchLine {
    static func send(_ line: String, to session: TerminalSession) {
        session.hostView.paste(text: line)
        if !session.hostView.performBindingAction("text:\\n") {
            NSLog(
                "helm: could not submit a launch line — the pane holds it unrun. ghostty "
                    + "refused the `text` binding action on terminal %@", session.id.uuidString)
        }
    }
}
