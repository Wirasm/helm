import XCTest
@testable import Helm

/// The markdown → segments splitter, exercised as a pure function. The shape
/// under test is what the prp-diagram skill emits: a bold one-line caption
/// followed by a ```mermaid fence, repeated per diagram.
final class ArtifactSegmentsTests: XCTestCase {
    func testNoFencesYieldsSingleMarkdownSegment() {
        let raw = "# Title\n\nJust prose.\n\n- a list"
        XCTAssertEqual(ArtifactSegment.split(raw), [.markdown(raw)])
    }

    func testCaptionPlusDiagramSplitsIntoTwoSegments() {
        let raw = """
        **Store layout**

        ```mermaid
        flowchart LR
            A --> B
        ```
        """
        XCTAssertEqual(
            ArtifactSegment.split(raw),
            [
                .markdown("**Store layout**\n"),
                .mermaid("flowchart LR\n    A --> B"),
            ]
        )
    }

    func testProseResumesAfterDiagram() {
        let raw = """
        Before.

        ```mermaid
        graph TD; A-->B
        ```

        After.
        """
        XCTAssertEqual(
            ArtifactSegment.split(raw),
            [
                .markdown("Before.\n"),
                .mermaid("graph TD; A-->B"),
                .markdown("\nAfter."),
            ]
        )
    }

    func testAdjacentDiagramsProduceNoEmptyMarkdownBetween() {
        let raw = """
        ```mermaid
        graph TD; A-->B
        ```

        ```mermaid
        graph LR; C-->D
        ```
        """
        XCTAssertEqual(
            ArtifactSegment.split(raw),
            [.mermaid("graph TD; A-->B"), .mermaid("graph LR; C-->D")]
        )
    }

    func testUnterminatedFenceRendersToEOF() {
        // Agents rewrite these files mid-read; a half-written diagram must
        // still render rather than swallowing the rest of the file.
        let raw = "Intro.\n\n```mermaid\nsequenceDiagram\n    A->>B: hi"
        XCTAssertEqual(
            ArtifactSegment.split(raw),
            [.markdown("Intro.\n"), .mermaid("sequenceDiagram\n    A->>B: hi")]
        )
    }

    func testMermaidFenceInsideGenericCodeBlockIsProse() {
        let raw = """
        ````
        ```mermaid
        graph TD; A-->B
        ```
        ````
        """
        XCTAssertEqual(ArtifactSegment.split(raw), [.markdown(raw)])
    }

    func testGenericCodeBlockStaysProse() {
        let raw = "```swift\nlet x = 1\n```"
        XCTAssertEqual(ArtifactSegment.split(raw), [.markdown(raw)])
    }

    func testFenceToleratesSurroundingWhitespaceAndCase() {
        let raw = "  ```Mermaid  \ngraph TD; A-->B\n  ```  "
        XCTAssertEqual(ArtifactSegment.split(raw), [.mermaid("graph TD; A-->B")])
    }

    func testEmptyDiagramBodyIsDropped() {
        let raw = "Before.\n```mermaid\n\n```\nAfter."
        XCTAssertEqual(
            ArtifactSegment.split(raw),
            [.markdown("Before."), .markdown("After.")]
        )
    }

    func testDiagramContentIsPreservedVerbatim() {
        let body = "flowchart TD\n    K[\"~/.prp/&lt;key&gt;/\"] --> A1[\"artifacts\"]"
        let raw = "```mermaid\n\(body)\n```"
        XCTAssertEqual(ArtifactSegment.split(raw), [.mermaid(body)])
    }
}
