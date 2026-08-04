import AppKit
import XCTest

@testable import Helm

/// The hints, against the real map.
///
/// Deliberately asserted on `Shortcut.all` rather than on fixtures wherever the point is
/// "what will the operator actually see" — a hint rendered from a two-row toy map proves
/// the renderer and nothing about the bar. Fixtures appear only where a rule needs a shape
/// the real map does not happen to contain.
final class KeyHintTests: XCTestCase {
    private func keys(_ label: String, terminalFocused: Bool) -> String? {
        KeyHints.visible(terminalFocused: terminalFocused).first { $0.label == label }?.keys
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
            Shortcut(
                .character("\(index)"), .command, posts: .helmSelectTerminal, payload: index - 1)
        }
        XCTAssertEqual(
            KeyHints.visible(terminalFocused: true, in: rows).first?.keys, "⌘1 ⌘2")
    }

    /// Non-consecutive digits are a list too — a gap means the run is a lie about what is
    /// bound, which is exactly the drift this file exists to prevent.
    func testNonConsecutiveDigitsAreNotCollapsed() {
        let rows = [1, 2, 4].map { index in
            Shortcut(
                .character("\(index)"), .command, posts: .helmSelectTerminal, payload: index - 1)
        }
        XCTAssertEqual(
            KeyHints.visible(terminalFocused: true, in: rows).first?.keys, "⌘1 ⌘2 ⌘4")
    }

    // MARK: - Drift

    /// **The guard that makes this a helper and not a second keymap.** Every command the
    /// map binds is either named on the bar or explicitly left off it; adding a shortcut
    /// without deciding which fails here. Nothing else in the toolchain would say a word.
    func testEveryBoundCommandIsEitherNamedOrDeliberatelyOmitted() {
        let bound = Set(Shortcut.all.map(\.notification))
        let accounted = Set(KeyHintCatalog.named.map(\.command))
            .union(KeyHintCatalog.omitted)
        XCTAssertEqual(
            bound.subtracting(accounted), [],
            "a bound command with no hint and no reason for having none"
        )
        XCTAssertEqual(
            accounted.subtracting(bound), [],
            "a hint (or an omission) for a command nothing binds any more"
        )
    }

    /// **The half the drift test above cannot see.** It asks whether a *command* is
    /// accounted for; this asks whether the command's KEYS can be drawn. `KeyGlyph.trigger`
    /// answers nil for a keyCode it does not name, and `render` quietly drops it — so
    /// binding a named command to Escape, Tab or a function key would pass every other test
    /// here while the hint silently lost a glyph or vanished outright. That the four codes
    /// helm binds today are all arrows is a fact about today, not a guarantee.
    func testEveryKeyCodeTheMapBindsCanBeDrawn() {
        for shortcut in Shortcut.all {
            guard case .keyCode = shortcut.trigger else { continue }
            XCTAssertNotNil(
                KeyGlyph.trigger(shortcut.trigger),
                "\(shortcut.notification.rawValue) binds a keyCode KeyGlyph cannot draw"
            )
        }
    }

    /// `KeyHint.id` is its label, so a duplicated one is two rows with one identity — which
    /// SwiftUI's `ForEach` renders wrong rather than refusing. Cheap to make impossible.
    func testCatalogLabelsAreUnique() {
        let labels = KeyHintCatalog.named.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count, "duplicate hint label in \(labels)")
    }

    /// Every hint the bar draws says something in both halves. An empty glyph string would
    /// render as a floating word with no key, which reads as a bug rather than as a hint.
    func testEveryVisibleHintIsComplete() {
        for focused in [true, false] {
            for hint in KeyHints.visible(terminalFocused: focused) {
                XCTAssertFalse(hint.keys.isEmpty, hint.label)
                XCTAssertFalse(hint.label.isEmpty, hint.keys)
            }
        }
    }
}
