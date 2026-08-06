import AppKit
import HelmWire
import QuartzCore
import XCTest

@testable import Helm

/// helm drawing itself, checked by reading the pixels back.
///
/// **These assertions are about an image, which is unusual, and it is the point.** #174 exists
/// because every agent that touched a surface ended with *"I could not see it, you should
/// look"*, and a capture feature verified only by "a file appeared" would reproduce exactly
/// that gap one level down. So the image is decoded and sampled: the chrome is really there,
/// the region the terminal occupies is really marked, and the marker is on the right half of a
/// flipped view rather than the wrong one.
///
/// **Nothing here needs a window, a display, a Metal device or a grant.** That is the same
/// claim the feature makes, tested the only way it can honestly be tested — a suite that
/// needed a screen would be asserting the opposite of what it is for.
@MainActor
final class WindowCaptureTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("helm-capture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: scratch)
        scratch = nil
    }

    // MARK: - Fixtures

    /// A flipped, self-drawing view — `NSHostingView` is flipped, so a test on an unflipped one
    /// would pass while production drew its marker upside down.
    private final class Pane: NSView {
        let colour: NSColor
        init(frame: NSRect, colour: NSColor) {
            self.colour = colour
            super.init(frame: frame)
        }
        required init?(coder: NSCoder) { fatalError("not used") }
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            colour.setFill()
            bounds.fill()
        }
    }

    /// A view backed by a `CAMetalLayer`, which is what helm's terminal is. No device is set
    /// and none is needed: the point is that `cacheDisplay` produces nothing for it either way.
    private final class MetalPane: NSView {
        override func makeBackingLayer() -> CALayer { CAMetalLayer() }
    }

    private func metalPane(_ frame: NSRect) -> MetalPane {
        let pane = MetalPane(frame: frame)
        pane.wantsLayer = true
        return pane
    }

    private func png(
        of view: NSView, terminals: [NSView] = [], name: String = "shot.png"
    ) throws -> (CaptureReport, NSBitmapImageRep) {
        let url = scratch.appendingPathComponent(name)
        let report = try WindowCapture.png(
            of: view, terminals: terminals, window: "helm — test", appearance: .light, to: url
        ).get()
        let rep = try XCTUnwrap(
            NSBitmapImageRep(data: try Data(contentsOf: url)), "the PNG did not decode")
        return (report, rep)
    }

    /// The colour at a point in *view* coordinates, read out of the decoded PNG.
    private func colour(
        _ rep: NSBitmapImageRep, at point: NSPoint, scale: Double
    ) throws
        -> NSColor
    {
        let pixel = try XCTUnwrap(
            rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale)),
            "no pixel at \(point)")
        return try XCTUnwrap(pixel.usingColorSpace(.sRGB))
    }

    private func assertSame(
        _ lhs: NSColor, _ rhs: NSColor, _ message: String, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (a, b) in [
            (lhs.redComponent, rhs.redComponent), (lhs.greenComponent, rhs.greenComponent),
            (lhs.blueComponent, rhs.blueComponent),
        ] {
            XCTAssertEqual(a, b, accuracy: 0.02, message, file: file, line: line)
        }
    }

    // MARK: - Drawing

    func testAViewIsDrawnIntoAPngWithNoGrantOfAnyKind() throws {
        // The acceptance criterion, at the level this type can answer it: pixels come out, and
        // nothing was asked of TCC to get them. `CGWindowListCreateImage` would need the grant
        // an agent cannot have; `cacheDisplay` needs nothing.
        let accent = Palette.helm.accent.nsColor(in: .light)
        let view = Pane(frame: NSRect(x: 0, y: 0, width: 200, height: 100), colour: accent)

        let (report, rep) = try png(of: view)
        XCTAssertEqual(report.pixelWidth, Int(200 * report.scale))
        XCTAssertEqual(report.pixelHeight, Int(100 * report.scale))
        XCTAssertEqual(report.window, "helm — test")
        assertSame(
            try colour(rep, at: NSPoint(x: 100, y: 50), scale: report.scale), accent,
            "the middle of the capture should be the colour the view drew")
    }

    func testAWindowWithNoTerminalSaysNothingIsMissingFromTheImage() throws {
        let view = Pane(
            frame: NSRect(x: 0, y: 0, width: 120, height: 60),
            colour: Palette.helm.surface.nsColor(in: .light))
        let (report, _) = try png(of: view)
        // `absent` rather than `excluded`: there was nothing to leave out, so a caller reading
        // this one is not being warned about a hole that does not exist.
        XCTAssertEqual(report.terminalContent, .absent)
        XCTAssertEqual(report.terminalSurfaces, 0)
    }

    func testAZeroSizedViewIsRefusedRatherThanProducingAnEmptyPng() {
        let view = Pane(frame: .zero, colour: .black)
        guard
            case .failure(let refusal) = WindowCapture.png(
                of: view, terminals: [], window: "helm", appearance: .light,
                to: scratch.appendingPathComponent("empty.png"))
        else { return XCTFail("a 0×0 view must not produce a capture") }
        XCTAssertTrue(refusal.reason.contains("nothing to draw"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: scratch.appendingPathComponent("empty.png").path),
            "and no file is left behind for a caller to find and trust")
    }

    // MARK: - Whether the terminal made it in

    func testAMetalLayerIsNotReproducibleAndAnIOSurfaceBackedOneIs() {
        // **The correction that cost a wrong answer.** #174 scoped this expecting every
        // terminal to be a `CAMetalLayer`, and the first build asked exactly that question — so
        // a capture with legible terminal text in it reported `terminalContent: absent`,
        // because ghostty had already swapped the backing layer for IOSurface compositing
        // (`AppTerminalView+Lifecycle.swift:176`). Both states are real, so both are pinned.
        XCTAssertFalse(
            WindowCapture.isReproducible(metalPane(NSRect(x: 0, y: 0, width: 10, height: 10))))

        // A layer holding an image is what an IOSurface-backed one looks like from here: it has
        // `contents`, and the layer tree draws it.
        let composited = Pane(frame: NSRect(x: 0, y: 0, width: 10, height: 10), colour: .white)
        composited.wantsLayer = true
        composited.layer?.contents = NSImage(size: NSSize(width: 10, height: 10))
        XCTAssertTrue(WindowCapture.isReproducible(composited))

        // And one that has not rendered yet has no contents, so drawing it would produce a
        // blank pane indistinguishable from a real empty terminal. That is excluded too.
        let unrendered = Pane(frame: NSRect(x: 0, y: 0, width: 10, height: 10), colour: .white)
        unrendered.wantsLayer = true
        XCTAssertFalse(WindowCapture.isReproducible(unrendered))
    }

    func testTheFourAnswersAreDistinctBecauseAMixedBenchIsOrdinary() {
        // A bench with one rendered pane and one that has just opened is the common case, not
        // an exotic one, and collapsing it into either "included" or "excluded" is a lie about
        // half the image.
        XCTAssertEqual(WindowCapture.content(of: 0, missing: 0), .absent)
        XCTAssertEqual(WindowCapture.content(of: 3, missing: 0), .included)
        XCTAssertEqual(WindowCapture.content(of: 3, missing: 3), .excluded)
        XCTAssertEqual(WindowCapture.content(of: 3, missing: 1), .partial)
    }

    func testATerminalInAnotherWindowIsNotCountedAgainstThisCapture() throws {
        // helm's manager lists every session in the app, not the ones in this window. Counting
        // a pane the caller cannot possibly see would make the report wrong about the image it
        // describes.
        let root = Pane(frame: NSRect(x: 0, y: 0, width: 200, height: 100), colour: .white)
        let mine = metalPane(NSRect(x: 0, y: 0, width: 200, height: 40))
        root.addSubview(mine)
        let elsewhere = metalPane(NSRect(x: 0, y: 0, width: 200, height: 40))

        let (report, _) = try png(of: root, terminals: [mine, elsewhere])
        XCTAssertEqual(report.terminalSurfaces, 1)
        XCTAssertEqual(report.terminalContent, .excluded)
        XCTAssertEqual(report.terminalSurfacesExcluded, 1)
    }

    func testTheExcludedRegionIsMarkedInTheImageAndOnTheCorrectHalfOfAFlippedView() throws {
        // **The flip is the bug this test exists for.** A bitmap context is y-up from its
        // bottom-left; an `NSHostingView` is y-down from its top-left. Get that wrong and the
        // marker covers the chrome while the blank terminal is left looking like a real one —
        // a picture that lies in both directions at once.
        let surface = Palette.helm.surface.nsColor(in: .light)
        let root = Pane(frame: NSRect(x: 0, y: 0, width: 200, height: 100), colour: surface)
        // In a flipped view this is the TOP 40 points.
        let terminal = metalPane(NSRect(x: 0, y: 0, width: 200, height: 40))
        root.addSubview(terminal)

        let (report, rep) = try png(of: root, terminals: [terminal])
        assertSame(
            try colour(rep, at: NSPoint(x: 100, y: 20), scale: report.scale),
            Palette.helm.surfaceRaised.nsColor(in: .light),
            "the top of the image is where the terminal is, and it must carry the marker")
        assertSame(
            try colour(rep, at: NSPoint(x: 100, y: 80), scale: report.scale), surface,
            "the bottom is chrome, and must be left exactly as helm drew it")
    }

    func testAReproducibleTerminalIsLeftAloneRatherThanPaintedOver() throws {
        // The other half, and the one the marker could quietly destroy: a pane whose cells DID
        // come out must not be covered by a label saying they did not.
        let surface = Palette.helm.surface.nsColor(in: .light)
        let root = Pane(frame: NSRect(x: 0, y: 0, width: 200, height: 100), colour: surface)
        let accent = Palette.helm.accent.nsColor(in: .light)
        let terminal = Pane(frame: NSRect(x: 0, y: 0, width: 200, height: 40), colour: accent)
        terminal.wantsLayer = true
        terminal.layer?.contents = NSImage(size: NSSize(width: 200, height: 40))
        root.addSubview(terminal)

        let (report, rep) = try png(of: root, terminals: [terminal])
        XCTAssertEqual(report.terminalContent, .included)
        XCTAssertEqual(report.terminalSurfacesExcluded, 0)
        assertSame(
            try colour(rep, at: NSPoint(x: 100, y: 20), scale: report.scale), accent,
            "what the pane drew is what the capture shows")
    }

    func testTheMarkerFollowsTheAppearanceItWasGiven() throws {
        // A capture of a dark helm must not be marked in light colours. There is no drawing
        // appearance current when rendering into a bitmap, so this is passed in rather than
        // resolved — and `nsColor(in:)` exists precisely so it cannot be resolved by accident.
        let root = Pane(frame: NSRect(x: 0, y: 0, width: 100, height: 40), colour: .white)
        let terminal = metalPane(root.bounds)
        root.addSubview(terminal)
        let url = scratch.appendingPathComponent("dark.png")
        _ = try WindowCapture.png(
            of: root, terminals: [terminal], window: "helm", appearance: .dark, to: url
        ).get()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try Data(contentsOf: url)))
        let scale = Double(rep.pixelsWide) / 100
        assertSame(
            try colour(rep, at: NSPoint(x: 50, y: 20), scale: scale),
            Palette.helm.surfaceRaised.nsColor(in: .dark), "marked in the dark palette")
    }
}
