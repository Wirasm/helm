import SwiftUI

/// The comment field that appears over a selection, and the accumulated notes behind the
/// header's `Notes (n)`.
///
/// **No decisions here.** Anchoring is `CanvasHTML.annotationScript()`'s, validation is
/// `CanvasAnnotation.decode`'s, the sidecar's path and shape are `CanvasNotes`'s, and what
/// to do when either refuses is `CanvasModel.annotate(comment:)`'s. This file draws.
struct CanvasCommentField: View {
    @ObservedObject var model: CanvasModel
    let selection: CanvasSelection

    @State private var comment = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "quote.opening")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(quoted)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                TextField("What about this?", text: $comment, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .font(.system(size: 12))
                    .focused($focused)
                    .onSubmit(submit)

                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Write this note to the sidecar")
            }
        }
        .padding(10)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .shadow(radius: 8, y: 2)
        .onAppear { focused = true }
        .onExitCommand { model.dismissSelection() }
    }

    private var quoted: String {
        (selection.body["text"] as? String) ?? ""
    }

    private func submit() {
        model.annotate(comment: comment)
        comment = ""
    }
}

// MARK: - The accumulation

/// The notes already written, and `Post`.
struct CanvasNotesList: View {
    @ObservedObject var model: CanvasModel
    /// Hand the accumulation to the focused pane's composer. Nil when this canvas is not
    /// mounted in a bench, which is only ever a preview.
    let post: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(model.notes.enumerated()), id: \.offset) { _, heading in
                        Text(heading)
                            .font(.system(size: 11))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 260)

            Divider()

            HStack(spacing: 8) {
                Button("Reveal in Finder") { model.revealNotes() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if let markdown = model.notesMarkdown {
                    Button("Post") { post?(markdown) }
                        .font(.system(size: 11))
                        .disabled(post == nil)
                        .help(
                            post == nil
                                ? "Open a terminal's reading face (⌘T) to post these"
                                : "Hand these notes to the agent's composer")
                }
            }
            .padding(10)
        }
        .frame(width: 340)
    }
}
