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

    func loadContent(page: String, remainingChunks: [String]) {
        self.remainingChunks = remainingChunks
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
            initMermaid()
        }
    }

    // MARK: - Private

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
