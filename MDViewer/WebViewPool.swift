import Cocoa
import WebKit

/// Maintains a pool of pre-warmed WebContentView instances for instant file opens.
/// All access is main-thread-only (WKWebView requirement). No concurrency primitives needed.
final class WebViewPool {
    private var pool: [WebContentView] = []
    private let capacity: Int

    init(capacity: Int = 2) {
        self.capacity = capacity
        for _ in 0..<capacity {
            pool.append(createView())
        }
    }

    /// Returns a pre-warmed view, or nil if pool is empty.
    /// Automatically triggers async replenishment.
    func dequeue() -> WebContentView? {
        guard !pool.isEmpty else { return nil }
        let view = pool.removeFirst()
        view.setNavigationDelegate(nil) // Clear pool's crash monitor before handoff
        replenish()
        return view
    }

    /// Remove a crashed view from the pool and create a replacement.
    func discard(_ view: WebContentView) {
        pool.removeAll { $0 === view }
        replenish()
        #if DEBUG
        print("[WebViewPool] discarded crashed view - \(ObjectIdentifier(view))")
        #endif
    }

    // MARK: - Private

    private func replenish() {
        guard pool.count < capacity else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.pool.count < self.capacity else { return }
            self.pool.append(self.createView())
        }
    }

    private func createView() -> WebContentView {
        let view = WebContentView(frame: .zero)
        view.setNavigationDelegate(self)
        return view
    }

    deinit {
        #if DEBUG
        print("[WebViewPool] deinit - \(ObjectIdentifier(self))")
        #endif
    }
}

// MARK: - WKNavigationDelegate (crash detection for idle pooled views)

extension WebViewPool: WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // Find which pooled view owns this crashed webView and discard it
        guard let crashedView = pool.first(where: { pooledView in
            pooledView.ownsWebView(webView)
        }) else { return }
        discard(crashedView)
    }
}
