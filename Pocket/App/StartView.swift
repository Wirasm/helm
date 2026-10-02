import PocketKit
import SwiftUI

/// start: a new orchestrator in a workspace, with its harness, model, effort and first message.
/// benchd records it as the operator's, so home pins it, and moves no focus on the Mac.
struct StartView: View {
    @EnvironmentObject private var model: PocketModel
    @Environment(\.dismiss) private var dismiss
    @State private var workspace = ""
    @State private var agent = "claude"
    @State private var modelName = ""
    @State private var effort = ""
    @State private var task = ""
    @State private var starting = false
    @State private var refused: String?

    private static let agents = ["claude", "codex", "pi"]
    /// "" is the harness's own default.
    private static let efforts = ["", "low", "medium", "high", "xhigh"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("start").font(Mono.title).foregroundStyle(Palette.text)
            field("workspace") {
                Picker("", selection: $workspace) {
                    ForEach(model.workspaces, id: \.self) { path in
                        Text(URL(fileURLWithPath: path).lastPathComponent).tag(path)
                    }
                }
                .tint(Palette.text)
            }
            field("agent") { choices(Self.agents, $agent) { $0 } }
            field("model") {
                TextField(
                    "", text: $modelName, prompt: Text("default").foregroundStyle(Palette.faint)
                )
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
            }
            field("effort") { choices(Self.efforts, $effort) { $0.isEmpty ? "default" : $0 } }
            TextField(
                "", text: $task, prompt: Text("task…").foregroundStyle(Palette.faint),
                axis: .vertical
            )
            .lineLimit(3...6)
            if let refused { Text(refused).font(Mono.small).foregroundStyle(Palette.asking) }
            Button(action: start) {
                Text(starting ? "starting…" : "start").frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Palette.finished, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(Palette.background)
            }
            .disabled(starting || workspace.isEmpty || task.isEmpty)
            Spacer()
        }
        .font(Mono.body)
        .foregroundStyle(Palette.text)
        .padding(16)
        .background(Palette.sheet)
        .presentationDetents([.large])
        .onAppear { workspace = workspace.isEmpty ? model.workspaces.first ?? "" : workspace }
    }

    private func field(_ label: String, @ViewBuilder _ value: () -> some View) -> some View {
        HStack {
            Text(label).foregroundStyle(Palette.dim)
            Spacer()
            value()
        }
    }

    private func choices(
        _ options: [String], _ selection: Binding<String>, label: @escaping (String) -> String
    ) -> some View {
        HStack(spacing: 12) {
            ForEach(options, id: \.self) { option in
                Button(label(option)) { selection.wrappedValue = option }
                    .foregroundStyle(selection.wrappedValue == option ? Palette.text : Palette.dim)
                    .underline(selection.wrappedValue == option)
            }
        }
    }

    private func start() {
        guard !starting else { return }
        starting = true
        Task {
            refused = await model.start(
                agent, in: workspace, model: modelName.isEmpty ? nil : modelName,
                effort: effort.isEmpty ? nil : effort, prompt: task)?.description
            starting = false
            if refused == nil { dismiss() }
        }
    }
}
