import AppKit
import os

/// Owns the project picker independently of NSDocument's asynchronous teardown.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var startWindow: StartWindowController?
    private var isTerminating = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        WFTheme.enforceApplication()
        // AppKit documents that the first NSDocumentController created during
        // applicationWillFinishLaunching becomes the shared controller. We
        // need that exact hook to distinguish an explicit Open from macOS
        // reopening the document that was visible in the previous session.
        _ = WebFramesDocumentController()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        WFTheme.enforceApplication()
        AppUpdater.shared.start()
        EvidenceStore.migrateAndClean()
        CodexConnectionStore.shared.restoreManagedConnection()
        AppMenu.install()
        NotificationCenter.default.addObserver(self, selector: #selector(documentWindowDidOpen),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(documentWindowWillClose),
                                               name: NSWindow.willCloseNotification, object: nil)
        Log.window.info("Launcher v4 — launch finished")
        showStartWindowIfNeeded()
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        for document in NSDocumentController.shared.documents {
            for controller in document.windowControllers {
                (controller as? DocumentWindowController)?.shutDown()
            }
        }
        CodexConnectorProcess.shared.stop()
    }

    /// Window › Projects: the project list, also while projects are open,
    /// so another project can be opened in its own window.
    @objc func showProjects(_ sender: Any?) {
        if startWindow == nil { startWindow = StartWindowController() }
        startWindow?.showWindow(nil)
        startWindow?.window?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showStartWindowIfNeeded() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { [weak self] _, _, error in
                if let error {
                    self?.showStartWindowIfNeeded()
                    NSApp.presentError(error)
                }
            }
        }
    }

    private func isProjectWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == "webframes.project"
    }

    private func showStartWindowIfNeeded(excluding closingWindow: NSWindow? = nil) {
        guard !isTerminating else { return }
        // A closing document can still be in NSDocumentController.documents.
        // Conversely a minimized project is still open and must not create a picker.
        let hasOpenProject = NSApp.windows.contains {
            $0 !== closingWindow && isProjectWindow($0) && ($0.isVisible || $0.isMiniaturized)
        }
        guard !hasOpenProject else { return }
        Log.window.info("Launcher v4 — showing project picker")
        if startWindow == nil { startWindow = StartWindowController() }
        startWindow?.showWindow(nil)
        startWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func documentWindowDidOpen(_ note: Notification) {
        guard let window = note.object as? NSWindow, isProjectWindow(window) else { return }
        WFTheme.apply(to: window)
        startWindow?.window?.orderOut(nil)
    }

    @objc private func documentWindowWillClose(_ note: Notification) {
        Log.window.info("Launcher v4 — window close notification")
        // Identify the window itself: its weak delegate/controller may already
        // be detached while AppKit tears the document down.
        guard let window = note.object as? NSWindow, isProjectWindow(window) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.showStartWindowIfNeeded(excluding: window)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if NSApp.windows.contains(where: { $0.identifier?.rawValue == "webframes.appSettings" && $0.isVisible }) { return }
        if startWindow?.window?.isVisible != true { showStartWindowIfNeeded() }
    }
}

/// Reject session restoration while preserving explicit opens from the
/// project picker, Finder, and File > Open.
@MainActor
final class WebFramesDocumentController: NSDocumentController {
    /// A `.webframes` item is always a Web Frames project, whether it is a
    /// package (format 2) or a single file (1.0.1). Launch Services can still
    /// hold 1.0.1's declaration of the type as plain data, and then reports a
    /// package as "public.folder", which no document class opens.
    override func typeForContents(of url: URL) throws -> String {
        if url.pathExtension.lowercased() == WebFramesDocument.fileExtension {
            return WebFramesDocument.fileTypeIdentifier
        }
        return try super.typeForContents(of: url)
    }

    override func reopenDocument(for urlOrNil: URL?,
                                 withContentsOf contentsURL: URL,
                                 display displayDocument: Bool,
                                 completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        Log.window.info("Launcher v4 — skipped automatic document reopen")
        completionHandler(nil, false, nil)
    }
}
