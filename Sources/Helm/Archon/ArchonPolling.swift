import Foundation

/// The loop both Archon surfaces run: refresh, wait, refresh, until the `.task` that owns it
/// is cancelled.
///
/// **Shared because it was byte-for-byte identical in two models. `refresh()` deliberately is
/// not.** Each one's body assigns that model's own `@Published private(set)` state, which Swift
/// only lets its own file mutate — sharing the body would mean loosening that, and `AGENTS.md`
/// reads access control as where the seam is rather than as something in its way.
enum ArchonPolling {
    /// Two seconds: a healthy `archon` call is ~0.6s (measured, 0.7.0, warm), so this leaves
    /// the CLI idle most of the window, and the rail is something you glance at while an agent
    /// works rather than something you watch.
    static let interval: Duration = .seconds(2)

    /// `@MainActor` because both callers are: a non-isolated version would have to be handed
    /// a `@Sendable` closure, and the whole body of both `refresh()`es is main-actor state.
    @MainActor
    static func loop(every interval: Duration = Self.interval, _ refresh: () async -> Void) async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: interval)
        }
    }
}
