import Cocoa

/// Custom view for printing paginated PDF content with headers and footers.
/// Used because WKWebView.printOperation is broken on macOS 26.
final class PDFPrintView: NSView {
    private let pdfDocument: CGPDFDocument
    private let pageCount: Int
    private let documentTitle: String

    private let headerHeight: CGFloat = 30
    private let footerHeight: CGFloat = 30
    private let margin: CGFloat = 36

    init(pdfData: Data, title: String) {
        let provider = CGDataProvider(data: pdfData as CFData)!
        self.pdfDocument = CGPDFDocument(provider)!
        self.pageCount = pdfDocument.numberOfPages
        self.documentTitle = title

        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    // MARK: - NSView Printing

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: pageCount)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        guard let printInfo = NSPrintOperation.current?.printInfo else {
            return .zero
        }
        let paperSize = printInfo.paperSize
        return NSRect(x: 0, y: 0, width: paperSize.width, height: paperSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let printOp = NSPrintOperation.current else { return }

        let page = printOp.currentPage
        guard page >= 1, page <= pageCount,
              let pdfPage = pdfDocument.page(at: page) else { return }

        let printInfo = printOp.printInfo
        let paperSize = printInfo.paperSize

        let contentX = margin
        let contentY = footerHeight + margin
        let contentWidth = paperSize.width - 2 * margin
        let contentHeight = paperSize.height - headerHeight - footerHeight - 2 * margin

        // Draw PDF page content scaled to fit
        let sourceRect = pdfPage.getBoxRect(.mediaBox)
        let scaleX = contentWidth / sourceRect.width
        let scaleY = contentHeight / sourceRect.height
        let scale = min(scaleX, scaleY)

        let scaledWidth = sourceRect.width * scale
        let offsetX = contentX + (contentWidth - scaledWidth) / 2

        context.saveGState()
        context.translateBy(x: offsetX, y: contentY)
        context.scaleBy(x: scale, y: scale)
        context.drawPDFPage(pdfPage)
        context.restoreGState()

        // Draw header
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let headerStr = documentTitle as NSString
        let headerSize = headerStr.size(withAttributes: headerAttrs)
        let headerY = paperSize.height - margin - headerSize.height
        headerStr.draw(at: NSPoint(x: margin, y: headerY), withAttributes: headerAttrs)

        // Header rule line
        let ruleY = headerY - 4
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: margin, y: ruleY))
        context.addLine(to: CGPoint(x: paperSize.width - margin, y: ruleY))
        context.strokePath()

        // Draw footer
        let footerAttrs = headerAttrs
        let pageStr = "Page \(page) of \(pageCount)" as NSString
        let pageSize = pageStr.size(withAttributes: footerAttrs)
        let footerY = margin

        // Footer rule line
        let footerRuleY = footerY + pageSize.height + 4
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.move(to: CGPoint(x: margin, y: footerRuleY))
        context.addLine(to: CGPoint(x: paperSize.width - margin, y: footerRuleY))
        context.strokePath()

        // Page number — right aligned
        pageStr.draw(
            at: NSPoint(x: paperSize.width - margin - pageSize.width, y: footerY),
            withAttributes: footerAttrs
        )

        // Document title in footer — left aligned
        let footerTitle = documentTitle as NSString
        footerTitle.draw(at: NSPoint(x: margin, y: footerY), withAttributes: footerAttrs)
    }
}
