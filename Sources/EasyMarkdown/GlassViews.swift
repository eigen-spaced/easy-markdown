import AppKit

/// A rounded pane with a thin Liquid Glass rim (macOS 26+) or a vibrancy rim on older systems.
final class GlassCard: NSView {
    private let inner = NSView()
    private var rim: NSView!
    private var rimLeading: NSLayoutConstraint!
    private var rimTrailing: NSLayoutConstraint!
    private var slideWidth: NSLayoutConstraint?

    /// Pane background; drawn slightly translucent so the glass reads through.
    var fillColor: NSColor = .textBackgroundColor {
        didSet { updateColors() }
    }

    init(content: NSView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        inner.wantsLayer = true
        inner.layer?.cornerRadius = 12
        inner.layer?.cornerCurve = .continuous
        inner.layer?.masksToBounds = true
        inner.layer?.borderWidth = 1
        Self.pin(content, in: inner)

        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 17
            let holder = NSView()
            Self.pin(inner, in: holder, inset: 5)
            glass.contentView = holder
            rim = glass
        } else {
            let fx = NSVisualEffectView()
            fx.material = .hudWindow
            fx.blendingMode = .behindWindow
            fx.state = .followsWindowActiveState
            fx.wantsLayer = true
            fx.layer?.cornerRadius = 17
            fx.layer?.cornerCurve = .continuous
            fx.layer?.masksToBounds = true
            fx.layer?.borderWidth = 1
            fx.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
            Self.pin(inner, in: fx, inset: 5)
            rim = fx
        }
        rim.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rim)
        rimLeading = rim.leadingAnchor.constraint(equalTo: leadingAnchor)
        rimTrailing = rim.trailingAnchor.constraint(equalTo: trailingAnchor)
        NSLayoutConstraint.activate([
            rimLeading, rimTrailing,
            rim.topAnchor.constraint(equalTo: topAnchor),
            rim.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateColors()
    }

    /// While the card's width animates, keep the contents at a fixed width pinned to one edge
    /// and clip the rest, so the pane slides rather than squashing and re-wrapping.
    func beginSlide(pinnedTo edge: NSLayoutConstraint.Attribute, width: CGFloat) {
        endSlide()
        wantsLayer = true
        layer?.masksToBounds = true
        (edge == .leading ? rimTrailing : rimLeading).isActive = false
        slideWidth = rim.widthAnchor.constraint(equalToConstant: width)
        slideWidth?.isActive = true
    }

    func endSlide() {
        guard let slideWidth else { return }
        slideWidth.isActive = false
        self.slideWidth = nil
        rimLeading.isActive = true
        rimTrailing.isActive = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            inner.layer?.backgroundColor = fillColor.withAlphaComponent(0.92).cgColor
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            inner.layer?.borderColor = (isDark ? NSColor.white.withAlphaComponent(0.08)
                                               : NSColor.black.withAlphaComponent(0.07)).cgColor
        }
    }

    static func pin(_ view: NSView, in container: NSView, inset: CGFloat = 0) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -inset),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -inset),
        ])
    }
}

/// Split view with a transparent gutter and a small grabber pill instead of a hard divider.
final class PaneSplitView: NSSplitView {
    static let defaultGutter: CGFloat = 8
    /// Animated down to 0 when a pane slides away so the remaining one ends flush.
    var gutter = defaultGutter
    override var dividerThickness: CGFloat { gutter }

    override func drawDivider(in rect: NSRect) {
        let pill = NSRect(x: rect.midX - 1.5, y: rect.midY - 14, width: 3, height: 28)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 1.5, yRadius: 1.5).fill()
    }
}
