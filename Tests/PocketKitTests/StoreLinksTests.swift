import Foundation
import HelmWire
import XCTest

@testable import PocketKit

final class StoreLinksTests: XCTestCase {
    private let root = "/remote/home/.prp/helm-1"
    private var links: StoreLinks {
        StoreLinks(
            stores: [BenchPrpStore(key: "helm-1", name: "helm", path: "/project", dir: root)],
            home: "/remote/home")
    }

    private func linked(_ markdown: String) -> AttributedString {
        links.linking(try! AttributedString(markdown: markdown))
    }

    func testBareCodeAndMarkdownDestinationsOpenTheRemoteStore() throws {
        for source in [
            "Read \(root)/plans/result.md.",
            "Read `~/.prp/helm-1/reports/result.html`.",
            "[the plan](\(root)/plans/result.md)",
            "[the report](~/.prp/helm-1/reports/result.html)",
            "(\(root)/plans/result.md), next",
        ] {
            let text = linked(source)
            let url = try XCTUnwrap(text.runs.compactMap(\.link).first, source)
            let page = try XCTUnwrap(links.page(at: url), source)
            XCTAssertEqual(page.store, root)
            XCTAssertTrue(page.path.hasPrefix(root + "/"))
        }
        let code = linked("`~/.prp/helm-1/reports/result.html`")
        XCTAssertEqual(code.runs.first?.inlinePresentationIntent, .code)
        XCTAssertEqual(String(code.characters), "~/.prp/helm-1/reports/result.html")
    }

    func testOutsideUnsupportedAndEmbeddedPathsStayPlain() {
        for source in [
            "/remote/home/secret.md", "~/.prp/unknown/a.md", "\(root)-other/a.md",
            "\(root)/../../secret.md", "\(root)/a.json", "\(root)/a.md.bak",
            "prefix\(root)/a.md",
            "[secret](/remote/home/secret.md)", "[relative](plans/a.md)",
            "[other host](file://other/remote/home/.prp/helm-1/a.md)",
            "[network path](//other/remote/home/.prp/helm-1/a.md)",
        ] {
            XCTAssertTrue(linked(source).runs.allSatisfy { $0.link == nil }, source)
        }
    }

    func testWebLinksKeepTheirDestinationAndLabel() throws {
        let bare = linked("https://host\(root)/a.md")
        XCTAssertTrue(bare.runs.allSatisfy { $0.link?.scheme != StoreLinks.scheme })
        let text = linked("[web](https://example.com/a.md)")
        XCTAssertEqual(String(text.characters), "web")
        XCTAssertEqual(text.runs.first?.link?.absoluteString, "https://example.com/a.md")
    }

    func testCustomStoreRootUsesRemoteHomeWithoutInventingTildeAliases() throws {
        let custom = StoreLinks(
            stores: [
                BenchPrpStore(key: "helm-1", name: "helm", path: nil, dir: "/data/stores/helm-1")
            ],
            home: "/remote/home")
        XCTAssertNotNil(custom.page("/data/stores/helm-1/a.md"))
        XCTAssertNil(custom.page("~/.prp/helm-1/a.md"))
        XCTAssertNil(StoreLinks().page("\(root)/a.md"))
        XCTAssertEqual(links.page("\(root)/plans/../reports/a.md")?.title, "reports/a")
    }

    func testTableCellsAndFormattedPathRunsKeepTheirLinksAndStyle() throws {
        let blocks = ChatMarkdown.blocks("| Document |\n|---|\n| **[plan](\(root)/plan.md)** |")
        guard case let .table(rows, _) = try XCTUnwrap(blocks.first).kind else {
            return XCTFail("expected a table")
        }
        let cell = links.linking(rows[1][0])
        let run = try XCTUnwrap(cell.runs.first)
        XCTAssertEqual(links.page(at: try XCTUnwrap(run.link))?.path, "\(root)/plan.md")
        XCTAssertEqual(run.inlinePresentationIntent, .stronglyEmphasized)
        let split = linked("\(root)/**plans**/result.md")
        XCTAssertEqual(
            links.page(at: try XCTUnwrap(split.runs.first?.link))?.path,
            "\(root)/plans/result.md")
    }

    func testMarkdownDestinationCanContainSpacesAndUnicode() throws {
        let text = linked("[plan](<\(root)/plans/hello world-é.md>)")
        let url = try XCTUnwrap(text.runs.first?.link)
        XCTAssertEqual(links.page(at: url)?.path, "\(root)/plans/hello world-é.md")
    }
}
