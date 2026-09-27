import AppKit

/// Whether the key pop-up is up (#499): the manage key held on its own for a moment.
///
/// **Which-key, not a mode.** Holding the manage key does nothing to the keys themselves: the
/// layer is chords (`ManageKey`), and they fire whether or not the pop-up is showing. The
/// pop-up only answers "what can I press now?" for an operator who paused to ask. So a key
/// pressed before the delay means he knew, and the pop-up stays away until he lets go; a key
/// pressed while it is up keeps it up, so he can watch focus move.
///
/// The decisions are `Phase.next`, pure, so the rules are tested without a window or a clock.
/// This object only carries them out: it starts the delay, and publishes whether to show.
@MainActor
final class ManageHold: ObservableObject {
    static let shared = ManageHold()

    @Published private(set) var phase: Phase = .idle

    var isShowing: Bool { phase == .showing }

    /// How long the manage key is held alone before the pop-up shows. Long enough that a
    /// practised ⌘⌥J never flashes it, short enough that a pause to think does.
    let delay: Duration
    /// Tells a delay that ended from one a release already cancelled.
    private var hold = 0

    init(delay: Duration = .milliseconds(450)) {
        self.delay = delay
    }

    enum Phase: Equatable {
        case idle
        /// Held, and nothing pressed yet: the delay is running.
        case waiting
        /// Held, and a key was pressed before the delay: he did not need it.
        case used
        case showing
    }

    enum Event: Equatable {
        /// The modifiers changed; `held` is whether they are now the manage key (± ⇧).
        case modifiers(held: Bool)
        case key
        case elapsed
        /// helm stopped being the active app: the key-up will never arrive here.
        case resign
    }

    func receive(_ event: Event) {
        let next = phase.next(event)
        if next == .waiting, phase != .waiting { startDelay() }
        if next != .waiting { hold += 1 }
        phase = next
    }

    private func startDelay() {
        hold += 1
        let mine = hold
        Task { [delay] in
            try? await Task.sleep(for: delay)
            guard mine == hold else { return }
            receive(.elapsed)
        }
    }
}

extension ManageHold.Phase {
    func next(_ event: ManageHold.Event) -> Self {
        switch (self, event) {
        case (_, .resign), (_, .modifiers(held: false)): .idle
        case (.idle, .modifiers(held: true)): .waiting
        case (.waiting, .key): .used
        case (.waiting, .elapsed): .showing
        default: self
        }
    }
}
