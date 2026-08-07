import Inject
import SwiftUI

/// The bench on screen: columns side by side, slots stacked inside them.
///
/// **Rendering, and only rendering.** No `if slot.panes.count > 1`, no placement, no
/// close-selects-neighbour — every one of those is a `Workbench` method, which is the
/// whole point of building the bench as a value first. Three times in two days the real
/// defect in this codebase was logic trapped in a `View` where no test could reach it;
/// this file is the answer to that, and stays worth checking by grepping it for `count`,
/// `first`, `firstIndex` and `isEmpty`.
///
/// The sizes are `SplitStack`'s, and computed from the bench rather than measured off the
/// screen — see that file for what measuring cost (#90).
struct WorkbenchView: View {
    @ObserveInjection private var inject
    @ObservedObject var model: WorkbenchModel
    let workspaceRoot: String?

    /// The smallest a column may be dragged to, and a slot below it. Held here rather than
    /// in `SplitStack` because they are this bench's judgement about its own tenants: a
    /// terminal narrower than this has nothing readable in it, and a slot shorter than this
    /// has lost its tab strip.
    static let minimumColumnWidth: CGFloat = 240
    static let minimumSlotHeight: CGFloat = 80

    var body: some View {
        Group {
            if let bench = model.bench {
                // The bench's own size, so a column can turn its fraction into points and
                // a slot can do the same one level down. The only measurement left in the
                // file, and it drives the layout rather than being written back into it.
                GeometryReader { geo in
                    SplitStack(
                        axis: .horizontal, extent: geo.size.width, members: bench.columns,
                        fraction: { $0.width }, minimumExtent: Self.minimumColumnWidth,
                        resize: { model.resizeColumn($0, to: $1, against: $2) }
                    ) { column in
                        ColumnView(
                            model: model, bench: bench, column: column, height: geo.size.height,
                            workspaceRoot: workspaceRoot)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            } else if let offer = model.restoreOffer {
                // A nil bench with an offer beside it is a *mount waiting on an answer* (#85),
                // not an empty helm. Both are nil because `Workbench`'s first invariant is
                // that a bench always holds a pane — the offer is what tells them apart.
                BenchRestoreOfferView(offer: offer) { model.answer($0) }
            } else {
                // No workspace open, so there is no bench — `Workbench`'s first invariant
                // is that a bench always holds a pane, so this is nil rather than empty.
                EmptyBench()
            }
        }
        // Which agent is in which pane (#63). Driven from a `.task` for `BoardModel.poll`'s
        // reason: SwiftUI cancels it on teardown, so the loop's lifetime is the window's. The
        // state it writes lives on the model, which outlives any single render.
        .task { await model.watchAgents() }
        .enableInjection()
    }
}

// MARK: - The empty bench

/// What helm shows with no workspace open — a fresh install, and the state it returns to
/// when the last workspace is closed.
///
/// **It was a `ContentUnavailableView`, and that is what #149 is about.** A SwiftUI system
/// component styles its title, description and glyph from AppKit, so the most-seen surface
/// in the app was the one surface that spent none of `Design/Palette.swift` — a live
/// instance of the defect the palette exists to remove, on the first thing anyone sees.
///
/// **It offers the action rather than naming a keystroke.** The old copy said "choose a
/// folder with ⌘⇧O" — a thing to remember, and written backwards besides (macOS prints
/// modifiers ⌃⌥⇧⌘, so it is ⇧⌘O, which is what the status bar already said). The button is
/// one click; the key is still shown beside it, rendered from `Shortcut.all` through
/// `KeyGlyph.binding` so the two can no longer disagree.
///
/// **It posts rather than opening the panel itself.** `WorkspaceBar` owns the `NSOpenPanel`
/// and already listens for `.openWorkspace`, so the button, the bar's `+` and ⇧⌘O are
/// one path with one behaviour. A second panel here would be a second answer to "what does
/// opening a workspace do".
///
/// **`ViewThatFits` because the bench is not always a pane.** With the rail open and a short
/// window this space is a band, and a column laid out for a full pane renders into a strip
/// with its rhythm collapsed — which is how the issue's capture looked. The horizontal form
/// is the fallback, not a second design.
private struct EmptyBench: View {
    /// nil only if the row is ever removed from the map, in which case the button stands
    /// alone rather than claiming a key that does not fire.
    private let keys = KeyGlyph.binding(for: .openWorkspace)

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 18) {
                glyph(size: 34)
                VStack(spacing: 6) {
                    heading
                    detail
                }
                openButton
            }
            HStack(spacing: 14) {
                glyph(size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    heading
                    detail
                }
                openButton
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surface)
    }

