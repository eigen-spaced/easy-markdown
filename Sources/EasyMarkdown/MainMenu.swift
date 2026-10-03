import AppKit

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "EasyMarkdown")
        menu.addItem(item("About EasyMarkdown", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Hide EasyMarkdown", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit EasyMarkdown", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New Tab", #selector(AppDelegate.newDocument(_:)), "n"))
        menu.addItem(item("New Window", #selector(AppDelegate.newDocumentWindow(_:)), "n", [.command, .option]))
        menu.addItem(item("Open…", #selector(AppDelegate.openDocument(_:)), "o"))
        menu.addItem(item("Welcome Window", #selector(AppDelegate.showWelcome(_:)), "0", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item("Save", #selector(DocumentWindowController.saveDocument(_:)), "s"))
        menu.addItem(item("Save As…", #selector(DocumentWindowController.saveDocumentAs(_:)), "s", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Export as PDF…", #selector(DocumentWindowController.exportPDF(_:)), "e", [.command, .shift]))
        menu.addItem(item("Reveal in Finder", #selector(DocumentWindowController.revealInFinder(_:)), "r", [.command, .shift]))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSTextView.pasteAsPlainText(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())

        let find = NSMenu(title: "Find")
        let action = #selector(NSTextView.performFindPanelAction(_:))
        find.addItem(item("Find…", action, "f", tag: Int(NSFindPanelAction.showFindPanel.rawValue)))
        find.addItem(item("Find and Replace…", action, "f", [.command, .option], tag: Int(NSFindPanelAction.replace.rawValue)))
        find.addItem(item("Find Next", action, "g", tag: Int(NSFindPanelAction.next.rawValue)))
        find.addItem(item("Find Previous", action, "g", [.command, .shift], tag: Int(NSFindPanelAction.previous.rawValue)))
        find.addItem(item("Use Selection for Find", action, "e", tag: Int(NSFindPanelAction.setFindString.rawValue)))
        menu.addItem(submenu(find))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Editor Only", #selector(DocumentWindowController.showEditorOnly(_:)), "1"))
        menu.addItem(item("Editor and Preview", #selector(DocumentWindowController.showSplit(_:)), "2"))
        menu.addItem(item("Preview Only", #selector(DocumentWindowController.showPreviewOnly(_:)), "3"))
        menu.addItem(.separator())
        menu.addItem(item("Sync Scrolling", #selector(AppDelegate.toggleScrollSync(_:)), "l", [.command, .option]))
        menu.addItem(.separator())
        for sub in themeMenu().items { menu.addItem(sub.copy() as! NSMenuItem) }
        menu.addItem(.separator())
        menu.addItem(item("Bigger", #selector(DocumentWindowController.increaseFontSize(_:)), "+"))
        menu.addItem(item("Smaller", #selector(DocumentWindowController.decreaseFontSize(_:)), "-"))
        menu.addItem(item("Actual Size", #selector(DocumentWindowController.resetFontSize(_:)), "0"))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    /// Appearance / Preview Theme / Code Theme submenus, shared by the View menu and toolbar.
    static func themeMenu() -> NSMenu {
        let menu = NSMenu(title: "Theme")
        func choices(_ title: String, _ options: [(id: String, title: String)], _ action: Selector) -> NSMenuItem {
            let sub = NSMenu(title: title)
            for option in options {
                let entry = NSMenuItem(title: option.title, action: action, keyEquivalent: "")
                entry.representedObject = option.id
                sub.addItem(entry)
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = sub
            return item
        }
        menu.addItem(choices("Appearance", Settings.Appearance.allCases.map { ($0.rawValue, $0.title) },
                             #selector(AppDelegate.setAppearance(_:))))
        menu.addItem(choices("Preview Theme", Settings.previewThemes, #selector(AppDelegate.setPreviewTheme(_:))))
        menu.addItem(choices("Code Theme", Settings.codeThemes, #selector(AppDelegate.setCodeTheme(_:))))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }
}
