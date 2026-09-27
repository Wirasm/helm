import Foundation
import HelmWire

/// What a benchd document puts on screen (#354): which workspace is mounted, and its bench.
/// Pure, so `WorkbenchModel.apply` only carries it out.
struct BenchDrawing: Equatable {
    let workspace: WorkspacePath?
    /// `.empty` with nothing active; otherwise the bench, drawn.
    let mount: MountState

    static func of(_ document: BenchDocument) -> BenchDrawing {
        guard let active = document.active.map(WorkspacePath.init),
            let workspace = document.workspace(at: active),
            let bench = Workbench(document: workspace.bench)
        else { return BenchDrawing(workspace: nil, mount: .empty) }
        return BenchDrawing(workspace: active, mount: .mounted(bench))
    }
}