    private func glyph(size: CGFloat) -> some View {
        Image(systemName: "folder")
            .font(.system(size: size, weight: .light))
            .foregroundStyle(Color.textFaint)
    }

    private var heading: some View {
        Text("Open a workspace")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
    }

    private var detail: some View {
        Text("A workspace is a folder. helm opens a terminal in it.")
            .font(.system(size: 12))
            .foregroundStyle(Color.textMuted)
            .multilineTextAlignment(.center)
    }

    private var openButton: some View {
        Button {
            HelmCommand.openWorkspace.post()
        } label: {
            HStack(spacing: 8) {
                Text("Choose Folder…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                if let keys {
                    Text(keys)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.textFaint)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.surfaceRaised, in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(Color.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(keys.map { "Open a folder as a workspace (\($0))" } ?? "Open a folder as a workspace")
    }
}

// MARK: - Column

private struct ColumnView: View {
    @ObserveInjection private var inject
    @ObservedObject var model: WorkbenchModel
    let bench: Workbench
    let column: Column
    /// The bench's height, which is the column's — columns span it. Handed down rather
    /// than measured, so a slot's height is known at the first layout instead of after one.
    let height: CGFloat
    let workspaceRoot: String?

    var body: some View {
        SplitStack(
            axis: .vertical, extent: height, members: column.slots,
            fraction: { $0.height }, minimumExtent: WorkbenchView.minimumSlotHeight,
            resize: { model.resizeSlot($0, to: $1, against: $2) }
        ) { slot in
            SlotView(
                model: model, bench: bench, slot: slot, workspaceRoot: workspaceRoot)
        }
        .enableInjection()
    }
}

// MARK: - Slot

private struct SlotView: View {
    @ObserveInjection private var inject
    @ObservedObject var model: WorkbenchModel
    let bench: Workbench
    let slot: Slot
    let workspaceRoot: String?

    var body: some View {
        VStack(spacing: 0) {
            SlotTabStrip(
                model: model, slot: slot, isFocused: slot.id == bench.focusedSlot,
                workspaceRoot: workspaceRoot)
            // A palette hairline rather than `Divider()`: a system separator is one more
            // colour from one more source, which is the thing the palette exists to end.
            Color.border.frame(height: 1)
            content
                // Clicking a pane's body is the operator saying *this is the pane I mean now*,
                // exactly as clicking its tab is — and until #152 only the tab said it. One
                // reporter per slot rather than one per pane type: it sits below whatever the
                // slot renders, so a terminal grid, a chat face and a canvas all report the
                // same way, and focus is measured in slots regardless.
                //
                // Behind the content rather than over it. The reporter takes no part in hit
                // testing at all — it reads a local event monitor — so nothing it covers stops
                // working, and putting it in front would only risk that.
                .background(PaneClickReporter { model.focus(slot.id) })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .enableInjection()
    }

    @ViewBuilder
    private var content: some View {
        if let pane = slot.panes.first(where: { $0.id == slot.selected }) {
            paneContent(pane)
                // Mandatory, and it must be the stable pane id and nothing else. An
                // NSViewRepresentable can never swap its NSView instance in place, and a
                // CHANGING `.id()` does not update a view — it replaces it, which re-runs
                // `makeNSView` and kills the pty. Never derive this from an index, a
                // title or a generation.
                .id(pane.id)
        }
    }

    @ViewBuilder
    private func paneContent(_ pane: Pane) -> some View {
        switch pane.content {
        case let .terminal(face, _):
            if let session = model.session(for: pane) {
                VStack(spacing: 0) {
                    // Above the terminal rather than over it (#63): the shell underneath is
                    // live and usable, and an overlay on a pane the operator may simply want
                    // to type in is the seizing the offer exists to avoid. It is absent when
                    // there is nothing to ask, which is every pane on a normal launch.
                    if let offer = model.resumeOffers[pane.id] {
                        AgentResumeBar(
                            offer: offer,
                            resume: { model.resume(pane.id) },
                            dismiss: { model.dismissResume(pane.id) })
                    }
                    // `focusedPane` is the bench's own reader — the focused slot's selected
                    // pane — so which terminal owns the keyboard is one question with one
                    // answer, asked where the answer lives rather than re-derived per slot.
                    TerminalPaneView(
                        session: session, face: face,
                        holdsKeyboard: bench.focusedPane?.id == pane.id)
                }
            }
        case .canvas:
            CanvasView(model: model.canvas(for: pane), post: postHandler)
        }
    }

    /// nil when there is nowhere unambiguous to send notes, which is what leaves the
    /// canvas's `Post` disabled with a reason rather than silently doing nothing.
    private var postHandler: ((String) -> Void)? {
        guard model.composeTarget != nil else { return nil }
        return { model.post($0) }
    }
}
