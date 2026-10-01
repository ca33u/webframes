import Foundation
import CoreGraphics

/// Phase 6e Step 70b: Swift port of JS `applyAddFrameSpec` /
/// `spawnFrame` / `spawnImageFrame` (Renderer/index.html ~line 919,
/// 1071, 1439). Given the `AddFrameModal` spec dict, produces a
/// sequence of `FrameModel` values ready to feed into
/// `WorkspaceStore.createFrame` — one per URL / image in the spec —
/// preserving the byte-for-byte shape the JS path emitted so a round-
/// trip through `DocumentPayload` is indistinguishable.
///
/// The applier is pure: it reads the current frame count and viewport
/// for position math, allocates frame numbers through the provided
/// closures (normally `WorkspaceStore.allocateFrameNum`), and does NOT
/// touch the store. The caller is responsible for walking the output
/// and calling `workspace.createFrame(_)` for each. Keeping the allocation
/// out lets tests build specs and inspect the output without needing a
/// full store instance.
@MainActor
enum AddFrameSpecApplier {

    /// Maps a modal-confirmed spec dict into zero or more frames.
    /// Returns `[]` on an unrecognized / malformed kind — matches JS
    /// behaviour where `applyAddFrameSpec` console-warned and returned
    /// silently rather than throwing.
    ///
    /// - Parameters:
    ///   - spec: The `[String: Any]` produced by `AddFrameModal
    ///           .currentSpec()`. Shape varies by `kind`.
    ///   - existingFrameCount: `workspace.frames.count` at the time of
    ///           the call, used for the horizontal stride in position
    ///           math. Folder / github / image kinds bump the stride
    ///           as they iterate so each frame in a batch lands a
    ///           column to the right of the previous one.
    ///   - viewport: Current pan/zoom. Drop positions are computed in
    ///           world-space — JS uses `(80 + stride*i − px) / scale`.
    ///   - allocateNum: Returns the next frame number and bumps the
    ///           store counter. Injected for testability.
    ///   - generateId: Returns a unique frame id. Injected so tests
    ///           can assert on a deterministic shape; production passes
    ///           `.defaultIdGenerator`.
    static func frames(for spec: [String: Any],
                       existingFrameCount: Int,
                       viewport: ViewportModel,
                       allocateNum: () -> Int,
                       generateId: () -> String) -> [FrameModel] {
        guard let kind = spec["kind"] as? String else { return [] }
        let w = (spec["w"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 1280
        let h = (spec["h"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 800

        switch kind {
        case "local", "url", "web":
            guard let rawURL = spec["url"] as? String else { return [] }
            let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            // Older documents can still provide the former URL/Localhost
            // kinds. The unified Web Page flow selects a safe default from
            // the address: local development uses HTTP, other hosts HTTPS.
            let url: String
            if kind == "url" { url = normalizeSchemeDefaulting(trimmed, to: "https://") }
            else if kind == "local" { url = normalizeHTTPScheme(trimmed) }
            else { url = normalizeWebPageAddress(trimmed) }
            let rawLabel = (spec["label"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let label = rawLabel.isEmpty ? url : rawLabel
            let origin = dropOrigin(index: 0, width: w,
                                    existing: existingFrameCount,
                                    viewport: viewport)
            return [FrameModel(
                id: generateId(), url: url, label: label,
                x: origin.x, y: origin.y, w: w, h: h,
                num: allocateNum(), isImage: false, filePath: nil,
                extras: [:]
            )]

        case "github":
            guard let owner = spec["owner"] as? String,
                  let repo  = spec["repo"]  as? String,
                  !owner.isEmpty, !repo.isEmpty,
                  let files = spec["files"] as? [String] else { return [] }
            let branch = (spec["branch"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "main"
            let authenticated = (spec["authenticated"] as? Bool) == true || !(spec["token"] as? String ?? "").isEmpty
            return files.enumerated().map { i, p in
                let url: String
                if authenticated {
                    url = GitHubFrameSource.frameURL(owner: owner, repo: repo, branch: branch, path: p)
                } else {
                    // Public repos: htmlpreview proxy renders the blob.
                    url = "https://htmlpreview.github.io/?https://github.com/\(owner)/\(repo)/blob/\(branch)/\(p)"
                }
                let label = basenameStrippingHTML(p)
                let origin = dropOrigin(index: i, width: w,
                                        existing: existingFrameCount,
                                        viewport: viewport)
                return FrameModel(
                    id: generateId(), url: url, label: label,
                    x: origin.x, y: origin.y, w: w, h: h,
                    num: allocateNum(), isImage: false, filePath: nil,
                    extras: [:]
                )
            }

        case "image":
            guard let images = spec["images"] as? [[String: Any]],
                  !images.isEmpty else { return [] }
            let userLabel = (spec["label"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return images.enumerated().compactMap { (i, item) -> FrameModel? in
                guard let dataURL = item["dataURL"] as? String,
                      !dataURL.isEmpty else { return nil }
                let natW = (item["natW"] as? NSNumber).map { $0.doubleValue } ?? 0
                let natH = (item["natH"] as? NSNumber).map { $0.doubleValue } ?? 0
                // Scale to a sensible on-canvas size the same way the
                // old modal did: width capped at 1440, height preserves
                // aspect ratio.
                let tw = CGFloat(min(natW > 0 ? natW : 1280, 1440))
                let th: CGFloat = (natW > 0 && natH > 0)
                    ? CGFloat((tw / CGFloat(natW) * CGFloat(natH)).rounded())
                    : 800
                let rawName = (item["name"] as? String) ?? ""
                let nameFromFile = rawName
                    .replacingOccurrences(of: #"\.[^.]+$"#,
                                          with: "",
                                          options: .regularExpression)
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: " ")
                let frameLabel = !userLabel.isEmpty ? userLabel :
                                 (!nameFromFile.isEmpty ? nameFromFile : "screenshot")
                let origin = dropOrigin(index: i, width: tw,
                                        existing: existingFrameCount,
                                        viewport: viewport)
                // imgUrl / natW / natH carried through `extras` — same
                // slot JS-originated image frames used, so a round-trip
                // through `DocumentPayload` is identity.
                let extras: [String: JSONValue] = [
                    "imgUrl": .string(dataURL),
                    "natW":   .number(natW),
                    "natH":   .number(natH),
                ]
                return FrameModel(
                    id: generateId(),
                    url: "image://\(frameLabel)",
                    label: frameLabel,
                    x: origin.x, y: origin.y, w: tw, h: th,
                    num: allocateNum(), isImage: true, filePath: nil,
                    extras: extras
                )
            }

        default:
            return []
        }
    }

    // MARK: - Helpers

    /// Drop-position math in world-space. Mirrors JS:
    ///   `x = (80 + (existing + i) * (min(w, 600) + 48) − px) / scale`
    ///   `y = (80 − py) / scale`
    /// Frames land in a rightward row, each column `min(w, 600) + 48pt`
    /// wide. Viewport pan/zoom gets undone so the origin is in the
    /// canvas world, not screen space.
    static func dropOrigin(index: Int, width w: CGFloat,
                           existing: Int,
                           viewport: ViewportModel) -> CGPoint {
        let stride = min(w, 600) + 48
        let x = (80 + CGFloat(existing + index) * stride - viewport.panX) / viewport.scale
        let y = (80 - viewport.panY) / viewport.scale
        return CGPoint(x: x, y: y)
    }

    /// Adds `http://` when the string lacks an `http://` / `https://`
    /// prefix. Case-insensitive match, matches JS's
    /// `/^https?:\/\//i.test(url)`.
    static func normalizeHTTPScheme(_ s: String) -> String {
        let lower = s.lowercased()
        return (lower.hasPrefix("http://") || lower.hasPrefix("https://"))
            ? s
            : "http://" + s
    }

    /// Like `normalizeHTTPScheme`, but uses the provided scheme prefix as
    /// the default when the input is bare. Used by the "url" tab so
    /// arbitrary websites default to `https://` instead of `http://`.
    static func normalizeSchemeDefaulting(_ s: String, to defaultScheme: String) -> String {
        let lower = s.lowercased()
        return (lower.hasPrefix("http://") || lower.hasPrefix("https://"))
            ? s
            : defaultScheme + s
    }

    /// Unified Web Page default: local development addresses normally do
    /// not use TLS, while pasted public hostnames should open over HTTPS.
    static func normalizeWebPageAddress(_ s: String) -> String {
        let lower = s.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return s }
        let local = lower == "localhost"
            || lower.hasPrefix("localhost:")
            || lower == "127.0.0.1"
            || lower.hasPrefix("127.0.0.1:")
            || lower == "0.0.0.0"
            || lower.hasPrefix("0.0.0.0:")
            || lower.hasPrefix("[::1]")
        return (local ? "http://" : "https://") + s
    }

    /// Returns the last path segment with any trailing `.html` / `.htm`
    /// stripped (case-insensitive). Empty string on empty input.
    static func basenameStrippingHTML(_ path: String) -> String {
        let base = path.split(separator: "/").last.map(String.init) ?? path
        return base.replacingOccurrences(
            of: #"\.html?$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    /// Default ID generator — matches JS `"f" + Date.now() + Math.random()`
    /// shape so frames created natively are indistinguishable on disk
    /// from frames that came in through the old JS path. Uses the
    /// system entropy pool (`.random(in:)`) — good enough for a
    /// session-scoped unique id.
    static func defaultIdGenerator() -> String {
        let t = Int(Date().timeIntervalSince1970 * 1000)
        let r = Double.random(in: 0..<1)
        return "f\(t)\(r)"
    }
}
