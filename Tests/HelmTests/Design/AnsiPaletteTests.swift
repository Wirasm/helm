import XCTest

@testable import Helm

/// The sixteen, checked for the two things that make them safe to own.
///
/// helm took these off the operator, so the burden is now helm's: a program that says "red"
/// has to still get something a reader calls red without stopping, and a program that says
/// "yellow" has to still be legible against helm's surface rather than merely present. Both
/// are rules, both are cheap to check, and neither is visible in a diff of hex values.
final class AnsiPaletteTests: XCTestCase {
    private let ansi = AnsiPalette.helm
    private let surface = Palette.helm.surface

    /// The hue band each family must stay inside, in degrees. Wide enough that tuning has
    /// room, narrow enough that a family cannot wander into its neighbour — `git diff`'s red
    /// and green are the load-bearing case, and they are opposite ends of the wheel.
    private var bands: [(name: String, token: Palette.Token, band: ClosedRange<Double>)] {
        [
            ("red", ansi.red, -20...20), ("bright red", ansi.brightRed, -20...20),
            ("yellow", ansi.yellow, 30...65), ("bright yellow", ansi.brightYellow, 30...65),
            ("green", ansi.green, 70...160), ("bright green", ansi.brightGreen, 70...160),
            ("cyan", ansi.cyan, 155...200), ("bright cyan", ansi.brightCyan, 155...200),
            ("blue", ansi.blue, 190...250), ("bright blue", ansi.brightBlue, 190...250),
            ("magenta", ansi.magenta, 260...330),
            ("bright magenta", ansi.brightMagenta, 260...330),
        ]
    }

    private var greys: [(name: String, token: Palette.Token)] {
        [
            ("black", ansi.black), ("white", ansi.white),
            ("bright black", ansi.brightBlack), ("bright white", ansi.brightWhite),
        ]
    }

    // MARK: - Hue identity

    /// **The promise made when helm took these over.** Lightness and chroma were retuned to
    /// helm's surface; the hue angle was not allowed to move. Red reads as red.
    func testEveryFamilyKeepsItsHue() {
        for appearance in Palette.Appearance.allCases {
            for (name, token, band) in bands {
                let hue = ColorMath.hue(token.value(in: appearance))
                XCTAssertTrue(
                    ColorMath.hue(hue, isWithin: band),
                    "\(name) in \(appearance) is at \(Int(hue))°, outside \(band)"
                )
            }
        }
    }

    /// The four greys are the dim/quiet pair in both weights, and a grey with a hue is a
    /// tint nobody asked for. A little is deliberate — they lean with the surface.
    func testTheGreysStayGrey() {
        for appearance in Palette.Appearance.allCases {
            for (name, token) in greys {
                let saturation = ColorMath.saturation(token.value(in: appearance))
                XCTAssertLessThan(
                    saturation, 0.2, "\(name) in \(appearance) is a colour, not a grey")
            }
        }
    }

    // MARK: - Legibility

    /// The six families are text — `git diff`, a test runner's pass and fail, a compiler
    /// error — so they carry the ordinary body-text floor against helm's surface.
    func testEveryColourIsReadableOnTheSurface() {
        for appearance in Palette.Appearance.allCases {
            for (name, token, _) in bands where !name.hasPrefix("bright") {
                let ratio = ColorMath.contrast(token, on: surface, in: appearance)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name) in \(appearance): \(ratio)")
            }
        }
    }

    /// The bright weights are emphasis rather than body — bold, a highlighted match — and on
    /// a LIGHT surface "brighter" and "more readable" pull in opposite directions. They keep
    /// the non-text floor instead, which is the honest bar for what they are used for.
    func testEveryBrightColourClearsTheEmphasisFloor() {
        for appearance in Palette.Appearance.allCases {
            for (name, token, _) in bands where name.hasPrefix("bright") {
                let ratio = ColorMath.contrast(token, on: surface, in: appearance)
                XCTAssertGreaterThanOrEqual(ratio, 3, "\(name) in \(appearance): \(ratio)")
            }
        }
    }

    /// `white` is what a program dims to — it has to be readable. `black` is what it dims
    /// *past*, and on a dark surface it is supposed to nearly disappear, so it is exempt
    /// from the floor and only has to be separable from the background at all.
    func testTheGreysAreReadableWhereTheyAreMeantToBe() {
        for appearance in Palette.Appearance.allCases {
            XCTAssertGreaterThanOrEqual(
                ColorMath.contrast(ansi.white, on: surface, in: appearance), 4.5,
                "white in \(appearance)")
            XCTAssertGreaterThanOrEqual(
                ColorMath.contrast(ansi.brightWhite, on: surface, in: appearance), 4.5,
                "bright white in \(appearance)")
            XCTAssertGreaterThan(
                ColorMath.contrast(ansi.black, on: surface, in: appearance), 1.2,
                "black in \(appearance) has to be visible, just barely")
        }
    }

    // MARK: - Shape

    /// A bright weight that equals its base is one wasted index and one program that cannot
    /// emphasise anything.
    func testBrightIsAlwaysADifferentColourFromItsBase() {
        let pairs = [
            ("black", ansi.black, ansi.brightBlack), ("red", ansi.red, ansi.brightRed),
            ("green", ansi.green, ansi.brightGreen), ("yellow", ansi.yellow, ansi.brightYellow),
            ("blue", ansi.blue, ansi.brightBlue), ("magenta", ansi.magenta, ansi.brightMagenta),
            ("cyan", ansi.cyan, ansi.brightCyan), ("white", ansi.white, ansi.brightWhite),
        ]
        for (name, base, bright) in pairs {
            XCTAssertNotEqual(base, bright, "\(name) and bright \(name) are the same colour")
        }
    }

    /// `ordered` is what renders as `palette = N=…`, so an index that is wrong or missing is
    /// a colour silently assigned to the wrong slot — the kind of thing that looks like a
    /// theme choice rather than a bug.
    func testOrderedCoversZeroThroughFifteenExactlyOnce() {
        XCTAssertEqual(ansi.ordered.map(\.index), Array(0...15))
        XCTAssertEqual(Set(ansi.ordered.map(\.name)).count, 16, "duplicate name in ordered")
    }
}
