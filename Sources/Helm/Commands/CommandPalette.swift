import HelmWire
import SwiftUI

/// Whether the command palette is open, what is typed in it and which line is picked (#500).
///
/// The model outlives the panel, so ⌘K toggles it from `LocalActions` whether or not the panel
/// is drawn. It holds no list: the lines are derived each time the panel draws
/// (`CommandList.of`), so nothing here can go stale.
@MainActor
final class CommandPalette: ObservableObject {
    @Published private(set) var isOpen = false
    @Published var query = "" {
        didSet { selection = 0 }
    }
    @Published var selection = 0

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        query = ""
        isOpen = true
    }

    func close() {
        isOpen = false
    }

    /// Moves the pick by `delta`, kept inside `count` lines.
    func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = min(max(selection + delta, 0), count - 1)
    }
}

/// The palette: a search field and the lines that fit it, over the top of the bench.
///
/// Typing filters (`FuzzyMatch`), ↑/↓ pick, Return runs the pick, Esc or ⌘K closes. A line is
/// also a button. Running a line closes the palette first, so what it opens or focuses is not
/// covered by it, and then hands the keyboard back to the pane that holds focus.
struct CommandPaletteView: View {
    @ObservedObject var palette: CommandPalette
    let commands: [Command]
    let run: (Command.Run) -> Void
    @FocusState private var fieldFocused: Bool

    private var matches: [Command] {
        FuzzyMatch.rank(commands, by: palette.query) { command in
            [command.title, command.detail].compactMap(\.self).joined(separator: " ")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if palette.isOpen {
                panel
                    .padding(.top, 40)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.1), value: palette.isOpen)
    }

    private var panel: some View {
        let matches = matches
        return VStack(spacing: 0) {
            TextField("Run a command, go to a pane or a workspace", text: $palette.query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .focused($fieldFocused)
                .onAppear { fieldFocused = true }
                .onSubmit { runPick(in: matches) }
                .onExitCommand { palette.close() }
                .onKeyPress(.upArrow) {
                    palette.move(-1, count: matches.count)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    palette.move(1, count: matches.count)
                    return .handled
                }
            Color.border.frame(height: 1)
            list(matches)
        }
        .frame(width: 560)
        .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.border))
        .shadow(color: .black.opacity(0.35), radius: 16)
    }

    private func list(_ matches: [Command]) -> some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.offset) { index, command in
                        row(command, picked: index == palette.selection)
                            .id(index)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: palette.selection) { scroller.scrollTo(palette.selection) }
            .overlay {
                if matches.isEmpty {
                    Text("Nothing matches").font(.system(size: 12))
                        .foregroundStyle(Color.textFaint).padding(12)
                }
            }
        }
    }

    private func row(_ command: Command, picked: Bool) -> some View {
        Button {
            finish(command.run)
        } label: {
            HStack(spacing: 8) {
                Text(command.title).foregroundStyle(Color.textPrimary).lineLimit(1)
                if let detail = command.detail {
                    Text(detail).foregroundStyle(Color.textFaint).lineLimit(1)
                }
                Spacer(minLength: 12)
                if let keys = command.keys {
                    Text(keys).foregroundStyle(Color.textMuted)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(picked ? Color.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.chrome)
    }

    private func runPick(in matches: [Command]) {
        guard matches.indices.contains(palette.selection) else { return }
        finish(matches[palette.selection].run)
    }

    private func finish(_ command: Command.Run) {
        palette.close()
        run(command)
    }
}

extension CommandList {
    /// What a terminal pane's tab shows, when it has a live session to ask: the same words.
    @MainActor
    static func liveTitle(of pane: BenchDocument.Pane, in workbench: WorkbenchModel) -> String? {
        guard case .terminal = pane.surface else { return nil }
        return workbench.session(for: Pane(id: pane.id, content: .init(pane.surface)))?
            .displayTitle
    }
}
