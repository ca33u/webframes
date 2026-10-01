import AppKit
import Network
import os
import UniformTypeIdentifiers

// MARK: - ImageTabPanel

final class ImageTabPanel: NSView, AddFrameTabPanel {

    var view: NSView { self }

    private let dropView = ImageDropView()
    private let previewStack = NSStackView()
    private let previewWrap = NSView()
    private let labelField = NSTextField()

    private struct Pending { let name: String; let image: NSImage; let dataURL: String; let natW: Int; let natH: Int }
    private var pending: [Pending] = []

    private let onValidityChange: () -> Void

    init(onValidityChange: @escaping () -> Void) {
        self.onValidityChange = onValidityChange
        super.init(frame: .zero)
        build()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func pasteImage() -> Bool { dropView.handlePaste() }

    private func build() {
        dropView.onFiles = { [weak self] urls in self?.addFilesFromURLs(urls) }
        dropView.onClick = { [weak self] in self?.openFilePicker() }
        dropView.onPaste = { [weak self] image, suggestedName in self?.addImage(image, name: suggestedName) }
        dropView.translatesAutoresizingMaskIntoConstraints = false

        previewStack.orientation = .horizontal
        previewStack.spacing = 8
        previewStack.alignment = .centerY
        previewStack.translatesAutoresizingMaskIntoConstraints = false
        previewWrap.translatesAutoresizingMaskIntoConstraints = false
        previewWrap.isHidden = true
        let previewLabel = makeFieldLabel("Selected images")
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        let previewVert = NSStackView(views: [previewLabel, previewStack])
        previewVert.orientation = .vertical
        previewVert.alignment = .leading
        previewVert.spacing = 4
        previewVert.translatesAutoresizingMaskIntoConstraints = false
        previewWrap.addSubview(previewVert)
        NSLayoutConstraint.activate([
            previewVert.topAnchor.constraint(equalTo: previewWrap.topAnchor),
            previewVert.bottomAnchor.constraint(equalTo: previewWrap.bottomAnchor),
            previewVert.leadingAnchor.constraint(equalTo: previewWrap.leadingAnchor),
            previewVert.trailingAnchor.constraint(equalTo: previewWrap.trailingAnchor),
        ])

        labelField.placeholderString = "Frame name"
        labelField.font = .systemFont(ofSize: 13)
        labelField.translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView(views: [dropView, previewWrap, makeFieldLabel("Frame name (optional)"), labelField])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            dropView.leadingAnchor.constraint(equalTo: leadingAnchor),
            dropView.trailingAnchor.constraint(equalTo: trailingAnchor),
            dropView.heightAnchor.constraint(equalToConstant: 160),
            previewWrap.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewWrap.trailingAnchor.constraint(equalTo: trailingAnchor),
            labelField.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelField.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image, .png, .jpeg, .svg, .webP]
        if let win = window {
            panel.beginSheetModal(for: win) { [weak self] resp in
                guard resp == .OK, let self else { return }
                self.addFilesFromURLs(panel.urls)
            }
        } else if panel.runModal() == .OK {
            addFilesFromURLs(panel.urls)
        }
    }

