import Foundation

/// From a registry row to the transcript file it is writing.
///
/// The registry row is the whole input — `sessionId` names the file and `cwd`
/// names the directory. helm reads `AgentRegistry`'s rows and nothing else;
/// there is no second registry reader here by #28's ruling.
///
/// `root` is injected so the whole resolver is exercisable against a fixture
/// directory, on a machine that has never run Claude Code.
enum TranscriptLocator {
    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    /// Claude Code's directory name for a working directory: every byte that is
    /// not an ASCII letter or digit becomes `-`.
    ///
    /// `/Users/rasmus/Projects/mine/sild/helm` → `-Users-rasmus-Projects-mine-sild-helm`,
    /// verified against the live store. Note this is lossy and deliberately so —
    /// it is Claude Code's scheme, not helm's, and helm only has to reproduce it.
    static func directoryName(for cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// The transcript for `session`, or nil when it has not written one yet.
    ///
    /// The slug is a guess — a lossy transform of a path helm did not choose — so
    /// a miss falls back to scanning the project directories for the file named
    /// after this session. Guessing the slug wrong and "the agent has written
    /// nothing yet" look identical from the outside, and only one of them is
    /// worth telling the operator about.
    static func transcript(
        for session: AgentSession, root: URL = defaultRoot
    ) -> URL? {
        guard let sessionId = session.sessionId, !sessionId.isEmpty else { return nil }
        return transcript(forSession: sessionId, cwd: session.cwd, root: root)
    }

    /// The same question asked without a registry row in hand (#63).
    ///
    /// A restore offer knows a session id and a `cwd` — read off the pane's persisted
    /// `ResumableAgent`, from a process that no longer exists — and has no row to describe.
    /// Synthesising an `AgentSession` with a made-up pid to ask this would be a value pretending
    /// to be something it is not, which is the shape `AGENTS.md` names as a seam. So the two
    /// fields the answer actually depends on are the parameters, and the row-shaped caller
    /// above unpacks itself.
    static func transcript(
        forSession sessionId: String, cwd: String?, root: URL = defaultRoot
    ) -> URL? {
        guard !sessionId.isEmpty else { return nil }
        let file = "\(sessionId).jsonl"

        if let cwd {
            let guess = root.appendingPathComponent(directoryName(for: cwd))
                .appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: guess.path) { return guess }
        }

        let directories =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for directory in directories {
            let candidate = directory.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
