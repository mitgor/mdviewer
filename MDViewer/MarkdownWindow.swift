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

        // Start invisible — shown after first paint
        self.alphaValue = 0

        // Enable 120fps on ProMotion displays
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
        // Enable layer-backing for the content view to unlock ProMotion
        contentView?.wantsLayer = true

        if let layer = contentView?.layer {
            layer.contentsScale = self.backingScaleFactor
        }

        // Request maximum display refresh rate (120Hz on ProMotion)
        if #available(macOS 14.0, *) {
            setupDisplayLink()
        }
    }

    @available(macOS 14.0, *)
    private func setupDisplayLink() {
        let highRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.preferredFrameRateRange = highRange
        link.add(to: .main, forMode: .common)

        // The display link's existence signals the compositor to use high refresh rate.
        // Invalidate after the window is fully set up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            link.invalidate()
        }
    }

    @available(macOS 14.0, *)
    @objc private func displayLinkFired(_ link: CADisplayLink) {
        // No-op — presence of the display link drives ProMotion refresh rate
    }
}