    private func addFilesFromURLs(_ urls: [URL]) {
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let img = NSImage(data: data) else { continue }
            let mime = Self.mime(for: url)
            let stored = ImageOptimizer.optimize(data, mime: mime)
            let dataURL = "data:\(stored?.mime ?? mime);base64,\((stored?.data ?? data).base64EncodedString())"
            let rep = img.representations.first as? NSBitmapImageRep
            let natW = rep?.pixelsWide ?? Int(img.size.width)
            let natH = rep?.pixelsHigh ?? Int(img.size.height)
            pending.append(Pending(name: url.deletingPathExtension().lastPathComponent,
                                   image: img, dataURL: dataURL, natW: natW, natH: natH))
        }
        rebuildPreviews()
        onValidityChange()
    }

    private func addImage(_ image: NSImage, name: String) {
        // Paste path — serialize to PNG so we have a data URL to send to JS.
        guard let tiff = image.tiffRepresentation,
              let bmp = NSBitmapImageRep(data: tiff),
              let data = bmp.representation(using: .png, properties: [:]) else { return }
        let dataURL = ImageOptimizer.optimize(dataURL: "data:image/png;base64,\(data.base64EncodedString())")
        let natW = bmp.pixelsWide
        let natH = bmp.pixelsHigh
        pending.append(Pending(name: name, image: image, dataURL: dataURL, natW: natW, natH: natH))
        rebuildPreviews()
        onValidityChange()
    }

    private static func mime(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png":          return "image/png"
        case "jpg", "jpeg":  return "image/jpeg"
        case "gif":          return "image/gif"
        case "svg":          return "image/svg+xml"
        case "webp":         return "image/webp"
        default:             return "application/octet-stream"
        }
    }

    private func rebuildPreviews() {
        previewStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, p) in pending.enumerated() {
            let tile = PreviewTile(image: p.image) { [weak self] in
                guard let self, self.pending.indices.contains(i) else { return }
                self.pending.remove(at: i)
                self.rebuildPreviews()
                self.onValidityChange()
            }
            previewStack.addArrangedSubview(tile)
        }
        previewWrap.isHidden = pending.isEmpty
    }

    func currentSpec() -> [String: Any]? {
        guard !pending.isEmpty else { return nil }
        let label = labelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let images: [[String: Any]] = pending.map {
            [
                "name":    $0.name,
                "dataURL": $0.dataURL,
                "natW":    $0.natW,
                "natH":    $0.natH,
            ]
        }
        var spec: [String: Any] = ["kind": "image", "images": images]
        if !label.isEmpty { spec["label"] = label }
        return spec
    }

    func reset() {
        pending.removeAll()
        rebuildPreviews()
        labelField.stringValue = ""
    }
}

// MARK: - ImageDropView

/// Combined drop-target + click-to-pick + paste-image zone. Registers for
/// file URLs and for in-app image payloads so clipboards with PNG bitmaps
/// also drop cleanly. Paste is handled via `performKeyEquivalent` — this
/// view grabs Cmd+V when it (or any descendant) is the first responder,
/// so users can paste an image without clicking into a text field.
/// Decorative text inside a single clickable drop zone must not register I-beam cursors.
private final class DropZoneLabel: NSTextField {
    override func resetCursorRects() {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class ImageDropView: NSView {

    private let folderMode: Bool
    var isEnabled = true {
        didSet {
            if !isEnabled { hovered = false; highlighted = false }
            updateAppearance()
            window?.invalidateCursorRects(for: self)
        }
    }
    var onFiles: (([URL]) -> Void)?
    var onClick: (() -> Void)?
    var onPaste: ((NSImage, String) -> Void)?

    private let hint = DropZoneLabel(wrappingLabelWithString: "Drop images here or click to browse")
    private let sub  = DropZoneLabel(wrappingLabelWithString: "PNG, JPG, WebP, SVG — or paste from clipboard")
    private var highlighted = false { didSet { updateAppearance() } }
    private var hovered = false { didSet { updateAppearance() } }
    private var hoverTracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    init(folderMode: Bool = false) {
        self.folderMode = folderMode
        super.init(frame: .zero)
        if folderMode {
            hint.stringValue = "Drop a project folder here or click to browse"
            sub.stringValue = "Discover pages, components and CSS variables"
            setAccessibilityLabel("Choose project folder")
            setAccessibilityRole(.button)
        }
        wantsLayer = true
        layer?.cornerRadius = WFDesign.Radius.medium
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor

        for label in [hint, sub] {
            label.isEditable = false
            label.isSelectable = false
        }
        hint.font = .systemFont(ofSize: 13)
        hint.textColor = WFDesign.text2
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = WFDesign.text3
        sub.alignment = .center
        sub.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [hint, sub])
        stack.orientation = .vertical
        stack.spacing = 4
        stack.alignment = .centerX
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        registerForDraggedTypes(folderMode ? [.fileURL] : [.fileURL, .tiff, .png])
        toolTip = folderMode ? "Click to choose a project folder" : "Click to choose images"
        updateAppearance()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    // MARK: Click

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        onClick?()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: isEnabled ? .pointingHand : .arrow)
    }

