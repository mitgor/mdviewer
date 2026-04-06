import Cocoa

/// Custom view for printing paginated PDF content with headers and footers.
/// Used because WKWebView.printOperation is broken on macOS 26.
final class PDFPrintView: NSView {
    private let pdfDocument: CGPDFDocument
    private let pageCount: Int
    private let documentTitle: String
    private let pageSize: NSSize

    private let headerHeight: CGFloat = 30
    private let footerHeight: CGFloat = 30
    private let margin: CGFloat = 36

    init(pdfData: Data, title: String, paperSize: NSSize? = nil) {
        let provider = CGDataProvider(data: pdfData as CFData)!
        self.pdfDocument = CGPDFDocument(provider)!
        self.pageCount = pdfDocument.numberOfPages
        self.documentTitle = title
        self.pageSize = paperSize ?? NSSize(width: 595.28, height: 841.89) // A4 default

        // Frame must span all pages vertically for NSPrintOperation
        let totalHeight = CGFloat(self.pageCount) * self.pageSize.height
        super.init(frame: NSRect(x: 0, y: 0, width: self.pageSize.width, height: totalHeight))
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
        let y = CGFloat(page - 1) * pageSize.height
        return NSRect(x: 0, y: y, width: pageSize.width, height: pageSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let printOp = NSPrintOperation.current else { return }

        let page = printOp.currentPage
        guard page >= 1, page <= pageCount,
              let pdfPage = pdfDocument.page(at: page) else { return }

        // Page origin in view coordinates
        let pageOriginY = CGFloat(page - 1) * pageSize.height

        let contentX = margin
        let contentY = pageOriginY + footerHeight + margin
        let contentWidth = pageSize.width - 2 * margin
        let contentHeight = pageSize.height - headerHeight - footerHeight - 2 * margin

        // Draw white background
        context.setFillColor(NSColor.white.cgColor)
        context.fill(NSRect(x: 0, y: pageOriginY, width: pageSize.width, height: pageSize.height))

        // Draw PDF page content scaled to fit
        let sourceRect = pdfPage.getBoxRect(.mediaBox)
        let scaleX = contentWidth / sourceRect.width
        let scaleY = contentHeight / sourceRect.height
        let scale = min(scaleX, scaleY)

        let scaledWidth = sourceRect.width * scale
        let scaledHeight = sourceRect.height * scale
        let offsetX = contentX + (contentWidth - scaledWidth) / 2
        let offsetY = contentY + (contentHeight - scaledHeight) / 2

        context.saveGState()
        context.translateBy(x: offsetX, y: offsetY)
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
        let headerY = pageOriginY + pageSize.height - margin - headerSize.height
        headerStr.draw(at: NSPoint(x: margin, y: headerY), withAttributes: headerAttrs)

        // Header rule line
        let ruleY = headerY - 4
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: margin, y: ruleY))
        context.addLine(to: CGPoint(x: pageSize.width - margin, y: ruleY))
        context.strokePath()

        // Draw footer
        let pageStr = "Page \(page) of \(pageCount)" as NSString
        let pageStrSize = pageStr.size(withAttributes: headerAttrs)
        let footerY = pageOriginY + margin

        // Footer rule line
        let footerRuleY = footerY + pageStrSize.height + 4
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.move(to: CGPoint(x: margin, y: footerRuleY))
        context.addLine(to: CGPoint(x: pageSize.width - margin, y: footerRuleY))
        context.strokePath()

        // Page number — right aligned
        pageStr.draw(
            at: NSPoint(x: pageSize.width - margin - pageStrSize.width, y: footerY),
            withAttributes: headerAttrs
        )

        // Document title in footer — left aligned
        let footerTitle = documentTitle as NSString
        footerTitle.draw(at: NSPoint(x: margin, y: footerY), withAttributes: headerAttrs)
    }
}
