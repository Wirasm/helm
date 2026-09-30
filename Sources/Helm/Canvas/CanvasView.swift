import AppKit
import HelmWire
import Inject
import SwiftUI

// MARK: - View

/// A canvas pane: a header naming the file, over the rendered file.
struct CanvasView: View {
    /// Hot reload: `.enableInjection()` below redraws this view when
    /// InjectionNext swaps a recompiled build of it into the running app.
    /// Both are no-ops in release (docs/VENDORED.md).
    @ObserveInjection private var inject
    @ObservedObject var model: CanvasModel

    var body: some View {
        if let document = model.showing {
            VStack(spacing: 0) {
                header(for: document)
                Divider()
                // Its own `if`, not an arm of the chain below: an update helm is holding back
                // and a note that failed to write are unrelated facts about different things,
                // and either hiding the other would be helm choosing which of the operator's
                // problems they are allowed to see.
                if let update = model.updateNotice {
                    updateStrip(update)
                }
                // Its own `if`, for the reason given directly above. This one asks rather than
                // reports, so it is the second strip carrying buttons — and it is above the write
                // failure deliberately: a conflict is *why* nothing is being written, so a
                // failure under it would be the symptom above the cause.
                if let conflict = model.conflictNotice {
                    conflictStrip(conflict)
                }
                // Its own `if`, for the reason given directly above: an edit that would not save
                // and a comment that would not write are facts about two different files, and
                // hiding either behind the other is helm choosing which of the operator's
                // problems they are allowed to see.
                if let failure = model.writeFailure {
                    noticeStrip(failure, symbol: "exclamationmark.triangle")
                }
                if let failure = model.notesFailure {
                    noticeStrip(failure, symbol: "exclamationmark.triangle")
                } else if let notice = model.notesNotice {
                    noticeStrip(notice, symbol: "checkmark.circle")
                }
                fileContent(for: document)
                    // Over the artifact, never squeezing it: the page keeps its layout and
                    // its scroll position, and the drawer is temporary.
                    .overlay(alignment: .trailing) { notesDrawer }
                    .animation(.easeOut(duration: 0.16), value: model.showsNotes)
                    // The comment field is drawn over the page rather than beside it, so
                    // the selection it is about stays visible under it. **After** the
                    // drawer, so it is on top of one: a mark on the trailing half puts the
                    // field over the drawer, and the field is the thing being typed into.
                    .overlay(alignment: .topLeading) { commentField }
            }
            .background(Color.surface)
            // Inside the `if`: the body is a bare ViewBuilder conditional with
            // no else, so there is no single view to hang this on outside it.
            .enableInjection()
        }
    }

    /// The sidecar over the trailing half of the pane. Sized from the pane it is over
    /// rather than from a fixed number, by `CanvasNotesDrawerMetrics`.
    @ViewBuilder
    private var notesDrawer: some View {
        if model.showsNotes {
            GeometryReader { proxy in
                CanvasNotesDrawer(model: model)
                    .frame(
                        width: CanvasNotesDrawerMetrics.width(inPaneOf: proxy.size.width),
                        height: proxy.size.height
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    /// Anchored near the selection the page reported, clamped so a selection at the
    /// bottom of a long document does not put the field off screen.
    @ViewBuilder
    private var commentField: some View {
        if let selection = model.selection {
            CanvasCommentField(model: model, selection: selection)
                .offset(
                    x: max(8, selection.rect.minX),
                    y: max(8, selection.rect.maxY + 8))
        }
    }

    /// The one strip that carries an action. Everything else helm says above a canvas is a
    /// receipt — this is a question, because the answer costs the operator their page.
    private func updateStrip(_ message: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise.circle")
                Text(message).lineLimit(2)
                Spacer()
                Button("Reload") { model.reloadArtifact() }
                    .buttonStyle(.chrome)
                    .foregroundStyle(Color.accent)
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.textMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.surfaceRaised)
            Divider()
        }
    }

    /// The second strip that carries actions, and the only one that carries two (#289).
    ///
    /// **Both buttons cost the operator something, so both are his to press and neither is
    /// default-styled into looking safe.** helm has already refused to write; what is left is a
    /// choice it has no standing to make — whether an agent's rewrite or his own half-sentence is
    /// the one that survives. The tooltips say which is which in full, because "Keep mine" and
    /// "Take theirs" are only unambiguous when read together.
    private func conflictStrip(_ message: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                Text(message).lineLimit(2)
                Spacer()
                Button("Keep mine") { model.keepMine() }
                    .buttonStyle(.chrome)
                    .foregroundStyle(Color.accent)
                    .help("Write what you have typed over the version on disk")
                Button("Take theirs") { model.takeTheirs() }
                    .buttonStyle(.chrome)
                    .foregroundStyle(Color.accent)
                    .help("Load the version on disk and lose what you have typed")
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.textMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.surfaceRaised)
            Divider()
        }
    }

