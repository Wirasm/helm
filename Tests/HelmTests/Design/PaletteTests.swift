import XCTest

@testable import Helm

/// The palette, checked as values — which is the whole reason it is one.
///
/// Two kinds of assertion here, and they guard different things. The hex pins say the chat
/// face did not move a pixel when its five colours were promoted to the app's. The contrast
/// ratios say the next person to retune a token cannot quietly make helm unreadable in one
/// appearance while it still looks fine in the other they happened to be running.
final class PaletteTests: XCTestCase {
    private let palette = Palette.helm

    // MARK: - Hex

    func testHexRoundTripsLowercaseAndPadded() {
        XCTAssertEqual(Palette.RGB(hex: 0xFB_FA_F8).hex, "#fbfaf8")
        XCTAssertEqual(Palette.RGB(hex: 0x00_00_00).hex, "#000000")
        XCTAssertEqual(Palette.RGB(hex: 0xFF_FF_FF).hex, "#ffffff")
        // The padding case: a channel below 0x10 must not render as one digit, or the
        // ghostty config line it becomes is a parse error rather than a wrong colour.
        XCTAssertEqual(Palette.RGB(hex: 0x01_02_03).hex, "#010203")
    }

    func testTokenAnswersPerAppearance() {
        let token = Palette.Token(light: 0x11_22_33, dark: 0x44_55_66)
        XCTAssertEqual(token.value(in: .light).hex, "#112233")
        XCTAssertEqual(token.value(in: .dark).hex, "#445566")
    }

    // MARK: - The fold

    /// The chat face's five colours, to the digit. `ChatPalette.paper`, `.ink`, `.quiet`,
    /// `.rule` and `.accent` became these five tokens; if one of these values changes, the
    /// chat face changed, and that has to be a deliberate edit rather than a side effect of
    /// tuning the chrome.
    func testTheChatFacesColoursSurvivedTheFoldExactly() {
        XCTAssertEqual(palette.surface.light.hex, "#fbfaf8", "was ChatPalette.paper")
        XCTAssertEqual(palette.surface.dark.hex, "#1c1e21")
        XCTAssertEqual(palette.textPrimary.light.hex, "#1b1d1f", "was ChatPalette.ink")
        XCTAssertEqual(palette.textPrimary.dark.hex, "#e6e3de")
        XCTAssertEqual(palette.textMuted.light.hex, "#5c6066", "was ChatPalette.quiet")
        XCTAssertEqual(palette.textMuted.dark.hex, "#9399a0")
        XCTAssertEqual(palette.border.light.hex, "#e2dfda", "was ChatPalette.rule")
        XCTAssertEqual(palette.border.dark.hex, "#303439")
        XCTAssertEqual(palette.accent.light.hex, "#3f8f80", "was ChatPalette.accent")
        XCTAssertEqual(palette.accent.dark.hex, "#5fc0ac")
    }

    // MARK: - Legibility

    /// Body text at AAA in both appearances. helm's centre is a wall of small monospace
    /// read for hours, so the ordinary AA floor of 4.5 is not the right bar for it.
    func testPrimaryTextIsReadableOnTheSurface() {
        for appearance in Palette.Appearance.allCases {
            let ratio = contrast(palette.textPrimary, on: palette.surface, in: appearance)
            XCTAssertGreaterThanOrEqual(ratio, 7, "textPrimary in \(appearance): \(ratio)")
        }
    }

