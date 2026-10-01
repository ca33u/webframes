import Foundation

/// The two GitHub REST calls the GitHub tab needs. URLs are built with
/// URLComponents from validated owner/repo/branch values: interpolating
/// user input into URL(string:)! crashed on a space in the owner field.
enum GitHubAPI {
    private struct GHRepo: Decodable { let default_branch: String? }
    private struct GHTree: Decodable {
        struct Entry: Decodable { let path: String; let type: String }
        let tree: [Entry]
    }

    enum GHError: LocalizedError {
        case notFound, httpStatus(Int), decoding, noHtml
        var errorDescription: String? {
            switch self {
            case .notFound:          return "repo not found — if private, add a GitHub token in Settings"
            case .httpStatus(let s): return "api error \(s)"
            case .decoding:          return "unexpected response from github api"
            case .noHtml:            return "no html files found in repo"
            }
        }
    }

    /// GitHub owner and repository names: letters, digits, "-", "_" and ".".
    static func isValidName(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100 && value != "." && value != ".."
            && value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    static func url(path: [String], query: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.github.com"
        components.path = "/" + path.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        return components.url
    }

    private static func request(_ url: URL, token: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    static func fetchDefaultBranch(owner: String, repo: String, token: String) async throws -> String {
        guard isValidName(owner), isValidName(repo),
              let url = url(path: ["repos", owner, repo]) else { throw GHError.notFound }
        let (data, resp) = try await URLSession.shared.data(for: request(url, token: token))
        if let http = resp as? HTTPURLResponse, http.statusCode == 404 { throw GHError.notFound }
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw GHError.httpStatus(http.statusCode) }
        guard let decoded = try? JSONDecoder().decode(GHRepo.self, from: data) else { throw GHError.decoding }
        return decoded.default_branch ?? "main"
    }

    static func fetchHtmlFiles(owner: String, repo: String, branch: String, token: String) async throws -> [String] {
        // Branch names may contain "/" (feature/x); URLComponents escapes the rest.
        guard isValidName(owner), isValidName(repo), !branch.isEmpty, !branch.contains(".."),
              let url = url(path: ["repos", owner, repo, "git", "trees", branch],
                            query: [URLQueryItem(name: "recursive", value: "1")]) else { throw GHError.notFound }
        let (data, resp) = try await URLSession.shared.data(for: request(url, token: token))
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 { throw GHError.httpStatus(http.statusCode) }
        guard let tree = try? JSONDecoder().decode(GHTree.self, from: data) else { throw GHError.decoding }
        let htmls = tree.tree
            .filter { $0.type == "blob" && $0.path.range(of: #"\.(html?|htm)$"#, options: .regularExpression) != nil }
            .map { $0.path }
            .sorted()
        if htmls.isEmpty { throw GHError.noHtml }
        return htmls
    }
}
