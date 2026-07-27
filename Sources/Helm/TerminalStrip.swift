import Inject
import SwiftUI
/// Tab strip across the top of the terminal face: one tab per shell session
/// (title from the terminal's title delegate, "shell N" until one arrives),
/// a + button (⌘N), and the artifact-browser button (⌘O) on the trailing edge.
/// Selecting a tab swaps which session's NSView is mounted below — the other
/// ptys keep running unmounted.
struct TerminalStrip: View {
    /// Hot reload: `.enableInjection()` below redraws this view when
    /// InjectionNext swaps a recompiled build of it into the running app.
    /// Both are no-ops in release (docs/VENDORED.md).
    @ObserveInjection private var inject
    @ObservedObject var manager: TerminalManager
    /// The artifact pane the browser opens files into (also owns Recents).
    @ObservedObject var artifact: ArtifactPaneModel
    /// Owned by TerminalWorkspace so ⌘O can toggle the popover from outside;
    /// the popover itself anchors to the strip's artifact button.
    @Binding var showBrowser: Bool
    /// The open workspace's repo root, passed straight through to the browser so it
    /// preselects that workspace's `~/.prp` store.
    var workspaceRoot: String?

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

            Button {
                showBrowser.toggle()
            } label: {
                Image(systemName: "doc.text")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open artifact (⌘O)")
            .popover(isPresented: $showBrowser, arrowEdge: .bottom) {
                ArtifactBrowser(model: artifact, workspaceRoot: workspaceRoot) {
                    showBrowser = false
                }
            }

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
        .enableInjection()
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
            indicator
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

    /// The tab's one indicator slot, by precedence: dead shell > bell (orange
    /// keeps priority) > finished-command tick/mark (inactive tabs, cleared on
    /// select) > live progress hint. All state, no popups — the quiet rules
    /// live in TerminalActivity (TerminalCapabilities.swift).
    @ViewBuilder
    private var indicator: some View {
        if session.status == .exited {
            // Dead shell: mark the tab so the fallback pane isn't a surprise.
            Image(systemName: "poweroff")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        } else if session.hasBell, !isSelected {
            // Bell from an inactive tab (BEL — e.g. an agent asking for
            // attention). Cleared when the tab is selected.
            Circle()
                .fill(.orange)
                .frame(width: 5, height: 5)
                .accessibilityLabel("Bell")
        } else if let outcome = session.activity.outcome, !isSelected {
            // A command finished in this inactive tab; duration (and exit
            // code on failure) in the tooltip. Selecting acknowledges.
            switch outcome {
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
                    .help(outcome.tooltip)
                    .accessibilityLabel("Command finished")
            case .failure:
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
                    .help(outcome.tooltip)
                    .accessibilityLabel("Command failed")
            }
        } else if let progress = session.activity.progress {
            // OSC 9;4: a tracked command is running (shown on the selected
            // tab too — it's a hint, not an alert).
            progressHint(progress)
        }
    }

    @ViewBuilder
    private func progressHint(_ progress: TerminalActivity.Progress) -> some View {
        switch progress {
        case let .percent(percent):
            // Tiny determinate ring, drawn by hand — the native circular
            // ProgressView doesn't shrink to tab-chrome size.
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: CGFloat(percent) / 100)
                    .stroke(.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 9, height: 9)
            .help("\(percent)%")
            .accessibilityLabel("Progress \(percent)%")
        case .error:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 9))
                .foregroundStyle(.red)
                .help("Command reported a progress error")
                .accessibilityLabel("Progress error")
        case .indeterminate, .paused:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.5)
                .frame(width: 10, height: 10)
                .help("Command running")
                .accessibilityLabel("Command running")
        }
    }
}
