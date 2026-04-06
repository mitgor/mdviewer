import Cocoa
import WebKit

protocol WebContentViewDelegate: AnyObject {
    func webContentViewDidFinishFirstPaint(_ view: WebContentView)
}

final class WebContentView: NSView, WKScriptMessageHandler {
    weak var delegate: WebContentViewDelegate?

    private let webView: WKWebView
    private var remainingChunks: [String] = []
    private var hasMermaid = false
    private var isMonospace = false

    /// Mermaid JS source, loaded lazily from bundle on first use
    private static var mermaidJS: String?
    private static var mermaidJSLoaded = false

    override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let contentController = WKUserContentController()
        config.userContentController = contentController

        webView = WKWebView(frame: .zero, configuration: config)

        super.init(frame: frame)

        contentController.add(self, name: "firstPaint")

        webView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(webView)

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func loadContent(page: String, remainingChunks: [String], hasMermaid: Bool) {
        self.remainingChunks = remainingChunks
        self.hasMermaid = hasMermaid
        let resourceURL = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        webView.loadHTMLString(page, baseURL: resourceURL)
    }

    func toggleMonospace() {
        isMonospace.toggle()
        webView.evaluateJavaScript("window.toggleMonospace()")
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "firstPaint" {
            delegate?.webContentViewDidFinishFirstPaint(self)
            injectRemainingChunks()
            if hasMermaid {
                loadAndInitMermaid()
            }
        }
    }

    // MARK: - Private

    private func injectRemainingChunks() {
        guard !remainingChunks.isEmpty else { return }

        var jsChunks = "["
        for (index, chunk) in remainingChunks.enumerated() {
            if index > 0 { jsChunks += "," }
            jsChunks += "`"
            for char in chunk {
                switch char {
                case "\\": jsChunks += "\\\\"
                case "`":  jsChunks += "\\`"
                case "$":  jsChunks += "\\$"
                default:   jsChunks.append(char)
                }
            }
            jsChunks += "`"
        }
        jsChunks += "]"

        let js = """
        (function(){
            var chunks = \(jsChunks);
            chunks.forEach(function(chunk, i) {
                setTimeout(function(){ window.appendChunk(chunk); }, i * 16);
            });
        })();
        """

        webView.evaluateJavaScript(js)
        remainingChunks = []
    }

    private var documentTitle: String = ""

    func printContent(title: String) {
        self.documentTitle = title
        // printOperation on WKWebView is broken on macOS 26.
        // Workaround: createPDF → paginate → print via custom NSView.
        generatePaginatedPDF { pdfData in
            guard let data = pdfData else { return }
            let printView = PDFPrintView(pdfData: data, title: title)
            let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
            printInfo.topMargin = 0
            printInfo.bottomMargin = 0
            printInfo.leftMargin = 0
            printInfo.rightMargin = 0

            let printOp = NSPrintOperation(view: printView, printInfo: printInfo)
            printOp.showsPrintPanel = true
            printOp.showsProgressPanel = true
            printOp.run()
        }
    }

    func exportPDF(filename: String) {
        self.documentTitle = filename
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = filename
            .replacingOccurrences(of: ".md", with: ".pdf")
            .replacingOccurrences(of: ".markdown", with: ".pdf")

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.generatePaginatedPDF { pdfData in
                guard let data = pdfData else { return }

                // Use PDFPrintView to render with headers/footers
                let printView = PDFPrintView(pdfData: data, title: filename)
                let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
                printInfo.topMargin = 0
                printInfo.bottomMargin = 0
                printInfo.leftMargin = 0
                printInfo.rightMargin = 0
                printInfo.jobDisposition = .save
                printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

                let printOp = NSPrintOperation(view: printView, printInfo: printInfo)
                printOp.showsPrintPanel = false
                printOp.showsProgressPanel = true
                printOp.run()

                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    /// Generate paginated PDF from webview content via createPDF + CG slicing.
    private func generatePaginatedPDF(completion: @escaping (Data?) -> Void) {
        webView.createPDF(configuration: WKPDFConfiguration()) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let data):
                    let paginated = Self.paginatePDF(data: data)
                    completion(paginated)
                case .failure(let error):
                    Self.showError("PDF generation failed: \(error.localizedDescription)")
                    completion(nil)
                }
            }
        }
    }

    /// Slice a tall single-page PDF into A4-sized pages.
    private static func paginatePDF(data: Data) -> Data {
        guard let provider = CGDataProvider(data: data as CFData),
              let sourcePDF = CGPDFDocument(provider),
              let sourcePage = sourcePDF.page(at: 1) else {
            return data
        }

        let sourceRect = sourcePage.getBoxRect(.mediaBox)
        let pageWidth = sourceRect.width
        let sourceHeight = sourceRect.height

        // A4 proportions applied to source width
        let pageHeight: CGFloat = 841.89 * (pageWidth / 595.28)
        let pageCount = Int(ceil(sourceHeight / pageHeight))

        if pageCount <= 1 {
            return data
        }

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            return data
        }

        for i in 0..<pageCount {
            var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
            context.beginPage(mediaBox: &mediaBox)

            let yOffset = sourceHeight - CGFloat(i + 1) * pageHeight
            context.translateBy(x: 0, y: -yOffset)
            context.drawPDFPage(sourcePage)

            context.endPage()
        }

        context.closePDF()
        return pdfData as Data
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "PDF Export Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// Load mermaid.js only when the document has mermaid blocks.
    /// Cached after first load — subsequent documents reuse the parsed JS.
    private func loadAndInitMermaid() {
        if !Self.mermaidJSLoaded {
            Self.mermaidJSLoaded = true
            if let url = Bundle.main.url(forResource: "mermaid.min", withExtension: "js") {
                Self.mermaidJS = try? String(contentsOf: url, encoding: .utf8)
            }
        }

        guard let js = Self.mermaidJS else { return }

        // Inject mermaid.js then initialize
        webView.evaluateJavaScript(js) { [weak self] _, _ in
            self?.webView.evaluateJavaScript("window.initMermaid()")
        }
    }
}
