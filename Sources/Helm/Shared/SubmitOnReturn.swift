import SwiftUI

extension View {
    /// **Enter submits, Shift+Enter starts a line** — the two together, on one modifier,
    /// because the second half has to be said and AppKit does not know it.
    ///
    /// `StandardKeyBinding.dict` binds `\r` to `insertNewline:` and `~\r` (Option-Return) to
    /// `insertNewlineIgnoringFieldEditor:`, and it has **no entry for Shift-Return at all**:
    /// shift does not change the character a Return produces, so a shifted Return resolves
    /// through the plain one and `.onSubmit` fires. On a vertical-axis `TextField` that means
    /// Shift+Enter *submits*, and the second line the operator was part-way through typing
    /// never exists. Every agent TUI helm talks to spells the newline this way, so the muscle
    /// memory arrives with the operator.
    ///
    /// **It takes `submit` rather than leaving `.onSubmit` at the call site, and that is the
    /// point of the modifier.** The defect has been found three times here and it was the same
    /// shape every time — a vertical `TextField` carrying `.onSubmit` and nothing beside it:
    /// the chat composer (#119), the Archon rail and the canvas comment field (#278). Supplying
    /// only the missing half would leave the *forgetting* exactly where it was; a caller that
    /// reaches for this cannot take the submit without the newline.
    ///
    /// **`.repeat` is in the phase set, and leaving it out is the same bug again for anyone who
    /// *holds* the chord.** macOS auto-repeats a held key past the repeat delay and SwiftUI
    /// classifies those ticks as `.repeat`; a handler subscribed to `.down` alone does not
    /// merely skip them — they fall through to AppKit exactly as an explicit `.ignored` would,
    /// reach `insertNewline:`, and submit. So the tap is fixed and the hold is not, which is the
    /// worse half: a two-key chord is held more readily than a single key is. A reviewer caught
    /// it on #275 and it was reproduced before it was believed, so every caller's suite has a
    /// held case — `ChatComposerReturnTests`, `ArchonRailReturnTests`,
    /// `CanvasCommentFieldReturnTests`.
    ///
    /// **`insertNewline` is a closure and not the `Binding<String>` this first took, and the
    /// difference is measured rather than stylistic.** A `Binding` handed in here is captured by
    /// the `.onKeyPress` action, and that capture is a **snapshot of the body pass that made
    /// it**: with the rail's field bound to `$model.draft`, typing `first line` and pressing
    /// Shift+Return produced a draft of `"\n"` — the handler's `text.wrappedValue` read `""`
    /// while a closure reading `model.draft` on the same event read `"first line"`. Printed side
    /// by side, on the first run of `ArchonRailReturnTests`. A closure lets the call site reach
    /// its own live storage — `@State`, which reads its box, or an `ObservableObject`, which is
    /// a reference — so the newline lands on the string the operator is actually looking at.
    ///
    /// Returning `.ignored` for everything else is what keeps this from being a second route
    /// around `submit` — plain Enter still travels `.onSubmit`, and ⌥Return still reaches
    /// AppKit's own binding, which inserts **at the caret** where callers append at the end.
    /// That difference is real and is the price of a `TextField` bound to a `String`: SwiftUI
    /// exposes no selection to insert into. It is visible the moment it happens rather than
    /// silent, and ⌥Return is the exact key for the mid-sentence case.
    ///
    /// **`ChatComposer` still spells all of this out inline and should call this instead — #292.**
    /// It is the same five lines and one mechanical edit; it is not made here only because
    /// `Sources/Helm/Chat/` is another slice's file and in flight. Until #292 lands there are two
    /// spellings of one rule, which is the thing this file exists to stop, and **it does not earn
    /// the carve-out** `AGENTS.md` gives `hooks/`/`pi/` and the spool scripts: those are separate
    /// runtimes, and `Chat/` and `Shared/` are the same target under the same `swift build`. So it
    /// carries the obligation every honest duplicate here carries anyway — being **detectable**.
    /// `SubmitOnReturnParityTests` reads both files and fails when the phase set or the shift
    /// guard stops matching, because no behavioural suite can see the *modifier* gaining something
    /// the inline copy never hears about.
    func submitOnReturnInsertNewlineOnShift(
        submit: @escaping () -> Void, insertNewline: @escaping () -> Void
    ) -> some View {
        onSubmit(submit)
            .onKeyPress(.return, phases: [.down, .repeat]) { press in
                guard press.modifiers.contains(.shift) else { return .ignored }
                insertNewline()
                return .handled
            }
    }
}
