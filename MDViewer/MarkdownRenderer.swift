import Foundation
import os
import cmark_gfm

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
    private let chunkByteLimit = 64 * 1024

    // CMARK-05: Cached extension pointers (looked up once at init)
    private let cachedExtList: UnsafeMutablePointer<cmark_llist>?

    init() {
        cmark_gfm_core_extensions_ensure_registered()
        let extNames = ["table", "strikethrough", "autolink", "tasklist"]
        var list: UnsafeMutablePointer<cmark_llist>? = nil
        for name in extNames {
            if let e = cmark_find_syntax_extension(name) {
                list = cmark_llist_append(
                    cmark_get_default_mem_allocator(), list,
                    UnsafeMutableRawPointer(e))
            }
        }
        self.cachedExtList = list
    }

    deinit {
        if let list = cachedExtList {
            cmark_llist_free(cmark_get_default_mem_allocator(), list)
        }
    }

    func render(markdown: String) -> (chunks: [String], hasMermaid: Bool) {
        let options: Int32 = CMARK_OPT_SMART | CMARK_OPT_UNSAFE

        guard let parser = cmark_parser_new(options) else {
            return (["<p>Failed to create parser.</p>"], false)
        }
        defer { cmark_parser_free(parser) }

        // Attach extensions to parser (parser stores pointers, does not take ownership)
        let extNames = ["table", "strikethrough", "autolink", "tasklist"]
        for name in extNames {
            if let e = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, e)
            }
        }

        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let root = cmark_parser_finish(parser) else {
            return (["<p>Failed to parse markdown.</p>"], false)
        }
        defer { cmark_node_free(root) }

        // Use chunked callback API (CMARK-04)
        let ctx = ChunkedRenderContext()
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
        defer { Unmanaged<ChunkedRenderContext>.fromOpaque(ctxPtr).release() }

        cmark_render_html_chunked(
            root, options, cachedExtList,
            cmark_get_default_mem_allocator(),
            chunkByteLimit,
            { (data, len, isLast, hasMermaid, userdata) -> Int32 in
                guard let data = data, let userdata = userdata else { return 1 }
                let ctx = Unmanaged<ChunkedRenderContext>
                    .fromOpaque(userdata).takeUnretainedValue()
                if len > 0 {
                    let chunk = String(
                        decoding: UnsafeBufferPointer(
                            start: UnsafeRawPointer(data)
                                .assumingMemoryBound(to: UInt8.self),
                            count: len
                        ),
                        as: UTF8.self
                    )
                    ctx.chunks.append(chunk)
                }
                if hasMermaid != 0 { ctx.hasMermaid = true }
                return 0
            },
            ctxPtr
        )

        return (ctx.chunks.isEmpty ? [""] : ctx.chunks, ctx.hasMermaid)
    }

    // MARK: - Buffer Reuse Assembly (STRM-02)

    /// Pre-allocated buffer for template + chunk assembly.
    /// Uses removeAll(keepingCapacity: true) to retain the heap allocation across calls.
    /// NOTE: Not thread-safe for concurrent calls on the same renderer instance.
    /// Callers must serialize or use separate renderer instances for concurrent renders.
    private var assemblyBuffer: [UInt8] = []

    /// Assemble template + chunk into a full page using a reusable byte buffer.
    func assembleFirstPage(template: SplitTemplate, chunk: String) -> String {
        assemblyBuffer.removeAll(keepingCapacity: true)
        assemblyBuffer.append(contentsOf: template.prefix.utf8)
        assemblyBuffer.append(contentsOf: chunk.utf8)
        assemblyBuffer.append(contentsOf: template.suffix.utf8)
        return String(decoding: assemblyBuffer, as: UTF8.self)
    }

    // MARK: - Streaming Render (STRM-01)

    /// Streaming render: fires onFirstChunk with the template-wrapped first chunk
    /// as soon as the C renderer produces it (before remaining chunks are done).
    /// onComplete is called after all chunks are produced, with remaining chunks and hasMermaid.
    ///
    /// NOTE: Not thread-safe for concurrent calls on the same renderer instance.
    /// Callers must serialize or use separate renderer instances for concurrent renders.
    func renderStreaming(
        markdown: String,
        template: SplitTemplate,
        onFirstChunk: @escaping (String) -> Void,
        onComplete: @escaping ([String], Bool) -> Void
    ) {
        let options: Int32 = CMARK_OPT_SMART | CMARK_OPT_UNSAFE

        guard let parser = cmark_parser_new(options) else {
            let fallback = assembleFirstPage(template: template, chunk: "<p>Failed to create parser.</p>")
            onFirstChunk(fallback)
            onComplete([], false)
            return
        }
        defer { cmark_parser_free(parser) }

        let extNames = ["table", "strikethrough", "autolink", "tasklist"]
        for name in extNames {
            if let e = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, e)
            }
        }

        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let root = cmark_parser_finish(parser) else {
            let fallback = assembleFirstPage(template: template, chunk: "<p>Failed to parse markdown.</p>")
            onFirstChunk(fallback)
            onComplete([], false)
            return
        }
        defer { cmark_node_free(root) }

        let ctx = StreamingRenderContext()
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
        defer { Unmanaged<StreamingRenderContext>.fromOpaque(ctxPtr).release() }

        // Capture self weakly for buffer assembly inside the callback
        ctx.onFirstChunk = { [weak self] chunkHTML in
            guard let self else { return }
            let page = self.assembleFirstPage(template: template, chunk: chunkHTML)
            onFirstChunk(page)
        }

        cmark_render_html_chunked(
            root, options, cachedExtList,
            cmark_get_default_mem_allocator(),
            chunkByteLimit,
            { (data, len, isLast, hasMermaid, userdata) -> Int32 in
                guard let data = data, let userdata = userdata else { return 1 }
                let ctx = Unmanaged<StreamingRenderContext>
                    .fromOpaque(userdata).takeUnretainedValue()
                if len > 0 {
                    let chunk = String(
                        decoding: UnsafeBufferPointer(
                            start: UnsafeRawPointer(data)
                                .assumingMemoryBound(to: UInt8.self),
                            count: len
                        ),
                        as: UTF8.self
                    )
                    if !ctx.firstChunkSent {
                        ctx.firstChunkSent = true
                        ctx.onFirstChunk?(chunk)
                    } else {
                        ctx.remainingChunks.append(chunk)
                    }
                }
                if hasMermaid != 0 { ctx.hasMermaid = true }
                return 0
            },
            ctxPtr
        )

        onComplete(ctx.remainingChunks, ctx.hasMermaid)
    }

    /// Streaming render from file URL with OSSignposter instrumentation.
    func renderStreaming(
        fileURL: URL,
        template: SplitTemplate,
        onFirstChunk: @escaping (String) -> Void,
        onComplete: @escaping ([String], Bool) -> Void
    ) -> Bool {
        let spID = renderingSignposter.makeSignpostID()

        let readState = renderingSignposter.beginInterval("file-read", id: spID)
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              let markdown = String(data: data, encoding: .utf8) else {
            renderingSignposter.endInterval("file-read", readState)
            return false
        }
        renderingSignposter.endInterval("file-read", readState)

        let parseState = renderingSignposter.beginInterval("parse-feed", id: spID)
        renderStreaming(markdown: markdown, template: template,
            onFirstChunk: { page in
                renderingSignposter.endInterval("parse-feed", parseState)
                let templateState = renderingSignposter.beginInterval("stream-first-chunk", id: spID)
                onFirstChunk(page)
                renderingSignposter.endInterval("stream-first-chunk", templateState)
            },
            onComplete: onComplete
        )
        return true
    }

    // MARK: - Batch Render (existing API)

    func renderFullPage(markdown: String, template: SplitTemplate) -> RenderResult {
        let (chunks, hasMermaid) = render(markdown: markdown)
        let firstChunk = chunks.first ?? ""
        let remaining = Array(chunks.dropFirst())
        let page = template.prefix + firstChunk + template.suffix
        return RenderResult(page: page, remainingChunks: remaining, hasMermaid: hasMermaid)
    }

    func renderFullPage(fileURL: URL, template: SplitTemplate) -> RenderResult? {
        let spID = renderingSignposter.makeSignpostID()

        let readState = renderingSignposter.beginInterval("file-read", id: spID)
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe),
              let markdown = String(data: data, encoding: .utf8) else {
            renderingSignposter.endInterval("file-read", readState)
            return nil
        }
        renderingSignposter.endInterval("file-read", readState)

        let parseState = renderingSignposter.beginInterval("parse+chunk", id: spID)
        let (chunks, hasMermaid) = render(markdown: markdown)
        renderingSignposter.endInterval("parse+chunk", parseState)

        let firstChunk = chunks.first ?? ""
        let remaining = Array(chunks.dropFirst())
        let page = template.prefix + firstChunk + template.suffix
        return RenderResult(page: page, remainingChunks: remaining, hasMermaid: hasMermaid)
    }
}

/// Context object passed through the C callback via Unmanaged pointer.
private final class ChunkedRenderContext {
    var chunks: [String] = []
    var hasMermaid: Bool = false
}

/// Context object for streaming render — fires onFirstChunk on first callback invocation,
/// accumulates remaining chunks for delivery via onComplete.
private final class StreamingRenderContext {
    var firstChunkSent = false
    var hasMermaid = false
    var remainingChunks: [String] = []
    var onFirstChunk: ((String) -> Void)?
}
