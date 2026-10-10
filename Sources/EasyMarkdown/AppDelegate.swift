import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [DocumentWindowController] = []
    private var welcome: WelcomeWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        Settings.shared.applyAppearance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        // Files passed via `open -a` / Finder arrive through application(_:open:) around launch;
        // only show the welcome window if none did.
        DispatchQueue.main.async {
            if self.controllers.isEmpty { self.showWelcome(nil) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && controllers.isEmpty { showWelcome(nil) }
        return true
    }

    @objc func showWelcome(_ sender: Any?) {
        if welcome == nil {
            let controller = WelcomeWindowController()
            controller.onNew = { [weak self] in self?.newDocument(nil) }
            controller.onOpen = { [weak self] in self?.openDocument(nil) }
            controller.onOpenURL = { [weak self] in self?.open($0) }
            controller.onClose = { [weak self] in self?.welcome = nil }
            welcome = controller
        }
        welcome?.showWindow(nil)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL {
                open(url)
            } else if url.scheme == "easymarkdown" {
                openCommand(url)
            }
        }
    }

    /// `easymarkdown://open?path=/abs/file.md&mode=preview` — used by `easymd -p`, since
    /// `open --args` is ignored when the app is already running.
    private func openCommand(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        guard let path = query["path"], !path.isEmpty else { return }
        let mode: ViewMode? = switch query["mode"] {
        case "preview": .preview
        case "editor": .editor
        case "split": .split
        default: nil
        }
        open(URL(fileURLWithPath: path), mode: mode)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let dirty = controllers.filter(\.isDirty)
        guard !dirty.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = dirty.count == 1
            ? "\(dirty[0].fileURL?.lastPathComponent ?? "Untitled") has unsaved changes."
            : "\(dirty.count) documents have unsaved changes."
        alert.informativeText = "Quit anyway and discard them?"
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard and Quit")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    // MARK: Documents

    func open(_ url: URL) {
        open(url, mode: nil)
    }

    /// `host` is the window to add a new tab to; by default the frontmost document window.
    func open(_ url: URL, mode: ViewMode?, nextTo host: NSWindow? = nil) {
        let url = url.standardizedFileURL
        if let existing = controllers.first(where: { $0.fileURL?.standardizedFileURL == url }) {
            if let mode { existing.setViewMode(mode) }
            existing.showWindow(nil)
            return
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            NSAlert(error: CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])).runModal()
            return
        }
        show(DocumentWindowController(url: url, mode: mode), nextTo: host)
    }

    /// Documents open as a new tab next to `host` (by default the current tab of the frontmost
    /// document window), or in a window of their own when there is none (or `newWindow` is set).
    private func show(_ controller: DocumentWindowController, nextTo host: NSWindow? = nil, newWindow: Bool = false) {
        controller.onClose = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
        }
        // Links clicked and files dropped in a document open next to it, not in whichever window is in front.
        controller.onOpenMarkdown = { [weak self, weak controller] in
            self?.open($0, mode: nil, nextTo: controller?.window)
        }
        if let window = controller.window {
            if !newWindow, let host = host ?? frontmostDocumentWindow() {
                host.addTabbedWindow(window, ordered: .above)
            } else if let last = controllers.last?.window {
                window.setFrame(last.frame, display: false)
                window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
            }
        }
        controllers.append(controller)
        controller.showWindow(nil)
        welcome?.close()
    }

    /// The selected tab of the frontmost on-screen document window.
    private func frontmostDocumentWindow() -> NSWindow? {
        let documents = controllers.compactMap(\.window)
        return NSApp.orderedWindows.first { window in
            window.isVisible && !window.isMiniaturized && documents.contains(window)
        }
    }

    @objc func newDocument(_ sender: Any?) {
        show(DocumentWindowController(url: nil))
    }

    @objc func newDocumentWindow(_ sender: Any?) {
        show(DocumentWindowController(url: nil), newWindow: true)
    }

    /// The tab bar's + button.
    @objc func newWindowForTab(_ sender: Any?) {
        newDocument(sender)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["md", "markdown", "mdown", "mkd", "txt"].compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK {
            panel.urls.forEach(open)
        }
    }

    // MARK: Settings actions

    @objc func toggleScrollSync(_ sender: Any?) {
        Settings.shared.scrollSync.toggle()
    }

    @objc func setAppearance(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? String, let appearance = Settings.Appearance(rawValue: value) {
            Settings.shared.appearance = appearance
        }
    }

    @objc func setPreviewTheme(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { Settings.shared.previewTheme = id }
    }

    @objc func setCodeTheme(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { Settings.shared.codeTheme = id }
    }
}

extension AppDelegate: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let settings = Settings.shared
        let value = item.representedObject as? String
        switch item.action {
        case #selector(toggleScrollSync(_:)): item.state = settings.scrollSync ? .on : .off
        case #selector(setAppearance(_:)): item.state = value == settings.appearance.rawValue ? .on : .off
        case #selector(setPreviewTheme(_:)): item.state = value == settings.previewTheme ? .on : .off
        case #selector(setCodeTheme(_:)): item.state = value == settings.codeTheme ? .on : .off
        default: break
        }
        return true
    }
}
