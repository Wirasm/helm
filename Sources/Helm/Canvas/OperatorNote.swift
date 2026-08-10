import Foundation

// MARK: - The note

/// A markdown file the operator started **in helm** — where it lands, and what it is called
/// (#289).
///
/// **This type used to be the scope line as well, and it is not any more.** It answered *"which
/// files may the operator write into?"* with `<artifact root>/<key>/notes/<name>.md`, because the
/// other half of #289 — editing a file an agent also rewrites — needed an answer to the question
/// `CanvasNotes`' header avoided, and only note-taking had one. That answer is built now
/// (`CanvasConflict`, `CanvasModel.reconcile`) and the operator has ruled that every markdown
/// canvas is editable, so the line moved to `EditableFile` and this type kept the half that was
/// always its own: **creating** one.
///
/// What remains here is entirely about *where a new note goes*, and none of it is reachable except
/// through ⌘⇧N. Nothing asks "is this file a note?" any more, because nothing needs to — an
/// editable file is judged by what it is, not by who started it.
///
/// **Standardized, because `Workbench.pane(showing:)` compares sources by value** (#88) — the same
/// invariant `EditableFile` carries, for the same reason.
struct OperatorNote: Equatable {
    /// The note's own file.
    let path: StandardizedPath

    var url: URL { URL(fileURLWithPath: path.value) }

    /// The one directory in a project store that is the operator's rather than an agent's.
    ///
    /// A sibling of prp's own `plans/`, `research/`, `reviews/` — the store's shape is a
    /// subdirectory per kind, and this is the kind nothing in prp writes. That separation is what
    /// an agent is told about in `.claude/skills/helm-canvas/SKILL.md`: read what is in here when
    /// the operator names it, never write into it. It is a convention rather than a lock, and
    /// saying so is more honest than implying helm could enforce it.
    ///
    /// **It is no longer what makes a file editable** — see the type's own header — so an agent
    /// writing here is still wrong, and it is wrong for a reason about ownership rather than about
    /// what helm will let anyone type into.
    static let directoryName = "notes"
}

// MARK: - Starting one

extension OperatorNote {
    /// Why a note could not be started. A named type rather than a bare `Error` so the sentence
    /// the operator reads is written here, once, beside the rule that produced it.
    enum Failure: Error, Equatable {
        /// No workspace is open, so there is no project whose store the note would belong to.
        case noWorkspace
        /// The filesystem refused. `reason` is the underlying error in the operator's terms.
        case couldNotWrite(String)
        /// Unreachable, and checked anyway — see `create`.
        case notARecognisableNote(String)

        var sentence: String {
            switch self {
            case .noWorkspace:
                "Open a workspace first — a note lands in that project's ~/.prp store."
            case let .couldNotWrite(reason):
                "Could not start a note: \(reason)"
            case let .notARecognisableNote(path):
                "helm wrote \(path) but will not let you edit it. This is a bug."
            }
        }
    }

    /// **Which store a workspace's notes belong to** — the same question the artifact browser
    /// asks, answered with the same resolver rather than a second one.
    ///
    /// Matching beats deriving, and `WorkspaceStore`'s header says why: a store that already
    /// exists records its own root in `project.json`, so the first pass is a string compare with
    /// no algorithm to drift from prp's. The derived key is the fallback, and it is prp's own
    /// algorithm — `<slug>-<blob hash prefix>` — pinned against the real `git hash-object` by
    /// `WorkspaceStoreTests`. So a note started before any agent has written an artifact for this
    /// project lands in the *same* directory prp will use when one finally does.
    ///
    /// Pure: `root` is already resolved, so this needs no subprocess and no disk.
    static func key(forRepositoryRoot root: String, in stores: [ArtifactStore]) -> String {
        WorkspaceStore.store(forRoot: root, in: stores)?.key
            ?? WorkspaceStore.derivedKey(forRoot: root)
    }

    /// The note's filename: `2026-08-07-note.md`, then `-2`, `-3`, … for the same day.
    ///
    /// **helm does not ask for a name, and that is the feature.** The operator is mid-thought —
    /// he opened this to write something down *now* — and a modal asking what to call it is the
    /// friction that makes the note not get taken at all. A name is a decision he can make later
    /// by renaming the file; a blank sheet is one he cannot make later.
    ///
    /// **The date is in it and `-note` is in it**, because both are read by a human scanning a
    /// directory. `2026-08-07.md` alone is a filename an agent's daily log could equally claim,
    /// and the store is shared with agents by design.
    ///
    /// Pure, and `taken` is passed in rather than read: the collision rule is then a test with no
    /// filesystem, and the one place that touches disk is `create`.
    static func filename(on date: Date, avoiding taken: Set<String>) -> String {
        let day = dayFormatter.string(from: date)
        let first = "\(day)-note.md"
        guard taken.contains(first) else { return first }
        var index = 2
        // Terminates because `taken` is finite — no bound to pick, and therefore no arbitrary
        // ceiling to be wrong about.
        while taken.contains("\(day)-note-\(index).md") { index += 1 }
        return "\(day)-note-\(index).md"
    }

