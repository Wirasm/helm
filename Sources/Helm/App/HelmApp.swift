import AppKit
import SwiftUI

/// The app entry point: install the key monitor, put `RootView` in a window, and
/// hang the menu off it. Everything it used to also hold — the keyboard map, the
/// menu, the notification names, the appearance enum — lives beside it now, so
/// adding a shortcut no longer means editing this file in three places.
@main
struct HelmApp: App {
    /// The one @AppStorage key for the appearance override (raw
    /// `AppearanceOverride` value; unknown values fall back to system).
    static let appearanceKey = "helmAppearance"

    @AppStorage(HelmApp.appearanceKey, store: DefaultsDomain.store)
    private var appearanceRaw = AppearanceOverride.system.rawValue

    private var appearance: AppearanceOverride {
        AppearanceOverride(rawValue: appearanceRaw) ?? .system
    }

    init() {
        // First, before anything reads a default. Until #45 the two launch paths resolved
        // `UserDefaults.standard` to two different domains; this carries what the SPM one
        // accumulated into the domain both now use. One-time and marker-guarded — and
        // skipped outright under `HELM_DEFAULTS_SUITE`, because draining the legacy domain
        // into a test instance would take it from the build entitled to it (#86).
        DefaultsDomain.migrateLegacyDomainAtLaunch()

        // Running as a bare SPM executable (`swift run helm`) nothing registers the process
        // with Launch Services, so AppKit treats it as a background app and the window never
        // fronts — force it regular and activate. Inside the real .app bundle (`make app`)
        // Launch Services handles activation natively and forcing it here would steal focus
        // — skip it.
        //
        // The test used to be `Bundle.main.bundleIdentifier == nil` and can no longer be:
        // the SPM binary now carries an identifier too, which is exactly what gives it one
        // defaults domain. Being unbundled and having no identifier were the same fact and
        // are not any more; only the first one is about activation.
        if !LaunchContext.isAppBundle {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Keymap.install()
    }

    var body: some Scene {
        // Titled from the domain, so an instance running on an isolated suite says so
        // where an agent outside the process can read it — `winshot --list` matches on
        // window titles, and `AGENTS.md` records that two helms are otherwise identical
        // by name. Unset, this is the literal "helm" it has always been.
        WindowGroup(DefaultsDomain.windowTitle) {
            RootView()
                .frame(minWidth: 900, minHeight: 600)
                // The override is applied at the AppKit level so it also
                // reaches sheets and any future windows; re-applied whenever
                // the stored value changes (menu or strip affordance).
                .onAppear { appearance.apply() }
                .onChange(of: appearanceRaw) { appearance.apply() }
        }
        .commands {
            // View ▸ Appearance — the discoverable, menu-bar home of the
            // override (the terminal strip carries the in-window affordance).
            CommandGroup(after: .sidebar) {
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(AppearanceOverride.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }
            CommandGroup(after: .toolbar) { HelmCommands() }
        }
    }
}
