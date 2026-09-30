import AppKit
import Combine

extension KeyFocus {
    /// Where the keyboard is right now: a terminal, a browser pane, or neither. Asked at the
    /// moment of a keystroke, synchronously, which is all the key monitor needs.
    @MainActor
    static func current(terminals: TerminalManager = .shared) -> KeyFocus {
        if terminals.anyTerminalHasFocus { return .terminal }
        if BrowserKeyboard.holder() != nil { return .browser }
        return .other
    }
}

/// Publishes the one thing the hints turn on: what holds the keyboard (`KeyFocus`).
///
/// `KeyFocus.current` already answers it, and answers it *synchronously* — which is all the
/// key monitor ever needed, since it asks at the moment of a keystroke. A pop-up that draws the
/// answer needs to be told when it changes, and AppKit publishes no first-responder
/// notification, so this listens to the window updates that bracket one and re-asks. It lives
/// in this slice because the key pop-up is the only surface that wants focus as a *published*
/// value.
///
/// **It republishes only on change**, which is what keeps `didUpdate` — a notification that
/// fires freely — from touching SwiftUI at all while the operator types. The check itself
/// is a key-window read and a walk of the open sessions.
///
/// The honest limit: if AppKit ever moves first responder without a window update, the
/// pop-up is briefly stale. That costs a wrong glyph in a hint until the next event, and
/// nothing else — the keymap is not driven from here, so what the operator presses still
/// does what the map says.
@MainActor
final class KeyFocusWatch: ObservableObject {
    @Published private(set) var focus: KeyFocus

    private let manager: TerminalManager
    /// `AnyCancellable` rather than notification tokens: it unsubscribes on dealloc by
    /// itself, where removing observers would mean touching main-actor state from `deinit`.
    private var subscriptions: Set<AnyCancellable> = []

    init(manager: TerminalManager = .shared) {
        self.manager = manager
        focus = KeyFocus.current(terminals: manager)

        for name in [
            // Posted after a window handles an event — the only public signal that brackets
            // a first-responder change, which is what a click into the grid is.
            NSWindow.didUpdateNotification,
            // Key changes do not always produce the above, and they move focus wholesale.
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
                .store(in: &subscriptions)
        }
    }

    private func refresh() {
        let now = KeyFocus.current(terminals: manager)
        guard now != focus else { return }
        focus = now
    }
}
