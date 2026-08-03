import Foundation

extension JSONDecoder {
    /// Archon serializes JavaScript dates with fractional seconds, while older persisted
    /// rows may omit them. Foundation's built-in `.iso8601` strategy does not accept both.
    static func archon() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { value in
            let container = try value.singleValueContainer()
            let string = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "invalid Archon date: \(string)")
        }
        return decoder
    }
}

/// The stable address persisted by a workbench pane. Volatile run and node state is
/// resolved from the CLI when the pane is visible.
struct ArchonRunRef: Codable, Equatable, Sendable {
    let id: String
    let workflowName: String
}

/// One row from `archon workflow status --json`, and the superset returned by verbose
/// `workflow get`. Run status remains a string so a newer Archon status is still visible.
struct ArchonRun: Codable, Equatable, Sendable {
    let id: String
    let workflowName: String
    let status: String
    let workingPath: String?
    let currentStepName: String?
    let totalSteps: Int?
    let startedAt: Date?
    let completedAt: Date?
    let metadata: Metadata?
    let nodes: [ArchonNode]?

    struct Metadata: Codable, Equatable, Sendable {
        let error: String?
    }

    private enum CodingKeys: String, CodingKey {
        case id, status, metadata, nodes
        case workflowName = "workflow_name"
        case workingPath = "working_path"
        case currentStepName = "current_step_name"
        case totalSteps = "total_steps"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }
}

struct ArchonNode: Codable, Equatable, Sendable {
    enum State: String, Codable, Equatable, Sendable {
        case running, completed, failed, skipped
    }

    let nodeId: String
    let state: State
    let startedAt: Date?
    let durationMs: Int?
    let outputPreview: String?
    let error: String?
}

struct ArchonWorkflow: Codable, Equatable, Sendable, Identifiable {
    var id: String { name }
    let name: String
    let description: String
    let provider: String?
    let model: String?
}

struct ArchonWorkflowLoadError: Codable, Equatable, Sendable {
    let filename: String
    let error: String
    let errorType: String?
}

struct ArchonStatusResponse: Codable, Equatable, Sendable {
    let runs: [ArchonRun]
}

struct ArchonWorkflowListResponse: Codable, Equatable, Sendable {
    let workflows: [ArchonWorkflow]
    let errors: [ArchonWorkflowLoadError]
}

struct ArchonLaunchAcknowledgement: Codable, Equatable, Sendable {
    let ok: Bool
    let action: String
    let detached: Bool
    let workflow: String
    let branch: String?
    let conversationId: String
    let logPath: String?
}

struct ArchonLaunchRequest: Equatable, Sendable {
    let workspacePath: String
    let workflow: String
    let input: String
    let branch: String?
    let noWorktree: Bool
}
