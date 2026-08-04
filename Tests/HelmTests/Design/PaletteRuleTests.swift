import XCTest

@testable import Helm

/// The palette rule, enforced instead of remembered.
///
/// `AGENTS.md` states it in as many words — *"Colour is a palette token, never a literal and
/// never a system default"* — and #149 is what it costs when only a reviewer is holding it:
/// the **empty bench**, the first surface anyone sees, was a `ContentUnavailableView` styled
/// entirely by AppKit, and `AgentDot` had been shipping SwiftUI's `.orange` since the palette
/// landed. Both were noticed by eye, months apart, and the sweep that followed found **47
/// more across fourteen files**. Reviewer attention had every chance and caught two of 49.
///
/// **Scanning the sources is unusual for a unit test, and deliberate here** — the same
/// argument `IsolatedDefaultsTests` makes for its own scan: it is the only mechanism that
/// catches the *next* view rather than this one. A compiler cannot; `.secondary` is a
/// perfectly good `ShapeStyle`, which is exactly why it kept getting written.
final class PaletteRuleTests: XCTestCase {
    /// `Sources/Helm`, from this file's own location so the scan does not depend on where
    /// the tests were invoked from.
    private var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Design/
            .deletingLastPathComponent()  // HelmTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/Helm")
    }

    /// **The only exemption, and it is the rule's subject rather than a hole in it.**
    /// `Design/` is where a colour is allowed to be a literal, because that is what a palette
    /// is: `Palette.swift` writes the hexes, `PaletteColors.swift` is the one `Color(nsColor:)`
    /// in the module, and `AnsiPalette.swift` names ANSI slots `red`, `green`, `black`.
    ///
    /// Everything else under `Sources/Helm` is scanned. Keep it that way — a second entry here
    /// is a surface that has stopped reading as one application, and the reason it was added
    /// will outlive whoever added it.
    private let exempt = ["Design/"]

    /// A system `ShapeStyle` where helm should have named a token.
    ///
    /// Matched at the *call site* rather than by bare name, so `value.red` on a palette
    /// component and a `Material` mentioned in prose are not offences. `.clear` is absent on
    /// purpose: it is the absence of a colour, and `isSelected ? Color.selection : .clear` is
    /// the idiom it exists for.
    private static let systemStyle = try! NSRegularExpression(
        pattern: """
            (?:foregroundStyle|foregroundColor|fill|stroke|strokeBorder|background|tint|border)\
            \\(\\s*\\.(primary|secondary|tertiary|quaternary|orange|red|green|blue|yellow\
            |purple|pink|brown|gray|grey|black|white|cyan|mint|teal|indigo|accentColor\
            |bar|regularMaterial|thinMaterial|ultraThinMaterial|thickMaterial\
            |ultraThickMaterial)\\b
            """)

    /// A colour written as a number, or lifted out of AppKit. Both are second colour sources
    /// by construction — nothing downstream can re-theme them and no test can read them.
    private static let literalColour = try! NSRegularExpression(
        pattern: "Color\\(nsColor:|Color\\(red:|Color\\(white:|Color\\(hue:|#colorLiteral")

    func testNoViewSpendsASystemColourOrALiteral() throws {
        var offences: [String] = []
        for (relative, source) in try helmSources() {
            for regex in [Self.systemStyle, Self.literalColour] {
                let range = NSRange(source.startIndex..., in: source)
                for match in regex.matches(in: source, range: range) {
                    guard let hit = Range(match.range, in: source) else { continue }
                    let line = source[source.startIndex..<hit.lowerBound]
                        .reduce(into: 1) { count, character in
                            if character.isNewline { count += 1 }
                        }
                    offences.append("\(relative):\(line) — \(source[hit])")
                }
            }
        }

        XCTAssertEqual(
            offences.sorted(), [],
            """
            spend a token from `Design/PaletteColors.swift` — `Color.textMuted`, \
            `Color.attention`, `Color.danger`, … — not a system style or a literal. \
            If the colour a surface needs is not in the palette, add a token (AGENTS.md).
            """)
    }

    /// The guard is only worth its oddity if it would actually fire, and a regex that matches
    /// nothing passes every scan silently. This is the scanner scanning a known offence.
    func testTheScanRecognisesTheViolationsThisTicketRemoved() {
        let before = """
            Circle().fill(.orange)
            Text("x").foregroundStyle(.secondary)
            .background(.regularMaterial, in: Capsule())
            attributed[range].backgroundColor = Color(nsColor: .quaternarySystemFill)
            """
        let range = NSRange(before.startIndex..., in: before)
        XCTAssertEqual(Self.systemStyle.numberOfMatches(in: before, range: range), 3)
        XCTAssertEqual(Self.literalColour.numberOfMatches(in: before, range: range), 1)

        let after = """
            Circle().fill(Color.attention)
            Text("x").foregroundStyle(Color.textMuted)
            .background(Color.surfaceRaised, in: Capsule())
            .fill(isSelected ? Color.selection : .clear)
            """
        let clean = NSRange(after.startIndex..., in: after)
        XCTAssertEqual(Self.systemStyle.numberOfMatches(in: after, range: clean), 0)
        XCTAssertEqual(Self.literalColour.numberOfMatches(in: after, range: clean), 0)
    }

    /// Every `.swift` under `Sources/Helm` that is not exempt, as (path, contents).
    ///
    /// Throws rather than skips when the tree cannot be read: a guard that quietly passes
    /// because it found no files is worse than no guard.
    private func helmSources() throws -> [(String, String)] {
        let root = sources
        let walk = try XCTUnwrap(
            FileManager.default.enumerator(atPath: root.path),
            "could not read \(root.path) — this guard must fail loudly, not skip")

        var found: [(String, String)] = []
        for case let relative as String in walk where relative.hasSuffix(".swift") {
            guard !exempt.contains(where: relative.hasPrefix) else { continue }
            let path = root.appendingPathComponent(relative).path
            found.append((relative, try String(contentsOfFile: path, encoding: .utf8)))
        }
        XCTAssertGreaterThan(found.count, 50, "the scan found almost nothing — check the path")
        return found
    }
}
