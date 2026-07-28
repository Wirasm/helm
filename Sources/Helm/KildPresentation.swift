import Foundation

/// Formatting decisions the observe column and dock share.
///
/// Pure functions, kept out of the views so they can be tested without a window — these two
/// survived the rename because they format facts rather than interpret them. Their room-era
/// siblings did not: `roomStatus(hasOpenDecisions:)` and
/// `participantLiveness(kind:idle:posted:)` both read fields the engine no longer has.
enum KildPresentation {

    /// What to say about a set of collisions.
    ///
    /// The count is **unique files across all colliding kilds**, not the number of kilds and
    /// not the sum of their file lists. Two kilds both touching `shared.swift` is one file
    /// in conflict, and saying "2" would double-count the same problem. Count and detail
    /// come from one set so they can never disagree — the bug this shape prevents is a badge
    /// reading "3" above a list of two filenames.
    static func collisionSummary(_ collisions: [Collision]) -> (
        names: String, files: [String], count: Int
    ) {
        let names = collisions
            .map(\.otherName)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .joined(separator: ", ")
        let files = Set(collisions.flatMap(\.files)).sorted()
        return (names: names, files: files, count: files.count)
    }

    /// Drop the provider path from a model id, keeping the model.
    ///
    /// `openai-codex/gpt-5.6-terra` → `gpt-5.6-terra`. The provider is infrastructure; in a
    /// narrow column the model is the part that distinguishes one agent from another. A
    /// model with no provider path is left alone rather than split on a separator it does
    /// not contain.
    static func modelShortname(_ model: String?) -> String {
        guard let model else { return "default" }
        return model.split(separator: "/").last.map(String.init) ?? model
    }
}
