import HelmWire
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The smallest a column may be dragged to, and a slot below it. Held here rather than
    /// in `SplitStack` because they are this bench's judgement about its own tenants: a
    /// terminal narrower than this has nothing readable in it, and a slot shorter than this
    /// has lost its tab strip.
    static let minimumColumnWidth: CGFloat = 240
    static let minimumSlotHeight: CGFloat = 80

    var body: some View {
        VStack(spacing: 0) {
            // **Above every branch, because the failure it reports happens in all of them.** ⌘⇧N
            // with no workspace open is the empty bench's case; ⌘⇧N against a `~/.prp` helm cannot
            // write to is the mounted one's. A strip inside a pane could say neither, because the
            // whole failure is that no pane was made (#289).
            if let failure = model.noteFailure {
                // Above the bench for the workspace bar's reason (`RootView`).
                noteFailureStrip(failure).zIndex(1)
            }
            bench
        }
        // What has each pane's terminal in benchd (M5b). Driven from a `.task` for
        // `BoardModel.poll`'s reason: SwiftUI cancels it on teardown, so the loop's lifetime is
        // the window's. The state it writes lives on the manager, which outlives any render.
        .task { await model.watchForegrounds() }
        .enableInjection()
    }

    /// One line, in the palette, in the shape a canvas already says things in. Not a dialog: the
    /// operator pressed a key and nothing came of it, which is worth a sentence and not a modal
    /// they have to dismiss before carrying on.
    private func noteFailureStrip(_ message: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                Text(message).lineLimit(2)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.textMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.surfaceRaised)
            Color.border.frame(height: 1)
        }
    }

    @ViewBuilder
    private var bench: some View {
        Group {
            if let bench = model.bench {
                // The bench's own size, so a column can turn its fraction into points and
                // a slot can do the same one level down. The only measurement left in the
                // file, and it drives the layout rather than being written back into it.
                GeometryReader { geo in
                    camera(on: bench, in: geo.size)
                        .environment(\.benchViewport, geo.frame(in: .global))
                }
            } else {
                // No workspace open, so there is no bench — `Workbench`'s first invariant
                // is that a bench always holds a pane, so this is nil rather than empty.
                EmptyBench()
            }
        }
    }
}

// MARK: - The camera

extension WorkbenchView {
    /// The bench laid out in the camera's canvas and panned over the window (⌘J, `BenchCamera`).
    /// Unzoomed, the canvas is the window and the pan is zero, so this is the plain layout.
    ///
    /// **The layout itself animates, not a transform over it.** Each pane really is laid out at
    /// the size it is drawn at, so a terminal resizes with it and its session hears the sizes as
    /// SIGWINCH to `bench attach`, coalesced to one per 16 ms with the last one always sent
    /// (#479). Measured on an isolated suite: one zoom sent each terminal four to six sizes over
    /// about 170 ms, and the last was the size drawn. Reduce Motion makes the change a cut.
    /// Zooming, returning and moving focus while zoomed animate; nothing else does.
    ///
    /// Clipped, because a zoomed canvas runs past the bench on every side and must not paint
    /// over the workspace bar or the status bar.
    fileprivate func camera(on bench: Workbench, in viewport: CGSize) -> some View {
        let camera =
            model.isZoomed ? BenchCamera.framing(bench, in: viewport) : .identity(viewport)
        return SplitStack(
            axis: .horizontal, extent: camera.canvas.width, members: bench.columns,
            fraction: { $0.width }, minimumExtent: Self.minimumColumnWidth,
            resize: {
                model.send(
                    .layoutResize(.columns(member: $0, against: $2), fraction: $1),
                    by: .operatorGesture)
            }
        ) { column in
            ColumnView(
                model: model, bench: bench, column: column, height: camera.canvas.height,
                workspaceRoot: workspaceRoot)
        }
        .frame(width: camera.canvas.width, height: camera.canvas.height)
        .offset(x: -camera.pan.x, y: -camera.pan.y)
        .frame(width: viewport.width, height: viewport.height, alignment: .topLeading)
        .clipped()
        // Keyed on the move, not on the camera: a window being resized changes the camera
        // every frame and must follow the pointer, not ease after it.
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.22),
            value: model.isZoomed ? bench.focusedSlot : nil)
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
/// one click; the key is still shown beside it, rendered from the table in force through
/// `KeyGlyph.binding` so the two can no longer disagree.
///
/// **It asks for the table's own action rather than opening a picker itself**, so the button,
/// the bar's `+` and ⇧⌘O are one path with one behaviour (`WorkspacePicker`). A second picker
/// here would be a second answer to "what does opening a workspace do".
///
/// **`ViewThatFits` because the bench is not always a pane.** In a short window this space
/// is a band, and a column laid out for a full pane renders into a strip
/// with its rhythm collapsed — which is how the issue's capture looked. The horizontal form
/// is the fallback, not a second design.
private struct EmptyBench: View {
    /// nil when nothing binds the action (the operator's keymap file can unbind it), in which
    /// case the button stands alone rather than claiming a key that does not fire.
    @ObservedObject private var keymap = Keymap.shared
    private var keys: String? {
        KeyGlyph.binding(for: .local(.openWorkspacePanel), in: keymap.table)
    }

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
            Actions.perform(.local(.openWorkspacePanel))
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
        .buttonStyle(.chrome)
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
            resize: {
                model.send(
                    .layoutResize(.slots(member: $0, against: $2), fraction: $1),
                    by: .operatorGesture)
            }
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
                // slot renders, so a terminal grid, a browser and a canvas all report the
                // same way, and focus is measured in slots regardless.
                //
                // Behind the content rather than over it. The reporter takes no part in hit
                // testing at all — it reads a local event monitor — so nothing it covers stops
                // working, and putting it in front would only risk that.
                .background(
                    PaneClickReporter { model.send(.focusSlot(slot.id), by: .operatorGesture) })
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
        VStack(spacing: 0) {
            // The kind draws it (`SurfaceKind`). `holdsKeyboard` is the bench's own reader —
            // the focused slot's selected pane — so which pane owns the keyboard is one question
            // with one answer, asked where the answer lives.
            model.surfaceView(of: pane, in: model.surfaceSlot(for: pane, in: slot))
        }
    }
}
