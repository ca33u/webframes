import Foundation
import WebKit
import UniformTypeIdentifiers

/// A private frame stores only repository coordinates. Credentials stay in Keychain.
nonisolated struct GitHubFrameSource {
    static let scheme = "wf-github"
    let owner: String
    let repo: String
    let branch: String
    static func frameURL(owner: String, repo: String, branch: String, path: String) -> String {
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? value }
        return "wf-github://\(owner)/\(encode(repo))/\(encode(branch))/" + path.split(separator: "/").map { encode(String($0)) }.joined(separator: "/")
    }
    init?(url: URL) {
        guard url.scheme == Self.scheme, let owner = url.host, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.split(separator: "/"), parts.count >= 3,
              let repo = String(parts[0]).removingPercentEncoding, let branch = String(parts[1]).removingPercentEncoding,
              !owner.isEmpty, !repo.isEmpty, !branch.isEmpty else { return nil }
        self.owner = owner; self.repo = repo; self.branch = branch
    }
    func request(for url: URL, token: String) throws -> URLRequest {
        guard url.scheme == Self.scheme, url.host == owner, url.user == nil, url.password == nil,
              let rawPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath else {
            throw ConnectionSettingsError.message("Invalid repository resource.")
        }
        var parts = rawPath.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        if parts.count >= 2, parts[0] == repo, parts[1] == branch { parts.removeFirst(2) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0.contains("/") || $0.contains("\\") }) else {
            throw ConnectionSettingsError.message("Invalid repository path.")
        }
        var components = URLComponents(string: "https://api.github.com")!
        components.path = "/repos/\(owner)/\(repo)/contents/" + parts.joined(separator: "/")
        components.queryItems = [URLQueryItem(name: "ref", value: branch)]
        var request = try ConnectionProvider.github.request(token: token)
        request.url = components.url
        request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        return request
    }
}

@MainActor final class GitHubFrameSchemeHandler: NSObject, WKURLSchemeHandler {
    private let source: GitHubFrameSource
    private var running: [ObjectIdentifier: Task<Void, Never>] = [:]
    init(source: GitHubFrameSource) { self.source = source; super.init() }
    nonisolated func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        MainActor.assumeIsolated { start(urlSchemeTask) }
    }
    nonisolated func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        MainActor.assumeIsolated { running.removeValue(forKey: ObjectIdentifier(urlSchemeTask as AnyObject))?.cancel() }
    }
    private func start(_ schemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(schemeTask as AnyObject)
        running[id] = Task {
            defer { running.removeValue(forKey: id) }
            do {
                guard let url = schemeTask.request.url else { throw URLError(.badURL) }
                let token = try KeychainHelper.load(key: "gh_token").get()
                let request = try source.request(for: url, token: token)
                let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForResource = 30
                let session = URLSession(configuration: config, delegate: ConnectionRedirectGuard(), delegateQueue: nil)
                defer { session.invalidateAndCancel() }
                let (data, response) = try await session.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 10_000_000 else {
                    throw ConnectionSettingsError.message("Could not load this GitHub file. Check its path and your GitHub connection in Settings.")
                }
                let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                let reply = URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil)
                schemeTask.didReceive(reply); schemeTask.didReceive(data); schemeTask.didFinish()
            } catch {
                if !Task.isCancelled { schemeTask.didFailWithError(ConnectionSettingsError.message("GitHub preview unavailable. Check the saved key in Settings and reload.")) }
            }
        }
    }
}
