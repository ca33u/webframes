import AppKit
import os

/// Let AppKit read NSPrincipalClass and create its single application instance.
@main
enum WebFramesApp {
    static func main() {
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}

/// A normal launch goes through the project picker. Explicit Finder opens
/// still use NSDocumentController; old window-restoration records are ignored.
@objc(WebFramesApplication)
final class WebFramesApplication: NSApplication {
    // NSApplication.delegate is weak. Keep the lifecycle owner alive here.
    private let lifecycleDelegate = AppDelegate()

    override func finishLaunching() {
        setActivationPolicy(.regular)
        appearance = WFTheme.dark
        delegate = lifecycleDelegate
        Log.window.info("Launcher v4 — application=\(NSStringFromClass(type(of: self)), privacy: .public)")
        super.finishLaunching()
        WFTheme.enforceApplication()
    }

    override func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier,
                                state: NSCoder,
                                completionHandler: @escaping (NSWindow?, Error?) -> Void) -> Bool {
        Log.window.info("Launcher v4 — skipped automatic window restoration")
        completionHandler(nil, nil)
        return true
    }
}
