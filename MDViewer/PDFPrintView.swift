import Cocoa

/// Custom view for printing WKWebView content with headers and footers.
/// Takes the raw tall PDF from createPDF and slices it into pages,
/// accounting for header/footer/margin space in each page.
final class PDFPrintView: NSView {
    private let sourcePage: CGPDFPage
    private let sourceRect: CGRect
    private let pageCount: Int
    private let documentTitle: String
    private let pageSize: NSSize

    private let headerHeight: CGFloat = 24
    private let footerHeight: CGFloat = 24
    private let margin: CGFloat = 36

    /// How much source content height fits in one output page's content area
    private let sourceHeightPerPage: CGFloat

    init?(pdfData: Data, title: String, paperSize: NSSize? = nil) {
        guard let provider = CGDataProvider(data: pdfData as CFData),
              let doc = CGPDFDocument(provider),
              let page = doc.page(at: 1) else {
            return nil
        }

        self.sourcePage = page
        self.sourceRect = page.getBoxRect(.mediaBox)
        self.documentTitle = title
        self.pageSize = paperSize ?? NSSize(width: 595.28, height: 841.89)

        // Content area within each output page
        let contentWidth = self.pageSize.width - 2 * margin
        let contentHeight = self.pageSize.height - headerHeight - footerHeight - 2 * margin

        // Scale factor to fit source width into content width
        let scale = contentWidth / sourceRect.width

        // How much source height fits per page (in source coordinates)
        self.sourceHeightPerPage = contentHeight / scale

        self.pageCount = max(1, Int(ceil(sourceRect.height / sourceHeightPerPage)))

        let totalHeight = CGFloat(pageCount) * self.pageSize.height
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
        guard page >= 1, page <= pageCount else { return }

        let pageOriginY = CGFloat(page - 1) * pageSize.height

        // White background
        context.setFillColor(NSColor.white.cgColor)
        context.fill(NSRect(x: 0, y: pageOriginY, width: pageSize.width, height: pageSize.height))

        // Content area
        let contentX = margin
        let contentY = pageOriginY + footerHeight + margin
        let contentWidth = pageSize.width - 2 * margin
        let contentHeight = pageSize.height - headerHeight - footerHeight - 2 * margin
        let scale = contentWidth / sourceRect.width

        // Clip to content area — prevents bleed into header/footer
        context.saveGState()
        context.clip(to: CGRect(x: contentX, y: contentY, width: contentWidth, height: contentHeight))

        // Calculate which portion of the source to show for this page.
        // Source page 1 shows the TOP of the content (highest Y in source coords).
        let sourceYOffset = sourceRect.height - CGFloat(page) * sourceHeightPerPage

        context.translateBy(x: contentX, y: contentY)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: -sourceYOffset)
        context.drawPDFPage(sourcePage)
        context.restoreGState()

        // Draw header/footer
        drawHeader(context: context, page: page, pageOriginY: pageOriginY)
        drawFooter(context: context, page: page, pageOriginY: pageOriginY)
    }

    // MARK: - Header & Footer

    private func drawHeader(context: CGContext, page: Int, pageOriginY: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let title = documentTitle as NSString
        let titleSize = title.size(withAttributes: attrs)
        let y = pageOriginY + pageSize.height - margin - titleSize.height
        title.draw(at: NSPoint(x: margin, y: y), withAttributes: attrs)

        // Rule line
        let ruleY = y - 3
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: margin, y: ruleY))
        context.addLine(to: CGPoint(x: pageSize.width - margin, y: ruleY))
        context.strokePath()
    }

    private func drawFooter(context: CGContext, page: Int, pageOriginY: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8.5, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        let footerY = pageOriginY + margin

        // Page number — right
        let pageStr = "Page \(page) of \(pageCount)" as NSString
        let pageStrSize = pageStr.size(withAttributes: attrs)
        pageStr.draw(
            at: NSPoint(x: pageSize.width - margin - pageStrSize.width, y: footerY),
            withAttributes: attrs
        )

        // Title — left
        let title = documentTitle as NSString
        title.draw(at: NSPoint(x: margin, y: footerY), withAttributes: attrs)

        // Rule line above footer text
        let ruleY = footerY + pageStrSize.height + 3
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: margin, y: ruleY))
        context.addLine(to: CGPoint(x: pageSize.width - margin, y: ruleY))
        context.strokePath()
    }
}
