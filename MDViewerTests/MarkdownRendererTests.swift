import XCTest
@testable import MDViewer

final class MarkdownRendererTests: XCTestCase {

    func testBasicMarkdownRendersToHTML() {
        let renderer = MarkdownRenderer()
        let chunks = renderer.render(markdown: "# Hello\n\nWorld")
        let joined = chunks.joined()
        XCTAssertTrue(joined.contains("<h1>"))
        XCTAssertTrue(joined.contains("Hello"))
        XCTAssertTrue(joined.contains("<p>World</p>"))
    }

    func testGFMTableRendersToHTML() {
        let renderer = MarkdownRenderer()
        let md = """
        | Name | Age |
        |------|-----|
        | Alice | 30 |
        """
        let chunks = renderer.render(markdown: md)
        let joined = chunks.joined()
        XCTAssertTrue(joined.contains("<table>"))
        XCTAssertTrue(joined.contains("Alice"))
    }

    func testMermaidBlockBecomesPlaceholder() {
        let renderer = MarkdownRenderer()
        let md = """
        ```mermaid
        graph TD
            A --> B
        ```
        """
        let chunks = renderer.render(markdown: md)
        let joined = chunks.joined()
        XCTAssertTrue(joined.contains("mermaid-placeholder"))
        XCTAssertTrue(joined.contains("data-mermaid-source"))
        XCTAssertFalse(joined.contains("<pre><code class=\"language-mermaid\">"))
    }

    func testChunkingSplitsLargeContent() {
        let renderer = MarkdownRenderer()
        var md = ""
        for i in 0..<100 {
            md += "## Heading \(i)\n\nParagraph \(i) content here.\n\n"
        }
        let chunks = renderer.render(markdown: md)
        XCTAssertGreaterThan(chunks.count, 1, "Large content should be split into multiple chunks")
        XCTAssertTrue(chunks[0].contains("Heading 0"))
    }

    func testSmallContentSingleChunk() {
        let renderer = MarkdownRenderer()
        let chunks = renderer.render(markdown: "Hello world")
        XCTAssertEqual(chunks.count, 1)
    }

    func testFullPageHTML() {
        let renderer = MarkdownRenderer()
        let result = renderer.renderFullPage(markdown: "# Test", templateHTML: "<body>{{FIRST_CHUNK}}</body>")
        XCTAssertTrue(result.page.contains("<h1>"))
        XCTAssertTrue(result.page.contains("<body>"))
    }

    func testRenderFromFile() {
        let renderer = MarkdownRenderer()
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("test.md")
        try! "# File Test\n\nContent".write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let result = renderer.renderFullPage(fileURL: tmpFile, templateHTML: "<body>{{FIRST_CHUNK}}</body>")
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.page.contains("File Test"))
    }
}
