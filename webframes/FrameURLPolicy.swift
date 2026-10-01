import Foundation

/// Which sources a frame may load. A `.webframes` file can come from anyone,
/// so its frame URLs are untrusted input: without this gate a document could
/// show a local file (file://) and Compare would send its snapshot to Codex.
enum FrameURLPolicy {
    static let allowedSchemes: Set<String> = ["http", "https", GitHubFrameSource.scheme]

    /// Image frames carry pixels in `extras["imgUrl"]`, not at their URL.
    static func isImageFrameURL(_ url: String) -> Bool { url.hasPrefix("image://") }

    static func allowedURL(_ string: String) -> URL? {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else { return nil }
        if scheme != GitHubFrameSource.scheme, url.host?.isEmpty != false { return nil }
        return url
    }

    /// Opening in the default browser: web pages only.
    static func browserURL(_ string: String) -> URL? {
        guard let url = allowedURL(string), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    static func unsupportedHTML(for source: String) -> String {
        let escaped = source
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;height:100%;background:#161616;color:#888;font:14px -apple-system,sans-serif}
        body{display:flex;align-items:center;justify-content:center;text-align:center;padding:24px;box-sizing:border-box}
        b{display:block;color:#e2e2e2;margin-bottom:6px}code{word-break:break-all}
        </style></head><body><div><b>Unsupported source</b><code>\(escaped)</code></div></body></html>
        """
    }
}
