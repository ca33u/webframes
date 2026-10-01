import Foundation

struct AstraCodexConnection: Codable {
    let version: Int
    let url: String
    let token: String
    func validatedURL() throws -> URL {
        guard version == 1, let base = URL(string:url), base.scheme == "http", base.host == "127.0.0.1",
              base.port != nil, base.user == nil, base.password == nil, base.query == nil,
              base.fragment == nil, ["", "/"].contains(base.path), token.count == 64,
              token.allSatisfy({ $0.isHexDigit }) else {
            throw AstraError.message("This is not a valid local \(AgentProvider.current.name) connector file.")
        }
        return base
    }
}

@MainActor
final class AstraCodexClient {
    private let connection: AstraCodexConnection
    private let base: URL
    private let session: URLSession
    private var jobID: String?
    /// What the last run sent: file count, size and paths, shown in review.
    private(set) var lastSnapshotSummary: String?
    init(connection: AstraCodexConnection) throws {
        self.connection = connection; base = try connection.validatedURL()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        session = URLSession(configuration:config)
    }
    private func request(_ path: String, method: String = "GET", body: [String:Any]? = nil) async throws -> [String:Any] {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(connection.token)",forHTTPHeaderField:"Authorization")
        if let body {
            request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject:body)
        }
        let (data,response) = try await session.data(for:request)
        guard let http = response as? HTTPURLResponse, let json = try JSONSerialization.jsonObject(with:data) as? [String:Any] else {
            throw AstraError.message("Invalid local \(AgentProvider.current.name) response.")
        }
        guard (200..<300).contains(http.statusCode) else { throw AstraError.message(json["error"] as? String ?? "Reconnect the local \(AgentProvider.current.name) connector.") }
        return json
    }
    func health() async throws {
        let result = try await request("health")
        guard let features = result["features"] as? [String], features.contains("fix-comments") else {
            throw AstraError.message("Restart the Web Frames \(AgentProvider.current.name) connector, then connect again.")
        }
    }
    func cancel() async {
        guard let id = jobID else { return }
        await cancelJob(id)
    }
    private func cancelJob(_ id:String) async {
        // A delayed cancellation of an old run must never cancel or clear a newer run.
        if jobID == id { jobID = nil }
        _ = try? await request("jobs/\(id)",method:"DELETE")
    }
    private func run(_ body:[String:Any],artifacts:AstraRunArtifacts,progress:(String)->Void) async throws -> Data {
        let started = try await request("jobs",method:"POST",body:body)
        guard let id = started["id"] as? String, UUID(uuidString:id) != nil else { throw AstraError.message("\(AgentProvider.current.name) did not start a run.") }
        jobID = id
        artifacts.event("codex_started",detail:"job=\(id) model=gpt-6-astra auth=saved-sign-in")
        do {
            let deadline = Date().addingTimeInterval(315)
            while Date() < deadline {
                try Task.checkCancellation()
                let status = try await request("jobs/\(id)")
                progress(status["stage"] as? String ?? "Working with \(AgentProvider.current.name)…")
                switch status["status"] as? String {
                case "completed":
                    guard let result = status["result"] else { throw AstraError.message("\(AgentProvider.current.name) returned no result.") }
                    let data = try JSONSerialization.data(withJSONObject:result)
                    guard data.count <= 150_000 else { throw AstraError.message("\(AgentProvider.current.name) result is too large.") }
                    jobID = nil; artifacts.event("codex_completed",detail:id); return data
                case "failed", "cancelled": throw AstraError.message(status["error"] as? String ?? "\(AgentProvider.current.name) run was cancelled.")
                default: break
                }
                try await Task.sleep(for:.milliseconds(700))
            }
            throw AstraError.message("\(AgentProvider.current.name) reached the five-minute limit.")
        } catch {
            Task { await self.cancelJob(id) }
            throw error
        }
    }
    private func sourceSnapshot(_ workspace:AstraWorkspace,includeJSON:Bool, maxBytes:Int = 512_000) throws -> [[String:Any]] {
        var files:[[String:Any]] = []; var size = 0
        for path in workspace.files() where includeJSON || !path.hasSuffix(".json") {
            let source = try workspace.read(path); size += source.text.utf8.count
            guard size <= maxBytes else { throw AstraError.message("Choose a smaller source folder. This operation supports up to \(maxBytes / 1_000) KB of selected code.") }
            files.append(["path":path,"content":source.text,"hash":source.hash])
        }
        guard !files.isEmpty else { throw AstraError.message("No supported source files were found in this project.") }
        let paths = files.compactMap { $0["path"] as? String }
        let kilobytes = max(1, size / 1_000)
        lastSnapshotSummary = "Sent to \(AgentProvider.current.name): \(paths.count) source file(s), \(kilobytes) KB. Credential-like and hidden files are excluded.\n"
            + paths.joined(separator: "\n")
        return files
    }
    func analyze(reference:AstraCapture,actual:AstraCapture,workspace:AstraWorkspace,
                 artifacts:AstraRunArtifacts,progress:(String)->Void) async throws -> AstraProposal {
        let files = try sourceSnapshot(workspace,includeJSON:false)
        let data = try await run(["kind":"analyze","images":[reference.dataURL,actual.dataURL],
            "dom":actual.contextText,"files":files],artifacts:artifacts,progress:progress)
        let proposal = try JSONDecoder().decode(AstraProposal.self,from:data)
        guard files.contains(where:{ $0["path"] as? String == proposal.path && $0["hash"] as? String == proposal.beforeHash }) else {
            throw AstraError.message("Proposal does not match the selected source snapshot.")
        }
        try artifacts.save(proposal,name:"proposal.json")
        return proposal
    }
    func verify(reference:AstraCapture,before:AstraCapture,after:AstraCapture,proposal:AstraProposal,
                artifacts:AstraRunArtifacts,progress:(String)->Void) async throws -> AstraVerification {
        let findings = try JSONSerialization.jsonObject(with:JSONEncoder().encode(proposal.findings))
        let data = try await run(["kind":"verify","images":[reference.dataURL,before.dataURL,after.dataURL],
            "dom":after.contextText,"findings":findings],artifacts:artifacts,progress:progress)
        let result = try JSONDecoder().decode(AstraVerification.self,from:data)
        guard result.checks.count == proposal.findings.count, Set(result.checks.map(\.id)) == Set(proposal.findings.map(\.id)),
              result.checks.allSatisfy({ ["verified","unresolved","inconclusive"].contains($0.status) }) else {
            throw AstraError.message("Verification did not cover every finding.")
        }
        try artifacts.save(result,name:"verification.json"); return result
    }

    func fixComments(_ comments:[CodexCommentContext],images:[String],workspace:AstraWorkspace,
                     artifacts:AstraRunArtifacts,progress:(String)->Void) async throws -> CodexCommentFixProposal {
        guard !comments.isEmpty else { throw AstraError.message("There are no open comments to fix.") }
        let files = try sourceSnapshot(workspace,includeJSON:true,maxBytes:2_000_000)
        progress("Sending \(files.count) source file(s) to \(AgentProvider.current.name)…")
        try artifacts.save(files.map { ["path": $0["path"] as? String ?? "", "hash": $0["hash"] as? String ?? ""] }, name: "codex-snapshot-files.json")
        let commentData = try JSONEncoder().encode(comments)
        guard let commentObjects = try JSONSerialization.jsonObject(with:commentData) as? [[String:Any]] else {
            throw AstraError.message("Comments could not be prepared for \(AgentProvider.current.name).")
        }
        let data = try await run([
            "kind":"fix-comments", "images":images, "comments":commentObjects, "files":files,
        ],artifacts:artifacts,progress:progress)
        let proposal = try JSONDecoder().decode(CodexCommentFixProposal.self,from:data)
        try artifacts.save(proposal,name:"comment-fix-proposal.json")
        return proposal
    }
}
