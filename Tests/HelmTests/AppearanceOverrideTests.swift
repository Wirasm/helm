import AppKit
import XCTest

@testable import Helm

/// The appearance override's pure mapping — raw persistence values and the
/// NSAppearance each case forces. `apply()` touches NSApp and is exercised by
/// running the app, not here.
final class AppearanceOverrideTests: XCTestCase {
    func testRawValuesAreStableForPersistence() {
        // @AppStorage persists these strings; changing them would silently
        // reset every user to System.
        XCTAssertEqual(AppearanceOverride.system.rawValue, "system")
        XCTAssertEqual(AppearanceOverride.light.rawValue, "light")
        XCTAssertEqual(AppearanceOverride.dark.rawValue, "dark")
        XCTAssertNil(AppearanceOverride(rawValue: "solarized"))
    }

    func testAppearanceNamesMapToAquaVariants() {
        // nil = follow the system (NSApp.appearance = nil).
        XCTAssertNil(AppearanceOverride.system.appearanceName)
        XCTAssertEqual(AppearanceOverride.light.appearanceName, .aqua)
        XCTAssertEqual(AppearanceOverride.dark.appearanceName, .darkAqua)
    }

    func testAllCasesCoverTheMenu() {
        XCTAssertEqual(
            AppearanceOverride.allCases, [.system, .light, .dark],
            "menu order: System first, then the two pins"
        )
    }
}
