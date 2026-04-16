import Cocoa
import os
import WebKit

protocol WebContentViewDelegate: AnyObject {
    func webContentViewDidFinishFirstPaint(_ view: WebContentView)
}

final class WebContentView: NSView, WKScriptMessageHandler {

    // MARK: - WeakScriptMessageProxy

    /// Breaks the WKUserContentController -> WebContentView retain cycle.
    /// WKUserContentController holds a strong reference to its message handlers;
    /// this proxy holds a weak reference back to the real handler.
    private class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
        weak var delegate: WKScriptMessageHandler?

        init(delegate: WKScriptMessageHandler) {
            self.delegate = delegate
            super.init()
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            delegate?.userContentController(userContentController, didReceive: message)
        }
    }

    // MARK: - Properties

    weak var delegate: WebContentViewDelegate?

    private let webView: WKWebView
    private var remainingChunks: [String] = []
    private var hasMermaid = false
    private var isMonospace = false
    private var hasProcessedFirstPaint = false

    override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        #if DEBUG
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        let contentController = WKUserContentController()
        config.userContentController = contentController

        webView = WKWebView(frame: .zero, configuration: config)

        super.init(frame: frame)

        contentController.add(WeakScriptMessageProxy(delegate: self), name: "firstPaint")

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
        if message.name == "firstPaint", !hasProcessedFirstPaint {
            hasProcessedFirstPaint = true
            delegate?.webContentViewDidFinishFirstPaint(self)
            injectRemainingChunks()
            if hasMermaid {
                loadAndInitMermaid()
            }
        }
    }

    // MARK: - Pool Support

    /// Allow external crash-detection delegate for pooled views.
    /// Pool sets itself as delegate for idle views; clears on dequeue.
    func setNavigationDelegate(_ delegate: WKNavigationDelegate?) {
        webView.navigationDelegate = delegate
    }

    /// Identity check: does this WebContentView own the given WKWebView?
    /// Used by WebViewPool to match a crashed WKWebView back to its owner.
    func ownsWebView(_ candidate: WKWebView) -> Bool {
        return webView === candidate
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "firstPaint")
        #if DEBUG
        print("[WebContentView] deinit - \(ObjectIdentifier(self))")
        #endif
    }

    // MARK: - Private

    private func injectRemainingChunks() {
        guard !remainingChunks.isEmpty else { return }

        let chunkInjectState = renderingSignposter.beginInterval("chunk-inject")
        let chunks = remainingChunks
        let chunkCount = chunks.count
        remainingChunks = []

        for (index, chunk) in chunks.enumerated() {
            let delay = Double(index) * 0.016  // 16ms stagger per chunk
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else {
                    // self gone — end interval on the last slot to avoid leaking
                    if index == chunkCount - 1 {
                        renderingSignposter.endInterval("chunk-inject", chunkInjectState)
                    }
                    return
                }
                self.webView.callAsyncJavaScript(
                    "window.appendChunk(html)",
                    arguments: ["html": chunk],
                    in: nil,
                    in: .page,
                    completionHandler: { _ in
                        // End signpost after last chunk injection completes
                        if index == chunkCount - 1 {
                            renderingSignposter.endInterval("chunk-inject", chunkInjectState)
                        }
                    }
                )
            }
        }
    }

    private var documentTitle: String = ""

    func printContent(title: String) {
        // WKWebView.printOperation is broken on macOS 26.
        // Workaround: createPDF → PDFPrintView → NSPrintOperation.
        capturePDF { data in
            guard let data = data else { return }
            let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
            printInfo.topMargin = 0
            printInfo.bottomMargin = 0
            printInfo.leftMargin = 0
            printInfo.rightMargin = 0

            guard let printView = PDFPrintView(pdfData: data, title: title, paperSize: printInfo.paperSize) else { return }
            let printOp = NSPrintOperation(view: printView, printInfo: printInfo)
            printOp.showsPrintPanel = true
            printOp.showsProgressPanel = true
            printOp.run()
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
            self?.capturePDF { data in
                guard let data = data else { return }
                let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
                printInfo.topMargin = 0
                printInfo.bottomMargin = 0
                printInfo.leftMargin = 0
                printInfo.rightMargin = 0
                printInfo.jobDisposition = .save
                printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

                guard let printView = PDFPrintView(pdfData: data, title: filename, paperSize: printInfo.paperSize) else { return }
                let printOp = NSPrintOperation(view: printView, printInfo: printInfo)
                printOp.showsPrintPanel = false
                printOp.showsProgressPanel = true
                printOp.run()

                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private func capturePDF(completion: @escaping (Data?) -> Void) {
        webView.createPDF(configuration: WKPDFConfiguration()) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let data):
                    completion(data)
                case .failure(let error):
                    let alert = NSAlert()
                    alert.messageText = "PDF Export Failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                    completion(nil)
                }
            }
        }
    }

    /// Load mermaid.min.js via script-src injection — WebKit loads directly from disk,
    /// bypassing the multi-megabyte IPC bridge call that evaluateJavaScript would require.
    private func loadAndInitMermaid() {
        let js = """
        (function() {
            var s = document.createElement('script');
            s.src = 'mermaid.min.js';
            s.onload = function() { window.initMermaid(); };
            s.onerror = function() {
                var els = document.querySelectorAll('.mermaid-placeholder');
                els.forEach(function(el) {
                    var pre = document.createElement('pre');
                    var code = document.createElement('code');
                    code.textContent = el.getAttribute('data-mermaid-source') || 'Mermaid failed to load';
                    pre.appendChild(code);
                    el.replaceWith(pre);
                });
            };
            document.head.appendChild(s);
        })()
        """
        webView.evaluateJavaScript(js)
    }
}
