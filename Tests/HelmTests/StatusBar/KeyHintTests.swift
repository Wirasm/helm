import AppKit
import XCTest

@testable import Helm

/// The hints, against the real map.
///
/// Deliberately asserted on `KeyBindings.all` rather than on fixtures wherever the point is
/// "what will the operator actually see" — a hint rendered from a two-row toy map proves
/// the renderer and nothing about the bar. Fixtures appear only where a rule needs a shape
/// the real map does not happen to contain.
final class KeyHintTests: XCTestCase {
    private func keys(_ label: String, terminalFocused: Bool) -> String? {
        KeyHints.visible(terminalFocused: terminalFocused, in: KeyBindings.all).first {
            $0.label == label
        }?.keys
    }

    // MARK: - Focus

    /// The case the bar exists for. ⌃1–9 is the workspace switcher only while focus is
    /// away from the grid — inside it those are the shell's own control codes — so a fixed
    /// hint would be wrong in whichever state it was not written for.
    func testWorkspaceHintFollowsFocus() {
        XCTAssertEqual(keys("workspace", terminalFocused: false), "⌃1–9")
        XCTAssertEqual(
            keys("workspace", terminalFocused: true), "⌥⌘1–9",
            "inside a terminal the fallback binding is the one that fires"
        )
    }

    /// A command that cannot fire is not advertised, in either direction: ⌘↑↓ exists only
    /// inside a terminal, ⌃←→ only outside one.
    func testHintsDisappearWhereTheirBindingCannotFire() {
        XCTAssertEqual(keys("turn", terminalFocused: true), "⌘↑↓")
        XCTAssertNil(keys("turn", terminalFocused: false))
        XCTAssertEqual(keys("cycle", terminalFocused: false), "⌃←→")
        XCTAssertNil(keys("cycle", terminalFocused: true))
    }

    // MARK: - Rendering

    /// Modifier order is macOS's, not the codebase's prose: helm's comments write ⌘⇧D
    /// because that is how it is said out loud, while every menu on the machine — including
    /// helm's own, an inch above this bar — prints ⇧⌘D. The bar matches the menus.
    func testGlyphsMatchWhatAMenuWouldPrint() {
        XCTAssertEqual(keys("new", terminalFocused: true), "⌘N")
        XCTAssertEqual(keys("split", terminalFocused: true), "⌘D")
        XCTAssertEqual(keys("split down", terminalFocused: true), "⇧⌘D")
        XCTAssertEqual(keys("close", terminalFocused: true), "⌥⌘W")
        XCTAssertEqual(keys("folder", terminalFocused: true), "⇧⌘O")
        XCTAssertEqual(keys("pane", terminalFocused: true), "⌘1–9")
        XCTAssertEqual(keys("focus", terminalFocused: true), "⌥⌘↑↓←→")
        XCTAssertEqual(keys("archon", terminalFocused: true), "⇧⌘R")
    }

    func testModifiersRenderInTheCanonicalMenuOrder() {
        XCTAssertEqual(KeyGlyph.modifiers([.command, .control, .shift, .option]), "⌃⌥⇧⌘")
        XCTAssertEqual(KeyGlyph.modifiers([]), "")
    }

    /// Three is a run; two is a list. "⌘1 ⌘2" is shorter than "⌘1–2" and says more, and the
    /// real map has no two-digit binding to prove it with.
    func testShortDigitListsAreNotCollapsedToARange() {
        let rows = (1...2).map { index in
            KeyBinding(
                .character("\(index)"), .command, .verb(.showTab(index: index - 1)), hint: "pane")
        }
        XCTAssertEqual(
            KeyHints.visible(terminalFocused: true, in: rows).first?.keys, "⌘1 ⌘2")
    }

    /// Non-consecutive digits are a list too — a gap means the run is a lie about what is
    /// bound, which is exactly the drift this file exists to prevent.
    func testNonConsecutiveDigitsAreNotCollapsed() {
        let rows = [1, 2, 4].map { index in
            KeyBinding(
                .character("\(index)"), .command, .verb(.showTab(index: index - 1)), hint: "pane")
        }
        XCTAssertEqual(
            KeyHints.visible(terminalFocused: true, in: rows).first?.keys, "⌘1 ⌘2 ⌘4")
    }

    // MARK: - One action's keys, for surfaces outside the bar

