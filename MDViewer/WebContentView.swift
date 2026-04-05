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

    /// Batch all remaining chunks into a single JS call instead of N separate bridge crossings.
    private func injectRemainingChunks() {
        guard !remainingChunks.isEmpty else { return }

        // Single-pass escape all chunks, then send one JS call
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

    private func initMermaid() {
        let js = "setTimeout(function(){ window.initMermaid(); }, 50);"
        webView.evaluateJavaScript(js)
    }
}
