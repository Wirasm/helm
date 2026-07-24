import Foundation

/// A markdown artifact, split at its ```mermaid fences: markdown prose between
/// diagrams, and the raw mermaid source of each diagram. Pure text → segments,
/// no I/O and no WebKit — fully exercisable from `swift test` without a GUI.
enum ArtifactSegment: Equatable {
    case markdown(String)
    case mermaid(String)

    /// Splits `raw` into interleaved markdown/mermaid segments.
    ///
    /// Fence rules (matching what the prp-diagram skill emits — a bold caption
    /// line followed by a ```mermaid fence):
    /// - An opening fence is a line that is exactly ``` + "mermaid" (leading
    ///   whitespace and trailing whitespace tolerated, info string
    ///   case-insensitive). Longer fences (````mermaid) are NOT diagrams.
    /// - The diagram ends at the next line that is exactly ``` (whitespace
    ///   tolerated). An unterminated fence runs to EOF — agents rewrite these
    ///   files while you read them, so a half-written diagram still renders.
    /// - ```mermaid inside another fenced code block is prose, not a diagram.
    /// - Whitespace-only segments (blank prose between adjacent diagrams, an
    ///   empty diagram body) are dropped.
    static func split(_ raw: String) -> [ArtifactSegment] {
        var segments: [ArtifactSegment] = []
        var prose: [Substring] = []
        var diagram: [Substring] = []
        var insideMermaid = false
        var insideOtherFence = false

        func flushProse() {
            let text = prose.joined(separator: "\n")
            prose = []
            if !text.allSatisfy(\.isWhitespace) {
                segments.append(.markdown(text))
            }
        }

        func flushDiagram() {
            let source = diagram.joined(separator: "\n")
            diagram = []
            if !source.allSatisfy(\.isWhitespace) {
                segments.append(.mermaid(source))
            }
        }

        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if insideMermaid {
                if trimmed == "```" {
                    insideMermaid = false
                    flushDiagram()
                } else {
                    diagram.append(line)
                }
                continue
            }

            if insideOtherFence {
                prose.append(line)
                // Any fence line closes a generic fenced block.
                if trimmed.hasPrefix("```") {
                    insideOtherFence = false
                }
                continue
            }

            if trimmed.hasPrefix("```") {
                let info = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                if info.lowercased() == "mermaid" {
                    insideMermaid = true
                    flushProse()
                } else {
                    // ``` or ```swift or ````anything — a generic fenced block;
                    // it stays prose, and nothing inside it opens a diagram.
                    insideOtherFence = true
                    prose.append(line)
                }
                continue
            }

            prose.append(line)
        }

        // EOF tolerance: an unterminated diagram still renders.
        if insideMermaid {
            flushDiagram()
        } else {
            flushProse()
        }
        return segments
    }
}
