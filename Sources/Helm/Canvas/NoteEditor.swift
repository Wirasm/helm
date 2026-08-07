import SwiftUI

// MARK: - What is in the editor, and what is on disk

/// The operator's note as it stands: what they have typed, and what helm last saw on disk.
///
/// **Two strings rather than one plus a dirty flag**, because the interesting question is not
/// *"has something changed"* but *"is what I am looking at what is in the file"* — and the honest
/// answer to that is a comparison, not a bit somebody has to remember to set. A flag has two
/// writers (typing sets it, saving clears it) and a save that fails halfway through clearing it is
/// a note the operator believes is written.
///
/// `saved` moves only when a write **succeeded**, so a failed save leaves `isDirty` true and the
/// next keystroke schedules another attempt. That is the whole of "saving must not lose work":
/// nothing is ever thrown away on the strength of a write helm did not see finish.
struct NoteDraft: Equatable {
    /// What is in the editor right now.
    var text: String
    /// What helm believes is on disk — what it wrote, or what it read when the editor opened.
    var saved: String
    /// When `saved` was written. nil until the first successful save, which is also the state a
    /// note the operator has typed nothing into is in.
    var savedAt: Date?

    var isDirty: Bool { text != saved }

    init(text: String, saved: String, savedAt: Date? = nil) {
        self.text = text
        self.saved = saved
        self.savedAt = savedAt
    }

    /// What the footer says about the file, in the operator's terms.
    ///
    /// **It says "Unsaved" while a save is pending, and that is deliberate rather than pessimistic
    /// wording.** helm writes a beat after typing stops, so for most of a sentence the file on
    /// disk genuinely is behind the screen — a label claiming otherwise would be the reassurance
    /// that makes an operator close the lid.
    ///
    /// A property on the value rather than a string built in the view, so the rule is reachable
    /// from `swift test` and there is one place it is written.
    var status: String {
        if isDirty { return "Unsaved" }
        guard let savedAt else { return "Empty note" }
        return "Saved \(Self.timeFormatter.string(from: savedAt))"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

// MARK: - The writing face

/// A note the operator is writing: the markdown source in a plain text view, with the file's own
/// path under it.
///
/// **A `TextEditor` over the markdown source, not an editable rendering — and the reason is what
/// the two things ARE.** A markdown canvas is a page helm *generates*: `marked` converts the
/// artifact and writes the result into `innerHTML`. Making that editable would mean turning HTML
/// back into markdown on every keystroke, which is a lossy round trip over a document nobody asked
/// helm to reformat. The markdown text *is* the file, so editing it is the identity operation —
/// what is typed is what is written, byte for byte, and `Read` renders it with exactly the
/// renderer that has always rendered it.
///
/// **It also means the annotation bridge is not involved at all.** With `.select` armed, dragging
/// over text on the page is a mark; that is what makes editing *on the page* the wrong shape today
/// and it is being split apart in parallel. This surface never has the page on screen, so it needs
/// nothing from that work and does not have to wait for it.
struct NoteEditorView: View {
    @ObservedObject var model: CanvasModel
    let note: OperatorNote
    let draft: NoteDraft

    /// **The point of ⌘⇧N is that the cursor is already in it.** A new note that needs a click
    /// before it takes a character is a blank pane, not a place to think.
    @FocusState private var writing: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Color.textPrimary)
                // `TextEditor` paints its own AppKit background, which is the fourth colour source
                // `Design/Palette.swift` exists to have removed. Hiding it lets `surface` through
                // — the same plane the rendered canvas and the terminal are on.
                .scrollContentBackground(.hidden)
                .background(Color.surface)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .focused($writing)
                .onAppear { writing = true }
            Color.border.frame(height: 1)
            footer
        }
        .background(Color.surface)
    }

    /// The editor writes through the model, never into a local `@State`.
    ///
    /// A `@State` copy would be a second place the note lives, and the one that is not saved. The
    /// model owns the draft because it also owns the file, the save timer and the watcher — and
    /// because it outlives this view, which SwiftUI rebuilds on any churn in a sibling pane.
    private var text: Binding<String> {
        Binding(get: { draft.text }, set: { model.edit($0) })
    }

    /// **The path, in full, and copyable — because handing it over is the point of the feature.**
    /// The operator's own words in #289 are *"I can just send the path to you of the file"*, so
    /// the minimum this surface owes him is a path he can read and take.
    ///
    /// **It is not put on the clipboard when the note is created.** Taking a note is not asking
    /// for the clipboard to change, and a clipboard that changes under an act nobody asked for
    /// destroys whatever was in it. `CopyableLabel` is the affordance the canvas header already
    /// uses for exactly this, so the gesture is one the operator has already learned here.
    private var footer: some View {
        HStack(spacing: 8) {
            CopyableLabel(
                value: Pasteboard.path(of: note.url),
                hint: "Click to copy \(Pasteboard.path(of: note.url))"
            ) {
                Text(Pasteboard.path(of: note.url))
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(draft.status)
                .font(.system(size: 10))
                .foregroundStyle(draft.isDirty ? Color.textFaint : Color.textMuted)
                .fixedSize()
        }
        .foregroundStyle(Color.textMuted)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.surfaceRaised)
    }
}
