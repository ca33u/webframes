import AppKit
import WebKit

struct AstraCapture {
    let id: UUID
    let image: NSImage
    let png: Data
    let context: [String: Any]
    var dataURL: String { "data:image/png;base64," + png.base64EncodedString() }
    var width: Int { (context["width"] as? NSNumber)?.intValue ?? 0 }
    var height: Int { (context["height"] as? NSNumber)?.intValue ?? 0 }
    func matchesPageState(of other:AstraCapture) -> Bool {
        guard let documentID = context["documentID"] as? String, !documentID.isEmpty else { return false }
        return documentID == other.context["documentID"] as? String
            && context["url"] as? String == other.context["url"] as? String
            && width == other.width && height == other.height
            && context["scrollX"] as? Double == other.context["scrollX"] as? Double
            && context["scrollY"] as? Double == other.context["scrollY"] as? Double
    }
    /// The context as sent to Codex and saved as evidence; the page URL has
    /// credentials and token parameters removed.
    var contextText: String {
        var shared = context
        if let url = shared["url"] as? String { shared["url"] = URLRedaction.redact(url) }
        return String(data: (try? JSONSerialization.data(withJSONObject: shared, options: [.sortedKeys])) ?? Data(), encoding: .utf8) ?? "{}"
    }
    func save(to folder: URL, name: String) throws {
        try png.write(to: folder.appendingPathComponent(name + ".png"), options: .atomic)
        try Data(contextText.utf8).write(to: folder.appendingPathComponent(name + ".json"), options: .atomic)
    }
}

