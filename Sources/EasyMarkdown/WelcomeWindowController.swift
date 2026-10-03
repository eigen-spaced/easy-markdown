import AppKit
import UniformTypeIdentifiers

/// Shown when the app is launched without a file: New / Open buttons plus recent files.
/// Markdown files can also be dropped onto it.
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    var onNew: (() -> Void)?
    var onOpen: (() -> Void)?
    var onOpenURL: ((URL) -> Void)?
    var onClose: (() -> Void)?

    private let recentStack = NSStackView()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.title = "Welcome to EasyMarkdown"
        super.init(window: window)
        window.delegate = self
        buildContent()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func showWindow(_ sender: Any?) {
        reloadRecents()
        super.showWindow(sender)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    // MARK: Layout

    private func buildContent() {
        guard let window else { return }
        let background = DropView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        background.onDrop = { [weak self] urls in urls.forEach { self?.onOpenURL?($0) } }
        window.contentView = background

        // Left: identity and actions.
        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 44, weight: .light)
        icon.contentTintColor = .controlAccentColor

        let title = NSTextField(labelWithString: "EasyMarkdown")
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let subtitle = NSTextField(labelWithString: "Version \(version ?? "1.0")")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor

        let newButton = Self.actionButton("New File", symbol: "square.and.pencil",
                                          target: self, action: #selector(newFile))
        let openButton = Self.actionButton("Open…", symbol: "folder",
                                           target: self, action: #selector(openFile))
        let hint = NSTextField(labelWithString: "or drop a markdown file here")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let buttons = NSStackView(views: [newButton, openButton])
        buttons.orientation = .vertical
        buttons.spacing = 10
        buttons.alignment = .leading
        newButton.widthAnchor.constraint(equalToConstant: 180).isActive = true
        openButton.widthAnchor.constraint(equalTo: newButton.widthAnchor).isActive = true

        let left = NSStackView(views: [icon, title, subtitle, buttons, hint])
        left.orientation = .vertical
        left.alignment = .centerX
        left.spacing = 6
        left.setCustomSpacing(14, after: icon)
        left.setCustomSpacing(28, after: subtitle)
        left.setCustomSpacing(12, after: buttons)
        left.translatesAutoresizingMaskIntoConstraints = false

        // Right: recent files inside a glass pane.
        let recentTitle = NSTextField(labelWithString: "Recent")
        recentTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        recentTitle.textColor = .secondaryLabelColor

        recentStack.orientation = .vertical
        recentStack.alignment = .leading
        recentStack.spacing = 2
        let recentColumn = NSStackView(views: [recentTitle, recentStack])
        recentColumn.orientation = .vertical
        recentColumn.alignment = .leading
        recentColumn.spacing = 8
        recentColumn.edgeInsets = NSEdgeInsets(top: 16, left: 10, bottom: 12, right: 10)
        recentStack.leadingAnchor.constraint(equalTo: recentColumn.leadingAnchor, constant: 10).isActive = true
        recentStack.trailingAnchor.constraint(equalTo: recentColumn.trailingAnchor, constant: -10).isActive = true

        let recentHolder = NSView()
        recentColumn.translatesAutoresizingMaskIntoConstraints = false
        recentHolder.addSubview(recentColumn)
        NSLayoutConstraint.activate([
            recentColumn.topAnchor.constraint(equalTo: recentHolder.topAnchor),
            recentColumn.leadingAnchor.constraint(equalTo: recentHolder.leadingAnchor),
            recentColumn.trailingAnchor.constraint(equalTo: recentHolder.trailingAnchor),
            recentColumn.bottomAnchor.constraint(lessThanOrEqualTo: recentHolder.bottomAnchor),
        ])
        recentTitle.leadingAnchor.constraint(equalTo: recentColumn.leadingAnchor, constant: 20).isActive = true
        let card = GlassCard(content: recentHolder)

        background.addSubview(left)
        background.addSubview(card)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 24),
            left.widthAnchor.constraint(equalToConstant: 240),
            left.centerYAnchor.constraint(equalTo: background.centerYAnchor, constant: 6),
            card.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: 20),
            card.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: background.topAnchor, constant: 34),
            card.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -12),
        ])
    }

    private static func actionButton(_ title: String, symbol: String,
                                     target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!,
                              target: target, action: action)
        button.imagePosition = .imageLeading
        button.controlSize = .large
        if #available(macOS 26.0, *) {
            button.bezelStyle = .glass
        } else {
            button.bezelStyle = .rounded
        }
        return button
    }

    private func reloadRecents() {
        recentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let urls = Settings.shared.recentFiles
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .prefix(7)
        if urls.isEmpty {
            let empty = NSTextField(labelWithString: "No recent files")
            empty.textColor = .tertiaryLabelColor
            recentStack.addArrangedSubview(empty)
            empty.leadingAnchor.constraint(equalTo: recentStack.leadingAnchor, constant: 10).isActive = true
            return
        }
        for url in urls {
            let row = RecentRow(url: url) { [weak self] in self?.onOpenURL?(url) }
            recentStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: recentStack.widthAnchor).isActive = true
        }
    }

    @objc private func newFile() { onNew?() }
    @objc private func openFile() { onOpen?() }
}

/// A clickable recent-file row: icon, name, and the folder it lives in.
private final class RecentRow: NSView {
    private let action: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }

    init(url: URL, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        toolTip = url.path

        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
        icon.imageScaling = .scaleProportionallyUpOrDown
        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        let folder = NSTextField(labelWithString: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
        folder.font = .systemFont(ofSize: 11)
        folder.textColor = .secondaryLabelColor
        folder.lineBreakMode = .byTruncatingHead
        for label in [name, folder] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let text = NSStackView(views: [name, folder])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [icon, text])
        row.spacing = 10
        GlassCard.pin(row, in: self, inset: 6)
        row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10).isActive = true
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        guard hovering else { return }
        NSColor.labelColor.withAlphaComponent(0.07).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        hovering = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Window background that accepts dropped markdown files.
private final class DropView: NSVisualEffectView {
    var onDrop: (([URL]) -> Void)?
    private static let extensions: Set<String> = ["md", "markdown", "mdown", "mkd", "txt"]

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (objects ?? []).filter { Self.extensions.contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let found = urls(sender)
        guard !found.isEmpty else { return false }
        onDrop?(found)
        return true
    }
}
