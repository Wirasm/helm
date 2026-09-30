import AppKit
import HelmWire
import SwiftUI

// MARK: - View

/// The artifact browser popover: pick a project, see its artifacts flat and
/// newest-first, click one to open it. A path field below opens any other file benchd can
/// see. Anchored to the strip's artifact button; ⌘O opens this. The listing refreshes on
/// every open. Everything in it is benchd's answer (`PrpStores`): the stores live on the
/// agents' machine (M5c, #459).
struct ArtifactBrowser: View {
    /// What to do with a chosen file — a closure rather than the workbench, so the
    /// browser stays a view over the stores and never learns what a bench is.
    /// *Where* the chosen file lands is benchd's placement, not this view's.
    private let onOpen: (URL) -> Void
    /// The open workspace's repo root (`WorkspaceModel.selectedWorkspaceRoot`), which
    /// preselects ITS store instead of whatever was picked last. A plain value, not the
    /// whole model.
    private let workspaceRoot: String?
    private let onDismiss: () -> Void
    /// benchd, asked about its stores and about a typed path.
    private let prp: PrpStores

    /// Stores, selection and files together, resolved by `ArtifactListing`.
    ///
    /// **Seeded in `init`, not in `onAppear`.** A popover sizes its window once, from
    /// whatever its content is at presentation, and `onAppear` runs after that — so
    /// discovering there sized this popover from the empty placeholder below and left the
    /// real listing to render into an 8pt sliver (#50). Anything that moves this work back
    /// to `onAppear` brings that back. `ArtifactBrowserTests` pins it by constructing a
    /// browser and reading this without ever laying one out.
    @State private(set) var listing: ArtifactListing

    init(
        workspaceRoot: String?,
        prp: PrpStores,
        onOpen: @escaping (URL) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onOpen = onOpen
        self.workspaceRoot = workspaceRoot
        self.prp = prp
        self.onDismiss = onDismiss
        _listing = State(
            initialValue: .load(prp, workspace: workspaceRoot, remembered: Self.rememberedKey)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let failure = listing.failure, listing.stores.isEmpty {
                message("Could not list the artifact stores: \(failure)")
            } else if listing.stores.isEmpty {
                emptyState
            } else {
                Picker("Project", selection: selection) {
                    ForEach(listing.stores) { store in
                        Text(store.name).tag(store.key)
                    }
                }
                .labelsHidden()
                .padding(10)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(listing.files, id: \.path) { file in
                            fileRow(file)
                        }
                        if let failure = listing.failure {
                            message("Could not list this project: \(failure)")
                        } else if listing.files.isEmpty {
                            Text("No artifacts in this project yet.")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.textMuted)
                                .padding(8)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 420)
            }

            Divider()
            BenchPathField(
                prompt: "Open a file by path…", wants: .file, prp: prp
            ) { path in
                onDismiss()
                onOpen(URL(fileURLWithPath: path))
            }
            .padding(10)
        }
        .frame(width: 380)
        .onAppear(perform: refresh)
    }

    /// The picker's binding. Picking a store re-lists and remembers it in one move —
    /// there is no separate `onChange` to fall out of step with the write.
    private var selection: Binding<String> {
        Binding(
            get: { listing.selectedKey },
            set: { key in
                listing = listing.selecting(key, from: prp)
                Self.rememberedKey = key
            }
        )
    }

    /// Re-read on every open, so a store an agent wrote to while the popover was shut is
    /// listed the next time it is opened. The initialiser has already done this once for
    /// the sizing pass; this is what keeps a reopened popover current.
    private func refresh() {
        listing = .load(prp, workspace: workspaceRoot, remembered: Self.rememberedKey)
        Self.rememberedKey = listing.selectedKey
    }

    /// Last-picked store key — the fallback when no workspace is open, or when the open
    /// one has no store yet. Remembered across popover opens and relaunch.
    ///
    /// Plain `UserDefaults` rather than `@AppStorage` because the initialiser has to read
    /// it before the view exists, which is not something a property wrapper bound to a
    /// view's update cycle can promise.
    private static let rememberedKeyDefault = "artifactBrowserStore"

    private static var rememberedKey: String {
        get { DefaultsDomain.store.string(forKey: rememberedKeyDefault) ?? "" }
        set { DefaultsDomain.store.set(newValue, forKey: rememberedKeyDefault) }
    }

    // MARK: Rows

    private func fileRow(_ file: BenchPrpArtifact) -> some View {
        let url = URL(fileURLWithPath: file.path)
        return Button {
            onOpen(url)
            onDismiss()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textMuted)
                    .frame(width: 14)
                Text(file.relative)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(BrowserRowButtonStyle())
        // Pasting an artifact's path into an agent's context is one of the most
        // frequent things done in helm, and it has no cheap route today: artifacts
        // moved out of the repo into ~/.prp, which put them outside every editor
        // that had a "copy path" on them.
        //
        // It used to abbreviate with `~` — the form prp's own docs use — and that made
        // helm's third copy-a-path surface its second answer to the same question. #168
        // settled it as absolute for every one of them; `Pasteboard.path(of:)` carries
        // the reasoning.
        .contextMenu {
            Button("Copy Path") {
                Pasteboard.copy(Pasteboard.path(of: url))
            }
            // The other half of the same problem. ~/.prp is outside every repo, so an
            // artifact is not reachable from an editor's file tree either — reading one
            // outside helm means typing the path into Finder by hand. `activateFileViewerSelecting`
            // reveals it *selected* in its folder rather than opening it, which is the
            // difference between "look at this next to its siblings" and "launch whatever
            // is registered for .md".
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private var emptyState: some View {
        message(
            "No artifact stores found — agents write artifacts to ~/.prp/<project>/ (plans, research, reviews) and they show up here."
        )
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color.textMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
    }
}

/// Hover-highlighted row, list-style, without dragging in a full List.
private struct BrowserRowButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 4)
                    // The same token the tab strips use, at two weights: a row under the
                    // pointer and a row being pressed are the same idea as a selected tab,
                    // one step short of committed. It was `.selectedControlColor`, which is
                    // the fourth colour source the palette exists to end.
                    .fill(
                        configuration.isPressed
                            ? Color.selection
                            : hovering ? Color.selection.opacity(0.55) : .clear
                    )
            )
            .onHover { hovering = $0 }
    }
}
