import AppKit

/// Overlay that shows an image from the preview over the whole window. Pinch or double-click
/// to zoom, scroll or drag to pan; Esc, Space or a click outside the image closes it.
final class ImageViewer: NSView {
    var onClose: (() -> Void)?

    private let scrollView = NSScrollView()
    private let canvas: ImageCanvas
    private weak var previousResponder: NSResponder?
    /// While true the image refits when the window resizes; zooming in clears it.
    private var isFitted = true
    private var isDismissing = false

    /// Loads a file, `data:` or http(s) image. Completion runs on the main queue.
    static func loadImage(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        guard url.scheme == "http" || url.scheme == "https" else {
            return completion(NSImage(contentsOf: url))
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let image = data.flatMap(NSImage.init(data:))
            DispatchQueue.main.async { completion(image) }
        }.resume()
    }

    init(image: NSImage) {
        canvas = ImageCanvas(image: image)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // A dark backdrop, like Quick Look, suits any image regardless of the preview theme.
        appearance = NSAppearance(named: .darkAqua)

        let backdrop = NSVisualEffectView()
        backdrop.material = .fullScreenUI
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        GlassCard.pin(backdrop, in: self)

        let clip = CenteringClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.allowsMagnification = true
        scrollView.documentView = canvas
        GlassCard.pin(scrollView, in: self)

        canvas.onDoubleClick = { [weak self] in self?.toggleZoom(at: $0) }
        NotificationCenter.default.addObserver(self, selector: #selector(didMagnify),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present(in window: NSWindow) {
        guard let content = window.contentView else { return }
        previousResponder = window.firstResponder
        content.addSubview(self)
        let guide = window.contentLayoutGuide as! NSLayoutGuide
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: guide.topAnchor),
            leadingAnchor.constraint(equalTo: content.leadingAnchor),
            trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        fit()
        window.makeFirstResponder(self)
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        guard !isDismissing else { return }
        isDismissing = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            animator().alphaValue = 0
        }, completionHandler: { [self] in
            let window = window
            removeFromSuperview()
            if let previousResponder { window?.makeFirstResponder(previousResponder) }
            onClose?()
        })
    }

    // MARK: Zoom

    /// Magnification that fits the whole image in view, never enlarging it past actual size.
    private var fitMagnification: CGFloat {
        let size = canvas.frame.size
        let available = scrollView.bounds.insetBy(dx: 24, dy: 24).size
        guard size.width > 0, size.height > 0, available.width > 0, available.height > 0 else { return 1 }
        return min(1, available.width / size.width, available.height / size.height)
    }

    private func fit() {
        let fit = fitMagnification
        scrollView.minMagnification = fit
        scrollView.maxMagnification = max(8, fit * 8)
        scrollView.magnification = fit
        isFitted = true
    }

    /// Double-click: zoom in around the click (to actual size, or 2× for small images), or back out.
    private func toggleZoom(at point: NSPoint) {
        let fit = fitMagnification
        let zoomedIn = scrollView.magnification > fit + 0.01
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            if zoomedIn {
                scrollView.animator().magnification = fit
            } else {
                scrollView.animator().setMagnification(max(1, fit * 2), centeredAt: point)
            }
        }
        isFitted = zoomedIn
    }

    @objc private func didMagnify() {
        isFitted = scrollView.magnification <= fitMagnification + 0.01
    }

    override func layout() {
        super.layout()
        if isFitted, !isDismissing { fit() }
    }

    // MARK: Events

    override var acceptsFirstResponder: Bool { true }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { dismiss() } else { super.keyDown(with: event) }
    }

    /// Clicks that reach here missed the image (the canvas handles its own).
    override func mouseDown(with event: NSEvent) { dismiss() }
}

/// Keeps the document centred when it is smaller than the visible area.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let document = documentView?.frame else { return rect }
        if rect.width > document.width { rect.origin.x = (document.width - rect.width) / 2 }
        if rect.height > document.height { rect.origin.y = (document.height - rect.height) / 2 }
        return rect
    }
}

/// The image at its natural size; the scroll view's magnification does the zooming.
private final class ImageCanvas: NSImageView {
    var onDoubleClick: ((NSPoint) -> Void)?

    init(image: NSImage) {
        super.init(frame: NSRect(origin: .zero, size: image.size))
        self.image = image
        imageScaling = .scaleAxesIndependently
        isEditable = false
        animates = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .openHand)
    }

    /// Drag to pan.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?(convert(event.locationInWindow, from: nil))
            return
        }
        guard let scrollView = enclosingScrollView, let window else { return }
        let clip = scrollView.contentView
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        var last = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            let scale = scrollView.magnification
            var bounds = clip.bounds
            bounds.origin.x -= (next.locationInWindow.x - last.x) / scale
            bounds.origin.y -= (next.locationInWindow.y - last.y) / scale
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            scrollView.reflectScrolledClipView(clip)
            last = next.locationInWindow
        }
    }
}
