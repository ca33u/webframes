//
//  KeychainHelperTests.swift
//  webframesTests
//
//  Exercises the thin wrapper over Keychain Services. Every test runs
//  against the real macOS Keychain (the test process shares the host
//  app's sandbox), so each test uses a unique key namespace and always
//  deletes after itself — even on failure — to avoid polluting the
//  Keychain or leaking stale items between runs.
//

import Foundation
import Testing
@testable import Web_Frames

@Suite("KeychainHelper")
struct KeychainHelperTests {

    // MARK: - save / load / delete

    @Test("save then load returns the same value")
    func saveLoadRoundTrip() {
        let key = Self.uniqueKey()
        defer { _ = KeychainHelper.delete(key: key) }

        let result = KeychainHelper.save(key: key, value: "hello")
        #expect(Self.isSuccess(result))

        switch KeychainHelper.load(key: key) {
        case .success(let got): #expect(got == "hello")
        case .failure(let e):   Issue.record("load failed: \(e)")
        }
    }

    @Test("save overwrites an existing value")
    func saveOverwrites() {
        let key = Self.uniqueKey()
        defer { _ = KeychainHelper.delete(key: key) }

        _ = KeychainHelper.save(key: key, value: "first")
        _ = KeychainHelper.save(key: key, value: "second")

        switch KeychainHelper.load(key: key) {
        case .success(let got): #expect(got == "second")
        case .failure(let e):   Issue.record("load failed: \(e)")
        }
    }

    @Test("load of a missing item returns .missingItem")
    func loadMissing() {
        let key = Self.uniqueKey()
        // Don't save — just load. Defer cleanup anyway in case of flakes.
        defer { _ = KeychainHelper.delete(key: key) }

        switch KeychainHelper.load(key: key) {
        case .success:
            Issue.record("expected .missingItem, got success")
        case .failure(let e):
            guard case .missingItem = e else {
                Issue.record("expected .missingItem, got \(e)")
                return
            }
        }
    }

    /// The delete API intentionally treats `errSecItemNotFound` as
    /// success so callers don't have to branch on "first delete" vs
    /// "redundant delete". This locks that contract.
    @Test("delete of a missing item is a no-op success")
    func deleteMissingIsSuccess() {
        let key = Self.uniqueKey()
        let result = KeychainHelper.delete(key: key)
        #expect(Self.isSuccess(result))
    }

    @Test("load after delete returns .missingItem")
    func loadAfterDelete() {
        let key = Self.uniqueKey()
        defer { _ = KeychainHelper.delete(key: key) }

        _ = KeychainHelper.save(key: key, value: "v")
        _ = KeychainHelper.delete(key: key)

        switch KeychainHelper.load(key: key) {
        case .success:
            Issue.record("expected .missingItem after delete")
        case .failure(let e):
            guard case .missingItem = e else {
                Issue.record("expected .missingItem, got \(e)")
                return
            }
        }
    }

    // MARK: - value shape coverage

    @Test("empty string round-trips")
    func emptyStringRoundTrip() {
        let key = Self.uniqueKey()
        defer { _ = KeychainHelper.delete(key: key) }

        _ = KeychainHelper.save(key: key, value: "")
        switch KeychainHelper.load(key: key) {
        case .success(let got): #expect(got == "")
        case .failure(let e):   Issue.record("load failed: \(e)")
        }
    }

    @Test("unicode value round-trips")
    func unicodeRoundTrip() {
        let key = Self.uniqueKey()
        defer { _ = KeychainHelper.delete(key: key) }

        let value = "🔑 Пароль — 中文 — \u{1F600}"
        _ = KeychainHelper.save(key: key, value: value)

        switch KeychainHelper.load(key: key) {
        case .success(let got): #expect(got == value)
        case .failure(let e):   Issue.record("load failed: \(e)")
        }
    }

    @Test("long value round-trips")
    func longValueRoundTrip() {
        let key = Self.uniqueKey()
        defer { _ = KeychainHelper.delete(key: key) }

        // ~8 KB — well under Keychain's per-item limit, well over any
        // single-page buffer a naive implementation might assume.
        let value = String(repeating: "A", count: 8 * 1024)
        _ = KeychainHelper.save(key: key, value: value)

        switch KeychainHelper.load(key: key) {
        case .success(let got): #expect(got == value)
        case .failure(let e):   Issue.record("load failed: \(e)")
        }
    }

    // MARK: - key scoping

    /// Two distinct keys must not trample each other — the keychain
    /// `service` is shared, only `account` differs. Regressions here
    /// would mean every saved token gets the last-write value.
    @Test("distinct keys are independent")
    func distinctKeysAreIndependent() {
        let k1 = Self.uniqueKey()
        let k2 = Self.uniqueKey()
        defer {
            _ = KeychainHelper.delete(key: k1)
            _ = KeychainHelper.delete(key: k2)
        }

        _ = KeychainHelper.save(key: k1, value: "one")
        _ = KeychainHelper.save(key: k2, value: "two")

        #expect((try? KeychainHelper.load(key: k1).get()) == "one")
        #expect((try? KeychainHelper.load(key: k2).get()) == "two")
    }

    // MARK: - helpers

    /// A per-test-run unique key under a recognisable prefix, so even
    /// if a test crashes without cleanup the leaked items are easy to
    /// spot and purge manually (`security find-generic-password -s
    /// pro.webframes.app`).
    private static func uniqueKey() -> String {
        "test.\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)"
    }

    private static func isSuccess<T>(_ result: Result<T, KeychainHelper.KeychainError>) -> Bool {
        if case .success = result { return true }
        return false
    }
}
