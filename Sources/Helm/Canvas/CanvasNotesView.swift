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
                    .foregroundStyle(Color.textMuted)
                Text(quoted)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textMuted)
                    .lineLimit(2)
                Spacer(minLength: 4)
                // The way out, drawn. Escape is `.onExitCommand` below and travels the
                // responder chain, so it is gone the moment focus is elsewhere — this is
                // not, and it also says the field can be closed at all (#165).
                Button {
                    model.dismissSelection()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.textMuted)
                .help("Dismiss without writing a note (esc)")
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
        .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.border))
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

/// How much of the canvas the drawer takes. A rule rather than a number in a view, so
/// "roughly half, and never a ribbon" is something `swift test` can hold.
enum CanvasNotesDrawerMetrics {
    /// Half the pane. Over, never squeezing — the artifact keeps its layout underneath.
    static let fraction: CGFloat = 0.5
    /// Below this a column of prose stops being readable and starts being a ribbon, so a
    /// narrow canvas gives the drawer more than half rather than less.
    static let minimum: CGFloat = 280

    /// **Never wider than the pane.** A drawer hanging off the edge of a narrow column
    /// would put Post and Reveal — the only route to either now — outside the window.
    static func width(inPaneOf paneWidth: CGFloat) -> CGFloat {
        guard paneWidth > 0 else { return minimum }
        return min(paneWidth, max(minimum, paneWidth * fraction))
    }

    /// Space around the prose.
    static let inset: CGFloat = 14

    /// The reading measure — **760, which is the artifact's own** (`CanvasHTML`'s
    /// `article { max-width: 760px }`). Half of an ultrawide is 1700pt, and prose set to
    /// that is 200 characters a line: the drawer would be wide and unreadable, which is a
    /// different way of failing this issue. The panel still takes half; the text stops.
    static let measure: CGFloat = 760

    /// How wide the prose is inside a drawer of this width. **A concrete number, not a
    /// `maxWidth`** — a vertical `ScrollView` proposes an unspecified width to its content,
    /// and under that proposal `maxWidth: .infinity` resolves to the *ideal* width instead
    /// of the container's. Measured, on the first live capture of this drawer: a 1720pt
    /// panel with a 515pt column of text in it.
    static func textWidth(inDrawerOf drawerWidth: CGFloat) -> CGFloat {
        max(0, min(drawerWidth - inset * 2, measure))
    }
}

/// The sidecar, over the trailing half of the canvas — **rendered**, not listed (#198).
///
/// **This replaces the popover, and that is the whole feature.** What was here listed
/// headings at `lineLimit(2)` and never showed a single word of what the operator had
/// written; the only way to read a note was Reveal in Finder, which leaves helm. So the
/// drawer renders the file — it is a `.md`, and `MarkdownText` already draws one at a
/// chosen type scale.
///
/// **It renders a file; it never interprets one.** `CanvasNotes.readable` takes the `<sub>`
/// wrapper off the timestamp and nothing else touches the text. Turning a heading back into
/// a `Mark` — which is what hover-highlighting needs — is #199's, and it has to stay #199's:
/// the moment this file parses a heading, the sidecar's headings stop being a rendering and
/// become a format with a round trip to keep honest.
struct CanvasNotesDrawer: View {
    @ObservedObject var model: CanvasModel
    /// Hand the accumulation to the focused pane's composer. Nil when this canvas is not
    /// mounted in a bench, which is only ever a preview.
    let post: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            accumulation
            Divider()
            footer
        }
        // The reading plane, because this is a document being read — the two bars above and
        // below it are the chrome, and read as a step up from it.
        .background(Color.surface)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.border).frame(width: 1)
        }
        .shadow(radius: 10, x: -2)
        .background { escapeCatcher }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.quote")
                .font(.system(size: 10))
                .foregroundStyle(Color.textMuted)
            // The file, named. The drawer is a view onto something on disk, and which file
            // that is answers "why is this not in my artifact" before it is asked.
            Text(model.sidecarURL?.lastPathComponent ?? "Notes")
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.sidecarURL?.path ?? "")
            Spacer(minLength: 4)
            // The way out, drawn — the same argument as the comment field's ✕. Escape is a
            // key equivalent below and the Notes button is up in the header; neither is
            // visible from inside the drawer.
            Button {
                model.toggleNotes()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.textMuted)
            .help("Close the notes (esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(Color.textPrimary)
        .background(Color.surfaceRaised)
    }

    /// The notes themselves, scrolling on their own — the artifact underneath keeps its
    /// scroll position, which is the point of a drawer over a replacement.
    @ViewBuilder
    private var accumulation: some View {
        if let text = model.notesText {
            GeometryReader { proxy in
                ScrollView {
                    MarkdownText(text: CanvasNotes.readable(text))
                        .frame(
                            width: CanvasNotesDrawerMetrics.textWidth(inDrawerOf: proxy.size.width),
                            alignment: .leading
                        )
                        .padding(CanvasNotesDrawerMetrics.inset)
                        // The column is pinned to the drawer's leading edge. A `ScrollView`
                        // centres content narrower than itself, and a measure floating in
                        // the middle of a wide panel reads as a mistake.
                        .frame(width: proxy.size.width, alignment: .leading)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        } else {
            // An empty sidecar has to read as empty rather than as a drawer that failed to
            // load one — they look identical, and only one of them is worth investigating.
            VStack(spacing: 6) {
                Text("No notes yet")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textMuted)
                Text("Mark something on the canvas and comment on it — it lands here.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textFaint)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Reveal in Finder") { model.revealNotes() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.textMuted)
                .disabled(!model.hasNotes)
            Spacer()
            Button("Post") { model.notesMarkdown.map { post?($0) } }
                .font(.system(size: 11))
                .disabled(post == nil || !model.hasNotes)
                .help(
                    post == nil
                        ? "Open a terminal's reading face (⌘T) to post these"
                        : "Hand these notes to the agent's composer")
        }
        .padding(10)
        .background(Color.surfaceRaised)
    }

    /// Escape, as a **key equivalent** rather than `.onExitCommand`: the canvas underneath
    /// is a WKWebView, so the first responder while reading an artifact is inside WebKit and
    /// a responder-chain exit command never reaches this view. `model.escapeClosesNotes` is
    /// what keeps it from stealing the comment field's Escape, which *is* on the chain.
    ///
    /// Zero-sized and transparent rather than `.hidden()`, which would take the shortcut
    /// with it.
    @ViewBuilder
    private var escapeCatcher: some View {
        if model.escapeClosesNotes {
            Button("", action: model.closeNotes)
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }
}
