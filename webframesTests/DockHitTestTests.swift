import AppKit
import Testing
@testable import Web_Frames

/// The dock's buttons live inside glass pills. A click at a button's
/// center must reach that button: glass views that do not size their
/// content leave the buttons drawn outside their pill, where AppKit's
/// hit-testing never finds them.
@MainActor
@Suite("Dock hit-testing")
struct DockHitTestTests {

    private func buttons(in view: NSView) -> [NSView] {
        view.subviews.flatMap { ($0 is DockButton ? [$0] : []) + buttons(in: $0) }
    }

    @Test func everyDockButtonReceivesClicksAtItsCenter() {
        let dock = DockView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: true)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        window.contentView = host
        dock.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(dock)
        NSLayoutConstraint.activate([
            dock.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            dock.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        host.layoutSubtreeIfNeeded()

        let all = buttons(in: dock)
        #expect(all.count >= 7)
        for button in all {
            #expect(button.frame.width > 0 && button.frame.height > 0)
            let center = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
            let inHost = button.convert(center, to: host)
            let hit = host.hitTest(host.convert(inHost, to: host.superview))
            #expect(hit === button || hit?.isDescendant(of: button) == true,
                    "click at \(button.toolTip ?? "button") hit \(String(describing: hit))")
        }
    }

    /// In the real window the dock is a subview of the split view, not of
    /// the canvas host; the host's region check must still recognise it,
    /// otherwise the Hand-mode pan monitor swallows dock clicks.
    @Test func canvasHostRecognisesTheDockInsideTheDocumentWindow() {
        let document = makeTestDocument()
        let controller = DocumentWindowController(document: document)
        defer { controller.close() }
        guard let window = controller.window else { Issue.record("no window"); return }
        window.contentView?.layoutSubtreeIfNeeded()
        let host = controller.canvasHost
        let all = buttons(in: host.dock)
        #expect(!all.isEmpty)
        for button in all {
            let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: host)
            #expect(host.isDockRegion(center), "dock button \(button.toolTip ?? "") not recognised")
        }
        #expect(!host.isDockRegion(NSPoint(x: host.bounds.midX, y: host.bounds.maxY - 40)))
    }
}
