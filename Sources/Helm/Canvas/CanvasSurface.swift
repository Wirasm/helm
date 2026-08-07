import Foundation

/// **A region of a page where the pointer is the page's, not helm's** (#111).
///
/// An artifact declares one by putting `data-helm-surface` on an element; helm's annotation
/// script then does nothing at all inside it — no `preventDefault`, no stroke, no `cleared`
/// message, and no anchor resolved out of it.
///
/// ## The collision this settles, measured rather than assumed
///
/// A drawable canvas — `@quickdrawjs/core` mounted in an `.html` artifact — is two drawing
/// layers on one page, and helm's is injected into every `.html` artifact including one read
/// straight from disk. Both halves were read in source before this was designed, and **the
/// first reading of the collision was wrong in mechanism**, which is worth recording because it
/// changes what the fix has to be:
///
/// - The brief said helm's `mousedown` handler — `e.preventDefault()` in the **capture** phase
///   (`canvas-annotation.js`, the mark-tool branch) — would stop the board receiving the
///   pointer at all. It does not. quickdraw listens on `pointerdown`/`pointermove`/`pointerup`
///   (`quickdraw/editor.js:425-428`) and **never cancels `pointerdown`**
///   (`_pointerDown`, `editor.js:449`), and a `pointerdown` is dispatched *before* its
///   compatibility `mousedown`. So helm cancelling the `mousedown` cancels the browser's
///   defaults for that event — focus, text-selection drag — and nothing else. The board draws.
/// - What actually happens with a mark tool held is therefore **worse than a dead surface: both
///   layers draw.** quickdraw commits a real `draw` record and helm lays its own SVG ink over
///   the top at `z-index: 2147483647`.
/// - And helm's ink cannot name what it circled. `targetsInside` ranks **DOM elements**; a
///   mounted board is one `<canvas>` with no per-shape nodes in the tree at all, so an
///   enclosure over a board resolves to the board's container — a 400-character quote of the
///   toolbar's button labels, anchored to an id that names the whole board.
/// - The unambiguous half needs no correction: with the text tool held, a drag over the board
///   leaves `document.getSelection()` collapsed, so `mouseup` posts `{kind: "cleared"}`, which
///   dismisses the operator's selection and closes the notes drawer. **Every stroke closes
///   their notes.** That tool was `.select` and was the *default* when this was written, so the
///   collision was met by an operator who had chosen nothing; #302 split it into `.read` and
///   `.text` and made `.read` the default, which moves the collision off the default path and
///   removes none of it. **The two are different mechanisms and neither implies the other** —
///   `.read` is a global mode the operator holds, this is a per-artifact declaration that binds
///   whatever they are holding. A board is broken again the moment anyone picks up `.text`,
///   which is precisely when they are most likely to.
///
/// ## The rule, in one sentence
///
/// **Inside a declared surface the page owns the pointer and helm names nothing.**
///
/// Not "helm draws less", not "helm defers to whichever layer moved first" — helm is simply not
/// there. The second half of that sentence is the part that is easy to drop and is not
/// optional: yielding the *pointer* while still resolving *anchors* out of the region would
/// leave the enclosure above reporting a board's container id, which is the failure that has no
/// visible symptom.
///
/// **helm's mark layer is strictly worse on a board, and that is why it yields the whole
/// region rather than sharing it.** The board has its own selection model, its own undo, its
/// own persistence, and — the part that decides it — its own **ids**, caller-supplied and never
/// regenerated on load. A stroke on the board becomes a record with an id, resolvable by
/// bounding-box overlap against the shapes the agent authored, and it reaches the agent through
/// the state latch (#110) as a name the agent can find again. helm's ink over the same gesture
/// reaches the agent as a quote of a toolbar. Circling a shape with helm's ink on a board that
/// has its own selection model is not a smaller version of the right answer; it is a different
/// and worse one.
///
/// ## Why an attribute, and why the *page* writes this one
///
/// `data-helm-frame` and `data-helm-mark` are helm marking helm's own chrome so the script can
/// skip it. This is the same shape pointed the other way: the page marking the page's own
/// surface so the script can skip that too. The argument for a marker over anything the script
/// could infer is `helmFrame`'s and is unchanged — *"an attribute helm itself writes cannot be
/// wrong in either direction"*, and here an attribute the **author** writes cannot be wrong
/// either, because declaring it is the author saying what they mean. The inference this
/// replaces would have been "is the target a `<canvas>`", which is wrong for every artifact
/// that draws a chart it would still like the operator to be able to circle.
///
/// **helm never reads this attribute in Swift.** It is a fact about the DOM, consumed entirely
/// by `Resources/canvas-annotation.js`, and it is declared here for one reason: so that the
/// spelling has a single home with the argument attached, and so a test can hold every copy of
/// it to that home. That is the same job `CanvasHTML.markToolGlobal` does for a global helm
/// only ever writes.
///
/// **Three copies exist and a JavaScript file cannot compile against a Swift constant**, so the
/// gate is a test that reads all three — `CanvasSurfaceTests
/// .testEveryHalfOfTheSurfaceSeamStillSpellsItTheSameWay`, on
/// `CanvasAnnotationScriptTests`' pattern:
///
/// 1. this constant,
/// 2. `Sources/Helm/Resources/canvas-annotation.js`, which yields on it,
/// 3. `.claude/skills/helm-board/board.html`, the artifact template that declares it — the far
///    side of the seam, and the reason this is a *contract* rather than a constant with one
///    reader. A board template that stopped writing the attribute would be a board whose every
///    stroke closed the operator's notes, with nothing on helm's side changed and every Swift
///    test green.
enum CanvasSurface {
    /// The attribute an artifact puts on an element to claim the pointer inside it.
    ///
    /// A bare attribute with no value, like `data-helm-frame`: there is nothing to configure,
    /// and a value would be a second thing to agree about across a seam that already needs a
    /// test to hold one.
    static let attribute = "data-helm-surface"

    /// The attribute as a CSS attribute selector, which is how the script asks the question
    /// (`closest(…)`). Derived rather than spelled a second time — the two would be a pair to
    /// keep in step for no gain, which is the defect this file exists to argue against.
    static let selector = "[\(attribute)]"
}
