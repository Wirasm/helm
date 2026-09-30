import HelmWire
import SwiftUI

/// A path the operator types, checked by benchd before anything uses it (M5c, #459): ⇧⌘O's
/// folder and the artifact browser's "open a file by path". It replaces Finder's open panel,
/// which could only ever show the Mac's disk; benchd's machine is where the work is, and `~`
/// means benchd's home there (`PrpStores.resolve`).
///
/// Return submits. A path benchd refuses, or one of the wrong kind, stays in the field with
/// benchd's reason under it, so the operator can correct it rather than start again.
struct BenchPathField: View {
    let prompt: String
    let wants: BenchPathResolved.Kind
    let prp: PrpStores
    /// benchd's absolute path, once it has said there is a `wants` there.
    let onResolved: (String) -> Void

    @State private var text = ""
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(prompt, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit(submit)
                .onChange(of: text) { failure = nil }
            if let failure {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func submit() {
        switch prp.resolve(text, as: wants) {
        case let .success(path): onResolved(path)
        case let .failure(why): failure = why.reason
        }
    }
}
