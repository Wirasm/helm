import SwiftUI
import WebKit

/// The drawer's temporary highlight belongs to the rendered page, never to the sidecar.
@MainActor
final class CanvasNoteHover: ObservableObject {
    weak var webView: WKWebView?
    @Published private(set) var status: [Int: String] = [:]
    private var active: Int?

    func hover(_ note: CanvasNotes.Note, entered: Bool) {
        guard entered else {
            if active == note.id { clear() }
            return
        }
        clear()
        active = note.id
        guard case let .selection(anchor) = note.mark else {
            status[note.id] = "This note points at something I cannot find."
            return
        }
        guard let webView else {
            status[note.id] = "The canvas cannot highlight this note right now."
            return
        }
        let payload: [String: String]
        switch anchor {
        case let .element(id, text): payload = ["anchorKind": "element", "id": id, "text": text]
        case let .quote(text): payload = ["anchorKind": "quote", "text": text]
        case let .excerpt(source, text):
            payload = ["anchorKind": "excerpt", "source": source, "text": text]
        case let .unanchored(reason, _):
            status[note.id] = "This note is not anchorable: \(reason)."
            return
        }
        webView.callAsyncJavaScript(
            "return window.__helmHoverNote(anchor);", arguments: ["anchor": payload],
            in: nil, in: CanvasFileCoordinator.bridgeWorld
        ) { [weak self] result in
            guard let self, self.active == note.id else { return }
            switch result {
            case .success(let value) where value as? String == "found":
                self.status[note.id] = nil
            case .success(let value) where value as? String == "not-found":
                self.status[note.id] = "This note points at something I cannot find."
            default:
                self.status[note.id] = "The canvas cannot highlight this note right now."
            }
        }
    }

    func reset() {
        clear()
        status = [:]
    }

    func clear() {
        active = nil
        webView?.evaluateJavaScript(
            "window.__helmClearNote && window.__helmClearNote();", in: nil,
            in: CanvasFileCoordinator.bridgeWorld, completionHandler: { _ in })
    }
}

struct CanvasHoverNote: View {
    let note: CanvasNotes.Note
    @ObservedObject var hover: CanvasNoteHover

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(CanvasNotes.readable(note.text))
                .textSelection(.enabled)
            if let message = hover.status[note.id]
                ?? (note.mark == nil ? "This note points at something I cannot find." : nil)
            {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hover.hover(note, entered: $0) }
    }
}
