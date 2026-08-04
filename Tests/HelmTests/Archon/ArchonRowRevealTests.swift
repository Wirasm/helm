import XCTest

@testable import Helm

/// The reveal rule for a finished run's dismiss control (#180).
///
/// These are the parts of the defect that can be settled without a pointer. The geometry — that
/// the row's hover region now covers the whole row rectangle — is held by
/// `ArchonRailHoverRegionTests` below, and confirmed visually by the operator.
final class ArchonRowRevealTests: XCTestCase {
    func testNothingIsRevealedToBeginWith() {
        let reveal = ArchonRowReveal()
        XCTAssertNil(reveal.revealed)
        XCTAssertFalse(reveal.isRevealed("run-a"))
        XCTAssertEqual(reveal.dismissOpacity(for: "run-a"), 0)
    }

    func testEnteringARowRevealsThatRowAndNoOther() {
        var reveal = ArchonRowReveal()
        reveal.update(inside: true, for: "run-a")

        XCTAssertTrue(reveal.isRevealed("run-a"))
        XCTAssertFalse(reveal.isRevealed("run-b"))
        XCTAssertEqual(reveal.dismissOpacity(for: "run-a"), 1)
        XCTAssertEqual(reveal.dismissOpacity(for: "run-b"), 0)
    }

    func testLeavingTheRevealedRowHidesIt() {
        var reveal = ArchonRowReveal()
        reveal.update(inside: true, for: "run-a")
        reveal.update(inside: false, for: "run-a")

        XCTAssertNil(reveal.revealed)
        XCTAssertEqual(reveal.dismissOpacity(for: "run-a"), 0)
    }

    /// **The one that would regress silently.** Sliding down the list delivers the entering
    /// row's `true` *before* the leaving row's `false`, so a naive `revealed = nil` on every
    /// exit clears the reveal the next row has already claimed — and the × blinks out under a
    /// pointer that never left the list.
    func testAnExitFromAnotherRowDoesNotClearThisRowsReveal() {
        var reveal = ArchonRowReveal()
        reveal.update(inside: true, for: "run-a")

        // Pointer crosses from a into b: b enters first, then a reports it was left.
        reveal.update(inside: true, for: "run-b")
        reveal.update(inside: false, for: "run-a")

        XCTAssertTrue(reveal.isRevealed("run-b"), "b claimed the reveal and a's exit took it away")
        XCTAssertFalse(reveal.isRevealed("run-a"))
    }

    /// An exit for a row that never had the reveal is a no-op, not a clear. Same rule as above,
    /// stated for the case where nothing is revealed at all.
    func testAnExitFromAnUnrelatedRowIsANoOp() {
        var reveal = ArchonRowReveal()
        reveal.update(inside: true, for: "run-a")
        reveal.update(inside: false, for: "run-z")

        XCTAssertTrue(reveal.isRevealed("run-a"))
    }

    /// Repeated `true`s arrive whenever the pointer re-enters, and must not toggle anything.
    func testRepeatedEntriesAreIdempotent() {
        var reveal = ArchonRowReveal()
        reveal.update(inside: true, for: "run-a")
        let once = reveal
        reveal.update(inside: true, for: "run-a")

        XCTAssertEqual(reveal, once)
    }

    /// `0` is not a dimmer setting. SwiftUI drops a fully transparent view from hit testing —
    /// measured for #180 with a grid of synthetic clicks over the row: 21 hits on the × while
    /// revealed, **zero** while hidden. So "revealed" and "clickable" are one fact, and a future
    /// change that makes the hidden value merely faint is changing behaviour, not styling.
    func testHiddenMeansFullyTransparentBecauseThatIsWhatMakesItUnclickable() {
        let reveal = ArchonRowReveal()
        XCTAssertEqual(
            reveal.dismissOpacity(for: "run-a"), 0,
            "a non-zero hidden opacity leaves an invisible but clickable × on every row")
    }
}

