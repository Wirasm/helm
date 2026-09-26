import Foundation
import HelmWire

/// What a benchd document puts on screen (#354): which workspace is mounted, its shelf, and
/// whether its bench is drawn or waits on #85's question. Pure, so `WorkbenchModel.apply` only
/// carries it out.
struct BenchDrawing: Equatable {
    let workspace: WorkspacePath?
    let shelved: Workbench?
    /// `.empty` with nothing active; `.awaitingRestore` on a first visit to a bench worth asking
    /// about (the question stays helm's, D4); otherwise the bench, drawn.
    let mount: MountState

    static func of(_ document: BenchDocument, answered: Set<WorkspacePath>) -> BenchDrawing {
        guard let active = document.active.map(WorkspacePath.init),
            let workspace = document.workspace(at: active),
            let bench = Workbench(document: workspace.bench)
        else { return BenchDrawing(workspace: nil, shelved: nil, mount: .empty) }
        let shelved = workspace.shelved.flatMap(Workbench.init(document:))
        if !answered.contains(active),
            let offer = BenchMountPolicy.offer(bench: bench, shelved: shelved)
        {
            return BenchDrawing(workspace: active, shelved: shelved, mount: .awaitingRestore(offer))
        }
        return BenchDrawing(workspace: active, shelved: shelved, mount: .mounted(bench))
    }
}
