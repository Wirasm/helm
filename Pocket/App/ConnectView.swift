import HelmWire
import PocketKit
import SwiftUI

/// Which benchd Pocket follows.
struct ConnectView: View {
    @EnvironmentObject private var model: PocketModel
    @Environment(\.dismiss) private var dismiss
    @Binding var url: String
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("benchd").font(Mono.title).foregroundStyle(Palette.text)
            TextField(
                "", text: $draft,
                prompt: Text("tcp://host:port").foregroundStyle(Palette.faint)
            )
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .foregroundStyle(Palette.text)
            .onSubmit(connect)
            if case let .disconnected(why) = model.state {
                Text(why).font(Mono.small).foregroundStyle(Palette.dim)
            }
            Button("connect", action: connect)
                .foregroundStyle(Palette.finished)
            Spacer()
        }
        .font(Mono.body)
        .padding(16)
        .background(Palette.sheet)
        .presentationDetents([.medium])
        .onAppear { draft = url }
    }

    /// RootView connects when the URL changes; a draft that is no URL stays here, refused.
    private func connect() {
        url = draft
        if BenchEndpoint.tcp(draft) != nil { dismiss() }
    }
}
