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

    func testChunkSplitsAtBlockBoundaries() {
        let renderer = MarkdownRenderer()
        // Create content where each paragraph is ~1KB, need >64 paragraphs to exceed 64KB
        var md = ""
        for i in 0..<80 {
            md += "Paragraph \(i): " + String(repeating: "x", count: 900) + "\n\n"
        }
        let (chunks, _) = renderer.render(markdown: md)
        XCTAssertGreaterThan(chunks.count, 1)
        // Each chunk after the first should start at a block-tag boundary
        for chunk in chunks.dropFirst() {
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(
                trimmed.hasPrefix("<p") || trimmed.hasPrefix("<h") ||
                trimmed.hasPrefix("<div") || trimmed.hasPrefix("<ul") ||
                trimmed.hasPrefix("<ol") || trimmed.hasPrefix("<table") ||
                trimmed.hasPrefix("<pre") || trimmed.hasPrefix("<blockquote") ||
                trimmed.hasPrefix("<hr") || trimmed.hasPrefix("<li"),
                "Each chunk after the first should start at a block-tag boundary, got: \(String(trimmed.prefix(30)))"
            )
        }
    }

    func testMemoryMappedFileRead() {
        let renderer = MarkdownRenderer()
        let tmpFile = FileManager.default.temporaryDirectory.appendingPathComponent("test_mmap.md")
        // Write content that will be read via mappedIfSafe
        let content = "# Memory Mapped\n\n" + String(repeating: "Test content. ", count: 100)
        try! content.write(to: tmpFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpFile) }

        let template = SplitTemplate(templateHTML: "<body>{{FIRST_CHUNK}}</body>")
        let result = renderer.renderFullPage(fileURL: tmpFile, template: template)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.page.contains("Memory Mapped"))
    }

    func testChunkByteSizeVerification() {
        let renderer = MarkdownRenderer()
        var md = ""
        // Generate ~300KB of content to get multiple chunks
        for i in 0..<600 {
            md += "## Section \(i)\n\n" + String(repeating: "Content ", count: 50) + "\n\n"
        }
        let (chunks, _) = renderer.render(markdown: md)
        XCTAssertGreaterThan(chunks.count, 1, "Large content should produce multiple chunks")
        // Verify byte sizes: each chunk should be roughly <=64KB
        for (index, chunk) in chunks.enumerated() {
            let byteCount = chunk.utf8.count
            XCTAssertLessThan(byteCount, 80_000,
                "Chunk \(index) byte size \(byteCount) should be roughly <=64KB")
        }
    }

    func testExtensionCachingDoesNotCrash() {
        // Verify that creating multiple renderers and rendering repeatedly
        // does not crash due to extension caching issues
        let renderer1 = MarkdownRenderer()
        let renderer2 = MarkdownRenderer()
        for _ in 0..<10 {
            let _ = renderer1.render(markdown: "| A | B |\n|---|---|\n| 1 | 2 |")
            let _ = renderer2.render(markdown: "~~strike~~ and https://example.com")
        }
        // If we get here without crashing, extension caching works correctly
    }

    func testChunkedAPIProducesNonEmptyChunks() {
        let renderer = MarkdownRenderer()
        let (chunks, _) = renderer.render(markdown: "# Title\n\nParagraph text")
        XCTAssertFalse(chunks.isEmpty)
        for (index, chunk) in chunks.enumerated() {
            XCTAssertFalse(chunk.isEmpty, "Chunk \(index) should not be empty")
        }
    }
}