    /// The second voice still has to be read, so it keeps the AA floor for body text.
    func testMutedTextClearsTheBodyTextFloor() {
        for appearance in Palette.Appearance.allCases {
            let ratio = contrast(palette.textMuted, on: palette.surface, in: appearance)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "textMuted in \(appearance): \(ratio)")
        }
    }

    /// `textFaint` and `accent` are deliberately quiet — a key hint, a cursor — so the bar
    /// is WCAG's non-text minimum of 3, not the body-text one. Below that they stop being
    /// quiet and start being invisible, which is a different thing entirely.
    func testQuietTokensStayVisible() {
        for appearance in Palette.Appearance.allCases {
            for (name, token) in [("textFaint", palette.textFaint), ("accent", palette.accent)] {
                let ratio = contrast(token, on: palette.surface, in: appearance)
                XCTAssertGreaterThanOrEqual(ratio, 3, "\(name) in \(appearance): \(ratio)")
            }
        }
    }

    /// Raised chrome has to read as a step, not as a second colour scheme, and a border has
    /// to be seen against the plane it edges. Both fail as "looks fine" bugs otherwise.
    func testChromeSitsJustAboveTheSurface() {
        for appearance in Palette.Appearance.allCases {
            let step = contrast(palette.surfaceRaised, on: palette.surface, in: appearance)
            XCTAssertGreaterThan(step, 1, "surfaceRaised must differ from surface")
            XCTAssertLessThan(step, 1.6, "…but stay the same plane, not a second scheme")
            let edge = contrast(palette.border, on: palette.surface, in: appearance)
            XCTAssertGreaterThan(edge, 1.15, "a hairline nobody can see is not a hairline")
        }
    }

    // MARK: - Archon's voice

    /// The three stops of Archon's own duotone, pinned. **The brand is the gradient**, not a
    /// magenta — its console says so — so moving one of these is a change to how the rail
    /// identifies itself rather than a tweak. Archon authors them in oklch at
    /// `packages/web/src/experiments/console/theme.css`:
    /// `oklch(0.640 0.295 330)`, `oklch(0.560 0.215 305)`, `oklch(0.755 0.165 168)`.
    ///
    /// The dark values are Archon's own published hexes for magenta and teal; the violet is
    /// the one stop lifted, because at its authored lightness it reads 3.22 on helm's dark
    /// surface. Every light value is the same hue taken down until it clears the floor below.
    func testTheBrandStopsAreArchonsDuotoneAtHelmsLightnesses() {
        XCTAssertEqual(palette.archonMagenta.light.hex, "#b200ad", "Archon's magenta, darkened")
        XCTAssertEqual(palette.archonMagenta.dark.hex, "#ed10ec", "Archon's own #ED10EC")
        XCTAssertEqual(palette.archonViolet.light.hex, "#8a38ce")
        XCTAssertEqual(palette.archonViolet.dark.hex, "#b266f9", "lifted from oklch(0.560)")
        XCTAssertEqual(palette.archonTeal.light.hex, "#04795b", "the stop that moves furthest")
        XCTAssertEqual(palette.archonTeal.dark.hex, "#06ce94", "Archon's own #06CE94")
    }

    /// The status hues, which are **deliberately not the brand**: Archon keeps them *"distinct
    /// from accent so brand swaps don't break meaning"*, and a build that quietly folded one
    /// into the magenta would make the rail's counts decorative.
    func testTheStatusTokensAreArchonsStatusHues() {
        XCTAssertEqual(palette.archonRunning.light.hex, "#0170b3", "Archon's electric blue")
        XCTAssertEqual(palette.archonRunning.dark.hex, "#3dacfe")
        XCTAssertEqual(palette.archonAttention.light.hex, "#9d5f00", "Archon's amber, darkened")
        XCTAssertEqual(palette.archonAttention.dark.hex, "#e1a035")
        XCTAssertEqual(palette.archonError.light.hex, "#c91f3f", "Archon's hot red, darkened")
        XCTAssertEqual(palette.archonError.dark.hex, "#ff5166")
    }

    /// **Not the console's values to the digit, and this is the assertion that says why.**
    /// Archon's console is dark-only at hue 265; helm has a light appearance, and on it the
    /// authored magenta lands at 3.75 and the authored teal at 1.92. Every one of these paints
    /// small text — a tracked wordmark, a count numeral — so the bar is the body floor of 4.5
    /// rather than the non-text 3 that `accent` and `textFaint` are held to.
    ///
    /// **This is also what makes the send button legible.** Its label is `Color.surface`
    /// knocked out of the gradient, so "each stop against the surface" and "the label against
    /// each stop" are the same measurement — one floor covers the title and the button both.
    func testEveryArchonTokenCarriesSmallTextInBothAppearances() {
        for appearance in Palette.Appearance.allCases {
            for (name, token) in [
                ("archonMagenta", palette.archonMagenta),
                ("archonViolet", palette.archonViolet),
                ("archonTeal", palette.archonTeal),
                ("archonRunning", palette.archonRunning),
                ("archonAttention", palette.archonAttention),
                ("archonError", palette.archonError),
            ] {
                let onSurface = contrast(token, on: palette.surface, in: appearance)
                XCTAssertGreaterThanOrEqual(
                    onSurface, 4.5, "\(name) in \(appearance): \(onSurface)")
                // The rail sits on chrome, not on the reading plane, so the raised surface is
                // the background that actually matters for the wordmark.
                let onChrome = contrast(token, on: palette.surfaceRaised, in: appearance)
                XCTAssertGreaterThanOrEqual(onChrome, 4, "\(name) on chrome in \(appearance)")
            }
        }
    }

    /// A gradient whose stops are indistinguishable is a flat fill with extra steps — and the
    /// point of the duotone is that you can see it travel from magenta to teal.
    func testTheBrandStopsAreVisiblyDifferentFromEachOther() {
        for appearance in Palette.Appearance.allCases {
            let stops = [palette.archonMagenta, palette.archonViolet, palette.archonTeal]
            for (first, second) in zip(stops, stops.dropFirst()) {
                XCTAssertGreaterThan(
                    distance(first, second, in: appearance), 0.3, "in \(appearance)")
            }
        }
    }

    /// `archonAttention` marks a run stopped waiting for a person; `accent` marks one that is
    /// live and fine. They are opposite claims, so a build that quietly retuned one into the
    /// other would leave the rail saying nothing at all with a straight face. The same holds
    /// for `archonError` against the teal a completed count spends.
    func testTheStatusColoursCannotBeMistakenForOneAnother() {
        for appearance in Palette.Appearance.allCases {
            XCTAssertGreaterThan(
                distance(palette.archonAttention, palette.accent, in: appearance), 0.5,
                "attention vs accent in \(appearance)")
            XCTAssertGreaterThan(
                distance(palette.archonError, palette.archonTeal, in: appearance), 0.5,
                "failed vs completed in \(appearance)")
            XCTAssertGreaterThan(
                distance(palette.archonRunning, palette.archonMagenta, in: appearance), 0.5,
                "a running run is Archon's blue, never a shade of its wordmark, in \(appearance)")
        }
    }

    private func distance(
        _ first: Palette.Token, _ second: Palette.Token, in appearance: Palette.Appearance
    ) -> Double {
        let one = first.value(in: appearance)
        let other = second.value(in: appearance)
        return abs(one.red - other.red) + abs(one.green - other.green)
            + abs(one.blue - other.blue)
    }

    // MARK: - WCAG

    /// Shared with `AnsiPaletteTests` via `ColorMath`, so the two suites cannot end up
    /// measuring "contrast" two different ways and both passing.
    private func contrast(
        _ foreground: Palette.Token, on background: Palette.Token, in appearance: Palette.Appearance
    ) -> Double {
        ColorMath.contrast(foreground, on: background, in: appearance)
    }
}
