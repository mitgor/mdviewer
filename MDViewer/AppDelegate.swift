import Cocoa
import os
import UniformTypeIdentifiers
import WebKit
import cmark_gfm

private let appSignposter = OSSignposter(
    subsystem: "com.mdviewer.app",
    category: "RenderingPipeline"
)

class AppDelegate: NSObject, NSApplicationDelegate, WebContentViewDelegate, NativeContentViewDelegate {
    private let renderer = MarkdownRenderer()
    private var template: SplitTemplate?
    private var windows: [MarkdownWindow] = []
    private var openedViaDelegate = false
    private var openToPaintStates: [ObjectIdentifier: OSSignpostIntervalState] = [:]
    private var hasCompletedFirstLaunchPaint = false
    private var pendingFileOpens = 0
    private let webViewPool = WebViewPool(capacity: 2)

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadTemplate()
        setupMenu()
        NativeRenderer.registerFonts()

        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.openedViaDelegate else { return }
            let args = ProcessInfo.processInfo.arguments
            if args.count > 1 {
                let url = URL(fileURLWithPath: args[1])
                self.openFile(url)
            }
        }

        // End launch signpost if no file is opened within 5 seconds (prevents infinite interval)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self, !self.hasCompletedFirstLaunchPaint else { return }
            self.hasCompletedFirstLaunchPaint = true
            launchSignposter.endInterval("launch-to-paint", launchSignpostState)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Pool drains automatically when AppDelegate is deallocated
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // During test hosting, don't terminate when no windows are open.
        if NSClassFromString("XCTestCase") != nil { return false }
        // Don't terminate while files are being rendered on background threads
        if pendingFileOpens > 0 { return false }
        return true
    }

    // MARK: - File Opening

    func application(_ sender: NSApplication, open urls: [URL]) {
        openedViaDelegate = true
        ensureTemplateLoaded()
        for url in urls {
            openFile(url)
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        openedViaDelegate = true
        ensureTemplateLoaded()
        let url = URL(fileURLWithPath: filename)
        openFile(url)
        return true
    }

    // MARK: - Menu Actions

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType("net.daringfireball.markdown"),
            UTType(filenameExtension: "md"),
            UTType(filenameExtension: "markdown"),
            UTType.plainText
        ].compactMap { $0 }
        panel.allowsMultipleSelection = true

        pendingFileOpens += 1 // Prevent termination while panel is open
        panel.begin { [weak self] response in
            guard let self = self else { return }
            self.pendingFileOpens -= 1
            guard response == .OK else { return }
            for url in panel.urls {
                self.openFile(url)
            }
        }
    }

    @objc func toggleMonospace(_ sender: Any?) {
        guard let window = NSApp.keyWindow as? MarkdownWindow else { return }
        if let webView = window.webContentView {
            webView.toggleMonospace()
        } else if let nativeView = window.nativeContentView {
            nativeView.toggleMonospace()
        }
    }

    @objc func printDocument(_ sender: Any?) {
        guard let window = NSApp.keyWindow as? MarkdownWindow else { return }
        if let webView = window.webContentView {
            webView.printContent(title: window.title)
        } else if let nativeView = window.nativeContentView {
            nativeView.printContent(title: window.title)
        }
    }

    @objc func exportPDF(_ sender: Any?) {
        guard let window = NSApp.keyWindow as? MarkdownWindow else { return }
        if let webView = window.webContentView {
            webView.exportPDF(filename: window.title)
        } else {
            // PDF export not available in native path
            let alert = NSAlert()
            alert.messageText = "PDF Export Unavailable"
            alert.informativeText = "PDF export requires the web rendering path. Use View > Toggle Native/Web Rendering first."
            alert.alertStyle = .informational
            alert.runModal()
        }
    }

    @objc func toggleRenderingMode(_ sender: Any?) {
        guard let window = NSApp.keyWindow as? MarkdownWindow else { return }
        let url = window.fileURL
        let forceNative = !window.isNativeRendering
        window.close()
        openFileForced(url, forceNative: forceNative)
    }

    // MARK: - WebContentViewDelegate

    func webContentViewDidFinishFirstPaint(_ view: WebContentView) {
        if !hasCompletedFirstLaunchPaint {
            hasCompletedFirstLaunchPaint = true
            launchSignposter.endInterval("launch-to-paint", launchSignpostState)
        }

        if let paintState = openToPaintStates.removeValue(forKey: ObjectIdentifier(view)) {
            appSignposter.endInterval("open-to-paint", paintState)
        }
        if let window = windows.first(where: { $0.contentViewWrapper === view }) {
            window.showWithFadeIn()
        }
    }

    // MARK: - NativeContentViewDelegate

    func nativeContentViewDidFinishFirstPaint(_ view: NativeContentView) {
        if !hasCompletedFirstLaunchPaint {
            hasCompletedFirstLaunchPaint = true
            launchSignposter.endInterval("launch-to-paint", launchSignpostState)
        }

        if let paintState = openToPaintStates.removeValue(forKey: ObjectIdentifier(view)) {
            appSignposter.endInterval("open-to-paint", paintState)
        }
        if let window = windows.first(where: { $0.contentViewWrapper === view }) {
            window.showWithFadeIn()
        }
    }

    // MARK: - Private

    private func ensureTemplateLoaded() {
        guard template == nil else { return }
        loadTemplate()
    }

    private func loadTemplate() {
        guard template == nil else { return }
        guard let templateURL = Bundle.main.url(forResource: "template", withExtension: "html") else {
            fatalError("template.html not found in bundle")
        }
        let html = (try? String(contentsOf: templateURL, encoding: .utf8)) ?? ""
        template = SplitTemplate(templateHTML: html)
    }

    private func openFile(_ url: URL) {
        openFileForced(url, forceNative: nil)
    }

    /// Open a file with optional forced rendering mode.
    /// - forceNative: nil = auto-detect, true = force native, false = force web
    private func openFileForced(_ url: URL, forceNative: Bool?) {
        guard let tmpl = template else { return }
        let paintState = appSignposter.beginInterval("open-to-paint")
        pendingFileOpens += 1

        let renderer = self.renderer

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let spID = renderingSignposter.makeSignpostID()

            // Read file
            let readState = renderingSignposter.beginInterval("file-read", id: spID)
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
                  let markdown = String(data: data, encoding: .utf8) else {
                renderingSignposter.endInterval("file-read", readState)
                DispatchQueue.main.async { [weak self] in
                    self?.pendingFileOpens -= 1
                    appSignposter.endInterval("open-to-paint", paintState)
                    let alert = NSAlert()
                    alert.messageText = "Cannot Open File"
                    alert.informativeText = "The file \(url.lastPathComponent) could not be read."
                    alert.alertStyle = .warning
                    alert.runModal()
                }
                return
            }
            renderingSignposter.endInterval("file-read", readState)

            // Determine rendering path
            let useNative: Bool
            var detectedRoot: UnsafeMutablePointer<cmark_node>? = nil
            if let forced = forceNative {
                useNative = forced
            } else {
                // Auto-detect: parse AST and scan for tables/mermaid
                guard let root = renderer.parseMarkdown(markdown) else {
                    DispatchQueue.main.async { [weak self] in
                        self?.pendingFileOpens -= 1
                        appSignposter.endInterval("open-to-paint", paintState)
                    }
                    return
                }
                useNative = renderer.canRenderNatively(root: root)
                if useNative {
                    // Retain root for native rendering -- avoid double parse
                    detectedRoot = root
                } else {
                    cmark_node_free(root)
                }
            }

            if useNative {
                // Native rendering path (NATV-01)
                // Reuse AST from auto-detect when available, otherwise parse fresh
                let root: UnsafeMutablePointer<cmark_node>
                if let existing = detectedRoot {
                    root = existing
                } else {
                    guard let parsed = renderer.parseMarkdown(markdown) else {
                        DispatchQueue.main.async { [weak self] in
                            self?.pendingFileOpens -= 1
                            appSignposter.endInterval("open-to-paint", paintState)
                        }
                        return
                    }
                    root = parsed
                }
                let nativeRenderer = NativeRenderer()
                let nativeResult = nativeRenderer.render(root: root)
                cmark_node_free(root)

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.pendingFileOpens -= 1
                    let contentView = NativeContentView(frame: .zero)
                    contentView.delegate = self
                    self.openToPaintStates[ObjectIdentifier(contentView)] = paintState

                    let window = MarkdownWindow(fileURL: url, contentView: contentView, isNative: true)
                    self.windows.append(window)
                    self.observeWindowClose(window)

                    contentView.loadContent(attributedString: nativeResult.attributedString)
                    // showWithFadeIn called from nativeContentViewDidFinishFirstPaint
                }
            } else {
                // Web rendering path (existing streaming behavior)
                var streamContentView: WebContentView?

                renderer.renderStreaming(markdown: markdown, template: tmpl,
                    onFirstChunk: { page in
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            let contentView = self.webViewPool.dequeue() ?? WebContentView(frame: .zero)
                            contentView.delegate = self
                            contentView.setNavigationDelegate(self)
                            self.openToPaintStates[ObjectIdentifier(contentView)] = paintState
                            streamContentView = contentView

                            contentView.loadContent(page: page, remainingChunks: [], hasMermaid: false)

                            let window = MarkdownWindow(fileURL: url, contentView: contentView, isNative: false)
                            self.windows.append(window)
                            self.observeWindowClose(window)

                            window.makeKeyAndOrderFront(nil)
                            window.alphaValue = 1.0
                        }
                    },
                    onComplete: { remainingChunks, hasMermaid in
                        DispatchQueue.main.async { [weak self] in
                            self?.pendingFileOpens -= 1
                            streamContentView?.setRemainingChunks(remainingChunks, hasMermaid: hasMermaid)
                        }
                    }
                )
            }
        }
    }

    private func observeWindowClose(_ window: MarkdownWindow) {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            guard let closedWindow = notification.object as? MarkdownWindow else { return }
            self?.windows.removeAll { $0 === closedWindow }
        }
    }

    private func setupMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About MDViewer", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MDViewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open...", action: #selector(openDocument(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Export as PDF...", action: #selector(exportPDF(_:)), keyEquivalent: "e")
        fileMenu.addItem(withTitle: "Print...", action: #selector(printDocument(_:)), keyEquivalent: "p")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Monospace", action: #selector(toggleMonospace(_:)), keyEquivalent: "m")
        viewMenu.addItem(withTitle: "Toggle Native/Web Rendering", action: #selector(toggleRenderingMode(_:)), keyEquivalent: "N")
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        NSApp.mainMenu = mainMenu
    }
}

// MARK: - WKNavigationDelegate (crash detection for active views)

extension AppDelegate: WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let window = windows.first(where: { ($0.contentViewWrapper as? WebContentView)?.ownsWebView(webView) == true }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rendering Process Crashed"
        alert.informativeText = "The web content process for \"\(window.title)\" terminated unexpectedly. The window will be closed."
        alert.alertStyle = .critical
        alert.runModal()
        window.close()
    }
}
