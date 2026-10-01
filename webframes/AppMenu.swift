import AppKit
import os

enum AppMenu {
    static func install() {
        let mainMenu = NSMenu()

        // App
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu(title: "Web Frames")
        appMenu.addItem(withTitle: "About Web Frames",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(MenuActions.openSettings(_:)), keyEquivalent: ",")
        settings.target = MenuActions.shared
        let updates = appMenu.addItem(withTitle: "Check for Updates…", action: #selector(AppUpdater.checkForUpdates(_:)), keyEquivalent: "")
        updates.target = AppUpdater.shared
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Web Frames",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All",
                        action: #selector(NSApplication.unhideAllApplications(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Web Frames",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu

        // File
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")

        fileMenu.addItem(withTitle: "New",
                         action: #selector(NSDocumentController.newDocument(_:)),
                         keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open…",
                         action: #selector(NSDocumentController.openDocument(_:)),
                         keyEquivalent: "o")
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = MenuActions.shared
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)

        fileMenu.addItem(.separator())

        // In-canvas "New Frame". ⌘T is AppKit's Show Fonts, so it lives on
        // ⇧⌘N next to New. Routed through the responder chain to the key
        // DocumentWindowController.
        let newFrame = NSMenuItem(title: "New Frame…",
                                  action: #selector(DocumentWindowController.newFrame(_:)),
                                  keyEquivalent: "n")
        newFrame.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(newFrame)

        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Reduce Image Sizes…",
                         action: #selector(DocumentWindowController.reduceImageSizes(_:)),
                         keyEquivalent: "")

        fileMenu.addItem(.separator())

        fileMenu.addItem(withTitle: "Close",
                         action: #selector(NSWindow.performClose(_:)),
                         keyEquivalent: "w")
        // Autosave is on; ⌘S stays wired so users get the "auto-save is on"
        // toast instead of silence.
        fileMenu.addItem(withTitle: "Save",
                         action: #selector(NSDocument.save(_:)),
                         keyEquivalent: "s")
        fileItem.submenu = fileMenu

        // Edit
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        // Undo/Redo are responder-chain selectors (`undo:` / `redo:`) that
        // aren't declared on any concrete Swift type we can reference via
        // `#selector`. `NSSelectorFromString` is the documented replacement
        // for the deprecated `Selector(String)` initializer.
        editMenu.addItem(withTitle: "Undo",
                         action: NSSelectorFromString("undo:"),
                         keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo",
                                    action: NSSelectorFromString("redo:"),
                                    keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut",   action: #selector(NSText.cut(_:)),   keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",  action: #selector(NSText.copy(_:)),  keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)),
                         keyEquivalent: "a")
        editItem.submenu = editMenu

