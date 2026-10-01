import AppKit

/// Lightweight transient notification: a small dark pill that fades in
/// near the top of a window, lingers, and fades out. Replaces NSAlert for
/// the "fyi, no action needed" cases (e.g. Cmd+S on an auto-saving doc).
final class ToastView: NSView {

    private let label = NSTextField(labelWithString: "")

    init(message: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.82).cgColor
        layer?.cornerRadius = WFDesign.Radius.medium
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        // UI test anchor — the toast is transient, so the identifier
        // makes it findable while it's on screen.
        setAccessibilityIdentifier("toast")

        label.stringValue = message
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor(white: 0.92, alpha: 1)
        label.translatesAutoresizingMaskIntoConstraints = false
        // Separate identifier on the label — XCUITest's staticTexts query
        // matches NSTextField elements, and the container's identifier on
        // its own isn't enough to find the text inside.
        label.setAccessibilityIdentifier("toastLabel")
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Pin a toast to the top-center of `host`, run the fade cycle, and
    /// remove it. If a previous toast is still showing in the same host,
    /// it's removed first so messages don't stack on top of each other.
    static func show(message: String, in host: NSView, duration: TimeInterval = 1.8) {
        for existing in host.subviews where existing is ToastView {
            existing.removeFromSuperview()
        }

        let toast = ToastView(message: message)
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.alphaValue = 0
        host.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            // Sits just below the titlebar strip — comfortably clear of
            // traffic-light buttons but still "near the top".
            toast.topAnchor.constraint(equalTo: host.topAnchor, constant: 56),
        ])

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            toast.animator().alphaValue = 1
        } completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                guard toast.superview != nil else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.22
                    toast.animator().alphaValue = 0
                } completionHandler: {
                    toast.removeFromSuperview()
                }
            }
        }
    }
}
