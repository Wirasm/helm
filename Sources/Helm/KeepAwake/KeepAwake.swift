import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac and its displays from idle-sleeping while the operator has asked for it (#496).
///
/// **Two assertions, and the display one is not optional.** System sleep stops the agents. Display
/// sleep does not since M5b (they run in benchd), but it stops helm: with every display asleep
/// `ghostty_surface_new` fails (the CoreVideo `-6661` pair in `docs/testing.md`), so a pane an
/// agent opens while the operator is away never gets a terminal. `release-resume.sh` holds
/// `caffeinate -d` for the same reason. The cost is a lit screen while this is on.
///
/// **`isOn` means the assertions are held**, not that they were asked for: when IOKit refuses,
/// the reason goes to the log and the capsule stays off, so it never claims a hold it lacks.
///
/// **Quitting releases them with no code here.** IOKit owns an assertion on behalf of the process
/// that created it and drops it when that process exits, crash included. What survives a relaunch
/// is the choice, in helm's defaults.
@MainActor
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    /// Bool in `DefaultsDomain.store`: whether the operator last left it on.
    static let defaultsKey = "helmKeepAwake"
    /// What `pmset -g assertions` shows beside helm's pid.
    static let assertionName = "helm keep awake"
    static let assertionTypes = [
        kIOPMAssertionTypePreventUserIdleSystemSleep,
        kIOPMAssertionTypePreventUserIdleDisplaySleep,
    ]

    @Published private(set) var isOn = false

    private let defaults: UserDefaults
    private var held: [IOPMAssertionID] = []

    /// Restores the persisted choice, which is why `HelmApp.init` touches `shared`: at launch,
    /// not at the status bar's first render.
    init(defaults: UserDefaults = DefaultsDomain.store) {
        self.defaults = defaults
        if defaults.bool(forKey: Self.defaultsKey) { hold() }
    }

    /// Only a test's model ever dies; `shared` lives as long as helm.
    deinit { for id in held { IOPMAssertionRelease(id) } }

    func toggle() {
        if isOn { release() } else { hold() }
        defaults.set(isOn, forKey: Self.defaultsKey)
    }

    private func hold() {
        for type in Self.assertionTypes {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                Self.assertionName as CFString, &id)
            guard result == kIOReturnSuccess else {
                NSLog("helm: keep awake refused — %@ returned 0x%x", type, result)
                release()
                return
            }
            held.append(id)
        }
        isOn = true
    }

    private func release() {
        for id in held { IOPMAssertionRelease(id) }
        held = []
        isOn = false
    }
}
