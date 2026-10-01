import Foundation
import os
import WebKit

/// Channel targets the `window.addEventListener(...)` name that JS listens on.
///
/// Phase 6e Step 70e retired the `.canvas` channel along with the canvas
/// WKWebView; the only surviving native→web dispatch is per-frame inspector
/// commands injected by `InspectBridgeScript`.
enum WebChannel: String {
    /// Per-frame WKWebView listens on this. Used by native to push inspector
    /// commands (wf-highlight, wf-inspect, …) into a single frame.
    case frame  = "wf-from-canvas"
}

/// Single transport for native → web dispatch.
///
/// All `evaluateJavaScript` calls that deliver a payload go through here so
/// that:
///   * JSON serialization happens once, in one place (no hand-rolled escaping
///     scattered across files)
///   * payload validation is uniform (refuse non-JSON-serializable inputs
///     instead of silently dropping or corrupting them)
///   * errors are logged via `Log.bridge` with the call site context
///
/// Payload shape is still `[String: Any]` at the call site — this is what the
/// JS bridge contract looks like today (typed envelopes on the Swift side
/// would be the next step, but this file is the chokepoint for that work).
enum WebMessenger {

    /// Dispatches `payload` as a `CustomEvent` on `channel`.
    ///
    /// Embeds the JSON via a backtick-quoted template literal + `JSON.parse`,
    /// which keeps the embedded blob opaque to JS parsing (no risk of stray
    /// quotes or newlines breaking the outer script). Backtick, backslash
    /// and `$` are escaped because they're the only characters that can
    /// interfere with a template literal.
    ///
    /// Fire-and-forget: success is not reported; failures are logged.
    static func dispatch(
        _ payload: [String: Any],
        on channel: WebChannel,
        to webView: WKWebView?,
        context: String = #function
    ) {
        guard let webView else {
            Log.bridge.error("dispatch[\(String(describing: context), privacy: .public)] skipped: no webView")
            return
        }
        guard let script = buildScript(payload: payload, channel: channel, context: context) else {
            return
        }
        webView.evaluateJavaScript(script) { _, error in
            if let error {
                Log.bridge.error("dispatch[\(String(describing: context), privacy: .public)] evaluateJavaScript failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Internal

    private static func buildScript(
        payload: [String: Any],
        channel: WebChannel,
        context: String
    ) -> String? {
        guard JSONSerialization.isValidJSONObject(payload) else {
            Log.bridge.error("dispatch[\(String(describing: context), privacy: .public)] skipped: payload is not JSON-serializable")
            return nil
        }
        guard let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.withoutEscapingSlashes]
              ),
              let json = String(data: data, encoding: .utf8) else {
            Log.bridge.error("dispatch[\(String(describing: context), privacy: .public)] skipped: JSON encoding failed")
            return nil
        }
        let escaped = json
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        return "window.dispatchEvent(new CustomEvent('\(channel.rawValue)',{detail:JSON.parse(`\(escaped)`)}));"
    }
}
