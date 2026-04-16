import Cocoa
import os
import UniformTypeIdentifiers
import WebKit

private let appSignposter = OSSignposter(
    subsystem: "com.mdviewer.app",
    category: "RenderingPipeline"
)

class AppDelegate: NSObject, NSApplicationDelegate, WebContentViewDelegate {
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
        window.contentViewWrapper.toggleMonospace()
    }

    @objc func printDocument(_ sender: Any?) {
        guard let window = NSApp.keyWindow as? MarkdownWindow else { return }
        window.contentViewWrapper.printContent(title: window.title)
    }

    @objc func exportPDF(_ sender: Any?) {
        guard let window = NSApp.keyWindow as? MarkdownWindow else { return }
        window.contentViewWrapper.exportPDF(filename: window.title)
    }

    // MARK: - WebContentViewDelegate

    func webContentViewDidFinishFirstPaint(_ view: WebContentView) {
        // End the launch-to-paint interval on the very first paint event
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
        guard let tmpl = template else { return }
        let paintState = appSignposter.beginInterval("open-to-paint")
        pendingFileOpens += 1

        // Parse markdown on background thread — keeps UI responsive for large files
        let renderer = self.renderer
        DispatchQueue.global(qos: .userInitiated).async {
            guard let result = renderer.renderFullPage(fileURL: url, template: tmpl) else {
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

            DispatchQueue.main.async { [weak self] in
                self?.pendingFileOpens -= 1
                self?.displayResult(result, for: url, paintState: paintState)
            }
        }
    }

    private func displayResult(_ result: RenderResult, for url: URL, paintState: OSSignpostIntervalState) {
        let contentView = webViewPool.dequeue() ?? WebContentView(frame: .zero)
        contentView.delegate = self
        contentView.setNavigationDelegate(self) // Monitor active web-process crashes
        openToPaintStates[ObjectIdentifier(contentView)] = paintState

        let window = MarkdownWindow(fileURL: url, contentView: contentView)
        windows.append(window)

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] notification in
            guard let closedWindow = notification.object as? MarkdownWindow else { return }
            self?.windows.removeAll { $0 === closedWindow }
        }

        contentView.loadContent(
            page: result.page,
            remainingChunks: result.remainingChunks,
            hasMermaid: result.hasMermaid
        )
        window.makeKeyAndOrderFront(nil)
        window.alphaValue = 1.0
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
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        NSApp.mainMenu = mainMenu
    }
}

// MARK: - WKNavigationDelegate (crash detection for active views)

extension AppDelegate: WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let window = windows.first(where: { $0.contentViewWrapper.ownsWebView(webView) }) else { return }
        let alert = NSAlert()
        alert.messageText = "Rendering Process Crashed"
        alert.informativeText = "The web content process for \"\(window.title)\" terminated unexpectedly. The window will be closed."
        alert.alertStyle = .critical
        alert.runModal()
        window.close()
    }
}