    /// Start a note for the workspace at `workspace`, and hand back the file it made.
    ///
    /// The whole of the disk work, in one place: resolve the repository root, resolve the store,
    /// make `notes/`, register the store if helm is the first thing to touch it, pick a free name,
    /// and create the file **empty**.
    ///
    /// **Empty rather than seeded with a heading.** A template is helm typing for the operator,
    /// and the first line of a note is the one line he definitely has in mind already.
    ///
    /// Throws rather than returning nil: an unwritable `~/.prp` is something the operator has to
    /// be told about in words, and `Failure.sentence` is those words. A ⌘⇧N that silently does
    /// nothing is the shape of failure this repository has paid for more than once.
    static func create(
        inWorkspaceAt workspace: String,
        under artifactRoot: URL = ArtifactStoreDiscovery.defaultRoot,
        on date: Date = Date()
    ) throws -> OperatorNote {
        // prp keys a store by the repository's MAIN checkout, so every worktree of one project
        // writes its notes beside that project's plans rather than into a store per branch.
        let repository = WorkspaceStore.repositoryRoot(for: workspace)
        let stores = ArtifactStoreDiscovery.discoverStores(under: artifactRoot)
        let store = artifactRoot.appendingPathComponent(
            key(forRepositoryRoot: repository, in: stores))
        let notes = store.appendingPathComponent(directoryName)
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: notes, withIntermediateDirectories: true)
            try register(store, forRepositoryRoot: repository)
            let taken = Set((try? manager.contentsOfDirectory(atPath: notes.path)) ?? [])
            let file = notes.appendingPathComponent(filename(on: date, avoiding: taken))
            // `.withoutOverwriting` because the name was picked from a listing taken a moment
            // ago: a second helm, or the operator's own editor, could have claimed it since, and
            // silently truncating somebody's file is not a cost worth paying to save a retry.
            try Data().write(to: file, options: .withoutOverwriting)
            guard let editable = EditableFile(file) else {
                // Unreachable: `file` was built with a `.md` extension and is not a sidecar, which
                // is exactly what `EditableFile` recognises. Checked rather than assumed so that a
                // later change to either half surfaces as a sentence the operator can read instead
                // of a note that opens and then refuses to take a character — ⌘⇧N goes straight
                // into the writing face, so a note helm would not let him edit is the one failure
                // this whole path exists to make impossible.
                throw Failure.notARecognisableNote(file.path)
            }
            return OperatorNote(path: editable.path)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.couldNotWrite(error.localizedDescription)
        }
    }

    /// prp's own registration, written **only when helm is the first thing to touch the store**.
    ///
    /// This is not helm inventing a format. prp's canonical resolver — byte-identical across every
    /// `prp-*` skill — is `mkdir -p "$PRP_DIR"; [ -f "$PRP_DIR/project.json" ] || printf
    /// '{"path": "%s", "name": "%s"}' …`, and prp's own design note says the file *"has exactly
    /// one writer (whoever first touches the store)"*. Starting a note is helm touching it first,
    /// so helm writes it, with the same two fields from the same two values: the resolved
    /// repository root, and prp's slug of its basename (`WorkspaceStore.slug`).
    ///
    /// **Without it the note would be invisible.** `ArtifactStoreDiscovery` lists a directory as a
    /// store only if it holds a `project.json`, so a note written into an unregistered key would
    /// be a file the operator could not find again through ⌘O — the one surface that would
    /// otherwise show it to him.
    ///
    /// An existing registration is never touched, whoever wrote it.
    private static func register(_ store: URL, forRepositoryRoot root: String) throws {
        let registration = store.appendingPathComponent("project.json")
        guard !FileManager.default.fileExists(atPath: registration.path) else { return }
        let data = try JSONSerialization.data(
            withJSONObject: ["path": root, "name": WorkspaceStore.slug(forRoot: root)],
            options: [.sortedKeys])
        try data.write(to: registration)
    }

    /// `en_US_POSIX`, because a note's filename must not change shape with the operator's region.
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
