import Foundation

/// Tells helm that the spool directory's contents changed.
///
/// **helm has no directory watch anywhere, and this is the first one.** `FileWatcher`
/// (`Canvas/Canvas.swift`) is a `DispatchSourceFileSystemObject` over a **single** `url`, and
/// `BoardModel` considered a directory-level source and deliberately chose polling instead —
/// *"a status change rewrites an existing file, which the directory-level `DispatchSource`
/// pattern would not reliably see"*. That reasoning is right, and it does not apply here.
///
/// **The difference, argued rather than assumed.** A vnode source on a directory reports a
/// `.write` when the directory itself is modified — when an entry is added, removed or
/// renamed. It does **not** report a write to the *contents* of a file already listed there,
/// because that does not touch the directory. The board watches for a **status field changing
/// inside an existing file**, which is exactly the invisible case; the spool watches for a
/// **file appearing** and then being renamed away, which is exactly the visible one. The two
/// features want opposite events, and the one BoardModel could not get is the one this one
/// does not need. `SpoolWatcherTests` pins both halves — that a created file fires, and that a
/// rewritten file does not — so the distinction is measured here rather than reasoned about.
///
/// **The backstop is not the mechanism.** A slow rescan runs alongside the watch so that a
/// missed event costs *latency* rather than a spawn that silently never happens — which is the
/// failure this whole ladder exists to remove. It is deliberately far slower than a poller
/// would be, because it is insurance and not the design.
@MainActor
final class SpoolWatcher {
    private let directory: URL
    private let backstop: Duration
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var sweep: Task<Void, Never>?

    init(
        directory: URL,
        backstop: Duration = .seconds(5),
        onChange: @escaping @MainActor () -> Void
    ) {
        self.directory = directory
        self.backstop = backstop
        self.onChange = onChange
    }

    /// Arm the watch and take one look immediately.
    ///
    /// The immediate look is load-bearing: requests written while helm was not running fire no
    /// event at all, and without this they would sit there until the next one arrived.
    func start() {
        watch()
        sweep = Task { [weak self, backstop] in
            while !Task.isCancelled {
                try? await Task.sleep(for: backstop)
                guard !Task.isCancelled else { return }
                self?.onChange()
            }
        }
        onChange()
    }

    func stop() {
        sweep?.cancel()
        sweep = nil
        source?.cancel()
        source = nil
    }

    private func watch() {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            NSLog("helm: cannot watch the spool at %@ — it will be polled instead", directory.path)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            if event.contains(.delete) || event.contains(.rename) {
                // The directory itself went. Re-open the path and keep watching whatever is
                // there now — the same rearm `FileWatcher` does for an atomically replaced
                // file, for the same reason: the descriptor is orphaned on the old inode.
                self.source?.cancel()
                self.source = nil
                self.rearm(attemptsLeft: 5)
            } else {
                self.onChange()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    private func rearm(attemptsLeft: Int) {
        if FileManager.default.fileExists(atPath: directory.path) {
            watch()
            onChange()
            return
        }
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated { self?.rearm(attemptsLeft: attemptsLeft - 1) }
        }
    }

    deinit {
        sweep?.cancel()
        source?.cancel()
    }
}
