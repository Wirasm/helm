import Foundation

/// Replacing the running application with the build it is quitting for.
///
/// **A `/bin/sh` script, because it has to outlive the process that asks for it.** helm cannot
/// replace the bundle it is executing, so the last thing it does is start this and terminate;
/// everything here happens with no helm running at all.
///
/// **It is a constant rather than an inline string so a test can run the same bytes.** This is
/// the one operation in helm that can destroy the operator's installed application, and an
/// inline literal inside `BuildUpdateModel` was reachable only by actually swapping a live
/// app — which is to say, not reachable at all. `BundleSwapTests` runs *this* value through
/// `/bin/sh` against disposable bundles and an already-dead pid, so the rollback and the
/// deadline are measured rather than reasoned about.
///
/// Rejected: `scripts/swap-bundle.sh`. An installed helm in `/Applications` has no checkout to
/// run a script from, so it would have to become a bundle resource — and that means the
/// `Package.swift` ↔ `project.yml` resource lockstep both files warn about, bought for nothing
/// a constant does not already give.
enum BundleSwap {
    /// Positional arguments only — a path with a space or a quote in it is then ordinary data
    /// rather than something to escape, and there is no interpolation for a caller to get
    /// wrong.
    ///
    /// `$1` pid to wait for, `$2` new bundle, `$3` bundle to replace, `$4` seconds to wait,
    /// `$5` how to relaunch.
    ///
    /// **Two renames, not a delete and a copy.** The obvious order — `rm -rf "$3"` then move
    /// the new one in — leaves the operator with *no* application for the length of an
    /// `rm -rf` over a bundle, which is the slow step and therefore a real window rather than
    /// a theoretical one. Renaming the old one aside is near-instant, and it leaves something
    /// to put back: every failure below restores it and relaunches, so the worst case is the
    /// build that was already installed, running again.
    static let script = """
        deadline=$(( $(date +%s) + ${4:-60} ))
        while kill -0 "$1" 2>/dev/null; do
          [ "$(date +%s)" -ge "$deadline" ] && exit 1
          sleep 0.2
        done

        launcher="${5:-/usr/bin/open}"
        stage="$3.helm-update"
        previous="$3.helm-previous"
        rm -rf "$stage" "$previous"

        # Nothing is moved until the new bundle is fully staged beside the old one.
        if ! cp -R "$2" "$stage"; then
          rm -rf "$stage"
          "$launcher" "$3"
          exit 2
        fi

        if [ -e "$3" ] && ! mv "$3" "$previous"; then
          rm -rf "$stage"
          "$launcher" "$3"
          exit 3
        fi

        if mv "$stage" "$3"; then
          rm -rf "$previous"
        else
          [ -e "$previous" ] && mv "$previous" "$3"
          rm -rf "$stage"
          "$launcher" "$3"
          exit 4
        fi

        "$launcher" "$3"
        """

    /// How long the helper waits for helm to actually exit before giving up.
    ///
    /// **Bounded rather than trusting the parent to tidy up**, which is the rule #291 cost a
    /// day to learn: a helper that waits forever on a pid that never dies is a process still
    /// spinning tomorrow. Giving up costs a build that did not install — the operator presses
    /// the badge again — and that is the cheap side of the trade.
    static let exitDeadline = 60

    static func arguments(
        waitingFor pid: pid_t,
        installing product: URL,
        over target: URL,
        deadline: Int = exitDeadline,
        launcher: String = "/usr/bin/open"
    ) -> [String] {
        [
            "-c", script, "helm-update",
            String(pid), product.path, target.path, String(deadline), launcher,
        ]
    }
}
