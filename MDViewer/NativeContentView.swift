import Cocoa
import os

/// Delegate protocol for NativeContentView paint completion.
/// Mirrors WebContentViewDelegate for consistent window lifecycle.
protocol NativeContentViewDelegate: AnyObject {
    func nativeContentViewDidFinishFirstPaint(_ view: NativeContentView)
}

final class NativeContentView: NSView {

    // MARK: - Properties

    weak var delegate: NativeContentViewDelegate?

    private let scrollView: NSScrollView
    private let textView: NSTextView
    private var isMonospace = false
    private var cachedAttributedString: NSAttributedString?

    // MARK: - Content Width

    /// Fixed content width matching template.html max-width: 680px
    private static let contentWidth: CGFloat = 680

    // MARK: - Init

    override init(frame: NSRect) {
        scrollView = NSScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white

        let textContainer = NSTextContainer(
            size: NSSize(width: NativeContentView.contentWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = false // fixed width for consistent line length

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.backgroundColor = .white
        textView.textContainerInset = NSSize(width: 0, height: 40) // vertical padding
        // Allow automatic link detection by NSTextView
        textView.isAutomaticLinkDetectionEnabled = false // links come from .link attribute

        super.init(frame: frame)

        scrollView.documentView = textView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    // MARK: - Content Loading

    /// Set the attributed string content and fire the first-paint delegate.
    /// Native rendering is synchronous -- paint fires immediately.
    func loadContent(attributedString: NSAttributedString) {
        self.cachedAttributedString = attributedString
        textView.textStorage?.setAttributedString(attributedString)
        // Center the text container in the scroll view
        updateTextContainerInset()
        // Native rendering is synchronous -- fire paint immediately
        delegate?.nativeContentViewDidFinishFirstPaint(self)
    }

    // MARK: - Monospace Toggle

    /// Toggle monospace display. Placeholder for Plan 02 integration --
    /// the cachedAttributedString is stored so re-rendering can happen
    /// when the toggle is connected to NativeRenderer.
    func toggleMonospace() {
        // Monospace re-rendering not yet implemented for native path (Plan 02).
        // Show informational alert so the user knows the action had no effect.
        let alert = NSAlert()
        alert.messageText = "Monospace Toggle Unavailable"
        alert.informativeText = "Monospace toggle is not yet supported in native rendering mode."
        alert.alertStyle = .informational
        alert.runModal()
    }

    // MARK: - Print Support

    /// Print the text view content directly (simpler than WKWebView workaround).
    func printContent(title: String) {
        guard let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo else { return }
        let printOp = NSPrintOperation(view: textView, printInfo: printInfo)
        printOp.showsPrintPanel = true
        printOp.showsProgressPanel = true
        printOp.run()
    }

    // MARK: - Layout

    /// Center the 680px text container within the scroll view by adjusting
    /// the horizontal textContainerInset based on view width.
    override func layout() {
        super.layout()
        updateTextContainerInset()
    }

    private func updateTextContainerInset() {
        let viewWidth = bounds.width
        let hInset = max(20, (viewWidth - NativeContentView.contentWidth) / 2)
        textView.textContainerInset = NSSize(width: hInset, height: 40)
    }

    // MARK: - Lifecycle

    deinit {
        #if DEBUG
        print("[NativeContentView] deinit - \(ObjectIdentifier(self))")
        #endif
    }
}
