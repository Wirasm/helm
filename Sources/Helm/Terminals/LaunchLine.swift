import Foundation

/// A line helm types into a terminal: the sessions drawer's open actions (`SessionsModel`), and
/// the words of `bench attach` a pane runs (`SessionAttach`).
/// An agent spawned by `bench spawn` never passes through here: benchd starts it in its own pty,
/// with the postures `bench_session::argv` spells for every agent.
///
/// The line is pasted, then submitted with a separate Return (`TerminalLaunchLine.send`):
/// libghostty wraps every `sendText` in bracketed-paste markers when the shell has mode 2004 on,
/// so a trailing `\r` would sit on the command line unsubmitted.
enum LaunchLine {
    /// POSIX single-quoting: everything inside is literal, and an embedded `'` is closed,
    /// escaped and reopened. The only escaping rule a shell has no exceptions to.
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
