import AppKit
import SwiftUI

/// The pane's downloads (#549): a button on the address bar while there are any, and a list of
/// them behind it. Each finished one opens in place when benchd shares this Mac, or is copied to
/// the Mac's downloads folder and shown in Finder when benchd is on another machine.
struct BrowserDownloadsButton: View {
    @ObservedObject var downloads: BrowserDownloads
    @State private var open = false

    var body: some View {
        if !downloads.items.isEmpty {
            Button {
                open.toggle()
            } label: {
                Image(systemName: busy ? "arrow.down.circle.dotted" : "arrow.down.circle")
                    .frame(width: 20, height: 20)
            }
            .help("Downloads")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                BrowserDownloadsList(downloads: downloads)
            }
        }
    }

    private var busy: Bool { downloads.items.contains { $0.state == .inProgress } }
}

private struct BrowserDownloadsList: View {
    @ObservedObject var downloads: BrowserDownloads
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Downloads").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Clear") { downloads.clear() }
                    .buttonStyle(.chrome)
                    .font(.system(size: 11))
            }
            ForEach(downloads.items) { item in
                row(item)
            }
            if let failure {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textMuted)
                    .textSelection(.enabled)
            }
        }
        .foregroundStyle(Color.textPrimary)
        .padding(12)
        .frame(width: 320)
    }

    private func row(_ item: BrowserDownloads.Download) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Text(status(item)).font(.system(size: 10.5)).foregroundStyle(Color.textMuted)
            }
            Spacer()
            if item.state == .completed {
                Button(action: { bring(item) }) { Text(actionTitle(item)) }
                    .buttonStyle(.chrome)
                    .font(.system(size: 11))
            }
        }
    }

    private func status(_ item: BrowserDownloads.Download) -> String {
        switch item.state {
        case .inProgress:
            guard item.totalBytes > 0 else { return "Downloading…" }
            return "Downloading, \(Int(item.receivedBytes / item.totalBytes * 100))%"
        case .canceled: return "Cancelled"
        case .completed:
            if let copied = item.copied { return "Copied to \(copied.path)" }
            return downloads.onOneMachine ? item.path ?? "" : "On benchd's machine"
        }
    }

    private func actionTitle(_ item: BrowserDownloads.Download) -> String {
        if downloads.onOneMachine { return "Open" }
        return item.copied == nil ? "Copy to Mac" : "Show in Finder"
    }

    private func bring(_ item: BrowserDownloads.Download) {
        failure = nil
        Task {
            switch await downloads.onMac(item.id) {
            case let .success(url):
                if downloads.onOneMachine {
                    NSWorkspace.shared.open(url)
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            case let .failure(why):
                failure = why.reason
            }
        }
    }
}
