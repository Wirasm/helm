import AppKit
import HelmWire
import QuartzCore

/// helm drawing its own window into a bitmap.
///
/// **`CaptureReport` and `TerminalContent` — the values this produces — live in `HelmWire`
/// (#221), not here.** They cross into `SpoolResult.capture`, which `Helm`'s own `SpoolModel`
/// writes and `WindowCaptureTests` decodes without linking AppKit; this file keeps the drawing
/// itself, which needs `NSView`/`CALayer` and has no business in a library only `Helm` depends
/// on. `tools/helm-capture.swift` still reads the result back as a raw dictionary — it cannot
/// `import HelmWire` either, for the reasons `AGENTS.md`'s "Why the spool is a script, and must
/// stay one" gives — and `SpoolWireConformanceTests` watches both its request and its result
/// handling, the latter by writing a real `SpoolResult` for every `Status` and checking the
/// script's exit code and stderr against it.
///
/// **This is drawing, not screen capture, and that is the whole point of #174.** Screen
/// Recording is a TCC grant: un-grantable from code, keyed on the code signature, and attached
/// to the *invoking context* — so an agent running a fresh ad-hoc `winshot` binary fails even
/// on a machine where the operator has granted everything they can see to grant. An app
/// rendering its own view hierarchy is gated by none of that. Nothing here touches
/// `CGWindowListCreateImage`, `ScreenCaptureKit` or any other capture API, and that is the
/// property to preserve: the moment one appears, this needs a grant again.
///
/// **`cacheDisplay` rather than `CALayer.render(in:)`, measured before it was chosen.** Both
/// draw the layer tree with no grant; both leave a `CAMetalLayer` blank. `render(in:)` also
/// comes out **vertically flipped** against an `NSHostingView`, because the layer's geometry
/// is y-up and the hosting view is y-down — a capture that is upside down is a capture nobody
/// trusts. `cacheDisplay` is AppKit's own draw-yourself path and needs no transform.
enum WindowCapture {
    /// Text below this many points high has nowhere to go, so the region gets its fill and
    /// border and no label.
    private static let labelFloor: CGFloat = 28

    /// Draw `view` and everything under it into a PNG at `url`.
    ///
    /// **`terminals` is passed in rather than discovered, and that is the correction #174's own
    /// scoping needed.** Sniffing the view tree for `CAMetalLayer` looks like the general
    /// answer and is a wrong one: once ghostty swaps a surface to an IOSurface-backed layer the
    /// scan finds nothing, and a capture full of legible terminal text reported
    /// `terminalContent: absent` — a false claim about the window, in the one direction that
    /// matters. helm knows its own panes (`TerminalManager.sessions`), so it is asked instead
    /// of guessed at.
    ///
    /// A `Result` rather than a throw so the refusal reason travels the same path every other
    /// spool answer does, and reaches `results/<id>.json` as prose a caller can act on.
    @MainActor
    static func png(
        of view: NSView, terminals: [NSView], window title: String,
        appearance: Palette.Appearance, to url: URL
    ) -> Result<CaptureReport, SpoolRefusal> {
        // Laid out and drawn before it is asked for pixels: a window that has never been
        // displayed has a view tree with no frames, and the capture would be a correct
        // rendering of nothing.
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()

        let bounds = view.bounds
        guard bounds.width >= 1, bounds.height >= 1 else {
            return .failure(
                SpoolRefusal(
                    "the window's content view is \(Int(bounds.width))×\(Int(bounds.height)) "
                        + "points — there is nothing to draw"))
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else {
            return .failure(
                SpoolRefusal("AppKit would not give helm a bitmap for a \(bounds) view"))
        }
        view.cacheDisplay(in: bounds, to: rep)

        let scale = Double(rep.pixelsWide) / Double(bounds.width)
        let present = terminals.filter { $0.isDescendant(of: view) }
        let missing = present.filter { !isReproducible($0) }
        // **1 point == 1 pixel from here on.** `NSGraphicsContext(bitmapImageRep:)` derives its
        // user space from the rep's `size`, so pinning `size` to the pixel count is what stops
        // the marker landing at half scale on a retina display — the one bug this geometry has.
        rep.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        mark(
            missing.map { $0.convert($0.bounds, to: view) }, in: rep, of: view, scale: scale,
            appearance: appearance)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            return .failure(SpoolRefusal("the bitmap could not be encoded as a PNG"))
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            return .failure(
                SpoolRefusal(
                    "could not write the PNG to \(url.path): \(error.localizedDescription)")
            )
        }
        return .success(
            CaptureReport(
                path: url.path, pixelWidth: rep.pixelsWide, pixelHeight: rep.pixelsHigh,
                scale: scale, window: title,
                terminalContent: content(of: present.count, missing: missing.count),
                terminalSurfaces: present.count, terminalSurfacesExcluded: missing.count))
    }

    static func content(of surfaces: Int, missing: Int) -> TerminalContent {
        switch (surfaces, missing) {
        case (0, _): .absent
        case (_, 0): .included
        case let (all, gone) where gone == all: .excluded
        default: .partial
        }
    }

    /// Whether this surface's pixels come out of the layer tree.
    ///
    /// **Two conditions, and both were paid for.** A `CAMetalLayer` renders into a drawable that
    /// is never the layer's `contents`, so `cacheDisplay` produces nothing for it — measured
    /// against a real one before this was written. But ghostty swaps the backing layer to an
    /// IOSurface-backed one once compositing starts, and that one *does* draw — so a class
    /// check alone reports "no terminal here" about a capture full of legible terminal text.
    ///
    /// `contents` is the second condition because a layer that has not rendered yet has none,
    /// and drawing it would produce a blank pane that looks exactly like a real empty one.
    /// Asking what the layer actually holds is the only form of this question that cannot be
    /// wrong in either direction.
    static func isReproducible(_ view: NSView) -> Bool {
        guard let layer = view.layer else { return false }
        if layer is CAMetalLayer { return false }
        return layer.contents != nil
    }

    /// Paint over each region helm could not draw, so the image says what the result file says.
    ///
    /// **A caller who only looks at the PNG must not be fooled either.** An unmarked Metal
    /// region reads as an empty terminal — a plausible, wrong answer, which is the shape this
    /// codebase keeps removing. A flat fill would read the same way, so the marker carries its
    /// sentence.
    private static func mark(
        _ regions: [NSRect], in rep: NSBitmapImageRep, of view: NSView, scale: Double,
        appearance: Palette.Appearance
    ) {
        guard !regions.isEmpty, let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return
        }
        let fill = Palette.helm.surfaceRaised.nsColor(in: appearance)
        let ink = Palette.helm.textMuted.nsColor(in: appearance)
        let height = view.bounds.height

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for region in regions {
            // The bitmap context is y-up with its origin bottom-left; an `NSHostingView` is
            // y-down. Asked of the view rather than assumed, because the root of a capture is
            // not always a hosting view.
            let top = view.isFlipped ? height - region.maxY : region.minY
            let pixels = NSRect(
                x: region.minX * scale, y: top * scale,
                width: region.width * scale, height: region.height * scale)
            fill.setFill()
            pixels.fill()
            ink.setStroke()
            NSBezierPath(rect: pixels.insetBy(dx: scale, dy: scale)).stroke()

            guard pixels.height >= labelFloor * scale else { continue }
            let label = NSAttributedString(
                string: "terminal content not captured",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11 * scale, weight: .regular),
                    .foregroundColor: ink,
                ])
            let size = label.size()
            guard size.width <= pixels.width else { continue }
            label.draw(
                at: NSPoint(x: pixels.midX - size.width / 2, y: pixels.midY - size.height / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
