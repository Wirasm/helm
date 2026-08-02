import Foundation
import XCTest

@testable import Helm

/// The predicate that decides whether helm forces its own activation policy at launch.
///
/// It replaced `Bundle.main.bundleIdentifier == nil`, which stopped meaning "not bundled" the
/// moment #45 gave the SPM binary an identifier. Getting this wrong is invisible to the
/// compiler and shows up only as behaviour: the window never comes to the front under
/// `swift run helm`, or Helm.app steals focus from whatever the operator was doing.
final class LaunchContextTests: XCTestCase {
    func testAnAppBundleIsRecognisedByItsPathExtension() {
        XCTAssertTrue(LaunchContext.isAppBundle(URL(fileURLWithPath: "/Applications/Helm.app")))
        // Where `make app` actually puts it.
        XCTAssertTrue(
            LaunchContext.isAppBundle(
                URL(fileURLWithPath: ".build/DerivedData/Build/Products/Debug/Helm.app")))
    }

    /// `Bundle.main.bundleURL` for a bare executable is the directory the binary sits in — the
    /// case that must keep forcing `.regular`, or `swift run helm` opens no visible window.
    func testTheSPMBuildDirectoryIsNotAnAppBundle() {
        XCTAssertFalse(
            LaunchContext.isAppBundle(
                URL(fileURLWithPath: "/Users/x/helm/.build/arm64-apple-macosx/debug")))
        XCTAssertFalse(LaunchContext.isAppBundle(URL(fileURLWithPath: "/usr/local/bin")))
    }

    /// The regression the rename exists to prevent: an identifier is no longer evidence of a
    /// bundle, so anything deciding activation from one is deciding from the wrong fact.
    func testHavingABundleIdentifierIsNotWhatMakesSomethingAnAppBundle() {
        let spm = URL(fileURLWithPath: "/Users/x/helm/.build/arm64-apple-macosx/debug")
        XCTAssertFalse(
            LaunchContext.isAppBundle(spm),
            "the SPM binary carries CFBundleIdentifier \(DefaultsDomain.canonical) and is still "
                + "not bundled — Launch Services knows nothing about it either way")
    }

}