@MainActor
final class AstraCaptureService {
    private static let world = WKContentWorld.world(name:"WebFrames.AstraCapture")
    // The page cannot access this isolated world's global. It resets on navigation.
    private static let identityScript = "globalThis.__webFramesAstraDocumentID ??= Array.from(crypto.getRandomValues(new Uint32Array(4))).join('-')"
    private func readContext(_ webView:WKWebView) async throws -> [String:Any]? {
        try await webView.evaluateJavaScript(Self.identityScript + ";" + Self.contextScript,in:nil,contentWorld:Self.world) as? [String:Any]
    }
    private func stableContext(_ context:[String:Any]) -> [String:Any] {
        var copy = context
        // WebKit rounds this timer; it is metadata, not a document identity.
        copy.removeValue(forKey:"timeOrigin")
        return copy
    }
    // All script text is application-owned. Page contents are returned only as data.
    static let contextScript = #"""
    (() => {
      const selector = e => {
        if (e.id) return '#' + CSS.escape(e.id);
        if (e.dataset.testid) return '[data-testid="' + CSS.escape(e.dataset.testid) + '"]';
        const parts = [];
        while(e && e !== document.body && parts.length < 7) {
          let s = e.tagName.toLowerCase();
          const sib = e.parentElement ? [...e.parentElement.children].filter(x => x.tagName === e.tagName) : [];
          if(sib.length > 1) s += ':nth-of-type(' + (sib.indexOf(e)+1) + ')';
          parts.unshift(s); e = e.parentElement;
        }
        return 'body > ' + parts.join(' > ');
      };
      const elements = [...document.querySelectorAll('h1,h2,h3,p,button,a,main,section,article,header,[data-testid],.card')]
        .filter(e => { const r=e.getBoundingClientRect();return r.width && r.height && r.bottom>0 && r.top<innerHeight; })
        .slice(0,100).map(e => {
          const r=e.getBoundingClientRect(), c=getComputedStyle(e);
          return {selector:selector(e),tag:e.tagName,text:(e.textContent||'').trim().slice(0,160),
            className:typeof e.className==='string'?e.className:'',component:e.dataset.component||null,
            x:r.x,y:r.y,width:r.width,height:r.height,
            styles:{display:c.display,gap:c.gap,gridTemplateColumns:c.gridTemplateColumns,fontSize:c.fontSize,
              fontWeight:c.fontWeight,lineHeight:c.lineHeight,color:c.color,backgroundColor:c.backgroundColor,
              padding:c.padding,borderRadius:c.borderRadius,overflow:c.overflow}};
        });
      return {documentID:globalThis.__webFramesAstraDocumentID,url:location.href,timeOrigin:performance.timeOrigin,width:innerWidth,height:innerHeight,
        scrollX,scrollY,dpr:devicePixelRatio,documentWidth:document.documentElement.scrollWidth,
        ready:document.readyState==='complete' && (!document.fonts || document.fonts.status==='loaded') && [...document.images].every(i=>i.complete && i.naturalWidth>0),
        elements};
    })()
    """#

    /// Capture the pixels currently visible in a frame without waiting for
    /// DOM stability. This is the user-facing "freeze" action, so animated
    /// or continuously updating pages should still snapshot immediately.
    func snapshot(_ webView: WKWebView) async throws -> AstraCapture {
        try Task.checkCancellation()
        guard webView.bounds.width > 0, webView.bounds.height > 0 else {
            throw AstraError.message("Frame has no visible viewport.")
        }
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        config.snapshotWidth = NSNumber(value: webView.bounds.width)
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            var completed = false
            let finish: (Result<NSImage, Error>) -> Void = { result in
                guard !completed else { return }
                completed = true
                continuation.resume(with: result)
            }
            webView.takeSnapshot(with: config) { image, error in
                if let image { finish(.success(image)) }
                else { finish(.failure(error ?? AstraError.message("Screenshot is unavailable."))) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                finish(.failure(AstraError.message("Screenshot timed out.")))
            }
        }
        try Task.checkCancellation()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]),
              !png.isEmpty else {
            throw AstraError.message("Screenshot could not be encoded.")
        }
        let now = ISO8601DateFormatter().string(from: Date())
        let context: [String: Any] = [
            "url": webView.url?.absoluteString ?? "",
            "width": Int(webView.bounds.width),
            "height": Int(webView.bounds.height),
            "pixelWidth": bitmap.pixelsWide,
            "pixelHeight": bitmap.pixelsHigh,
            "capturedAt": now,
        ]
        return AstraCapture(id: UUID(), image: image, png: png, context: context)
    }

    func capture(_ webView: WKWebView) async throws -> AstraCapture {
        try Task.checkCancellation()
        guard webView.bounds.width > 0, webView.bounds.height > 0 else { throw AstraError.message("Frame has no visible viewport.") }
        _ = try? await webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent('wf-from-canvas',{detail:{type:'wf-highlight-off'}}));")
        var previous = "", stable = 0
        var context: [String: Any] = [:]
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            try Task.checkCancellation()
            guard let current = try await readContext(webView) else {
                throw AstraError.message("Could not capture the page DOM.")
            }
            let signature = String(data: try JSONSerialization.data(withJSONObject: stableContext(current), options: .sortedKeys), encoding: .utf8) ?? ""
            if !webView.isLoading && current["ready"] as? Bool == true && signature == previous { stable += 1 } else { stable = 0 }
            previous = signature; context = current
            if stable >= 2 { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard stable >= 2 else { throw AstraError.message("Page did not become ready and stable within 15 seconds. Try capture again.") }
        let config = WKSnapshotConfiguration()
        config.rect = webView.bounds
        config.snapshotWidth = NSNumber(value: webView.bounds.width)
        let image: NSImage = try await withCheckedThrowingContinuation { continuation in
            var completed = false
            let finish: (Result<NSImage, Error>) -> Void = { result in
                guard !completed else { return }; completed = true; continuation.resume(with: result)
            }
            webView.takeSnapshot(with: config) { image, error in
                if let image { finish(.success(image)) }
                else { finish(.failure(error ?? AstraError.message("Screenshot is unavailable."))) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { finish(.failure(AstraError.message("Screenshot timed out."))) }
        }
        try Task.checkCancellation()
        guard let after = try await readContext(webView),
              NSDictionary(dictionary: stableContext(context)).isEqual(to: stableContext(after)), !webView.isLoading else {
            throw AstraError.message("Page changed during capture. Try again.")
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]), !png.isEmpty else {
            throw AstraError.message("Screenshot could not be encoded.")
        }
        context["captureID"] = UUID().uuidString
        context["capturedAt"] = ISO8601DateFormatter().string(from: Date())
        context["pixelWidth"] = bitmap.pixelsWide; context["pixelHeight"] = bitmap.pixelsHigh
        return AstraCapture(id: UUID(), image: image, png: png, context: context)
    }

    func reload(_ webView: WKWebView) async throws {
        let old = try await webView.evaluateJavaScript(Self.identityScript,in:nil,contentWorld:Self.world) as? String
        guard webView.reloadFromOrigin() != nil else { throw AstraError.message("This frame could not be reloaded.") }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(150))
            guard !webView.isLoading else { continue }
            if let new = try? await webView.evaluateJavaScript(Self.identityScript,in:nil,contentWorld:Self.world) as? String, new != old { return }
        }
        throw AstraError.message("Reload did not produce a new page. The applied fix is not verified.")
    }
}
