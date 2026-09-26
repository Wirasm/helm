import Foundation

@testable import Helm

extension TerminalManager {
    /// One fresh shell in `path`, with `path` the workspace on screen — started the way helm
    /// starts every terminal pane benchd's document names (`adopt`). For a test that needs a
    /// session and no bench.
    @discardableResult
    func adoptShell(in path: WorkspacePath, id: UUID = UUID()) -> TerminalSession {
        adopt(terminals: [id], in: path)
        guard let session = surfaces.existing(id, as: TerminalSession.self) else {
            preconditionFailure("adopt started no session for \(id)")
        }
        return session
    }
}
