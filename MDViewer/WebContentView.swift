import Cocoa
import WebKit

protocol WebContentViewDelegate: AnyObject {
    func webContentViewDidFinishFirstPaint(_ view: WebContentView)
}

final class WebContentView: NSView, WKNavigationDelegate, WKScriptMessageHandler {
    weak var delegate: WebContentViewDelegate?

    private let webView: WKWebView
    private var remainingChunks: [String] = []
    private var isMonospace = false
    private var tempHTMLFile: URL?

    override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let contentController = WKUserContentController()
        config.userContentController = contentController

        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

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

    deinit {
        if let tempFile = tempHTMLFile {
            try? FileManager.default.removeItem(at: tempFile)
        }
    }

    func preWarm(templateHTML: String) {
        let emptyPage = templateHTML.replacingOccurrences(of: "{{FIRST_CHUNK}}", with: "")
        loadHTMLViaFile(emptyPage)
    }

    func loadContent(page: String, remainingChunks: [String]) {
        self.remainingChunks = remainingChunks
        loadHTMLViaFile(page)
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
            initMermaid()
        }
    }

    // MARK: - Private

    /// Write HTML to a temp file in the Resources directory, then load via loadFileURL.
    /// This grants WKWebView full access to sibling resources (fonts, mermaid.min.js).
    private func loadHTMLViaFile(_ html: String) {
        let resourceURL = Bundle.main.resourceURL ?? Bundle.main.bundleURL

        // Write to a temp file inside the Resources directory so relative URLs resolve
        let tempFile = resourceURL.appendingPathComponent("_mdviewer_temp_\(ProcessInfo.processInfo.processIdentifier).html")

        // Clean up previous temp file
        if let prev = tempHTMLFile {
            try? FileManager.default.removeItem(at: prev)
        }

        do {
            try html.write(to: tempFile, atomically: true, encoding: .utf8)
            tempHTMLFile = tempFile
            webView.loadFileURL(tempFile, allowingReadAccessTo: resourceURL)
        } catch {
            // Fallback to loadHTMLString if we can't write to Resources
            // (e.g., sandboxed app). In that case, use a writable temp dir.
            let fallbackDir = FileManager.default.temporaryDirectory
            let fallbackFile = fallbackDir.appendingPathComponent("mdviewer_page.html")

            // Copy resources to temp dir for access
            let fm = FileManager.default
            for resource in ["mermaid.min.js", "lmroman10-regular.woff2", "lmroman10-bold.woff2", "lmmono10-regular.woff2"] {
                let src = resourceURL.appendingPathComponent(resource)
                let dst = fallbackDir.appendingPathComponent(resource)
                if !fm.fileExists(atPath: dst.path) {
                    try? fm.copyItem(at: src, to: dst)
                }
            }

            try? html.write(to: fallbackFile, atomically: true, encoding: .utf8)
            tempHTMLFile = fallbackFile
            webView.loadFileURL(fallbackFile, allowingReadAccessTo: fallbackDir)
        }
    }

    private func injectRemainingChunks() {
        guard !remainingChunks.isEmpty else { return }

        for (index, chunk) in remainingChunks.enumerated() {
            let escaped = chunk
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "$", with: "\\$")

            let delay = index * 16
            let js = "setTimeout(function(){ window.appendChunk(`\(escaped)`); }, \(delay));"
            webView.evaluateJavaScript(js)
        }
        remainingChunks = []
    }

    private func initMermaid() {
        let js = "setTimeout(function(){ window.initMermaid(); }, 50);"
        webView.evaluateJavaScript(js)
    }
}