        // View
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        // Canvas shortcuts are handled first by DocumentWindowController's
        // key monitor; these items make them discoverable and clickable.
        // Single-key equivalents are disabled while text or a web page has
        // focus (see validateMenuItem), so typing never triggers them.
        let canvasItems: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Zoom In", #selector(DocumentWindowController.zoomInCanvas(_:)), "=", .command),
            ("Zoom Out", #selector(DocumentWindowController.zoomOutCanvas(_:)), "-", .command),
            ("Zoom to Fit", #selector(DocumentWindowController.zoomCanvasToFit(_:)), "0", .command),
            ("Zoom to Selection", #selector(DocumentWindowController.zoomCanvasToSelection(_:)), "p", []),
        ]
        let toolItems: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Select", #selector(DocumentWindowController.selectCursorTool(_:)), "v", []),
            ("Hand", #selector(DocumentWindowController.selectHandTool(_:)), "h", []),
            ("Comment Mode", #selector(DocumentWindowController.toggleCommentMode(_:)), "c", []),
            ("Add Frame…", #selector(DocumentWindowController.newFrame(_:)), "f", []),
        ]
        let panelItems: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Show Sidebar", #selector(DocumentWindowController.toggleFramesSidebar(_:)), "s", [.command, .control]),
            ("Show Comments", #selector(DocumentWindowController.toggleCommentsPanel(_:)), "i", [.command, .control]),
        ]
        let modeItems: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Flow", #selector(DocumentWindowController.showFlowMode(_:)), "1", .command),
            ("Library", #selector(DocumentWindowController.showLibraryMode(_:)), "2", .command),
        ]
        for (index, group) in [canvasItems, toolItems, panelItems, modeItems].enumerated() {
            if index > 0 { viewMenu.addItem(.separator()) }
            for (title, action, key, mask) in group {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
                item.keyEquivalentModifierMask = mask
                viewMenu.addItem(item)
            }
        }
        viewMenu.addItem(.separator())
        let fs = NSMenuItem(title: "Enter Full Screen",
                            action: #selector(NSWindow.toggleFullScreen(_:)),
                            keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fs)
        viewItem.submenu = viewMenu

        // Arrange — Figma's align/distribute shortcuts, handled by the key
        // document window (DocumentWindowController.arrangeFrames).
        let arrangeItem = NSMenuItem()
        mainMenu.addItem(arrangeItem)
        let arrangeMenu = NSMenu(title: "Arrange")
        for (index, action) in FrameArrangement.allCases.enumerated() {
            if index == 3 || index == 6 { arrangeMenu.addItem(.separator()) }
            let item = NSMenuItem(title: action.rawValue,
                                  action: #selector(DocumentWindowController.arrangeFrames(_:)),
                                  keyEquivalent: action.keyEquivalent)
            item.keyEquivalentModifierMask = action.keyModifiers
            item.tag = index
            arrangeMenu.addItem(item)
        }
        arrangeMenu.addItem(.separator())
        for (index, move) in FrameStacking.allCases.enumerated() {
            let item = NSMenuItem(title: move.rawValue,
                                  action: #selector(DocumentWindowController.restackFrames(_:)),
                                  keyEquivalent: move.keyEquivalent)
            item.keyEquivalentModifierMask = move.keyModifiers
            item.tag = index
            arrangeMenu.addItem(item)
        }
        arrangeItem.submenu = arrangeMenu

        // Window
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize",
                           action: #selector(NSWindow.performMiniaturize(_:)),
                           keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom",
                           action: #selector(NSWindow.performZoom(_:)),
                           keyEquivalent: "")
        windowMenu.addItem(.separator())
        let projects = windowMenu.addItem(withTitle: "Projects",
                                          action: #selector(AppDelegate.showProjects(_:)),
                                          keyEquivalent: "p")
        projects.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front",
                           action: #selector(NSApplication.arrangeInFront(_:)),
                           keyEquivalent: "")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        // Help
        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        for (title, action) in [("Getting Started", #selector(MenuActions.openGettingStarted(_:))),
                                ("Keyboard Shortcuts", #selector(MenuActions.showKeyboardShortcuts(_:))),
                                ("Open Sample Project", #selector(MenuActions.openSampleProject(_:))),
                                ("Release Notes", #selector(MenuActions.openReleaseNotes(_:)))] {
            let item = helpMenu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = MenuActions.shared
        }
        helpItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = mainMenu
    }
}

final class MenuActions: NSObject, NSMenuDelegate {
    static let shared = MenuActions()

    static let siteURL = URL(string: "https://www.webframes.pro")!

    static var releaseNotesURL: URL {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        guard !version.isEmpty, !build.isEmpty,
              let url = URL(string: "https://www.webframes.pro/updates/WebFrames-\(version)-\(build).html") else {
            return siteURL
        }
        return url
    }

    /// Canvas shortcuts as shown in Help › Keyboard Shortcuts. Keep in sync
    /// with DocumentWindowController.handleCanvasShortcutKeyDown and the View menu.
    static let keyboardShortcuts: [(keys: String, action: String)] = [
        ("⇧⌘N or F", "Add frame"),
        ("V", "Select"),
        ("H or hold Space", "Hand (pan)"),
        ("C", "Comment mode"),
        ("⌘= / ⌘-", "Zoom in / out"),
        ("⌘0", "Zoom to fit"),
        ("P", "Zoom to selected frame"),
        ("⌘A", "Select all frames"),
        ("⌫", "Delete selection"),
        ("⌃⌘S", "Show or hide sidebar"),
        ("⌃⌘I", "Show or hide comments"),
        ("⌘1 / ⌘2", "Flow / Library"),
        ("⌥A / ⌥H / ⌥D", "Align left / horizontal centers / right"),
        ("⌥W / ⌥V / ⌥S", "Align top / vertical centers / bottom"),
        ("⌃⌥H / ⌃⌥V", "Distribute horizontally / vertically"),
        ("⌘] / ⌘[", "Bring forward / send backward"),
        ("⌥⌘] / ⌥⌘[", "Bring to front / send to back"),
        ("⌘V", "Paste images as frames"),
    ]

    @objc func openSettings(_ sender: Any?) {
        AppSettingsWindowController.shared.present()
    }

    @objc func openGettingStarted(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://www.webframes.pro/#workflow")!)
    }

    /// Opens the sample in the key project, or in a new project when only
    /// the Start window is up.
    @objc func openSampleProject(_ sender: Any?) {
        if let controller = (NSApp.keyWindow ?? NSApp.mainWindow)?.windowController as? DocumentWindowController {
            controller.openSampleProject(sender)
            return
        }
        do {
            let document = try NSDocumentController.shared.openUntitledDocumentAndDisplay(false)
            document.makeWindowControllers()
            guard let controller = document.windowControllers.first as? DocumentWindowController else { return }
            controller.showWindow(nil)
            controller.openSampleProject(sender)
        } catch {
            NSApp.presentError(error)
        }
    }

    @objc func openReleaseNotes(_ sender: Any?) {
        NSWorkspace.shared.open(Self.releaseNotesURL)
    }

    @objc func showKeyboardShortcuts(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Keyboard Shortcuts"
        alert.informativeText = Self.keyboardShortcuts
            .map { "\($0.keys)\t\($0.action)" }
            .joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: Open Recent

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        for url in urls {
            let item = menu.addItem(withTitle: url.deletingPathExtension().lastPathComponent,
                                    action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        let clear = menu.addItem(withTitle: "Clear Menu",
                                 action: urls.isEmpty ? nil : #selector(NSDocumentController.clearRecentDocuments(_:)),
                                 keyEquivalent: "")
        clear.isEnabled = !urls.isEmpty
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSApp.presentError(error) }
        }
    }
}