    /// **The bug this exists to make impossible.** The empty bench said `⌘⇧O` and the
    /// workspace bar's `+` tooltip said the same, while the status bar an inch below said
    /// `⇧⌘O` — one window, three surfaces, two answers about one key (#149). The bar was
    /// right, because that is the order every menu on the machine prints. Nothing outside
    /// this file may type a glyph now; it asks here, and gets the bar's answer by
    /// construction.
    func testABindingRendersTheSameGlyphsTheBarShows() {
        XCTAssertEqual(
            KeyGlyph.binding(for: .local(.openWorkspacePanel), in: KeyBindings.all), "⇧⌘O")
        XCTAssertEqual(
            KeyGlyph.binding(for: .local(.openWorkspacePanel), in: KeyBindings.all),
            keys("folder", terminalFocused: true),
            "the empty bench and the status bar must not be able to disagree")
        XCTAssertEqual(KeyGlyph.binding(for: .verb(.newTerminal), in: KeyBindings.all), "⌘N")
        XCTAssertEqual(KeyGlyph.binding(for: .local(.toggleRail), in: KeyBindings.all), "⇧⌘R")
    }

    /// An action nothing binds gets nil rather than a plausible-looking string, so a caller
    /// can decline to advertise a key instead of naming one that does not fire.
    func testAnUnboundActionHasNoGlyphs() {
        XCTAssertNil(KeyGlyph.binding(for: .verb(.showTab(index: 20)), in: KeyBindings.all))
    }

    // MARK: - Drift

    /// **The guard that the label moving onto the row left to keep.** A hint's word used to
    /// live in a catalogue beside the keymap, and a test made every bound command either named
    /// there or deliberately omitted. The word is on the row now, so there is nothing to keep
    /// in step — but a row added with no `hint` would still vanish from the bar silently. The
    /// one deliberate omission is font size (`KeyHint`'s header), so it is the only one allowed.
    func testEveryRowWithoutAHintIsFontSize() {
        for row in KeyBindings.all where row.hint == nil {
            guard case .local(.adjustFontSize) = row.action else {
                XCTFail("\(row.action) has no hint and no reason for having none")
                continue
            }
        }
    }

    /// **The half the test above cannot see.** It asks whether a row is on the bar; this asks
    /// whether its KEYS can be drawn. `KeyGlyph.trigger` answers nil for a keyCode it does not
    /// name, and `render` quietly drops it — so binding a hinted action to Escape, Tab or a
    /// function key would pass every other test here while the hint silently lost a glyph or
    /// vanished outright. That the codes helm binds today are all arrows is a fact about today.
    func testEveryKeyCodeTheTableBindsCanBeDrawn() {
        for row in KeyBindings.all {
            guard case .keyCode = row.trigger else { continue }
            XCTAssertNotNil(
                KeyGlyph.trigger(row.trigger), "\(row.action) binds a keyCode KeyGlyph cannot draw")
        }
    }

    /// `KeyHint.id` is its label, so a duplicated one is two rows with one identity — which
    /// SwiftUI's `ForEach` renders wrong rather than refusing. Rows share a label on purpose
    /// (⌘↑ and ⌘↓ are one "turn"), so this asks it of what the bar draws.
    func testVisibleLabelsAreUnique() {
        for focused in [true, false] {
            let labels = KeyHints.visible(terminalFocused: focused, in: KeyBindings.all).map(
                \.label)
            XCTAssertEqual(Set(labels).count, labels.count, "duplicate hint label in \(labels)")
        }
    }

    /// The bar reads in the table's order, and the pane keys lead because they are the ones an
    /// operator needs on day one and nothing else in the window hints at.
    func testHintsReadInTheTablesOrder() {
        XCTAssertEqual(
            KeyHints.visible(terminalFocused: true, in: KeyBindings.all).map(\.label),
            [
                "new", "note", "split", "split down", "close", "pane", "focus", "move",
                "artifact", "turn", "workspace", "folder", "archon", "browser", "sessions",
            ])
    }

    /// Every hint the bar draws says something in both halves. An empty glyph string would
    /// render as a floating word with no key, which reads as a bug rather than as a hint.
    func testEveryVisibleHintIsComplete() {
        for focused in [true, false] {
            for hint in KeyHints.visible(terminalFocused: focused, in: KeyBindings.all) {
                XCTAssertFalse(hint.keys.isEmpty, hint.label)
                XCTAssertFalse(hint.label.isEmpty, hint.keys)
            }
        }
    }
}
