import AppKit
import UniformTypeIdentifiers

enum ViewMode: Int, CaseIterable {
    case editor = 1, split = 2, preview = 3
}

private enum Defaults {
    static let viewMode = "viewMode"
    static let fontSize = "editorFontSize"
    static let defaultFontSize: CGFloat = 13
}

private extension NSToolbarItem.Identifier {
    static let viewMode = Self("viewMode")
    static let scrollSync = Self("scrollSync")
    static let theme = Self("theme")
    static let exportPDF = Self("exportPDF")
}

/// One window (shown as a tab) per document: a plain-text editor and a rendered preview, each in a glass pane.
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate,
                                      NSSplitViewDelegate, NSMenuItemValidation, NSToolbarDelegate {
    private(set) var fileURL: URL?
    var onClose: ((DocumentWindowController) -> Void)?
    var onOpenMarkdown: ((URL) -> Void)?

    private let splitView = PaneSplitView()
    private let editorScroll = NSScrollView()
    private let textView = NSTextView(usingTextLayoutManager: false)
    private let preview = MarkdownPreview()
    private lazy var editorCard = GlassCard(content: editorScroll)
    private lazy var previewCard = GlassCard(content: preview.webView)
    private let highlighter = MarkdownHighlighter()

    private var watcher: FileWatcher?
    /// Contents of the file as last read from / written to disk.
    private var diskText = ""
    private var renderWork: DispatchWorkItem?
    private var reloadWork: DispatchWorkItem?
    private var isShowingConflict = false
    private var splitRatio: CGFloat = 0.5

    // Scroll sync state. Each side ignores scroll events briefly after being driven by the other.
    private var lineStarts: [Int] = [0]
    private var ignoreEditorScrollUntil = Date.distantPast
    private var ignorePreviewScrollUntil = Date.distantPast

    private weak var viewModeGroup: NSToolbarItemGroup?
    private weak var scrollSyncButton: NSButton?

    private var viewMode: ViewMode = ViewMode(rawValue: UserDefaults.standard.integer(forKey: Defaults.viewMode)) ?? .split {
        didSet { applyViewMode(from: oldValue) }
    }
    // Pane slide when switching view modes.
    private var modeTimer: Timer?
    private var finishModeTransition: (() -> Void)?
    private var isAnimatingMode: Bool { modeTimer != nil }

    private var fontSize: CGFloat {
        get {
            let v = UserDefaults.standard.double(forKey: Defaults.fontSize)
            return v > 0 ? CGFloat(v) : Defaults.defaultFontSize
        }
        set {
            UserDefaults.standard.set(Double(newValue), forKey: Defaults.fontSize)
            applyFontSize()
        }
    }

    var isDirty: Bool { textView.string != diskText }

    init(url: URL?, mode: ViewMode? = nil) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 520, height: 360)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "EasyMarkdownDocument"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self

        configureEditor()
        configureLayout()
        configureToolbar()
        configurePreview()

        if let url, let text = Self.read(url) {
            textView.string = text
            diskText = text
            setFileURL(url)
        } else {
            setFileURL(nil)
            preview.load(baseDirectory: FileManager.default.homeDirectoryForCurrentUser)
        }
        textView.undoManager?.removeAllActions()
        if let mode { viewMode = mode }
        textChanged()
        applyFontSize()
        applyViewMode()
        renderNow()

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: Settings.didChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Setup

    private func configureEditor() {
        let tv = textView
        tv.delegate = self
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 22, height: 22)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.layoutManager?.allowsNonContiguousLayout = true
        tv.defaultParagraphStyle = MarkdownHighlighter.paragraphStyle

        editorScroll.documentView = tv
        editorScroll.drawsBackground = false
        editorScroll.hasVerticalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.scrollerStyle = .overlay
        editorScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(editorDidScroll),
                                               name: NSView.boundsDidChangeNotification,
                                               object: editorScroll.contentView)
    }

    private func configureLayout() {
        guard let window else { return }
        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        window.contentView = background

        splitView.isVertical = true
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(editorCard)
        splitView.addArrangedSubview(previewCard)
        background.addSubview(splitView)

        let guide = window.contentLayoutGuide as! NSLayoutGuide
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: guide.topAnchor, constant: 4),
            splitView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            splitView.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            splitView.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -10),
        ])
        window.setFrameAutosaveName("EasyMarkdownDocument")
    }

    private func configureToolbar() {
        let toolbar = NSToolbar(identifier: "EasyMarkdownToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    private func configurePreview() {
        preview.onOpenMarkdown = { [weak self] in self?.onOpenMarkdown?($0) }
        preview.onScroll = { [weak self] in self?.previewDidScroll(toLine: $0) }
        preview.onThemeColors = { [weak self] in self?.apply(themeColors: $0) }
    }

    private func setFileURL(_ url: URL?) {
        fileURL = url
        watcher = nil
        if let url {
            window?.title = url.lastPathComponent
            window?.subtitle = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            window?.representedURL = url
            Settings.shared.noteRecent(url)
            preview.load(baseDirectory: url.deletingLastPathComponent())
            watcher = FileWatcher(url: url) { [weak self] in self?.scheduleReloadFromDisk() }
        } else {
            window?.title = "Untitled"
            window?.subtitle = ""
            window?.representedURL = nil
        }
        updateEditedState()
    }

    private func applyFontSize() {
        highlighter.fontSize = fontSize
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        highlightEditor()
        preview.webView.pageZoom = fontSize / Defaults.defaultFontSize
    }

    private func apply(themeColors colors: ThemeColors) {
        highlighter.colors = colors
        editorCard.fillColor = colors.background
        previewCard.fillColor = colors.background
        textView.insertionPointColor = colors.link
        textView.selectedTextAttributes = [.backgroundColor: colors.link.withAlphaComponent(0.25)]
        textView.typingAttributes[.foregroundColor] = colors.foreground
        highlightEditor()
    }

    private func applyViewMode(from old: ViewMode? = nil) {
        finishModeTransition?()
        if let old, old != viewMode, window?.isVisible == true, splitView.bounds.width > 0,
           !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            animateViewMode(from: old)
        } else {
            layoutViewMode()
        }
        viewModeGroup?.selectedIndex = viewMode.rawValue - 1
        let focus: NSView = viewMode == .preview ? preview.webView : textView
        window?.makeFirstResponder(focus)
    }

    /// Static layout for the current mode.
    private func layoutViewMode() {
        splitView.gutter = PaneSplitView.defaultGutter
        editorCard.isHidden = viewMode == .preview
        previewCard.isHidden = viewMode == .editor
        splitView.adjustSubviews()
        let total = splitView.bounds.width
        if viewMode == .split, total > 0 {
            splitView.setPosition(total * splitRatio, ofDividerAt: 0)
        }
        if viewMode == .split { syncPreviewToEditor() }
    }

    /// Slides the editor in/out from the left and the preview from the right by animating the
    /// divider. Panes that appear or disappear keep a fixed width so they slide instead of re-wrapping.
    private func animateViewMode(from old: ViewMode) {
        let total = splitView.bounds.width
        func geometry(_ mode: ViewMode) -> (position: CGFloat, gutter: CGFloat) {
            switch mode {
            case .editor: return (total, 0)
            case .preview: return (0, 0)
            case .split: return ((total * splitRatio).rounded(), PaneSplitView.defaultGutter)
            }
        }
        let start = geometry(old), end = geometry(viewMode)
        if old == .preview || viewMode == .preview {
            editorCard.beginSlide(pinnedTo: .trailing, width: max(start.position, end.position))
        }
        if old == .editor || viewMode == .editor {
            let width = max(total - start.position - start.gutter, total - end.position - end.gutter)
            previewCard.beginSlide(pinnedTo: .leading, width: width)
        }
        editorCard.isHidden = false
        previewCard.isHidden = false

        let splitView = splitView
        func apply(_ t: CGFloat) {
            splitView.gutter = start.gutter + (end.gutter - start.gutter) * t
            splitView.setPosition(start.position + (end.position - start.position) * t, ofDividerAt: 0)
        }
        let duration = 0.24
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            let p = min(1, (CACurrentMediaTime() - began) / duration)
            apply(1 - pow(1 - p, 3))  // ease-out cubic
            if p >= 1 { self?.finishModeTransition?() }
        }
        finishModeTransition = { [weak self] in
            guard let self else { return }
            self.modeTimer?.invalidate()
            self.modeTimer = nil
            self.finishModeTransition = nil
            self.editorCard.endSlide()
            self.previewCard.endSlide()
            self.layoutViewMode()
        }
        modeTimer = timer
        apply(0)
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func settingsChanged() {
        scrollSyncButton?.state = Settings.shared.scrollSync ? .on : .off
        if Settings.shared.scrollSync { syncPreviewToEditor() }
    }

    // MARK: Editing & rendering

    func textDidChange(_ notification: Notification) {
        textChanged()
        updateEditedState()
        renderWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.renderNow() }
        renderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func textChanged() {
        var starts = [0]
        var index = 0
        for unit in textView.string.utf16 {
            index += 1
            if unit == 10 { starts.append(index) }
        }
        lineStarts = starts
        highlightEditor()
    }

    private func highlightEditor() {
        // Restyling mid-composition would disturb input methods; the next change catches up.
        guard let storage = textView.textStorage, !textView.hasMarkedText() else { return }
        highlighter.highlight(storage)
    }

    private func renderNow() {
        preview.render(textView.string) { [weak self] in
            // Rendering changes the preview's height; keep it aligned with the editor.
            self?.syncPreviewToEditor()
        }
    }

    private func updateEditedState() {
        window?.isDocumentEdited = isDirty
    }

    // MARK: Scroll sync

    private var isSyncing: Bool { viewMode == .split && Settings.shared.scrollSync && !isAnimatingMode }

    @objc private func editorDidScroll() {
        guard Date() >= ignoreEditorScrollUntil else { return }
        syncPreviewToEditor()
    }

    private func syncPreviewToEditor() {
        guard isSyncing else { return }
        ignorePreviewScrollUntil = Date().addingTimeInterval(0.2)
        preview.scroll(toLine: editorTopLine())
    }

    private func previewDidScroll(toLine line: Double) {
        guard isSyncing, Date() >= ignorePreviewScrollUntil else { return }
        ignoreEditorScrollUntil = Date().addingTimeInterval(0.2)
        scrollEditor(toLine: line)
    }

    private func lineIndex(containing charIndex: Int) -> Int {
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= charIndex { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Rect (in text-container coordinates) covering every line fragment of a source line.
    private func rectForLine(_ line: Int) -> NSRect? {
        guard let lm = textView.layoutManager else { return nil }
        // textStorage.length avoids bridging (and copying) the whole document on every scroll.
        let length = textView.textStorage?.length ?? 0
        guard length > 0, line < lineStarts.count else { return nil }
        let start = min(lineStarts[line], length - 1)
        let nextStart = line + 1 < lineStarts.count ? lineStarts[line + 1] : length
        let end = max(start, min(nextStart - 1, length - 1))
        let first = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: start), effectiveRange: nil)
        let last = lm.lineFragmentRect(forGlyphAt: lm.glyphIndexForCharacter(at: end), effectiveRange: nil)
        return first.union(last)
    }

    /// Fractional 0-based source line at the top of the editor, or -1 when scrolled to the end.
    private func editorTopLine() -> Double {
        guard let lm = textView.layoutManager, let container = textView.textContainer else { return 0 }
        let visible = editorScroll.contentView.bounds
        if visible.minY > 0, visible.maxY >= textView.frame.height - 2 { return -1 }

        let y = visible.minY - textView.textContainerOrigin.y
        guard y > 0 else { return 0 }
        let glyph = lm.glyphIndex(for: NSPoint(x: 0, y: y), in: container)
        let line = lineIndex(containing: lm.characterIndexForGlyph(at: glyph))
        guard let rect = rectForLine(line), rect.height > 0 else { return Double(line) }
        return Double(line) + max(0, min(1, (y - rect.minY) / rect.height))
    }

    private func scrollEditor(toLine line: Double) {
        let clip = editorScroll.contentView
        let maxY = max(0, textView.frame.height - clip.bounds.height)
        var y: CGFloat
        if line < 0 {
            y = maxY
        } else {
            let index = min(Int(line), lineStarts.count - 1)
            guard let rect = rectForLine(index) else { return }
            y = rect.minY + CGFloat(line - Double(index)) * rect.height + textView.textContainerOrigin.y
        }
        y = min(max(0, y), maxY)
        clip.scroll(to: NSPoint(x: 0, y: y))
        editorScroll.reflectScrolledClipView(clip)
    }

    // MARK: Hot reload

    private func scheduleReloadFromDisk() {
        // Coalesce the burst of events an atomic save produces.
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reloadFromDisk() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func reloadFromDisk() {
        // A missing file is usually mid-rename; the next event will pick it up.
        guard let url = fileURL, let text = Self.read(url), text != diskText else { return }

        if text == textView.string {
            diskText = text
        } else if !isDirty {
            diskText = text
            replaceEditorText(with: text)
        } else {
            promptForConflict(diskText: text)
        }
        updateEditedState()
    }

    private func replaceEditorText(with text: String) {
        let selection = textView.selectedRange()
        let scrollOrigin = editorScroll.contentView.bounds.origin
        ignoreEditorScrollUntil = Date().addingTimeInterval(0.2)
        textView.string = text
        textView.undoManager?.removeAllActions()
        textChanged()
        let length = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        editorScroll.contentView.scroll(to: scrollOrigin)
        editorScroll.reflectScrolledClipView(editorScroll.contentView)
        renderNow()
    }

    private func promptForConflict(diskText newText: String) {
        guard let window, !isShowingConflict else { return }
        isShowingConflict = true
        let alert = NSAlert()
        alert.messageText = "\(fileURL?.lastPathComponent ?? "This file") changed on disk"
        alert.informativeText = "You also have unsaved edits here. Reload the version on disk and discard your edits?"
        alert.addButton(withTitle: "Reload from Disk")
        alert.addButton(withTitle: "Keep My Edits")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            self.isShowingConflict = false
            // Re-read in case the file changed again while the sheet was up.
            let latest = self.fileURL.flatMap(Self.read) ?? newText
            self.diskText = latest
            if response == .alertFirstButtonReturn {
                self.replaceEditorText(with: latest)
            }
            self.updateEditedState()
        }
    }

    // MARK: File I/O

    private static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    @discardableResult
    private func write(to url: URL) -> Bool {
        let text = textView.string
        do {
            // Write through symlinks so dotfile-managed notes stay linked.
            try Data(text.utf8).write(to: url.resolvingSymlinksInPath(), options: .atomic)
            diskText = text
            if url != fileURL { setFileURL(url) }
            updateEditedState()
            return true
        } catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
            return false
        }
    }

    private func runSavePanel(completion: @escaping (Bool) -> Void) {
        guard let window else { return completion(false) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "Untitled.md"
        if let dir = fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return completion(false) }
            completion(self.write(to: url))
        }
    }

    /// Saves, prompting for a location if untitled. Completion reports success.
    func save(completion: @escaping (Bool) -> Void = { _ in }) {
        if let url = fileURL {
            completion(write(to: url))
        } else {
            runSavePanel(completion: completion)
        }
    }

    // MARK: Actions (reached via the responder chain)

    @objc func saveDocument(_ sender: Any?) { save() }

    @objc func saveDocumentAs(_ sender: Any?) { runSavePanel { _ in } }

    @objc func exportPDF(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let base = fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        panel.nameFieldStringValue = base + ".pdf"
        if let dir = fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let output = panel.url, let self else { return }
            let baseDir = self.fileURL?.deletingLastPathComponent() ?? FileManager.default.homeDirectoryForCurrentUser
            PDFExporter.export(markdown: self.textView.string, baseDirectory: baseDir, to: output) { ok in
                if !ok { NSSound.beep() }
            }
        }
    }

    func setViewMode(_ mode: ViewMode) {
        viewMode = mode
    }

    /// Menu/keyboard changes are remembered as the default for new windows.
    private func chooseViewMode(_ mode: ViewMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: Defaults.viewMode)
        viewMode = mode
    }

    @objc func showEditorOnly(_ sender: Any?) { chooseViewMode(.editor) }
    @objc func showSplit(_ sender: Any?) { chooseViewMode(.split) }
    @objc func showPreviewOnly(_ sender: Any?) { chooseViewMode(.preview) }

    @objc private func viewModeGroupChanged(_ sender: NSToolbarItemGroup) {
        chooseViewMode(ViewMode(rawValue: sender.selectedIndex + 1) ?? .split)
    }

    @objc func increaseFontSize(_ sender: Any?) { fontSize = min(fontSize + 1, 32) }
    @objc func decreaseFontSize(_ sender: Any?) { fontSize = max(fontSize - 1, 9) }
    @objc func resetFontSize(_ sender: Any?) { fontSize = Defaults.defaultFontSize }

    @objc func revealInFinder(_ sender: Any?) {
        if let fileURL { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(showEditorOnly(_:)): item.state = viewMode == .editor ? .on : .off
        case #selector(showSplit(_:)): item.state = viewMode == .split ? .on : .off
        case #selector(showPreviewOnly(_:)): item.state = viewMode == .preview ? .on : .off
        case #selector(revealInFinder(_:)): return fileURL != nil
        default: break
        }
        return true
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .viewMode, .flexibleSpace, .scrollSync, .theme, .exportPDF]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func symbol(_ name: String, _ label: String) -> NSImage {
            NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
        }
        switch id {
        case .viewMode:
            let group = NSToolbarItemGroup(
                itemIdentifier: id,
                images: [symbol("square.and.pencil", "Editor"),
                         symbol("rectangle.split.2x1", "Editor and Preview"),
                         symbol("eye", "Preview")],
                selectionMode: .selectOne,
                labels: ["Editor", "Split", "Preview"],
                target: self, action: #selector(viewModeGroupChanged(_:)))
            group.label = "View"
            group.selectedIndex = viewMode.rawValue - 1
            group.subitems[0].toolTip = "Editor only (⌘1)"
            group.subitems[1].toolTip = "Editor and preview (⌘2)"
            group.subitems[2].toolTip = "Preview only (⌘3)"
            viewModeGroup = group
            return group

        case .scrollSync:
            let button = NSButton(image: symbol("arrow.up.and.down.text.horizontal", "Scroll Sync"),
                                  target: nil, action: #selector(AppDelegate.toggleScrollSync(_:)))
            button.setButtonType(.pushOnPushOff)
            button.bezelStyle = .texturedRounded
            button.state = Settings.shared.scrollSync ? .on : .off
            scrollSyncButton = button
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = button
            item.label = "Scroll Sync"
            item.toolTip = "Sync editor and preview scrolling"
            return item

        case .theme:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = symbol("paintpalette", "Theme")
            item.label = "Theme"
            item.toolTip = "Appearance, preview theme and code theme"
            item.showsIndicator = false
            item.menu = MainMenu.themeMenu()
            return item

        case .exportPDF:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = symbol("arrow.down.doc", "Export PDF")
            item.label = "Export PDF"
            item.toolTip = "Export as PDF (⇧⌘E)"
            item.action = #selector(exportPDF(_:))
            item.target = self
            item.isBordered = true
            return item

        default:
            return nil
        }
    }

    // MARK: NSSplitViewDelegate

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard viewMode == .split, !isAnimatingMode, splitView.bounds.width > 0 else { return }
        splitRatio = editorCard.frame.width / splitView.bounds.width
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        isAnimatingMode ? proposed : max(proposed, 220)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
        isAnimatingMode ? proposed : min(proposed, splitView.bounds.width - 220)
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(fileURL?.lastPathComponent ?? "Untitled")?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.save { ok in if ok { sender.close() } }
            case .alertThirdButtonReturn:
                self.diskText = self.textView.string
                sender.close()
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        watcher = nil
        NotificationCenter.default.removeObserver(self)
        onClose?(self)
    }
}
