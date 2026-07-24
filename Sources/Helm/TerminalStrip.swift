import SwiftUI

/// Tab strip across the top of the terminal face: one tab per shell session
/// (title from the terminal's title delegate, "shell N" until one arrives),
/// a + button (⌘N), and the artifact-open button (⌘O) on the trailing edge.
/// Selecting a tab swaps which session's NSView is mounted below — the other
/// ptys keep running unmounted.
struct TerminalStrip: View {
    @ObservedObject var manager: TerminalManager
    let onOpenArtifact: () -> Void

    // Same storage the View ▸ Appearance menu uses; HelmApp observes the key
    // and applies the override, so picking here re-themes the whole app.
    @AppStorage(HelmApp.appearanceKey)
    private var appearanceRaw = AppearanceOverride.system.rawValue

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(manager.sessions) { session in
                        TerminalTab(
                            session: session,
                            isSelected: session.id == manager.selectedID,
                            // The last terminal cannot be closed; its ✕ is disabled.
                            canClose: manager.canClose,
                            onSelect: { manager.select(session) },
                            onClose: { manager.close(session) }
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                manager.newTerminal()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New terminal (⌘N)")

            Divider()
                .frame(height: 14)

            Button(action: onOpenArtifact) {
                Image(systemName: "doc.text")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open artifact (⌘O)")

            // Subtle appearance affordance (mirrors View ▸ Appearance).
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
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

/// One tab. Observes its session directly so title/status changes re-render
/// the tab without the whole strip depending on every session.
private struct TerminalTab: View {
    @ObservedObject var session: TerminalSession
    let isSelected: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            if session.status == .exited {
                // Dead shell: mark the tab so the fallback pane isn't a surprise.
                Image(systemName: "poweroff")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            Text(session.displayTitle)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 180)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(!canClose)
            .opacity(canClose ? 1 : 0.3)
            .help(canClose ? "Close terminal (kills this shell)" : "The last terminal cannot be closed")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color(nsColor: .selectedControlColor).opacity(0.55) : .clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onTapGesture(perform: onSelect)
    }
}
