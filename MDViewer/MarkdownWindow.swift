import Cocoa
import QuartzCore

final class MarkdownWindow: NSWindow {
    private static let defaultSize = NSSize(width: 720, height: 900)
    private static var lastCascadePoint: NSPoint = .zero

    let contentViewWrapper: WebContentView

    init(fileURL: URL, contentView: WebContentView) {
        self.contentViewWrapper = contentView

        // Start with a centered frame; autosave may override below
        let centeredFrame: NSRect
        if let screen = NSScreen.main {
            let visibleFrame = screen.visibleFrame
            centeredFrame = NSRect(
                x: visibleFrame.midX - Self.defaultSize.width / 2,
                y: visibleFrame.midY - Self.defaultSize.height / 2,
                width: Self.defaultSize.width,
                height: Self.defaultSize.height
            )
        } else {
            centeredFrame = NSRect(origin: NSPoint(x: 100, y: 100), size: Self.defaultSize)
        }

        super.init(
            contentRect: centeredFrame,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        self.contentView = contentView
        self.title = fileURL.lastPathComponent
        self.titlebarAppearsTransparent = false
        self.isReleasedWhenClosed = false
        self.minSize = NSSize(width: 400, height: 300)
        self.alphaValue = 0

        // Per-file frame persistence: AppKit restores saved frame automatically
        let frameBeforeAutosave = self.frame
        self.setFrameAutosaveName(Self.autosaveName(for: fileURL))
        let autosaveRestoredFrame = (self.frame != frameBeforeAutosave)

        // Only cascade if no saved position was restored
        if !autosaveRestoredFrame {
            Self.lastCascadePoint = self.cascadeTopLeft(from: Self.lastCascadePoint)
        }

        configureHighRefreshRate()
    }

    deinit {
        #if DEBUG
        print("[MarkdownWindow] deinit - \(ObjectIdentifier(self))")
        #endif
    }

    func showWithFadeIn() {
        makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.animator().alphaValue = 1.0
        }
    }

    // MARK: - Private

    private static func autosaveName(for fileURL: URL) -> NSWindow.FrameAutosaveName {
        let path = fileURL.standardizedFileURL.path
        return "MDViewer:\(path)"
    }

    private func configureHighRefreshRate() {
        contentView?.wantsLayer = true

        if let layer = contentView?.layer {
            layer.contentsScale = self.backingScaleFactor
        }
    }
}
