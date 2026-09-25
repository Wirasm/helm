/// What carries out a binding's action.
///
/// A `.verb` action is resolved against the bench and sent through the `VerbSink` as the
/// operator; a `.local` one is carried out by whoever owns what it touches. `RootView`
/// composes the one that does both (`LocalActions`), because it holds every owner.
@MainActor
protocol ActionPerformer: AnyObject {
    func perform(_ action: KeyBinding.Action)
}

/// The one place the keymap monitor, the menu and a view's button hand an action to.
///
/// **A single typed target, not a broadcast.** This replaces `HelmCommand`'s NotificationCenter
/// channel, where every subscriber saw every command and each picked out its own; now exactly
/// one performer is asked, and a new action is a compile error there until it has a route.
@MainActor
enum Actions {
    /// The window's performer. Weak because `RootView` owns it; nil before the window mounts,
    /// when a key has nothing to act on anyway.
    static weak var performer: (any ActionPerformer)?

    static func perform(_ action: KeyBinding.Action) {
        performer?.perform(action)
    }
}
