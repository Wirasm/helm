import Foundation
import HelmWire

// MARK: - CanvasForkRoute

/// Whether a mark can be asked of a fork, and of which conversation (#535).
///
/// **The fork is bound early; mail is bound late.** A note goes to whoever is in the opener's pane
/// now (`CanvasNoteRoute`), because that agent can act on it. A question goes to the conversation
/// that *wrote* the file, which benchd copied onto the canvas pane as `author` when it was opened:
/// after a `/clear` or an exit the pane holds some other conversation, or none, and a fork of that
/// would answer about work it never did.
///
/// Pure, so the rule is tested without a daemon.
enum CanvasForkRoute: Equatable {
    /// The conversation to fork, which harness holds it, and the cwd its transcript lives under.
    /// benchd forks claude, codex and pi, each read-only, and refuses anything else by name.
    case fork(BenchDocument.Agent)
    /// Nothing to fork, and the sentence the disabled action shows. **Never a silent no-op**: a
    /// button that does nothing reads as a broken one.
    case unavailable(String)

    static let noOpener = "No agent opened this canvas, so there is no conversation to fork"

    static func route(opener: UUID?, author: BenchDocument.Agent?) -> CanvasForkRoute {
        guard opener != nil else { return .unavailable(noOpener) }
        guard let author else {
            return .unavailable(
                "The agent that opened this canvas had no recorded conversation to fork")
        }
        return .fork(author)
    }

    var canFork: Bool {
        if case .fork = self { true } else { false }
    }
}

// MARK: - CanvasForkDelivery

/// What happened when the operator asked a fork, and the sentence the pane shows for it.
enum CanvasForkDelivery: Equatable, CanvasMarkOutcome {
    /// benchd started the fork; its handle names its pane.
    case asked(handle: String)
    case unavailable(String)
    /// benchd refused, or could not be reached.
    case failed(String)

    /// **Copy when the copy is the delivery**, `CanvasNoteDelivery`'s rule: a fork that started
    /// has the question in its prompt, and anything else leaves the operator nothing but the paste.
    var copiesToClipboard: Bool {
        switch self {
        case .asked: false
        case .unavailable, .failed: true
        }
    }

    func receipt(sidecar: String) -> String {
        switch self {
        case let .asked(handle):
            "Written to \(sidecar) and asked a fork of the author, in pane \(handle)"
        case let .unavailable(why):
            "Written to \(sidecar) and copied — \(why)"
        case let .failed(why):
            "Written to \(sidecar) and copied — the fork did not start: \(why)"
        }
    }
}

// MARK: - CanvasForkPrompt

/// The fork's first prompt, as the spike wrote it and all three of its forks obeyed
/// (`spike-fork-author-session.md`): what it is, exactly what was marked, the question, and how
/// to answer.
enum CanvasForkPrompt {
    static func text(canvas: URL, source: String?, marked: String, question: String) -> String {
        let fence = Self.fence(for: marked)
        let span: String
        switch source.flatMap({ Self.lines(of: marked, in: $0) }) {
        case let .some(range) where range.count == 1: span = "Line: \(range.lowerBound)"
        case let .some(range): span = "Lines: \(range.lowerBound)-\(range.upperBound)"
        case .none:
            span =
                "Lines: unknown; the marked text is not in the file verbatim, or is there "
                + "more than once"
        }
        return """
            You are a fork of the conversation that wrote the file below. The original is still \
            working in its own pane. Do not continue its task, and do not edit any files: you are \
            here to answer the operator's question.

            File: \(canvas.path)
            \(span)

            The operator marked:

            \(fence)text
            \(marked)
            \(fence)

            The operator's question:

            \(question)

            Answer from what you already know from the conversation. If you do not know, say so \
            rather than guessing.
            """
    }

    /// The 1-based lines the marked text spans in the file, when it is there verbatim and once. A
    /// rendered markdown mark often is not (emphasis and links lose their markup), and a phrase
    /// the file repeats could be any of its places, so either way there is no range rather than a
    /// guessed one.
    static func lines(of marked: String, in source: String) -> ClosedRange<Int>? {
        guard !marked.isEmpty, let found = source.range(of: marked),
            source.range(of: marked, range: source.index(after: found.lowerBound)..<source.endIndex)
                == nil
        else { return nil }
        let first = source[..<found.lowerBound].filter { $0 == "\n" }.count + 1
        return first...(first + marked.filter { $0 == "\n" }.count)
    }

    /// A fence the marked text cannot close: one backtick longer than its longest run.
    static func fence(for text: String) -> String {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }
}