/// The row's hit region, enforced instead of remembered (#180).
///
/// **Scanning a source file is unusual for a unit test and deliberate here**, on exactly the
/// argument `PaletteRuleTests` makes for its own scan: it is the only mechanism that catches the
/// *next* control rather than this one. Hover geometry is not reachable from `swift test` —
/// SwiftUI's hover needs a real pointer, measured: synthetic `.mouseMoved` produced zero
/// `.onHover` callbacks over five delivery routes — so nothing else can hold this.
///
/// What it holds: an `.onHover` in the Archon rail must sit on a chain that has declared its own
/// hit region. Without `.contentShape`, the region a container's `.onHover` gets is the union of
/// whatever children are in it, the gaps between them report `false`, and #180 is what that
/// feels like: 38% of the finished row was dead, the × among it.
///
/// **Scoped to `Sources/Helm/Archon` rather than the whole module, and that is a scope decision
/// rather than a claim the rule stops here.** The other three `.onHover` sites in helm were read
/// while fixing this: `SplitStack` and `CopyableLabel` both declare a `.contentShape` and would
/// pass. `ArtifactBrowser`'s row style does not, and whether that is a defect turns on how a
/// `ButtonStyle`'s label region behaves — a different question, in a feature #180 has no business
/// editing. Widen this to `Sources/Helm` when someone has answered it.
///
/// Do not widen it by making the rule mushier instead. A `.background` fill does **not** stand in
/// for a `.contentShape`: measured for #180, clicking the gap between two labels in a row backed
/// by `RoundedRectangle().fill(Color.clear)` reached nothing at all, exactly as with an
/// `.opacity(0)` background.
final class ArchonRailHoverRegionTests: XCTestCase {
    private var archonDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Archon/
            .deletingLastPathComponent()  // HelmTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/Helm/Archon")
    }

    func testEveryHoverInTheRailDeclaresItsOwnHitRegion() throws {
        let sources = try archonSources()
        XCTAssertFalse(sources.isEmpty, "the scan found no sources — check the path")

        var hovers = 0
        var offences: [String] = []
        for (name, source) in sources {
            let lines = source.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() where Self.isAHoverSite(line) {
                hovers += 1
                if !Self.chainDeclaresAHitRegion(lines, endingAt: index) {
                    offences.append(
                        "\(name):\(index + 1) — \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }

        XCTAssertGreaterThan(
            hovers, 0,
            "no `.onHover` found in Sources/Helm/Archon — this guard must fail loudly, not skip")
        XCTAssertEqual(
            offences.sorted(), [],
            """
            put `.contentShape(Rectangle())` on the row, above its `.onHover`. Without one the \
            hover region is the union of the row's children and the gaps between them report \
            `false` — which is #180: the × vanished as the pointer moved onto it, and a \
            transparent × cannot be clicked.
            """)
    }

    /// The guard is only worth its oddity if it would actually fire. This is the scanner
    /// reading the shape the fix removed, and the shape it put there.
    func testTheScanRecognisesARowThatInheritsItsHoverRegion() {
        let before = """
            }
            .padding(.vertical, 4)
            .onHover { inside in hovered = inside ? run.id : nil }
            """.components(separatedBy: .newlines)
        XCTAssertFalse(
            Self.chainDeclaresAHitRegion(before, endingAt: before.count - 1),
            "the scanner passed the exact shape #180 was filed about")

        let after = """
            }
            .padding(.vertical, 4)
            // a comment between the two must not break the chain
            .contentShape(Rectangle())
            .onHover { inside in reveal.update(inside: inside, for: run.id) }
            """.components(separatedBy: .newlines)
        XCTAssertTrue(Self.chainDeclaresAHitRegion(after, endingAt: after.count - 1))
    }

    /// Prose above the fix mentions `.onHover` by name. If the scan counted that as a site it
    /// would walk back past the `.contentShape` into the comment block and report the fixed row
    /// as broken — a guard that fails on the code satisfying it teaches people to delete it.
    func testTheScanIgnoresCommentsThatMerelyNameTheModifier() {
        XCTAssertFalse(Self.isAHoverSite("        // Without it the region an `.onHover` gets is"))
        XCTAssertTrue(Self.isAHoverSite("        .onHover { inside in reveal.update(inside) }"))
    }

    /// A line that actually attaches a hover, as opposed to one that talks about one. Prose
    /// naming the modifier is exactly what sits above the fix in `ArchonRailView`, and counting
    /// it would make this guard fail on the change that satisfies it.
    private static func isAHoverSite(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.contains(".onHover") && !trimmed.hasPrefix("//")
    }

    /// Walk back from the `.onHover` over the modifier chain it terminates — further `.foo(…)`
    /// modifiers and the comments between them — and report whether a `.contentShape` is among
    /// them. Anything that is not a modifier or a comment ends the chain, so a `.contentShape`
    /// belonging to some *other* view further up the file cannot be mistaken for this one's.
    private static func chainDeclaresAHitRegion(_ lines: [String], endingAt index: Int) -> Bool {
        var cursor = index
        while cursor >= 0 {
            let line = lines[cursor].trimmingCharacters(in: .whitespaces)
            if line.contains(".contentShape(") { return true }
            let isModifier = line.hasPrefix(".")
            let isComment = line.hasPrefix("//") || line.isEmpty
            guard isModifier || isComment else { return false }
            cursor -= 1
        }
        return false
    }

    private func archonSources() throws -> [(String, String)] {
        let root = archonDirectory
        let walk = try XCTUnwrap(
            FileManager.default.enumerator(atPath: root.path),
            "could not read \(root.path) — this guard must fail loudly, not skip")

        var found: [(String, String)] = []
        for case let relative as String in walk where relative.hasSuffix(".swift") {
            let path = root.appendingPathComponent(relative).path
            found.append((relative, try String(contentsOfFile: path, encoding: .utf8)))
        }
        return found
    }
}
