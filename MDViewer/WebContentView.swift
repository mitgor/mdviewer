import Cocoa
import WebKit

protocol WebContentViewDelegate: AnyObject {
    func webContentViewDidFinishFirstPaint(_ view: WebContentView)
}

final class WebContentView: NSView, WKNavigationDelegate, WKScriptMessageHandler {
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

        webView.navigationDelegate = self
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

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // If this is the print webview finishing load, fire the print completion
        if let completion = printCompletion {
            printCompletion = nil
            // Small delay for rendering to settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                completion()
            }
        }
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

    func printContent() {
        preparePrintableWebView { printView in
            let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
            printInfo.topMargin = 36
            printInfo.bottomMargin = 36
            printInfo.leftMargin = 36
            printInfo.rightMargin = 36

            let printOp = printView.printOperation(with: printInfo)
            printOp.showsPrintPanel = true
            printOp.showsProgressPanel = true
            printOp.run()
        }
    }

    func exportPDF(filename: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = filename.replacingOccurrences(of: ".md", with: ".pdf")
            .replacingOccurrences(of: ".markdown", with: ".pdf")

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.preparePrintableWebView { printView in
                let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
                printInfo.topMargin = 36
                printInfo.bottomMargin = 36
                printInfo.leftMargin = 36
                printInfo.rightMargin = 36
                printInfo.jobDisposition = .save
                printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

                let printOp = printView.printOperation(with: printInfo)
                printOp.showsPrintPanel = false
                printOp.showsProgressPanel = true
                printOp.run()

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }

    /// WKWebView's print renderer can't handle content loaded via loadHTMLString.
    /// Workaround: get the full HTML, write to temp file, load in a fresh webview
    /// via loadFileURL, then print from that webview.
    private func preparePrintableWebView(completion: @escaping (WKWebView) -> Void) {
        webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
            guard let html = result as? String else { return }

            let tmpDir = FileManager.default.temporaryDirectory
            let tmpFile = tmpDir.appendingPathComponent("mdviewer_print.html")
            try? html.data(using: .utf8)?.write(to: tmpFile)

            let printView = WKWebView(frame: self?.webView.frame ?? .zero)
            printView.navigationDelegate = self

            // Store completion to call when navigation finishes
            self?.printCompletion = { completion(printView) }

            printView.loadFileURL(tmpFile, allowingReadAccessTo: tmpDir)
        }
    }

    private var printCompletion: (() -> Void)?

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
