import AppKit
import SwiftUI

/// App-level appearance override: System follows macOS, Light/Dark pin the
/// app. Applied via `NSApp.appearance` (nil = System), which every window —
/// and the `colorScheme` environment the mermaid islands re-theme on —
/// inherits. Persisted under `HelmApp.appearanceKey`; the View ▸ Appearance
/// menu and the terminal strip's affordance share that storage.
enum AppearanceOverride: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The NSAppearance name to force, or nil to follow the system.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    @MainActor
    func apply() {
        NSApp.appearance = appearanceName.flatMap { NSAppearance(named: $0) }
    }
}

/// The in-window appearance affordance, mirroring View ▸ Appearance.
///
/// A view of its own so the surfaces that host it do not need to know the storage
/// key or the enum — the terminal strip currently carries it, but that is a
/// placement choice, not a terminal concern.
struct AppearanceMenu: View {
    @AppStorage(HelmApp.appearanceKey)
    private var appearanceRaw = AppearanceOverride.system.rawValue

    var body: some View {
        Menu {
            Picker("Appearance", selection: $appearanceRaw) {
                ForEach(AppearanceOverride.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "circle.lefthalf.filled")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Appearance")
    }
}
