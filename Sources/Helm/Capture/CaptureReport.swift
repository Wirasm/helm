import Foundation

/// What a capture actually contains — computed from the view tree, never asserted.
///
/// **The honesty is the feature.** #174 says it in as many words: *"a PNG with a blank terminal
/// that does not announce itself is worse than no PNG"*. Every field here exists so a caller
/// who has only the result file, and a caller who has only the image, both learn the same
/// thing.
///
/// The value `WindowCapture` produces and helm hands to benchd as its answer to `bench get
/// screenshot` (`HelmAsks`), which the agent reads as JSON.
struct CaptureReport: Codable, Equatable {
    /// Where the PNG is. Absolute.
    let path: String
    let pixelWidth: Int
    let pixelHeight: Int
    /// Backing scale — 2 on a retina display, so `pixelWidth / scale` is the size in points a
    /// layout assertion would be written against.
    let scale: Double
    /// The window that was drawn, by title. With `HELM_DEFAULTS_SUITE` set that reads
    /// `helm — <suite>`, which is how a caller tells its own instance from the operator's.
    let window: String
    /// Whether any part of that window was visible on a display when it was drawn — AppKit's
    /// `occlusionState` containing `.visible`, read per capture (#408).
    ///
    /// **`false` means the web content in the PNG may not be real.** A locked screen or a
    /// window fully covered by another leaves helm's window occluded, and WebKit suspends an
    /// occluded page's web process and marks its layers volatile within seconds. `cacheDisplay`
    /// then draws what a suspended `WKWebView` holds, which is nothing: a canvas that is loaded
    /// and fine comes out as a blank page, with the header above it drawn normally. Terminals
    /// are unaffected — their layers are in-process — which is why this is about the window and
    /// not a per-pane count. helm does not try to force WebKit to paint; the suspension is WebKit
    /// working as designed, and the report saying so is the fix.
    let windowVisible: Bool
    let terminalContent: TerminalContent
    /// How many terminal panes were on the bench in this window. `terminalContent` is `.absent`
    /// exactly when this is zero.
    let terminalSurfaces: Int
    /// How many of them could **not** be drawn. Zero on `.included`, all of them on
    /// `.excluded`, and the reason `.partial` exists as a case at all.
    let terminalSurfacesExcluded: Int

    init(
        path: String, pixelWidth: Int, pixelHeight: Int, scale: Double, window: String,
        windowVisible: Bool, terminalContent: TerminalContent, terminalSurfaces: Int,
        terminalSurfacesExcluded: Int
    ) {
        self.path = path
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.window = window
        self.windowVisible = windowVisible
        self.terminalContent = terminalContent
        self.terminalSurfaces = terminalSurfaces
        self.terminalSurfacesExcluded = terminalSurfacesExcluded
    }
}

/// Whether terminal cells are in the PNG.
///
/// **`.included` is earned per capture, never assumed.** #174 scoped this feature expecting the
/// answer to always be no — *"the terminal is a Metal-layer NSView, so Metal content does not
/// come out of `CALayer.render(in:)`"* — and that premise is right about `CAMetalLayer` and
/// wrong about what helm actually runs. The vendored wrapper says so itself: *"the render
/// pipeline can swap `self.layer` to an IOSurfaceLayer for IOSurface-backed compositing"*
/// (`AppTerminalView+Lifecycle.swift:176`). An IOSurface-backed layer has real `contents`, and
/// the layer tree draws it.
///
/// So the question is asked of **each surface at capture time** rather than answered once here.
/// Both states are reachable in one process — a pane that has not rendered yet is still a
/// `CAMetalLayer` — which is exactly why `.partial` is a case rather than an impossibility.
enum TerminalContent: String, Codable {
    /// No terminal pane in the window at all, so nothing is missing from the image.
    case absent
    /// Every terminal pane's cells are in the PNG.
    case included
    /// No terminal pane's cells are. Their regions carry a marker in the PNG itself.
    case excluded
    /// Some are and some are not. The ones that are not carry the marker; the ones that are
    /// are untouched.
    case partial
}
