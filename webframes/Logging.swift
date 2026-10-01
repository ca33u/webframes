import Foundation
import os

/// Centralized os.Logger categories.
///
/// Subsystem is the product bundle ID — filter in Console.app with
/// `subsystem:app.essazanov.webframes`. Categories let us narrow to
/// one concern (e.g. `category:bridge`) without losing the rest.
///
/// Marked `nonisolated` because the project ships with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Without this, the
/// static `Logger` properties become MainActor-isolated and can't be
/// referenced from `nonisolated` callers like `KeychainHelper` or from
/// the `nonisolated` `WKScriptMessageHandler` entry point.
nonisolated enum Log {
    private static let subsystem = "app.essazanov.webframes"

    /// Native ↔ web messaging: evaluateJavaScript dispatch, payload serialization.
    static let bridge   = Logger(subsystem: subsystem, category: "bridge")
    /// Per-frame WKWebView lifecycle (create/destroy/load/rect).
    static let frame    = Logger(subsystem: subsystem, category: "frame")
    /// Keychain save/load/delete with OSStatus reporting.
    static let keychain = Logger(subsystem: subsystem, category: "keychain")
    /// AppKit menu wiring and menu → canvas dispatch.
    static let menu     = Logger(subsystem: subsystem, category: "menu")
    /// Canvas WKWebView loading and resource resolution.
    static let canvas   = Logger(subsystem: subsystem, category: "canvas")
    /// NSWindow state save/restore.
    static let window   = Logger(subsystem: subsystem, category: "window")
    /// NSDocument lifecycle: read/write/state-sync.
    static let doc      = Logger(subsystem: subsystem, category: "doc")
}
