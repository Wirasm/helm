import AppKit
import Foundation

/// Watches for a newer build and, when the operator asks, swaps to it.
///
/// **Polling, not watching, and for the reason `BoardModel` already documents.** The stamp is
/// one file that gets *rewritten* at the same path on every build, and a directory-level
/// `DispatchSource` reports entries appearing and disappearing rather than a write to a file
/// already listed there. `SpoolWatcher`'s header draws the same distinction from the other
/// side — it watches for a file *appearing*, which is the visible case. This is the invisible
/// one, so it polls.
///
/// Five seconds rather than the board's two: a build finishing is a minutes-scale event, the
/// badge is not something anyone is waiting on with a stopwatch, and the tick is one `stat`
/// and a sub-kilobyte read.
@MainActor
final class BuildUpdateModel: ObservableObject {
    @Published private(set) var update: BuildUpdate = .upToDate

    private let directory: BuildStampDirectory
    private let runningSHA: String?
    private let isIsolated: Bool
    /// The bundle this helm is *running from*, which is what a relaunch replaces.
    ///
    /// Deliberately not a hard-coded `/Applications/Helm.app`: helm should replace itself
    /// where it actually lives, so an operator who keeps it somewhere else is not handed a
    /// second copy in a directory they never chose.
    private let installTarget: URL

    init(
        directory: BuildStampDirectory = .resolve(),
        runningSHA: String? = RunningBuild.sha,
        isIsolated: Bool = DefaultsDomain.isIsolated,
        installTarget: URL = Bundle.main.bundleURL
    ) {
        self.directory = directory
        self.runningSHA = runningSHA
        self.isIsolated = isIsolated
        self.installTarget = installTarget
    }

    /// Polls until cancelled — driven from `StatusBarView`'s `.task`, so its lifetime is the
    /// bar's. If the bar is not on screen there is nobody to show a badge to.
    ///
    /// **An isolated instance never polls at all, and that is the policy `BuildStampDirectory`
    /// declined to encode as a path.** A `HELM_DEFAULTS_SUITE` helm is a worktree build under
    /// test; offering to replace the operator's installed application from one would be the
    /// test instance reaching into exactly the state the suite exists to keep it out of.
    func poll(every interval: Duration = .seconds(5)) async {
        guard !isIsolated else { return }
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: interval)
        }
    }

    /// One tick: read the stamp off the main actor and re-decide.
    ///
    /// **A stamp whose product is gone is dropped here, and that is what keeps the badge from
    /// being a button that does nothing.** `make clean` after a build leaves a perfectly valid
    /// stamp describing a bundle that no longer exists; offering it would put a control in the
    /// status bar whose only possible outcome is a line in the system log. The check is on this
    /// side rather than in `BuildUpdate.decide` because it needs the filesystem, and that
    /// function is pure so the interesting cases stay reachable from a test.
    ///
    /// Both reads happen in the same detached task: the stamp and the `stat` behind
    /// `installableProduct` are I/O, and neither belongs on the actor drawing the terminal.
    func refresh() async {
        let directory = self.directory
        let stamp = await Task.detached { () -> BuildStamp? in
            guard let stamp = directory.read(), stamp.installableProduct != nil else { return nil }
            return stamp
        }.value
        let decided = BuildUpdate.decide(running: runningSHA, waiting: stamp)
        guard decided != update else { return }
        update = decided
    }

    /// Install the waiting build and come back on it.
    ///
    /// **The click is the consent, and it is the only consent there is.** helm cannot replace
    /// the bundle it is executing, so this necessarily quits — taking every agent in every
    /// pane with it, exactly as a manual quit would. That cost is why this is on a badge the
    /// operator presses and never on a timer, a prompt, or anything that fires by itself.
    ///
    /// The swap is done by a detached `/bin/sh` because it has to outlive the process asking
    /// for it. **It is bounded rather than trusted to tidy up**: if helm has not exited within
    /// the deadline the helper gives up and touches nothing, so the worst case is a build that
    /// did not install rather than a stray process waiting forever on a pid that will never
    /// go away.
    func relaunch() {
        guard let stamp = update.waiting else { return }
        guard let product = stamp.installableProduct else {
            NSLog(
                "helm: refusing to install build %@ — %@ is not an .app bundle on disk",
                stamp.sha, stamp.product)
            return
        }
        // Replacing a bundle with itself would delete it and copy it back, which is a great
        // deal of risk for no change at all.
        guard product.standardizedFileURL != installTarget.standardizedFileURL else {
            NSLog("helm: refusing to install build %@ over itself at %@", stamp.sha, product.path)
            return
        }
        do {
            try swap(to: product)
        } catch {
            NSLog("helm: could not start the update helper: %@", String(describing: error))
            return
        }
        NSApp.terminate(nil)
    }

    /// Hand the swap to `BundleSwap` and let go of it.
    ///
    /// The script itself — the staging, the rollback, the deadline — lives there rather than
    /// here so that a test can run the same bytes without replacing a live application. This
    /// end is only "start it and stop existing".
    private func swap(to product: URL) throws {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = BundleSwap.arguments(
            waitingFor: ProcessInfo.processInfo.processIdentifier,
            installing: product,
            over: installTarget)
        try helper.run()
    }
}
