import SwiftUI

/// The workflow Send launches, on screen beside the composer, and the list it is picked from
/// (#528).
///
/// It used to sit behind the settings icon, in a `Picker` menu: the rail's rule was that
/// "which workflow Enter launches is one click away, not on screen", and the operator then
/// could not find it at all. A project has thirty-odd workflows, so the list is searched rather
/// than scrolled, with the ⌘K palette's matcher (`ArchonModel.workflows(matching:)`).
///
/// **The list is drawn over the drawer's run list rather than in a popover.** The drawer has the
/// room, the keyboard stays in the window it was in, and a popover is a window of its own that
/// `bench get screenshot` cannot draw.
struct ArchonWorkflowLabel: View {
    @ObservedObject var model: ArchonModel
    let workspacePath: WorkspacePath?

    var body: some View {
        Button {
            if model.isPickingWorkflow {
                model.isPickingWorkflow = false
            } else {
                Task { await model.openWorkflowPicker(in: workspacePath) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.config.workflow.isEmpty ? "choose a workflow" : model.config.workflow)
                    .foregroundStyle(Color.archonViolet)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: model.isPickingWorkflow ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.textMuted)
                if let note = model.workflowNote {
                    Text(note).foregroundStyle(Color.textFaint).lineLimit(1)
                }
            }
            .font(.system(size: 10.5, design: .monospaced))
            .contentShape(Rectangle())
        }
        .buttonStyle(.chrome)
        .disabled(workspacePath == nil)
        .help("The workflow Send launches. Click, or press w in the run list, to change it.")
    }
}

/// The searchable list: type to filter, ↑↓ to move, Return or a click to pick, Esc to close.
struct ArchonWorkflowList: View {
    @ObservedObject var model: ArchonModel
    /// Where the keyboard goes after a pick: the next thing to do is type the instruction.
    let picked: () -> Void
    /// Where it goes after Esc: back to the run list it came from.
    let cancelled: () -> Void
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let matches = model.workflows(matching: query)
        VStack(spacing: 0) {
            TextField("Search workflows", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .focused($fieldFocused)
                .onAppear { fieldFocused = true }
                .onChange(of: query) { selection = 0 }
                .onSubmit { pick(in: matches) }
                .onExitCommand {
                    model.isPickingWorkflow = false
                    cancelled()
                }
                .onKeyPress(.upArrow) { move(-1, in: matches) }
                .onKeyPress(.downArrow) { move(1, in: matches) }
            Color.border.frame(height: 1)
            list(matches)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            // Open on the current choice, so Return alone keeps it.
            selection = matches.firstIndex { $0.name == model.config.workflow } ?? 0
        }
    }

    private func list(_ matches: [ArchonWorkflow]) -> some View {
        ScrollViewReader { scroller in
            ScrollView {
                // One identity per row, the workflow's name: an index `.id` on top of a
                // name-keyed `ForEach` left the lazy stack drawing the unfiltered rows under a
                // filtered query, measured on the isolated build.
                VStack(spacing: 0) {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, workflow in
                        row(workflow, picked: index == selection)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: selection) { scroll(scroller, to: selection, in: matches) }
            .onAppear { scroll(scroller, to: selection, in: matches) }
            .overlay {
                if matches.isEmpty {
                    Text(model.isLoadingWorkflows ? "Loading…" : "Nothing matches")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.textFaint)
                        .padding(12)
                }
            }
        }
    }

    private func row(_ workflow: ArchonWorkflow, picked: Bool) -> some View {
        Button {
            choose(workflow.name)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(workflow.name)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.textPrimary)
                    if workflow.name == model.config.workflow {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.archonViolet)
                    }
                }
                if !workflow.description.isEmpty {
                    Text(workflow.description)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.textFaint)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(picked ? Color.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.chrome)
    }

    /// Workflow files Archon could not load are named here, beside the list they are missing
    /// from, rather than nowhere.
    @ViewBuilder
    private var footer: some View {
        if !model.workflowLoadErrors.isEmpty {
            Color.border.frame(height: 1)
            Text("\(model.workflowLoadErrors.count) workflow file(s) could not be loaded.")
                .font(.caption)
                .foregroundStyle(Color.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
    }

    private func scroll(_ scroller: ScrollViewProxy, to index: Int, in matches: [ArchonWorkflow]) {
        guard matches.indices.contains(index) else { return }
        scroller.scrollTo(matches[index].id)
    }

    private func move(_ delta: Int, in matches: [ArchonWorkflow]) -> KeyPress.Result {
        guard !matches.isEmpty else { return .handled }
        selection = min(max(selection + delta, 0), matches.count - 1)
        return .handled
    }

    private func pick(in matches: [ArchonWorkflow]) {
        guard matches.indices.contains(selection) else { return }
        choose(matches[selection].name)
    }

    private func choose(_ name: String) {
        model.pick(name)
        picked()
    }
}
