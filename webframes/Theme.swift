import AppKit

/// Web Frames intentionally ships with one application theme. Page content
/// inside web frames keeps its own colors; this only controls native chrome.
@MainActor
enum WFTheme {
    static let dark = NSAppearance(named: .darkAqua)!

    static func enforceApplication() {
        NSApp.appearance = dark
        for window in NSApp.windows { apply(to: window) }
    }

    static func apply(to window: NSWindow) {
        window.appearance = dark
        window.contentViewController?.view.appearance = dark
        window.contentView?.appearance = dark
    }
}

/// Native glass surface for the dock, frame toolbars and modal cards.
///
/// macOS 26 and later: a real Liquid Glass `NSGlassEffectView` (tint and
/// corner radius passed through). macOS 15: a dark, nearly opaque surface
/// with a hairline border, since Liquid Glass is not available there.
/// Callers only use `contentView`, `cornerRadius` and `tintColor`, so the
/// backing view can differ per OS.
final class WFGlassEffectView: NSView {
    private var hostedContentView: NSView?
    /// NSGlassEffectView on macOS 26+, an NSVisualEffectView before.
    private let surface: NSView

    var cornerRadius: CGFloat = 0 { didSet { applySurface() } }
    var tintColor: NSColor? { didSet { applySurface() } }

    var contentView: NSView? {
        get { hostedContentView }
        set {
            hostedContentView?.removeFromSuperview()
            hostedContentView = newValue
            guard let newValue else {
                if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView { glass.contentView = nil }
                return
            }
            if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
                // The glass view sizes and positions its own content view.
                glass.contentView = newValue
                return
            }
            newValue.translatesAutoresizingMaskIntoConstraints = false
            surface.addSubview(newValue)
            NSLayoutConstraint.activate([
                newValue.topAnchor.constraint(equalTo: surface.topAnchor),
                newValue.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
                newValue.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
                newValue.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            ])
        }
    }

    override init(frame frameRect: NSRect) {
        if #available(macOS 26.0, *) {
            surface = NSGlassEffectView()
        } else {
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .withinWindow
            effect.state = .active
            surface = effect
        }
        super.init(frame: frameRect)
        appearance = WFTheme.dark
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        applySurface()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func applySurface() {
        if #available(macOS 26.0, *), let glass = surface as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            glass.tintColor = tintColor
            return
        }
        surface.wantsLayer = true
        surface.layer?.cornerRadius = cornerRadius
        surface.layer?.masksToBounds = true
        surface.layer?.backgroundColor = (tintColor ?? WFDesign.bg2.withAlphaComponent(0.96)).cgColor
        surface.layer?.borderColor = WFDesign.border2.cgColor
        surface.layer?.borderWidth = 1
    }
}

/// Groups glass pills. On macOS 26+ this is an `NSGlassEffectContainerView`,
/// so neighbouring pills sample the background together and render as one
/// glass layer; before that it is a plain host without its own look.
final class WFGlassEffectContainerView: NSView {
    var spacing: CGFloat = 0 {
        didSet {
            if #available(macOS 26.0, *), let glass = host as? NSGlassEffectContainerView { glass.spacing = spacing }
        }
    }
    private var hostedContentView: NSView?
    private let host: NSView

    var contentView: NSView? {
        get { hostedContentView }
        set {
            hostedContentView?.removeFromSuperview()
            hostedContentView = newValue
            if #available(macOS 26.0, *), let glass = host as? NSGlassEffectContainerView {
                glass.contentView = newValue
                return
            }
            guard let newValue else { return }
            newValue.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(newValue)
            NSLayoutConstraint.activate([
                newValue.topAnchor.constraint(equalTo: host.topAnchor),
                newValue.bottomAnchor.constraint(equalTo: host.bottomAnchor),
                newValue.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                newValue.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            ])
        }
    }

    override init(frame frameRect: NSRect) {
        if #available(macOS 26.0, *) {
            host = NSGlassEffectContainerView()
        } else {
            host = NSView()
        }
        super.init(frame: frameRect)
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
