import AppKit
import SwiftUI

/// ⌘F in a browser pane (#549): a find field under the address bar. Headless Chrome has no find
/// bar of its own, so the page's own `window.find` does the searching (`BrowserPaneModel.find`):
/// it selects the match and scrolls it into view, which the frames then show.
///
/// Typing searches from the top of the page; Enter finds the next match, ⇧Enter the previous,
/// both wrapping. Esc closes the row and gives the page the keyboard back.
struct BrowserFindBar: View {
    @ObservedObject var model: BrowserPaneModel
    @Binding var text: String
    var field: FocusState<BrowserPaneView.Field?>.Binding
    let close: () -> Void

    @State private var notFound = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Color.textFaint)
            TextField("Find in page", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.textPrimary)
                .focused(field, equals: .find)
                .onSubmit {
                    search(backwards: NSEvent.modifierFlags.contains(.shift), fromTop: false)
                }
                .onExitCommand(perform: close)
                .onChange(of: text) { search(backwards: false, fromTop: true) }
            if notFound {
                Text("Not found")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textMuted)
            }
            Button {
                search(backwards: true, fromTop: false)
            } label: {
                Image(systemName: "chevron.up").frame(width: 20, height: 20)
            }
            .help("Previous match (⇧Return)")
            Button {
                search(backwards: false, fromTop: false)
            } label: {
                Image(systemName: "chevron.down").frame(width: 20, height: 20)
            }
            .help("Next match (Return)")
            Button(action: close) {
                Image(systemName: "xmark").frame(width: 20, height: 20)
            }
            .help("Close (Esc)")
        }
        .buttonStyle(.chrome)
        .foregroundStyle(Color.textMuted)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    private func search(backwards: Bool, fromTop: Bool) {
        let words = text
        guard !words.isEmpty else {
            notFound = false
            return
        }
        Task {
            let found = await model.find(words, backwards: backwards, fromTop: fromTop)
            // A later keystroke has already asked again; its answer is the one to show.
            guard words == text else { return }
            notFound = found == false
        }
    }
}