    // The zone is one control: labels and the layout stack never intercept clicks.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero,
                                 options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                 owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
        if let window {
            hovered = isEnabled && !isHiddenOrHasHiddenAncestor && window.isKeyWindow
                && visibleRect.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        } else { hovered = false }
    }

    override func mouseEntered(with event: NSEvent) { hovered = isEnabled }
    override func mouseExited(with event: NSEvent) { hovered = false }

    private func updateAppearance() {
        let active = isEnabled && (hovered || highlighted)
        layer?.backgroundColor = (active
            ? WFDesign.accent.withAlphaComponent(highlighted ? 0.18 : 0.09)
            : NSColor.black.withAlphaComponent(0.12)).cgColor
        layer?.borderColor = (active
            ? WFDesign.accent.withAlphaComponent(highlighted ? 0.95 : 0.6)
            : NSColor.separatorColor).cgColor
        hint.textColor = active ? WFDesign.text : WFDesign.text2
        sub.textColor = active ? WFDesign.text2 : WFDesign.text3
    }

    // MARK: Paste

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window != nil, !isHiddenOrHasHiddenAncestor,
           !(window?.firstResponder is NSText), CanvasKeyboard.isPaste(event), handlePaste() {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func handlePaste() -> Bool {
        guard !folderMode, isEnabled else { return false }
        let pb = NSPasteboard.general
        if let types = pb.types, types.contains(.png) || types.contains(.tiff) {
            if let img = NSImage(pasteboard: pb) {
                onPaste?(img, "pasted-image")
                return true
            }
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            let images = urls.filter { NSImage(byReferencing: $0).isValid }
            if !images.isEmpty { onFiles?(images); return true }
        }
        return false
    }

    // MARK: Dragging

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isEnabled, !folderMode || folderURL(sender.draggingPasteboard) != nil else { return [] }
        highlighted = true
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = false
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        guard isEnabled else { return false }
        let pb = sender.draggingPasteboard
        if folderMode {
            guard let url = folderURL(pb) else { return false }
            onFiles?([url]); return true
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingContentsConformToTypes: [UTType.image.identifier]
        ]) as? [URL] {
            onFiles?(urls)
            return !urls.isEmpty
        }
        if let img = NSImage(pasteboard: pb) {
            onPaste?(img, "dropped-image")
            return true
        }
        return false
    }

    private func folderURL(_ pasteboard: NSPasteboard) -> URL? {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              urls.count == 1, let url = urls.first,
              (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        return url
    }

    override func keyDown(with event: NSEvent) {
        if folderMode, isEnabled, [" ", "\r"].contains(event.charactersIgnoringModifiers ?? "") { onClick?(); return }
        super.keyDown(with: event)
    }

}

// MARK: - PreviewTile

/// 48×48 image tile with a trailing "×" remove button overlaid on the
/// top-right corner. Mirrors the HTML `.img-preview-item` look.
final class PreviewTile: NSView {
    init(image: NSImage, onRemove: @escaping () -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = WFDesign.Radius.small
        layer?.masksToBounds = true

        let iv = NSImageView()
        iv.image = image
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iv)

        let rm = NSButton(title: "×", target: nil, action: nil)
        rm.bezelStyle = .circular
        rm.isBordered = false
        rm.font = .systemFont(ofSize: 13, weight: .bold)
        rm.contentTintColor = .white
        rm.wantsLayer = true
        rm.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        rm.layer?.cornerRadius = 9
        rm.translatesAutoresizingMaskIntoConstraints = false
        // Block-based target — NSButton's target is weak-held, so capture
        // the closure in an NSObject action wrapper.
        let wrap = ActionWrapper(block: onRemove)
        rm.target = wrap
        rm.action = #selector(ActionWrapper.fire)
        objc_setAssociatedObject(self, &PreviewTile.wrapKey, wrap, .OBJC_ASSOCIATION_RETAIN)
        addSubview(rm)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 48),
            heightAnchor.constraint(equalToConstant: 48),
            iv.topAnchor.constraint(equalTo: topAnchor),
            iv.bottomAnchor.constraint(equalTo: bottomAnchor),
            iv.leadingAnchor.constraint(equalTo: leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: trailingAnchor),
            rm.widthAnchor.constraint(equalToConstant: 18),
            rm.heightAnchor.constraint(equalToConstant: 18),
            rm.topAnchor.constraint(equalTo: topAnchor, constant: -4),
            rm.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 4),
        ])
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private static var wrapKey: UInt8 = 0
}

/// Tiny helper — NSButton targets are weak-held, so for closure-based
/// actions we attach this retain-wrapped wrapper via objc_setAssociatedObject.
private final class ActionWrapper: NSObject {
    let block: () -> Void
    init(block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}
