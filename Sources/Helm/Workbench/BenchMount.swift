import Foundation

// MARK: - MountState

/// What the workbench is showing: nothing, or a bench.
///
/// It had a third state until M5b (#359): a workspace waiting on #85's "Restore N panes?". The
/// question existed because helm's terminals died with helm. Every terminal pane is a benchd
/// session now, so a relaunched helm shows the panes as they are, and there is nothing to ask.
enum MountState: Equatable {
    /// No workspace open. A fresh install, and where closing the last workspace returns to.
    case empty
    /// A bench, on screen. Never empty — `Workbench`'s first invariant is that it holds a pane.
    case mounted(Workbench)

    var bench: Workbench? {
        if case let .mounted(bench) = self { bench } else { nil }
    }
}
