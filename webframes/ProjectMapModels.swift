import Foundation

nonisolated struct ProjectMapSnapshot: Codable, Equatable, Sendable {
    var id = UUID().uuidString
    var name: String
    var rootPath: String
    var bookmark: Data?
    var baseURL = "http://localhost:3000"
    /// The live web server backing the imported routes. Optional keeps
    /// documents created before server groups were introduced decodable.
    var webSource: ProjectWebSource?
    var catalogURL: String?
    var scannedAt = Date()
    var framework: String
    var routes: [ProjectRoute] = []
    var components: [ProjectComponent] = []
    var tokens: [ProjectToken] = []
    var warnings: [String] = []

    /// Older documents already carry enough information to show and monitor
    /// their server. Give them a stable derived id until the next edit saves
    /// an explicit source.
    var effectiveWebSource: ProjectWebSource {
        webSource ?? ProjectWebSource(
            id: "project-\(id)",
            name: name.isEmpty ? "Web project" : name,
            address: baseURL
        )
    }
}
nonisolated struct ProjectWebSource: Codable, Equatable, Sendable {
    var id = UUID().uuidString
    var name: String
    var address: String
}
nonisolated struct ProjectRoute: Codable, Equatable, Sendable {
    var path: String
    var source: String
    var dynamic: Bool
    var examplePath: String = ""
    var selected = false
    var frameID: String?
    var missing = false
    var links: [String] = []
    var concretePath: String? { dynamic ? (examplePath.isEmpty ? nil : examplePath) : path }
}
nonisolated struct ProjectComponent: Codable, Equatable, Sendable {
    var name: String
    var source: String
    var line: Int
    var pages: [String]
}
nonisolated struct ProjectToken: Codable, Equatable, Sendable {
    var name: String
    var value: String
    var source: String
    var line: Int
}
