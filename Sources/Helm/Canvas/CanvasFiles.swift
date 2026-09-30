import Foundation
import HelmWire

/// Everything a canvas does to a file: read it, write it against what the operator was shown,
/// append a note to its sidecar. **helm does none of it itself** (M5c, #459): benchd does, through
/// the `file/*` verbs, on one machine as much as when benchd is on another and helm shares no disk
/// with it. When a canvas file changes, benchd says so on the follower (`file/changed`,
/// `CanvasModel.fileChanged`), so nothing in helm watches a file either.
///
/// **One path, on purpose.** Keeping local reads for a local benchd would mean two change
/// detectors and two sets of edge cases, and the remote one would be the path nobody runs daily.
/// On one machine a verb is a unix-socket round trip (0.06 ms p50, spike S1).
///
/// A protocol so a test can hold the files on its own disk (`DiskCanvasFiles`) without a benchd.
protocol CanvasFiles: Sendable {
    /// The file's bytes. `within` is the folder a page's sibling must be inside, symlinks
    /// followed on benchd's side.
    func read(_ path: String, within folder: String?) -> CanvasFileRead
    /// The whole file, against what the writer expects to replace (`BenchFileExpect`).
    func write(_ text: String, to path: String, expect: BenchFileExpect) -> CanvasFileWrite
    /// A note at the end of a sidecar, which is created if it is not there.
    func append(_ text: String, to path: String) throws
}

/// What a read found.
///
/// **`failed` is never `absent`, and that is the rule this type exists for.** benchd not
/// answering, or answering that it could not read the file, means helm does not know what is
/// there; `absent` means there is nothing to protect. An editor that took the first for the second
/// would seed an empty draft and autosave it over the real file.
enum CanvasFileRead: Equatable {
    case bytes(Data)
    case absent
    /// Outside the folder the read was confined to.
    case outside
    /// benchd could not be asked, or could not read it; the words say which.
    case failed(String)
}

/// What a write did.
enum CanvasFileWrite: Equatable {
    case written
    /// The file no longer held what the write expected. Nothing was written; these bytes are there.
    case changed(Data)
    case failed(String)
}

struct CanvasFileFailure: Error, LocalizedError, Equatable {
    let reason: String
    var errorDescription: String? { reason }
}

extension CanvasFiles {
    /// An `.html` artifact's own bytes for the page, or nil — which fails the navigation and
    /// leaves the last render up (`CanvasSchemeHandler`). Why is logged: the page cannot say it.
    func document(_ artifact: URL) -> Data? {
        switch read(artifact.path, within: nil) {
        case let .bytes(data): return data
        case .absent, .outside: return nil
        case let .failed(why):
            NSLog("helm: could not read \(artifact.lastPathComponent) for its canvas — \(why)")
            return nil
        }
    }
}

/// The canvas's files through benchd: the client's endpoint, one verb per call. Blocking and
/// bounded like every verb helm sends from the main actor (`BenchClient.requestTimeout`).
struct BenchCanvasFiles: CanvasFiles {
    let client: BenchClient

    func read(_ path: String, within folder: String?) -> CanvasFileRead {
        let request = BenchFileReadRequest(id: Self.id(), path: path, within: folder)
        switch ask(request, answering: BenchFileRead.self) {
        case let .success(.bytes(data)): return .bytes(data)
        case .success(.absent): return .absent
        case .success(.outside): return .outside
        case let .failure(failure): return .failed(failure.reason)
        }
    }

    func write(_ text: String, to path: String, expect: BenchFileExpect) -> CanvasFileWrite {
        let request = BenchFileWriteRequest(id: Self.id(), path: path, text: text, expect: expect)
        switch ask(request, answering: BenchFileWrite.self) {
        case .success(.written): return .written
        case let .success(.changed(data)): return .changed(data)
        case let .failure(failure): return .failed(failure.reason)
        }
    }

    func append(_ text: String, to path: String) throws {
        let request = BenchFileAppendRequest(id: Self.id(), path: path, text: text)
        if case let .failure(failure) = ask(request, answering: BenchFileAppended.self) {
            throw failure
        }
    }

    /// One verb, and every way it can fail as one sentence: not reached, refused, or an answer
    /// this build cannot read.
    private func ask<Payload: Decodable & Sendable>(
        _ request: some Encodable, answering: Payload.Type
    ) -> Result<Payload, CanvasFileFailure> {
        do {
            let answer = try client.request(request, answering: Payload.self)
            guard answer.status == .ok, let data = answer.data else {
                return .failure(
                    CanvasFileFailure(reason: answer.reason ?? "benchd refused without a reason"))
            }
            return .success(data)
        } catch {
            return .failure(CanvasFileFailure(reason: String(describing: error)))
        }
    }

    private static func id() -> String { "helm-file-\(UUID().uuidString)" }
}
