import Foundation
import os
import cmark_gfm
import cmark_gfm_extensions

struct RenderResult {
    let page: String
    let remainingChunks: [String]
    let hasMermaid: Bool
}

/// Pre-split template for fast concatenation (no string scanning at render time).
struct SplitTemplate {
    let prefix: String
    let suffix: String

    init(templateHTML: String) {
        let marker = "{{FIRST_CHUNK}}"
        if let range = templateHTML.range(of: marker) {
            prefix = String(templateHTML[templateHTML.startIndex..<range.lowerBound])
            suffix = String(templateHTML[range.upperBound..<templateHTML.endIndex])
        } else {
            prefix = templateHTML
            suffix = ""
        }
    }
}

let renderingSignposter = OSSignposter(
    subsystem: "com.mdviewer.app",
    category: "RenderingPipeline"
)

final class MarkdownRenderer {
    private let chunkThreshold = 50

    private static let mermaidRegex = try! NSRegularExpression(
        pattern: #"<pre><code class="language-mermaid">([\s\S]*?)</code></pre>"#
    )
    private static let blockTagRegex = try! NSRegularExpression(
        pattern: #"<(?:p|h[1-6]|div|pre|blockquote|table|ul|ol|hr|li)[\s>]"#
    )

    init() {
        cmark_gfm_core_extensions_ensure_registered()
    }

    func render(markdown: String) -> (chunks: [String], hasMermaid: Bool) {
        let html = parseMarkdownToHTML(markdown)
        let (processed, hasMermaid) = processMermaidBlocks(html)
        return (chunkHTML(processed), hasMermaid)
    }

    func renderFullPage(markdown: String, template: SplitTemplate) -> RenderResult {
        let (chunks, hasMermaid) = render(markdown: markdown)
        let firstChunk = chunks.first ?? ""
        let remaining = Array(chunks.dropFirst())
        // Direct concatenation — no string scanning
        let page = template.prefix + firstChunk + template.suffix
        return RenderResult(page: page, remainingChunks: remaining, hasMermaid: hasMermaid)
    }

    func renderFullPage(fileURL: URL, template: SplitTemplate) -> RenderResult? {
        let spID = renderingSignposter.makeSignpostID()

        // File read interval
        let readState = renderingSignposter.beginInterval("file-read", id: spID)
        guard let markdown = try? String(contentsOf: fileURL, encoding: .utf8) else {
            renderingSignposter.endInterval("file-read", readState)
            return nil
        }
        renderingSignposter.endInterval("file-read", readState)

        // Parse interval
        let parseState = renderingSignposter.beginInterval("parse", id: spID)
        let html = parseMarkdownToHTML(markdown)
        renderingSignposter.endInterval("parse", parseState)

        // Chunk-split interval
        let chunkState = renderingSignposter.beginInterval("chunk-split", id: spID)
        let (processed, hasMermaid) = processMermaidBlocks(html)
        let chunks = chunkHTML(processed)
        renderingSignposter.endInterval("chunk-split", chunkState)

        let firstChunk = chunks.first ?? ""
        let remaining = Array(chunks.dropFirst())
        let page = template.prefix + firstChunk + template.suffix
        return RenderResult(page: page, remainingChunks: remaining, hasMermaid: hasMermaid)
    }

    // MARK: - Private

    private func parseMarkdownToHTML(_ markdown: String) -> String {
        let options: Int32 = CMARK_OPT_SMART | CMARK_OPT_UNSAFE

        guard let parser = cmark_parser_new(options) else {
            return "<p>Failed to create parser.</p>"
        }
        defer { cmark_parser_free(parser) }

        let extensions = ["table", "strikethrough", "autolink", "tasklist"]
        for ext in extensions {
            if let e = cmark_find_syntax_extension(ext) {
                cmark_parser_attach_syntax_extension(parser, e)
            }
        }

        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let root = cmark_parser_finish(parser) else {
            return "<p>Failed to parse markdown.</p>"
        }
        defer { cmark_node_free(root) }

        var extList: UnsafeMutablePointer<cmark_llist>? = nil
        for ext in extensions {
            if let e = cmark_find_syntax_extension(ext) {
                extList = cmark_llist_append(cmark_get_default_mem_allocator(), extList, UnsafeMutableRawPointer(e))
            }
        }

        guard let htmlCStr = cmark_render_html_with_mem(root, options, extList, cmark_get_default_mem_allocator()) else {
            return "<p>Failed to render HTML.</p>"
        }
        defer { free(htmlCStr) }

        return String(cString: htmlCStr)
    }

    private func processMermaidBlocks(_ html: String) -> (String, Bool) {
        let nsString = html as NSString
        let matches = Self.mermaidRegex.matches(in: html, range: NSRange(location: 0, length: nsString.length))
        guard !matches.isEmpty else { return (html, false) }

        var result = html
        for match in matches.reversed() {
            let fullRange = match.range
            let codeRange = match.range(at: 1)
            let mermaidSource = nsString.substring(with: codeRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let decoded = decodeHTMLEntities(mermaidSource)
            let encoded = encodeHTMLEntities(decoded)

            let placeholder = """
            <div class="mermaid-placeholder" data-mermaid-source="\(encoded)">
                <span style="color:#999;font-size:0.9em;">Loading diagram...</span>
            </div>
            """

            result = (result as NSString).replacingCharacters(in: fullRange, with: placeholder)
        }

        return (result, true)
    }

    private func decodeHTMLEntities(_ input: String) -> String {
        var result = input
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        return result
    }

    private func encodeHTMLEntities(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count + input.count / 8)
        for char in input {
            switch char {
            case "&":  result += "&amp;"
            case "\"": result += "&quot;"
            case "<":  result += "&lt;"
            case ">":  result += "&gt;"
            default:   result.append(char)
            }
        }
        return result
    }

    private func chunkHTML(_ html: String) -> [String] {
        let nsString = html as NSString
        let matches = Self.blockTagRegex.matches(in: html, range: NSRange(location: 0, length: nsString.length))

        if matches.count <= chunkThreshold {
            return [html]
        }

        let splitPoint = matches[chunkThreshold - 1].range.location
        let firstChunk = String(nsString.substring(to: splitPoint))
        let rest = String(nsString.substring(from: splitPoint))

        return [firstChunk, rest]
    }
}
