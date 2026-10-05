import CanvasKit
import PocketKit
import SwiftUI

/// A store document through the same benchd file reader as an HTML page, drawn as chat markdown.
struct MarkdownPageView: View {
    @EnvironmentObject private var model: PocketModel
    let page: PocketPage
    @State private var text: String?
    @State private var failed: String?

    var body: some View {
        ScrollView {
            if let text {
                MarkdownView(text: text)
            } else if let failed {
                Text(failed).font(Mono.small).foregroundStyle(Palette.asking)
            } else {
                Text("loading…").font(Mono.small).foregroundStyle(Palette.dim)
            }
        }
        .task(id: model.state) {
            guard model.state == .connected else { return }
            text = nil
            failed = nil
            guard let files = model.files else { return }
            let read = await Task.detached { () -> Result<String, CanvasFileFailure> in
                switch files.read(page.path, within: page.store) {
                case let .bytes(data):
                    guard let text = CanvasText.decode(data) else {
                        return .failure(CanvasFileFailure(reason: "the document is not UTF-8"))
                    }
                    return .success(CanvasText.rendered(text))
                case .absent:
                    return .failure(CanvasFileFailure(reason: "the document is no longer there"))
                case .outside:
                    return .failure(CanvasFileFailure(reason: "the document is outside its store"))
                case let .failed(why): return .failure(CanvasFileFailure(reason: why))
                }
            }.value
            guard !Task.isCancelled else { return }
            switch read {
            case let .success(value): text = value
            case let .failure(why): failed = why.reason
            }
        }
    }
}
