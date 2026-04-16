import XCTest
import cmark_gfm
@testable import MDViewer

final class NativeRendererTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        NativeRenderer.registerFonts()
    }

    // MARK: - Helper

    private func renderNative(_ markdown: String) -> NSAttributedString {
        let markdownRenderer = MarkdownRenderer()
        guard let root = markdownRenderer.parseMarkdown(markdown) else {
            XCTFail("Failed to parse markdown")
            return NSAttributedString()
        }
        defer { cmark_node_free(root) }

        let nativeRenderer = NativeRenderer()
        let result = nativeRenderer.render(root: root)
        return result.attributedString
    }

    // MARK: - Heading Tests

    func testHeadingRendersWithLargerFont() {
        let result = renderNative("# Heading 1")
        XCTAssertTrue(result.string.contains("Heading 1"))

        // Check font size at the start of the attributed string
        let attrs = result.attributes(at: 0, effectiveRange: nil)
        guard let font = attrs[.font] as? NSFont else {
            XCTFail("No font attribute found at range [0]")
            return
        }
        // h1 = 2em * 16 = 32pt
        XCTAssertEqual(font.pointSize, 32, accuracy: 0.5,
            "H1 font size should be 32pt, got \(font.pointSize)")
    }

    func testMultipleHeadingLevels() {
        let md = "# H1\n\n## H2\n\n### H3"
        let result = renderNative(md)

        // Find ranges for each heading text
        let string = result.string as NSString
        let h1Range = string.range(of: "H1")
        let h2Range = string.range(of: "H2")
        let h3Range = string.range(of: "H3")

        XCTAssertNotEqual(h1Range.location, NSNotFound)
        XCTAssertNotEqual(h2Range.location, NSNotFound)
        XCTAssertNotEqual(h3Range.location, NSNotFound)

        let h1Font = result.attributes(at: h1Range.location, effectiveRange: nil)[.font] as? NSFont
        let h2Font = result.attributes(at: h2Range.location, effectiveRange: nil)[.font] as? NSFont
        let h3Font = result.attributes(at: h3Range.location, effectiveRange: nil)[.font] as? NSFont

        guard let h1Size = h1Font?.pointSize,
              let h2Size = h2Font?.pointSize,
              let h3Size = h3Font?.pointSize else {
            XCTFail("Missing font attributes on headings")
            return
        }

        XCTAssertGreaterThan(h1Size, h2Size, "H1 should be larger than H2")
        XCTAssertGreaterThan(h2Size, h3Size, "H2 should be larger than H3")
        // Verify specific sizes: h1=32, h2=24, h3=20
        XCTAssertEqual(h1Size, 32, accuracy: 0.5)
        XCTAssertEqual(h2Size, 24, accuracy: 0.5)
        XCTAssertEqual(h3Size, 20, accuracy: 0.5)
    }

    // MARK: - Paragraph Tests

    func testParagraphRendersText() {
        let result = renderNative("Hello world")
        XCTAssertTrue(result.string.contains("Hello world"))
    }

    // MARK: - Inline Formatting Tests

    func testBoldRendersWithBoldTrait() {
        let result = renderNative("**bold text**")
        let string = result.string as NSString
        let range = string.range(of: "bold text")
        XCTAssertNotEqual(range.location, NSNotFound, "Should contain 'bold text'")

        let attrs = result.attributes(at: range.location, effectiveRange: nil)
        guard let font = attrs[.font] as? NSFont else {
            XCTFail("No font attribute at bold text range")
            return
        }
        let traits = font.fontDescriptor.symbolicTraits
        XCTAssertTrue(traits.contains(.bold),
            "Font at 'bold text' should have bold trait, got traits: \(traits)")
    }

    func testItalicRendersWithItalicTrait() {
        let result = renderNative("*italic text*")
        let string = result.string as NSString
        let range = string.range(of: "italic text")
        XCTAssertNotEqual(range.location, NSNotFound, "Should contain 'italic text'")

        let attrs = result.attributes(at: range.location, effectiveRange: nil)
        guard let font = attrs[.font] as? NSFont else {
            XCTFail("No font attribute at italic text range")
            return
        }
        let traits = font.fontDescriptor.symbolicTraits
        XCTAssertTrue(traits.contains(.italic),
            "Font at 'italic text' should have italic trait, got traits: \(traits)")
    }

    func testNestedFormattingBoldInItalic() {
        let result = renderNative("*text **bold** more*")
        let string = result.string as NSString

        // Find the "bold" text range
        let boldRange = string.range(of: "bold")
        XCTAssertNotEqual(boldRange.location, NSNotFound)

        let attrs = result.attributes(at: boldRange.location, effectiveRange: nil)
        guard let font = attrs[.font] as? NSFont else {
            XCTFail("No font attribute at nested bold range")
            return
        }
        let traits = font.fontDescriptor.symbolicTraits
        // Should have both bold and italic traits
        XCTAssertTrue(traits.contains(.bold),
            "Nested bold text should have bold trait")
        XCTAssertTrue(traits.contains(.italic),
            "Nested bold text inside italic should have italic trait")

        // Verify the surrounding "text" has italic but not bold
        let textRange = string.range(of: "text")
        if textRange.location != NSNotFound {
            let textAttrs = result.attributes(at: textRange.location, effectiveRange: nil)
            if let textFont = textAttrs[.font] as? NSFont {
                let textTraits = textFont.fontDescriptor.symbolicTraits
                XCTAssertTrue(textTraits.contains(.italic),
                    "'text' should have italic trait")
            }
        }
    }

    // MARK: - Code Tests

    func testInlineCodeUsesMonoFont() {
        let result = renderNative("Use `code` here")
        let string = result.string as NSString
        let range = string.range(of: "code")
        XCTAssertNotEqual(range.location, NSNotFound, "Should contain 'code'")

        let attrs = result.attributes(at: range.location, effectiveRange: nil)
        guard let font = attrs[.font] as? NSFont else {
            XCTFail("No font attribute at code range")
            return
        }
        let fontName = font.fontName.lowercased()
        XCTAssertTrue(fontName.contains("mono") || fontName.contains("courier") || fontName.contains("menlo"),
            "Inline code font should be monospace, got: \(font.fontName)")
    }

    func testCodeBlockRendersContent() {
        let md = """
        ```
        let x = 42
        ```
        """
        let result = renderNative(md)
        XCTAssertTrue(result.string.contains("let x = 42"),
            "Code block content should appear in attributed string")
    }

    // MARK: - Link Tests

    func testLinkHasURLAttribute() {
        let result = renderNative("[example](https://example.com)")
        let string = result.string as NSString
        let range = string.range(of: "example")
        XCTAssertNotEqual(range.location, NSNotFound, "Should contain 'example'")

        let attrs = result.attributes(at: range.location, effectiveRange: nil)
        guard let link = attrs[.link] else {
            XCTFail("No .link attribute at 'example' range")
            return
        }
        if let url = link as? URL {
            XCTAssertEqual(url.absoluteString, "https://example.com")
        } else if let urlString = link as? String {
            XCTAssertEqual(urlString, "https://example.com")
        } else {
            XCTFail("Link attribute is neither URL nor String: \(link)")
        }
    }

    // MARK: - List Tests

    func testUnorderedListHasBullets() {
        let result = renderNative("- item 1\n- item 2")
        let string = result.string
        XCTAssertTrue(string.contains("item 1"), "Should contain 'item 1'")
        XCTAssertTrue(string.contains("item 2"), "Should contain 'item 2'")
        // Check for bullet character (U+2022)
        XCTAssertTrue(string.contains("\u{2022}"),
            "Unordered list should contain bullet character")
    }

    func testOrderedListHasNumbers() {
        let result = renderNative("1. first\n2. second")
        let string = result.string
        XCTAssertTrue(string.contains("first"), "Should contain 'first'")
        XCTAssertTrue(string.contains("second"), "Should contain 'second'")
        // Check for numbering
        XCTAssertTrue(string.contains("1.") || string.contains("1)"),
            "Ordered list should contain numbering")
    }

    // MARK: - Blockquote Tests

    func testBlockquoteRendersContent() {
        let result = renderNative("> quote text")
        XCTAssertTrue(result.string.contains("quote text"),
            "'quote text' should appear in attributed string")
    }

    // MARK: - Thematic Break Tests

    func testHorizontalRuleRenders() {
        let result = renderNative("---")
        XCTAssertGreaterThan(result.length, 0,
            "Horizontal rule should produce non-empty attributed string")
    }

    // MARK: - Strikethrough Tests

    func testStrikethroughHasAttribute() {
        let result = renderNative("~~struck~~")
        let string = result.string as NSString
        let range = string.range(of: "struck")
        XCTAssertNotEqual(range.location, NSNotFound, "Should contain 'struck'")

        let attrs = result.attributes(at: range.location, effectiveRange: nil)
        let strikeValue = attrs[.strikethroughStyle] as? Int
        XCTAssertNotNil(strikeValue,
            "Strikethrough text should have .strikethroughStyle attribute")
        if let value = strikeValue {
            XCTAssertGreaterThan(value, 0,
                "Strikethrough style value should be > 0")
        }
    }

    // MARK: - canRenderNatively Tests

    func testCanRenderNativelyRejectsTable() {
        let md = """
        | Name | Age |
        |------|-----|
        | Alice | 30 |
        """
        let markdownRenderer = MarkdownRenderer()
        guard let root = markdownRenderer.parseMarkdown(md) else {
            XCTFail("Failed to parse markdown with table")
            return
        }
        defer { cmark_node_free(root) }

        let canRender = markdownRenderer.canRenderNatively(root: root)
        XCTAssertFalse(canRender,
            "canRenderNatively should return false for markdown with GFM tables")
    }

    func testCanRenderNativelyRejectsMermaid() {
        let md = """
        ```mermaid
        graph TD
            A --> B
        ```
        """
        let markdownRenderer = MarkdownRenderer()
        guard let root = markdownRenderer.parseMarkdown(md) else {
            XCTFail("Failed to parse markdown with mermaid")
            return
        }
        defer { cmark_node_free(root) }

        let canRender = markdownRenderer.canRenderNatively(root: root)
        XCTAssertFalse(canRender,
            "canRenderNatively should return false for markdown with mermaid blocks")
    }

    func testCanRenderNativelyAcceptsSimpleMarkdown() {
        let md = """
        # Title

        Some paragraph text.

        ```swift
        let x = 1
        ```

        - item 1
        - item 2
        """
        let markdownRenderer = MarkdownRenderer()
        guard let root = markdownRenderer.parseMarkdown(md) else {
            XCTFail("Failed to parse simple markdown")
            return
        }
        defer { cmark_node_free(root) }

        let canRender = markdownRenderer.canRenderNatively(root: root)
        XCTAssertTrue(canRender,
            "canRenderNatively should return true for simple markdown without tables or mermaid")
    }

    // MARK: - Font Tests (NATV-03)

    func testBodyTextUsesLatinModernFont() {
        let result = renderNative("Hello")
        let attrs = result.attributes(at: 0, effectiveRange: nil)
        guard let font = attrs[.font] as? NSFont else {
            XCTFail("No font attribute found at range [0]")
            return
        }
        let fontName = font.fontName.lowercased()
        // Latin Modern Roman 10 registered font name or fallback
        XCTAssertTrue(
            fontName.contains("latin") || fontName.contains("lmroman") ||
            fontName.contains("times"),
            "Body text should use Latin Modern Roman (or Times fallback), got: \(font.fontName)")
    }

    // MARK: - Edge Cases

    func testEmptyMarkdownReturnsEmptyString() {
        let result = renderNative("")
        XCTAssertEqual(result.length, 0,
            "Empty markdown should produce empty or minimal attributed string")
    }
}
