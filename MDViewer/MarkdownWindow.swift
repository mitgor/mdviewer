import Cocoa
import QuartzCore

final class MarkdownWindow: NSWindow {
    private static let defaultSize = NSSize(width: 720, height: 900)
    private static let frameSaveKey = "MDViewerWindowFrame"

    let contentViewWrapper: WebContentView

    init(fileURL: URL, contentView: WebContentView) {
        self.contentViewWrapper = contentView

        let savedFrame = Self.loadSavedFrame()
        let frame = savedFrame ?? NSRect(
            origin: Self.cascadedOrigin(),
            size: Self.defaultSize
        )

        super.init(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        self.contentView = contentView
        self.title = fileURL.lastPathComponent
        self.titlebarAppearsTransparent = false
        self.isReleasedWhenClosed = false
        self.minSize = NSSize(width: 400, height: 300)
        self.setFrameAutosaveName(Self.frameSaveKey)

        self.alphaValue = 0

        configureHighRefreshRate()
    }

    func showWithFadeIn() {
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.animator().alphaValue = 1.0
        }
    }

    // MARK: - Private

    private static func cascadedOrigin() -> NSPoint {
        guard let screen = NSScreen.main else {
            return NSPoint(x: 100, y: 100)
        }
        let screenFrame = screen.visibleFrame
        return NSPoint(
            x: screenFrame.midX - defaultSize.width / 2,
            y: screenFrame.midY - defaultSize.height / 2
        )
    }

    private static func loadSavedFrame() -> NSRect? {
        return nil
    }

    private func configureHighRefreshRate() {
        contentView?.wantsLayer = true

        if let layer = contentView?.layer {
            layer.contentsScale = self.backingScaleFactor
        }
    }
}
