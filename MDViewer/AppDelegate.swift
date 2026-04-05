import Cocoa
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate, WebContentViewDelegate {
    private let renderer = MarkdownRenderer()
    private var template: SplitTemplate?
    private var windows: [MarkdownWindow] = []
    private var openedViaDelegate = false

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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
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
            UTType(filenameExtension: "md"),
            UTType(filenameExtension: "markdown")
        ].compactMap { $0 }
        panel.allowsMultipleSelection = true

        panel.begin { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls {
                self?.openFile(url)
            }
        }
    }

    @objc func toggleMonospace(_ sender: Any?) {
        guard let window = NSApp.keyWindow as? MarkdownWindow else { return }
        window.contentViewWrapper.toggleMonospace()
    }

    // MARK: - WebContentViewDelegate

    func webContentViewDidFinishFirstPaint(_ view: WebContentView) {
        if let window = windows.first(where: { $0.contentViewWrapper === view }) {
            window.showWithFadeIn()
        }
    }

    // MARK: - Private

    private func ensureTemplateLoaded() {
        if template == nil {
            loadTemplate()
            setupMenu()
        }
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

        // Parse markdown on background thread — keeps UI responsive for large files
        let renderer = self.renderer
        DispatchQueue.global(qos: .userInitiated).async {
            guard let result = renderer.renderFullPage(fileURL: url, template: tmpl) else {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Cannot Open File"
                    alert.informativeText = "The file \(url.lastPathComponent) could not be read."
                    alert.alertStyle = .warning
                    alert.runModal()
                }
                return
            }

            DispatchQueue.main.async { [weak self] in
                self?.displayResult(result, for: url)
            }
        }
    }

    private func displayResult(_ result: RenderResult, for url: URL) {
        let contentView = WebContentView(frame: .zero)
        contentView.delegate = self

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
