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

    func printContent() {
        // printOperation is broken on macOS 26 (produces blank pages).
        // Use createPDF + open in Preview as workaround.
        let tmpFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("MDViewer_print.pdf")
        exportPDF(to: tmpFile) { success in
            if success {
                NSWorkspace.shared.open(tmpFile)
            }
        }
    }

    func exportPDF(filename: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = filename
            .replacingOccurrences(of: ".md", with: ".pdf")
            .replacingOccurrences(of: ".markdown", with: ".pdf")

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.exportPDF(to: url) { success in
                if success {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }

    private func exportPDF(to url: URL, completion: @escaping (Bool) -> Void) {
        // createPDF captures the full scrollable content as a single page.
        // This is the correct behavior for a document viewer — continuous PDF.
        webView.createPDF(configuration: WKPDFConfiguration()) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let data):
                    do {
                        try data.write(to: url)
                        completion(true)
                    } catch {
                        Self.showError("Could not save PDF: \(error.localizedDescription)")
                        completion(false)
                    }
                case .failure(let error):
                    Self.showError("PDF generation failed: \(error.localizedDescription)")
                    completion(false)
                }
            }
        }
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
