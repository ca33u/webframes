import AppKit
import Network
import os
import UniformTypeIdentifiers

/// One discovery session per document, shared by Project and Web Page.
@MainActor final class LocalServerDiscovery {
    var projectAddress: String?
    private(set) var ports: [Int] = []
    private var pending: Task<[Int], Never>?
    private var lastScan = Date.distantPast
    private var lastPorts: [Int] = []
    private static let commonPorts = Array(3000...3010) + [5173, 5174, 4200, 4321, 5000, 5001, 8000, 8080, 8081, 8888, 9000, 1313, 3333, 5500, 6006, 7777, 8787]

    nonisolated static func isLocal(_ address: String) -> Bool {
        guard let parts = URLComponents(string: address), ["http", "https"].contains(parts.scheme?.lowercased() ?? "") else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(parts.host?.lowercased() ?? "")
    }

    func discover(address: String, force: Bool) async -> [Int] {
        var wanted = Self.commonPorts
        for candidate in [projectAddress, address].compactMap({ $0 }) where Self.isLocal(candidate) {
            if let port = URLComponents(string: candidate)?.port { wanted.append(port) }
        }
        wanted = Array(Set(wanted)).sorted()
        if wanted == lastPorts {
            if let pending { return await pending.value }
            if !force, Date().timeIntervalSince(lastScan) < 10 { return ports }
        }
        pending?.cancel()
        lastPorts = wanted
        let task = Task { await WebPageTabPanel.scanLocalhost(ports: wanted, timeout: 0.6) }
        pending = task
        let result = await task.value
        guard !task.isCancelled, wanted == lastPorts else { return ports }
        ports = result; lastScan = Date(); pending = nil
        return result
    }

    nonisolated static func responds(_ address: String, timeout: TimeInterval = 4) async -> Bool {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return false }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return response is HTTPURLResponse
        } catch { return false }
    }
}
