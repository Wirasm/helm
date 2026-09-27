import IOKit.pwr_mgt
import XCTest

@testable import Helm

/// Asks IOKit, not the model, which assertions this process holds: `isOn` is the model's own
/// claim, and the point is that the claim and the hold agree.
@MainActor
final class KeepAwakeTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        defaults = try isolatedDefaults("keepawake")
    }

    func testTurningItOnHoldsSystemAndDisplaySleepAssertionsAndOffHoldsNone() {
        let model = KeepAwake(defaults: defaults)
        XCTAssertEqual(heldTypes(), [])

        model.toggle()
        XCTAssertTrue(model.isOn)
        XCTAssertEqual(heldTypes(), Set(KeepAwake.assertionTypes))

        model.toggle()
        XCTAssertFalse(model.isOn)
        XCTAssertEqual(heldTypes(), [])
    }

    /// A relaunch is a new model on the same defaults: the old process's hold is gone (here, its
    /// model's deinit; in helm, the process exiting) and the choice is what brings it back.
    func testTheChoiceSurvivesARelaunch() {
        do {
            let before = KeepAwake(defaults: defaults)
            before.toggle()
        }
        XCTAssertEqual(heldTypes(), [])

        let relaunched = KeepAwake(defaults: defaults)
        XCTAssertTrue(relaunched.isOn)
        XCTAssertEqual(heldTypes(), Set(KeepAwake.assertionTypes))

        relaunched.toggle()
        XCTAssertFalse(KeepAwake(defaults: defaults).isOn)
        XCTAssertEqual(heldTypes(), [])
    }

    /// The types of every assertion this process holds under helm's name.
    private func heldTypes() -> Set<String> {
        var byProcess: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
            let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return [] }
        let mine = all[NSNumber(value: getpid())] ?? []
        return Set(
            mine.filter { $0[kIOPMAssertionNameKey] as? String == KeepAwake.assertionName }
                .compactMap { $0[kIOPMAssertionTypeKey] as? String })
    }
}
