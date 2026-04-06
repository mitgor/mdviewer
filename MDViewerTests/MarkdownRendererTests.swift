import XCTest
@testable import MDViewer

final class MarkdownRendererTests: XCTestCase {

    func testBasicMarkdownRendersToHTML() {
        let renderer = MarkdownRenderer()
        let (chunks, _) = renderer.render(markdown: "# Hello\n\nWorld")
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
        let (chunks, _) = renderer.render(markdown: md)
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
        let (chunks, hasMermaid) = renderer.render(markdown: md)
        let joined = chunks.joined()
        XCTAssertTrue(hasMermaid)
        XCTAssertTrue(joined.contains("mermaid-placeholder"))
        XCTAssertTrue(joined.contains("data-mermaid-source"))
        XCTAssertFalse(joined.contains("<pre><code class=\"language-mermaid\">"))
    }

    func testNoMermaidFlagWhenAbsent() {
        let renderer = MarkdownRenderer()
        let (_, hasMermaid) = renderer.render(markdown: "# No diagrams here")
        XCTAssertFalse(hasMermaid)
    }

    func testChunkingSplitsLargeContent() {
        let renderer = MarkdownRenderer()
        var md = ""
        // Generate ~200KB of markdown content to ensure well over 64KB of HTML output
        for i in 0..<500 {
            md += "## Heading \(i)\n\n" + String(repeating: "Word ", count: 60) + "\n\n"
        }
        let (chunks, _) = renderer.render(markdown: md)
        // Content well over 64KB should produce multiple chunks via byte-size splitting
        XCTAssertGreaterThan(chunks.count, 2, "Content well over 64KB should produce more than 2 chunks")
        // Verify each chunk is at most ~64KB (allow tolerance for block-boundary splitting)
        for (index, chunk) in chunks.enumerated() {
            XCTAssertLessThan(chunk.utf8.count, 80_000,
                "Chunk \(index) should be roughly <=64KB (was \(chunk.utf8.count) bytes)")
        }
        XCTAssertTrue(chunks[0].contains("Heading 0"), "First chunk should contain first heading")
    }

    func testSmallContentSingleChunk() {
        let renderer = MarkdownRenderer()
        let (chunks, _) = renderer.render(markdown: "Hello world")
        XCTAssertEqual(chunks.count, 1)
    }

    func testFullPageHTML() {
        let renderer = MarkdownRenderer()
        let template = SplitTemplate(templateHTML: "<body>{{FIRST_CHUNK}}</body>")
        let result = renderer.renderFullPage(markdown: "# Test", template: template)
        XCTAssertTrue(result.page.contains("<h1>"))
        XCTAssertTrue(result.page.contains("<body>"))
    }

    func testSplitTemplateConcat() {
        let template = SplitTemplate(templateHTML: "PREFIX{{FIRST_CHUNK}}SUFFIX")
        XCTAssertEqual(template.prefix, "PREFIX")
        XCTAssertEqual(template.suffix, "SUFFIX")
    }

    func testRenderFromFile() {
        let renderer = MarkdownRenderer()
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("test.md")
        try! "# File Test\n\nContent".write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let template = SplitTemplate(templateHTML: "<body>{{FIRST_CHUNK}}</body>")
        let result = renderer.renderFullPage(fileURL: tmpFile, template: template)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.page.contains("File Test"))
    }
}