    private func noticeStrip(_ message: String, symbol: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(message).lineLimit(2)
                Spacer()
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.textMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.surfaceRaised)
            Divider()
        }
    }

    /// Write ⇄ Read, on a markdown canvas.
    ///
    /// **Read is the state it starts in, and Write is a press.** That is the operator's own line
    /// — *"there should be a read mode and editor mode, default is read"* — and it is why an
    /// editable canvas is indistinguishable from a read-only one until he asks.
    ///
    /// Accent while writing, the same way a held tool and an open drawer already say which way
    /// they are pointing — one treatment for "this control is on", spent at a third site rather
    /// than a third treatment invented for it.
    private var writeToggle: some View {
        Button {
            if model.draft == nil { model.write() } else { model.read() }
        } label: {
            Text(model.draft == nil ? "Write" : "Read")
                .font(.system(size: 11))
                .frame(minWidth: 32)
        }
        .buttonStyle(.chrome)
        .foregroundStyle(model.draft == nil ? Color.textMuted : Color.accent)
        .help(model.draft == nil ? "Edit this file" : "Render this file")
    }

    /// The tools, as chrome on the canvas rather than a mode you have to know about.
    ///
    /// Two small buttons instead of a `Picker`: a segmented control would grow the header
    /// by its own chrome, and this sits beside three existing icon buttons that already
    /// establish the shape.
    ///
    /// **`.read` is in the picker rather than implied by nothing being lit** (#302), and it is
    /// the one that starts lit. A mode with no button is a mode the operator cannot see they
    /// are in — and it is the only tool that is put down by picking it, so leaving it out
    /// would also mean the only route back to reading is knowing that pressing the held tool
    /// again does it.
    private var markPicker: some View {
        HStack(spacing: 2) {
            ForEach(CanvasMarkTool.allCases, id: \.self) { tool in
                Button {
                    model.pick(tool)
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 11))
                        .frame(width: 20, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(model.markTool == tool ? Color.selection : .clear))
                }
                .buttonStyle(.chrome)
                .foregroundStyle(model.markTool == tool ? Color.accent : Color.textMuted)
                .help(tool.help)
            }
        }
    }

    /// The writing face, when there is an editable file and the operator is in it.
    ///
    /// **Ahead of `document.content` rather than a case inside it**, because a draft is about the
    /// file and not about what helm made of its bytes: a file the operator has emptied loads as
    /// `.markdown("")` and one that has just been deleted under them loads as `.notice`, and
    /// switching them out of the editor on either would drop what they were typing.
    @ViewBuilder
    private func fileContent(for document: CanvasModel.Document) -> some View {
        if let editable = model.editable, let draft = model.draft {
            CanvasEditorView(model: model, file: editable, draft: draft)
        } else {
            renderedContent(for: document)
        }
    }

    @ViewBuilder
    private func renderedContent(for document: CanvasModel.Document) -> some View {
        switch document.content {
        case let .markdown(markdown):
            MarkdownCanvasView(
                url: document.url, files: model.files, markdown: markdown,
                generation: document.generation,
                markTool: model.markTool, showsMark: model.showsMark,
                onSelection: model.pageDidReport)
        case .web:
            // The only canvas that can take an update as data: an `.html` artifact is read
            // straight from disk, so its own scripts run and one of them may be
            // `window.helmCanvasUpdate`. A markdown canvas is a page helm *generates* —
            // `marked` writes the artifact into `innerHTML`, where a `<script>` never executes
            // — so there is no author's code on it to register a handler, and it reloads
            // exactly as it always has.
            HTMLCanvasView(
                url: document.url, files: model.files, generation: document.generation,
                markTool: model.markTool, showsMark: model.showsMark,
                onSelection: model.pageDidReport,
                changes: document.changes,
                reloadDemand: model.reloadDemand, onUpdate: model.pageAnsweredUpdate,
                onDataWrite: model.pageWroteData)
        case let .plainText(text):
            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        case let .notice(message):
            Text(message)
                .foregroundStyle(Color.textMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
        }
    }

    private func header(for document: CanvasModel.Document) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(Color.textMuted)
            // **The name is the handle to the file, so it hands the file over.** What you
            // most often want from an open canvas is where it is — to pass to an agent, to
            // paste into a shell — and the path was already here as a tooltip, which is a
            // thing you can read and not take. The tooltip stays and the click is added.
            CopyableLabel(
                value: Pasteboard.path(of: document.url),
                hint: "Click to copy \(Pasteboard.path(of: document.url))"
            ) {
                Text(document.url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            // **Only on a markdown file, which is the visible half of the scope line.** An
            // `.html` artifact, a plain-text file and a sidecar have no Write button at all —
            // there is nothing to click and nothing to explain.
            if model.editable != nil {
                writeToggle
            }
            // Nothing to mark while writing: the page is not on screen, and a picker over a text
            // editor would be buttons that do nothing.
            if model.draft == nil {
                markPicker
            }
            // Attention as state on an existing element, never a popup: a count on the
            // header, not a badge that pops. It is a toggle now rather than a popover's
            // anchor, and it says which way it is pointing — accent while the drawer is
            // open, the same way a held tool does.
            //
            // Shown for **any** sidecar, not only one with `##` entries in it: the count is
            // helm's own notes, but an agent appending plain prose beside the canvas still
            // put something there to read, and hiding the only way in would be this issue
            // over again.
            if model.hasNotes {
                Button {
                    model.toggleNotes()
                } label: {
                    Text(model.notes.isEmpty ? "Notes" : "Notes (\(model.notes.count))")
                        .font(.system(size: 11))
                }
                .buttonStyle(.chrome)
                .foregroundStyle(model.showsNotes ? Color.accent : Color.textMuted)
                .help("The comments written beside this canvas")
            }
            Button {
                model.revealInFinder()
            } label: {
                Image(systemName: "magnifyingglass.circle").frame(width: 18, height: 18)
            }
            .buttonStyle(.chrome)
            .foregroundStyle(Color.textMuted)
            .help("Reveal in Finder")
            Button {
                model.close()
            } label: {
                Image(systemName: "xmark.circle").frame(width: 18, height: 18)
            }
            .buttonStyle(.chrome)
            .foregroundStyle(Color.textMuted)
            .help("Close artifact")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(Color.textPrimary)
        .background(ChromeBackground())
    }
}
