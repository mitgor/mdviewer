import Cocoa
import os
import cmark_gfm

/// Result of native rendering -- immutable value type matching project conventions.
struct NativeRenderResult {
    let attributedString: NSAttributedString
}

/// Module-level signposter for native rendering instrumentation (PERF-02).
let nativeRenderingSignposter = OSSignposter(
    subsystem: "com.mdviewer.app",
    category: "NativeRendering"
)

final class NativeRenderer {

    // MARK: - Typography Constants

    private enum Typography {
        static let bodySize: CGFloat = 16
        static let lineHeightMultiplier: CGFloat = 1.6
        static let maxContentWidth: CGFloat = 680
        static let textColor = NSColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1) // #333
        static let headingColor = NSColor(red: 0.102, green: 0.102, blue: 0.102, alpha: 1) // #1a1a1a
        static let linkColor = NSColor(red: 0.102, green: 0.227, blue: 0.420, alpha: 1) // #1a3a6b
        static let quoteColor = NSColor(red: 0.333, green: 0.333, blue: 0.333, alpha: 1) // #555
        static let codeBackground = NSColor(red: 0.973, green: 0.965, blue: 0.941, alpha: 1) // #f8f6f0
        static let hrColor = NSColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1) // #ccc
        static let listIndent: CGFloat = 32 // 2em at 16pt

        static func headingSize(level: Int) -> CGFloat {
            switch level {
            case 1: return bodySize * 2.0    // 32pt
            case 2: return bodySize * 1.5    // 24pt
            case 3: return bodySize * 1.25   // 20pt
            case 4: return bodySize * 1.1    // 17.6pt
            case 5: return bodySize          // 16pt
            case 6: return bodySize * 0.9    // 14.4pt
            default: return bodySize
            }
        }
    }

    // MARK: - Style State

    private struct StyleState {
        var fontSize: CGFloat
        var isBold: Bool
        var isItalic: Bool
        var isCode: Bool
        var textColor: NSColor
        var linkURL: URL?
        var isStrikethrough: Bool
        var listDepth: Int
        var isOrderedList: Bool
        var listItemIndex: Int
        var blockquoteDepth: Int
    }

    // MARK: - Font Registration

    private static var fontsRegistered = false

    /// Register bundled OTF fonts for Core Text. Called once at app startup.
    static func registerFonts() {
        guard !fontsRegistered else { return }
        fontsRegistered = true

        let fontNames = ["lmroman10-regular.otf", "lmroman10-bold.otf", "lmmono10-regular.otf"]
        for name in fontNames {
            guard let url = Bundle.main.url(forResource: name, withExtension: nil) else {
                #if DEBUG
                print("[NativeRenderer] Font not found in bundle: \(name)")
                #endif
                continue
            }
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            #if DEBUG
            if let error = error?.takeRetainedValue() {
                print("[NativeRenderer] Failed to register \(name): \(error)")
            }
            #endif
        }
    }

    // MARK: - Cached Fonts

    private let bodyFont: NSFont
    private let boldFont: NSFont
    private let italicFont: NSFont
    private let boldItalicFont: NSFont
    private let codeFont: NSFont
    private let codeBlockFont: NSFont
    private let headingFonts: [Int: NSFont] // level -> font

    init() {
        NativeRenderer.registerFonts()

        // Serif fonts: Latin Modern Roman 10, fallback to Times New Roman
        let serifName = "Latin Modern Roman 10"
        let monoName = "Latin Modern Mono 10"
        let fallbackSerif = "Times New Roman"
        let fallbackMono = "Menlo"

        let bodySize = Typography.bodySize

        // Body (regular)
        if let font = NSFont(name: serifName, size: bodySize) {
            bodyFont = font
        } else {
            #if DEBUG
            print("[NativeRenderer] Warning: '\(serifName)' not found, falling back to '\(fallbackSerif)'")
            #endif
            bodyFont = NSFont(name: fallbackSerif, size: bodySize) ?? NSFont.systemFont(ofSize: bodySize)
        }

        // Bold -- NSFontDescriptor.withSymbolicTraits returns non-optional on macOS
        let boldDesc = bodyFont.fontDescriptor.withSymbolicTraits(.bold)
        if let font = NSFont(descriptor: boldDesc, size: bodySize) {
            boldFont = font
        } else {
            boldFont = NSFont.boldSystemFont(ofSize: bodySize)
        }

        // Italic
        let italicDesc = bodyFont.fontDescriptor.withSymbolicTraits(.italic)
        if let font = NSFont(descriptor: italicDesc, size: bodySize) {
            italicFont = font
        } else {
            italicFont = bodyFont
        }

        // Bold Italic
        let boldItalicDesc = bodyFont.fontDescriptor.withSymbolicTraits([.bold, .italic])
        if let font = NSFont(descriptor: boldItalicDesc, size: bodySize) {
            boldItalicFont = font
        } else {
            boldItalicFont = boldFont
        }

        // Mono fonts: Latin Modern Mono 10, fallback to Menlo
        let inlineCodeSize: CGFloat = bodySize * 0.9 // 14.4pt
        let blockCodeSize: CGFloat = bodySize * 0.85  // 13.6pt

        if let font = NSFont(name: monoName, size: inlineCodeSize) {
            codeFont = font
        } else {
            #if DEBUG
            print("[NativeRenderer] Warning: '\(monoName)' not found, falling back to '\(fallbackMono)'")
            #endif
            codeFont = NSFont(name: fallbackMono, size: inlineCodeSize) ?? NSFont.monospacedSystemFont(ofSize: inlineCodeSize, weight: .regular)
        }

        if let font = NSFont(name: monoName, size: blockCodeSize) {
            codeBlockFont = font
        } else {
            codeBlockFont = NSFont(name: fallbackMono, size: blockCodeSize) ?? NSFont.monospacedSystemFont(ofSize: blockCodeSize, weight: .regular)
        }

        // Heading fonts (bold serif at each heading size)
        var hFonts: [Int: NSFont] = [:]
        for level in 1...6 {
            let size = Typography.headingSize(level: level)
            let desc = bodyFont.fontDescriptor.withSymbolicTraits(.bold)
            if let font = NSFont(descriptor: desc, size: size) {
                hFonts[level] = font
            } else {
                hFonts[level] = NSFont.boldSystemFont(ofSize: size)
            }
        }
        headingFonts = hFonts
    }

    // MARK: - Public API

    /// Walk the cmark AST and produce an NSAttributedString.
    /// The root pointer is borrowed -- caller owns it and will free it.
    func render(root: UnsafeMutablePointer<cmark_node>) -> NativeRenderResult {
        let spID = nativeRenderingSignposter.makeSignpostID()
        let intervalState = nativeRenderingSignposter.beginInterval("native-render", id: spID)
        defer { nativeRenderingSignposter.endInterval("native-render", intervalState) }

        let result = NSMutableAttributedString()
        var styleStack: [StyleState] = [makeDefaultStyle()]

        guard let iter = cmark_iter_new(root) else {
            return NativeRenderResult(attributedString: result)
        }
        defer { cmark_iter_free(iter) }

        // Track list item counters per depth
        var listItemCounters: [Int: Int] = [:] // depth -> current item number

        while true {
            let eventType = cmark_iter_next(iter)
            guard eventType != CMARK_EVENT_DONE else { break }

            guard let node = cmark_iter_get_node(iter) else { continue }
            let nodeType = cmark_node_get_type(node)

            // Check for extension node types via type string
            let typeString: String? = {
                guard let cStr = cmark_node_get_type_string(node) else { return nil }
                return String(cString: cStr)
            }()

            let currentStyle = styleStack.last ?? makeDefaultStyle()

            if eventType == CMARK_EVENT_ENTER {
                switch nodeType {
                case CMARK_NODE_DOCUMENT:
                    break // no-op

                case CMARK_NODE_HEADING:
                    let level = Int(cmark_node_get_heading_level(node))
                    var newStyle = currentStyle
                    newStyle.fontSize = Typography.headingSize(level: level)
                    newStyle.isBold = true
                    newStyle.textColor = Typography.headingColor
                    styleStack.append(newStyle)

                case CMARK_NODE_PARAGRAPH:
                    styleStack.append(currentStyle)

                case CMARK_NODE_BLOCK_QUOTE:
                    var newStyle = currentStyle
                    newStyle.isItalic = true
                    newStyle.textColor = Typography.quoteColor
                    newStyle.blockquoteDepth = currentStyle.blockquoteDepth + 1
                    styleStack.append(newStyle)

                case CMARK_NODE_LIST:
                    var newStyle = currentStyle
                    let listType = cmark_node_get_list_type(node)
                    newStyle.isOrderedList = (listType == CMARK_ORDERED_LIST)
                    newStyle.listDepth = currentStyle.listDepth + 1
                    newStyle.listItemIndex = 0
                    listItemCounters[newStyle.listDepth] = 0
                    styleStack.append(newStyle)

                case CMARK_NODE_ITEM:
                    var newStyle = currentStyle
                    let depth = currentStyle.listDepth
                    let counter = (listItemCounters[depth] ?? 0) + 1
                    listItemCounters[depth] = counter
                    newStyle.listItemIndex = counter
                    styleStack.append(newStyle)

                    // Prepend bullet or number
                    let prefix: String
                    if currentStyle.isOrderedList {
                        prefix = "\(counter). "
                    } else {
                        prefix = "\u{2022} " // bullet
                    }
                    let attrs = makeAttributes(for: currentStyle)
                    let paraStyle = NSMutableParagraphStyle()
                    paraStyle.lineHeightMultiple = Typography.lineHeightMultiplier
                    let indent = Typography.listIndent * CGFloat(depth)
                    paraStyle.headIndent = indent
                    paraStyle.firstLineHeadIndent = indent - 16 // hang the bullet/number
                    paraStyle.paragraphSpacingBefore = 2
                    var prefixAttrs = attrs
                    prefixAttrs[.paragraphStyle] = paraStyle
                    result.append(NSAttributedString(string: prefix, attributes: prefixAttrs))

                case CMARK_NODE_CODE_BLOCK:
                    // Leaf-like: append full content and skip children
                    if let literal = cmark_node_get_literal(node) {
                        let text = String(cString: literal)
                        let paraStyle = NSMutableParagraphStyle()
                        paraStyle.lineHeightMultiple = Typography.lineHeightMultiplier
                        paraStyle.paragraphSpacingBefore = 8
                        let attrs: [NSAttributedString.Key: Any] = [
                            .font: codeBlockFont,
                            .foregroundColor: Typography.textColor,
                            .backgroundColor: Typography.codeBackground,
                            .paragraphStyle: paraStyle
                        ]
                        result.append(NSAttributedString(string: text, attributes: attrs))
                        if !text.hasSuffix("\n") {
                            result.append(NSAttributedString(string: "\n", attributes: attrs))
                        }
                    }
                    // Push style so EXIT pops it
                    styleStack.append(currentStyle)

                case CMARK_NODE_HTML_BLOCK:
                    // Render raw HTML as plaintext (rare in non-table files)
                    if let literal = cmark_node_get_literal(node) {
                        let text = String(cString: literal)
                        let attrs = makeAttributes(for: currentStyle)
                        result.append(NSAttributedString(string: text, attributes: attrs))
                    }
                    styleStack.append(currentStyle)

                case CMARK_NODE_THEMATIC_BREAK:
                    let paraStyle = NSMutableParagraphStyle()
                    paraStyle.paragraphSpacingBefore = 12
                    paraStyle.alignment = .center
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: bodyFont,
                        .foregroundColor: Typography.hrColor,
                        .paragraphStyle: paraStyle
                    ]
                    result.append(NSAttributedString(string: "\n\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\n", attributes: attrs))
                    styleStack.append(currentStyle)

                case CMARK_NODE_EMPH:
                    var newStyle = currentStyle
                    newStyle.isItalic = true
                    styleStack.append(newStyle)

                case CMARK_NODE_STRONG:
                    var newStyle = currentStyle
                    newStyle.isBold = true
                    styleStack.append(newStyle)

                case CMARK_NODE_LINK:
                    var newStyle = currentStyle
                    newStyle.textColor = Typography.linkColor
                    if let urlStr = cmark_node_get_url(node) {
                        let urlString = String(cString: urlStr)
                        newStyle.linkURL = URL(string: urlString)
                    }
                    styleStack.append(newStyle)

                case CMARK_NODE_IMAGE:
                    // Images not supported in NSTextView natively -- show alt text placeholder
                    styleStack.append(currentStyle)

                case CMARK_NODE_TEXT:
                    if let literal = cmark_node_get_literal(node) {
                        let text = String(cString: literal)
                        let attrs = makeAttributes(for: currentStyle)
                        result.append(NSAttributedString(string: text, attributes: attrs))
                    }

                case CMARK_NODE_CODE:
                    if let literal = cmark_node_get_literal(node) {
                        let text = String(cString: literal)
                        var attrs = makeAttributes(for: currentStyle)
                        attrs[.font] = codeFont
                        attrs[.backgroundColor] = Typography.codeBackground
                        result.append(NSAttributedString(string: text, attributes: attrs))
                    }

                case CMARK_NODE_SOFTBREAK:
                    let attrs = makeAttributes(for: currentStyle)
                    result.append(NSAttributedString(string: " ", attributes: attrs))

                case CMARK_NODE_LINEBREAK:
                    let attrs = makeAttributes(for: currentStyle)
                    result.append(NSAttributedString(string: "\n", attributes: attrs))

                case CMARK_NODE_HTML_INLINE:
                    if let literal = cmark_node_get_literal(node) {
                        let text = String(cString: literal)
                        let attrs = makeAttributes(for: currentStyle)
                        result.append(NSAttributedString(string: text, attributes: attrs))
                    }

                default:
                    // Handle extension types via type string
                    if let ts = typeString {
                        switch ts {
                        case "strikethrough":
                            var newStyle = currentStyle
                            newStyle.isStrikethrough = true
                            styleStack.append(newStyle)
                        case "tasklist":
                            // Tasklist items handled via checkbox prefix
                            styleStack.append(currentStyle)
                        default:
                            // Unknown extension -- push current style to maintain stack balance
                            styleStack.append(currentStyle)
                        }
                    } else {
                        // Unknown core node -- push no-op style so EXIT can always pop
                        styleStack.append(currentStyle)
                    }
                }

            } else if eventType == CMARK_EVENT_EXIT {
                switch nodeType {
                case CMARK_NODE_HEADING:
                    // Add newline after heading
                    let attrs = makeAttributes(for: currentStyle)
                    result.append(NSAttributedString(string: "\n", attributes: attrs))
                    styleStack.removeLast()

                case CMARK_NODE_PARAGRAPH:
                    // Add paragraph break (only paragraphSpacingBefore on next block)
                    let paraStyle = NSMutableParagraphStyle()
                    paraStyle.lineHeightMultiple = Typography.lineHeightMultiplier
                    let defaultAttrs: [NSAttributedString.Key: Any] = [
                        .font: bodyFont,
                        .paragraphStyle: paraStyle
                    ]
                    result.append(NSAttributedString(string: "\n", attributes: defaultAttrs))
                    styleStack.removeLast()

                case CMARK_NODE_BLOCK_QUOTE,
                     CMARK_NODE_CODE_BLOCK,
                     CMARK_NODE_HTML_BLOCK,
                     CMARK_NODE_THEMATIC_BREAK:
                    styleStack.removeLast()

                case CMARK_NODE_LIST:
                    styleStack.removeLast()

                case CMARK_NODE_ITEM:
                    // Add newline if last character isn't already a newline
                    if let lastChar = result.string.last, lastChar != "\n" {
                        let attrs = makeAttributes(for: currentStyle)
                        result.append(NSAttributedString(string: "\n", attributes: attrs))
                    }
                    styleStack.removeLast()

                case CMARK_NODE_EMPH,
                     CMARK_NODE_STRONG,
                     CMARK_NODE_LINK:
                    styleStack.removeLast()

                case CMARK_NODE_IMAGE:
                    styleStack.removeLast()

                case CMARK_NODE_DOCUMENT:
                    break

                default:
                    // Pop the style pushed on enter (core or extension)
                    if styleStack.count > 1 {
                        styleStack.removeLast()
                    }
                }
            }
        }

        // Trim trailing whitespace
        let fullString = result.string
        if let lastNonWS = fullString.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted, options: .backwards) {
            let endIndex = fullString.distance(from: fullString.startIndex, to: lastNonWS.upperBound)
            if endIndex < result.length {
                result.deleteCharacters(in: NSRange(location: endIndex, length: result.length - endIndex))
            }
        }

        return NativeRenderResult(attributedString: result)
    }

    // MARK: - Private Helpers

    private func makeDefaultStyle() -> StyleState {
        return StyleState(
            fontSize: Typography.bodySize,
            isBold: false,
            isItalic: false,
            isCode: false,
            textColor: Typography.textColor,
            linkURL: nil,
            isStrikethrough: false,
            listDepth: 0,
            isOrderedList: false,
            listItemIndex: 0,
            blockquoteDepth: 0
        )
    }

    private func makeAttributes(for style: StyleState) -> [NSAttributedString.Key: Any] {
        let font = resolveFont(for: style)

        let paraStyle = NSMutableParagraphStyle()
        paraStyle.lineHeightMultiple = Typography.lineHeightMultiplier

        if style.listDepth > 0 {
            let indent = Typography.listIndent * CGFloat(style.listDepth)
            paraStyle.headIndent = indent
            paraStyle.firstLineHeadIndent = indent
            paraStyle.paragraphSpacingBefore = 2
        } else if style.blockquoteDepth > 0 {
            let indent: CGFloat = 16 * CGFloat(style.blockquoteDepth)
            paraStyle.headIndent = indent
            paraStyle.firstLineHeadIndent = indent
            paraStyle.paragraphSpacingBefore = 4
        } else {
            paraStyle.paragraphSpacingBefore = 4
        }

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.textColor,
            .paragraphStyle: paraStyle
        ]

        if let url = style.linkURL {
            attrs[.link] = url
        }

        if style.isStrikethrough {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }

        return attrs
    }

    private func resolveFont(for style: StyleState) -> NSFont {
        if style.isCode {
            return codeFont
        }

        // For non-body sizes (headings), create the appropriately sized font
        if style.fontSize != Typography.bodySize {
            if style.isBold && style.isItalic {
                let desc = bodyFont.fontDescriptor.withSymbolicTraits([.bold, .italic])
                if let font = NSFont(descriptor: desc, size: style.fontSize) {
                    return font
                }
                return headingFonts[1] ?? boldFont // fallback
            } else if style.isBold {
                // Look up cached heading font at this size
                for (_, font) in headingFonts {
                    if abs(font.pointSize - style.fontSize) < 0.1 {
                        return font
                    }
                }
                let desc = bodyFont.fontDescriptor.withSymbolicTraits(.bold)
                return NSFont(descriptor: desc, size: style.fontSize) ?? boldFont
            } else if style.isItalic {
                let desc = bodyFont.fontDescriptor.withSymbolicTraits(.italic)
                if let font = NSFont(descriptor: desc, size: style.fontSize) {
                    return font
                }
                return italicFont
            } else {
                return NSFont(name: bodyFont.fontName, size: style.fontSize) ?? bodyFont
            }
        }

        // Body size
        if style.isBold && style.isItalic {
            return boldItalicFont
        } else if style.isBold {
            return boldFont
        } else if style.isItalic {
            return italicFont
        }
        return bodyFont
    }
}
