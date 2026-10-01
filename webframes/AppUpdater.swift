import AppKit
import Sparkle

/// One updater for all project windows. Development builds never replace themselves.
@MainActor
final class AppUpdater: NSObject, NSMenuItemValidation {
    static let shared = AppUpdater()
    private var controller: SPUStandardUpdaterController?

    func start() {
        #if !DEBUG
        guard controller == nil, Self.isConfigured else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        #endif
    }

    private static var isConfigured: Bool {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return false }
        return true
    }

    @objc func checkForUpdates(_ sender: Any?) {
        if let controller {
            controller.checkForUpdates(sender)
            return
        }
        let alert = NSAlert()
        #if DEBUG
        alert.messageText = "Development build"
        alert.informativeText = "Automatic updates are available in the release version of Web Frames. This build is updated through Xcode."
        #else
        alert.messageText = "Updates are not configured"
        alert.informativeText = "This build does not include a valid update configuration. Download the latest release from webframes.pro."
        #endif
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        controller?.updater.canCheckForUpdates ?? true
    }
}
