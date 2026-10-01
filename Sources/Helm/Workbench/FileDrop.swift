import HelmWire
import SwiftUI
import UniformTypeIdentifiers

/// A file dragged in from Finder opens as a canvas where it is dropped (#178): in a gap of a tab
/// strip, or beside a slot from its edge band, in the drop zone a dragged tab shows.
///
/// **The one pasteboard drop on the bench, and only for file URLs.** A drag from another app
/// cannot be a `DragGesture`, which is what a tab's drag is (`PaneDrop`). It is a SwiftUI drop on
/// the bench's viewport, so a body that takes drops itself, as a web view does, still gets them
/// first; and a slot's middle resolves to nothing, so what a drop on a terminal or a page does
/// stays theirs. Where the place is resolved, and how it is drawn, is the tab drag's own.
///
/// **benchd decides what opening there does** (`pane/open` with `at`): one verb per file, as the
/// operator's gesture. A file that bench already shows is moved there rather than opened twice.
extension WorkbenchModel {
    /// Files are held over the bench at `point`, in `PaneDrop.space`. Answers whether letting go
    /// here does anything: opens them, or says why it cannot.
    func dragFiles(at point: CGPoint) -> Bool {
        let target =
            remoteEndpoint == nil
            ? bench.flatMap {
                PaneDrop.resolve(pane: nil, at: point, bench: $0, frames: paneDrag.frames)
            } : nil
        paneDrag.update(nil, target: target)
        return target != nil || remoteEndpoint != nil
    }

    /// The files left the bench without being dropped.
    func endFileDrag() {
        _ = paneDrag.end()
    }

    /// Files were dropped at `point`. Each markdown or HTML file opens as a canvas: the first at
    /// the place under the pointer, the rest as tabs beside it. A file that is not one of those is
    /// named on the status bar rather than skipped silently, and nothing is sent where no zone
    /// was drawn.
    ///
    /// **Not over TCP (M5c).** The file is on this Mac, and benchd reads its own disk: a path both
    /// machines have (`~/.prp/…` is the usual one) would open the other machine's file. So the
    /// drop is refused, saying so, rather than sent.
    func dropFiles(_ urls: [URL], at point: CGPoint) {
        _ = dragFiles(at: point)
        let target = paneDrag.end()
        if let remote = remoteEndpoint {
            verbFailed(
                "\(Self.names(urls)) is on this Mac, and benchd at \(remote) reads its own disk; "
                    + "copy it there and `bench open` it")
            return
        }
        guard let target else { return }
        let files = urls.filter(RenderableFile.isRenderable)
        let skipped = urls.filter { !RenderableFile.isRenderable($0) }
        if !skipped.isEmpty {
            verbFailed("helm opens markdown and HTML files, and \(Self.names(skipped)) is neither")
        }
        guard let first = files.first,
            let landed = send(
                .paneOpenAt(target.place, surface: .canvas(path: first.path)),
                by: .operatorGesture)
        else { return }
        let rest = files.dropFirst()
        // The drawn document should hold the first pane; if it does not yet, say which files
        // were left rather than dropping them silently.
        guard let slot = bench?.slot(for: landed)?.id else {
            if !rest.isEmpty {
                verbFailed(
                    "\(Self.names(Array(rest))) did not open: the first file's pane is not drawn yet"
                )
            }
            return
        }
        for file in rest {
            send(
                .paneOpenAt(.tab(slot: slot, before: nil), surface: .canvas(path: file.path)),
                by: .operatorGesture)
        }
    }

    /// The benchd this helm reaches over TCP, or nil for the local socket.
    private var remoteEndpoint: BenchEndpoint? {
        if case .tcp = client.endpoint { return client.endpoint }
        return nil
    }

    private static func names(_ urls: [URL]) -> String {
        urls.map(\.lastPathComponent).joined(separator: ", ")
    }
}

/// The drop's AppKit half: reads where the pointer is and which files it carries, and hands both
/// to `WorkbenchModel`, which is where a test reaches it. Attached to the view that names
/// `PaneDrop.space`, so `DropInfo.location` is already in it.
struct FileDropDelegate: DropDelegate {
    let model: WorkbenchModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: model.dragFiles(at: info.location) ? .copy : .forbidden)
    }

    func dropExited(info _: DropInfo) {
        model.endFileDrag()
    }

    func performDrop(info: DropInfo) -> Bool {
        let point = info.location
        let providers = info.itemProviders(for: [.fileURL])
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await provider.droppedFileURL() { urls.append(url) }
            }
            model.dropFiles(urls, at: point)
        }
        return true
    }
}

extension NSItemProvider {
    /// The file URL a Finder drag carries: as a URL, or as its data representation.
    @MainActor
    fileprivate func droppedFileURL() async -> URL? {
        guard let item = try? await loadItem(forTypeIdentifier: UTType.fileURL.identifier)
        else { return nil }
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        return nil
    }
}
