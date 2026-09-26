import SwiftUI

/// benchd's side of the status bar, in daemon mode (#354): a capsule when the follower cannot
/// reach benchd, naming the socket, and the reason the last verb did not happen.
///
/// **Visible failure is the whole job** (AC8). While benchd is down the last document stays on
/// screen and nothing changes locally — so without this, a key that did nothing would look
/// exactly like a key helm ignored.
struct BenchStatusBadge: View {
    @ObservedObject var client: BenchClient
    @ObservedObject var workbench: WorkbenchModel

    var body: some View {
        HStack(spacing: 6) {
            if case let .disconnected(why) = client.state {
                Text("benchd unreachable")
                    .foregroundStyle(Color.surface)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.danger, in: Capsule())
                    .help("\(client.socketPath.isEmpty ? "no socket" : client.socketPath) — \(why)")
            }
            if let failure = workbench.verbFailure {
                Text(failure).foregroundStyle(Color.attention).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 360)
            }
        }
    }
}
