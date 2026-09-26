import Foundation
import PackagePlugin

/// Runs the pinned `swiftlint` with the caller's arguments and exits with its status, so
/// `scripts/check-size.sh` sees SwiftLint's own verdict rather than the plugin's.
@main struct Lint: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let process = Process()
        process.executableURL = try context.tool(named: "swiftlint").url
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        exit(process.terminationStatus)
    }
}
