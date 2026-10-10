import AppKit
import WebKit

/// Markdown files dragged in from Finder or elsewhere.
enum MarkdownDrop {
    static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd", "txt"]

    static func urls(_ info: NSDraggingInfo) -> [URL] {
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (objects ?? []).filter { extensions.contains($0.pathExtension.lowercased()) }
    }

    static func hasFiles(_ info: NSDraggingInfo) -> Bool {
        info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }
}

/// Blurred "drop to open" panel shown while markdown files are dragged over a window.
///
/// Views underneath (window background, editor, preview) call `dragEntered` when a drag
/// arrives; the overlay then appears on top and becomes the drop target itself, so the drag can
/// move between the panes without the indicator flickering.
final class DropOverlay: NSView {
    var onDrop: (([URL]) -> Void)?

    private let opensTabs: Bool
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?
    private var escapeMonitor: Any?
    /// `draggingSequenceNumber` of the drag being shown, and of one cancelled with Esc.
    private var currentDrag: Int?
    private var cancelledDrag: Int?

    /// `opensTabs` only changes the wording: "open in a new tab" vs. plain "open".
    init(cornerRadius: CGFloat, opensTabs: Bool = true) {
        self.opensTabs = opensTabs
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        isHidden = true
        alphaValue = 0

        let blur = NSVisualEffectView()
        blur.material = .fullScreenUI
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = cornerRadius
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        GlassCard.pin(blur, in: self)
        GlassCard.pin(DashedBorder(cornerRadius: max(0, cornerRadius - 8)), in: self, inset: 8)

        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 40, weight: .light)
        icon.contentTintColor = .controlAccentColor
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle

        let stack = NSStackView(views: [icon, titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(12, after: icon)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Called by the views underneath
    // Each returns nil for drags that aren't markdown files, which the view handles as usual.

    /// Shows the overlay for markdown drags; [] if this drag was cancelled with Esc.
    func dragEntered(_ info: NSDraggingInfo) -> NSDragOperation? {
        let operation = dragUpdated(info)
        if operation == .copy { show(for: info) }
        return operation
    }

    func dragUpdated(_ info: NSDraggingInfo) -> NSDragOperation? {
        guard !MarkdownDrop.urls(info).isEmpty else { return nil }
        return info.draggingSequenceNumber == cancelledDrag ? [] : .copy
    }

    /// The overlay normally takes over the drag right after appearing, which looks like the
    /// view underneath losing it; only hide if it doesn't.
    func dragExited() {
        hide(after: 0.1)
    }

    /// Opens the dropped files; false if this drag was cancelled with Esc.
    func performDrop(_ info: NSDraggingInfo) -> Bool? {
        guard let operation = dragUpdated(info) else { return nil }
        hide()
        guard operation == .copy else { return false }
        onDrop?(MarkdownDrop.urls(info))
        return true
    }

    // MARK: Showing

    private func show(for info: NSDraggingInfo) {
        hideWork?.cancel()
        hideWork = nil
        currentDrag = info.draggingSequenceNumber
        let urls = MarkdownDrop.urls(info)
        titleLabel.stringValue = !opensTabs ? "Drop to open" : urls.count == 1 ? "Drop to open in a new tab" : "Drop to open in new tabs"
        detailLabel.stringValue = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        // When this app is active (e.g. dragging from a Finder window behind it), Esc reaches us
        // rather than the drag source, so treat it as cancelling: hide and refuse this drag.
        if escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53, let self else { return event }
                self.cancelledDrag = self.currentDrag
                self.hide()
                return nil
            }
        }
        guard isHidden || alphaValue < 1 else { return }
        registerForDraggedTypes([.fileURL])
        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            animator().alphaValue = 1
        }
    }

    private func hide(after delay: TimeInterval = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fadeOut() {
        hideWork = nil
        unregisterDraggedTypes()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Shown again mid-fade: stay visible.
            guard let self, self.hideWork == nil, self.alphaValue == 0 else { return }
            self.isHidden = true
        })
    }

    // MARK: NSDraggingDestination (while visible)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragEntered(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hide()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        hide()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        performDrop(sender) ?? false
    }

    /// Clicks never land here in practice (it's only visible mid-drag), but don't let any
    /// reach the panes underneath.
    override func mouseDown(with event: NSEvent) {}
}

private final class DashedBorder: NSView {
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
        path.fill()
        path.lineWidth = 2
        path.setLineDash([8, 6], count: 2, phase: 0)
        NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
        path.stroke()
    }
}

/// Window background that accepts dropped markdown files (via its overlay).
final class DropView: NSVisualEffectView {
    weak var dropOverlay: DropOverlay?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOverlay?.dragEntered(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOverlay?.dragUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropOverlay?.dragExited()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropOverlay?.performDrop(sender) ?? false
    }
}

/// The editor: dropped markdown files open as documents instead of inserting their paths.
/// Other drops (text, other files) keep the text view's behaviour.
final class EditorTextView: NSTextView {
    weak var dropOverlay: DropOverlay?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOverlay?.dragEntered(sender) ?? super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOverlay?.dragUpdated(sender) ?? super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropOverlay?.dragExited()
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropOverlay?.performDrop(sender) ?? super.performDragOperation(sender)
    }
}

/// The preview: dropped markdown files open as documents; other files are refused rather than
/// letting WebKit navigate the preview away to them.
final class PreviewWebView: WKWebView {
    weak var dropOverlay: DropOverlay?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard MarkdownDrop.hasFiles(sender) else { return super.draggingEntered(sender) }
        return dropOverlay?.dragEntered(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard MarkdownDrop.hasFiles(sender) else { return super.draggingUpdated(sender) }
        return dropOverlay?.dragUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropOverlay?.dragExited()
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard MarkdownDrop.hasFiles(sender) else { return super.performDragOperation(sender) }
        return dropOverlay?.performDrop(sender) ?? false
    }
}
