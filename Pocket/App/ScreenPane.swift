import HelmWire
import PocketKit
import SwiftUI

/// The chat's raw terminal (its `screen` toggle): the session's screen ten times a second, as
/// `bench watch screen` reads it, and the keys row, for whatever the chat cannot answer.
struct ScreenPane: View {
    @EnvironmentObject private var model: PocketModel
    /// The target `screen/get` and `screen/send` take: the session, or the pane showing it.
    let target: String
    @State private var screen: BenchScreen?
    @State private var unreachable: String?
    @State private var refused: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Top-left as a terminal draws, at least the viewport's size so a short screen does
            // not float in the middle; a wider or taller one scrolls, showing its bottom first.
            GeometryReader { viewport in
                ScrollView([.vertical, .horizontal]) {
                    Text((screen?.lines ?? []).joined(separator: "\n"))
                        .font(Mono.screen).foregroundStyle(Palette.text)
                        .fixedSize()
                        .frame(
                            minWidth: viewport.size.width, minHeight: viewport.size.height,
                            alignment: .topLeading)
                }
                .defaultScrollAnchor(.bottomLeading)
            }
            if let why = refused ?? unreachable {
                Text(why).font(Mono.small).foregroundStyle(Palette.asking).lineLimit(2)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 22) {
                    ForEach(PocketKey.allCases, id: \.self) { key in
                        Button(key.label) {
                            Task { refused = await model.send(key.input, to: target)?.description }
                        }
                    }
                }
                .font(Mono.body).foregroundStyle(Palette.dim)
                .padding(.vertical, 4)
            }
        }
        .task(id: target) { await follow() }
    }

    private func follow() async {
        screen = nil
        while !Task.isCancelled {
            switch await model.screen(target) {
            case let .success(next):
                if next != screen { screen = next }
                unreachable = nil
            case let .failure(why): unreachable = why.description
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
