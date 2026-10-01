import AppKit
import Network

@MainActor
final class AstraDemoServer {
    let root: URL
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    init(root: URL) { self.root = root }
    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            var done = false
            let finish: (Result<URL, Error>) -> Void = { result in
                guard !done else { return }; done = true; continuation.resume(with: result)
            }
            listener.stateUpdateHandler = { state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready:
                        guard let port = listener.port else { return }
                        finish(.success(URL(string: "http://127.0.0.1:\(port.rawValue)/index.html")!))
                    case .failed(let error): finish(.failure(error))
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                if !done { listener.cancel(); finish(.failure(AstraError.message("Local demo server could not start."))) }
            }
        }
    }
    func stop() { listener?.cancel(); listener = nil; connections.values.forEach { $0.cancel() }; connections.removeAll() }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        let id = UUID(); connections[id] = connection
        connection.start(queue: .main)
        receive(connection, id: id, buffer: Data())
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            connection.cancel(); self?.connections.removeValue(forKey: id)
        }
    }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                var bytes = buffer; if let data { bytes.append(data) }
                guard bytes.count <= 8192, error == nil else { connection.cancel(); self.connections.removeValue(forKey: id); return }
                guard let request = String(data: bytes, encoding: .utf8), request.contains("\r\n\r\n") else {
                    if complete { connection.cancel(); self.connections.removeValue(forKey: id) }
                    else { self.receive(connection, id: id, buffer: bytes) }; return
                }
                let parts = request.components(separatedBy: "\r\n")[0].split(separator: " ")
                let resource = parts.count >= 2 ? String(parts[1]).components(separatedBy:"?")[0] : ""
                let allowed = ["/index.html":"text/html; charset=utf-8", "/styles.css":"text/css; charset=utf-8", "/app.js":"text/javascript; charset=utf-8"]
                let file = self.root.appendingPathComponent(String(resource.dropFirst()))
                let good = parts.first == "GET" && allowed[resource] != nil
                let body = good ? (try? Data(contentsOf: file)) : nil
                let payload = body ?? Data("Not found".utf8)
                var response = Data("HTTP/1.1 \(body == nil ? "404 Not Found" : "200 OK")\r\nContent-Type: \(allowed[resource] ?? "text/plain")\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
                response.append(payload)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                self.connections.removeValue(forKey:id)
            }
        }
    }
}

enum AstraDemoFixture {
    static let html = #"""
    <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="styles.css"><title>Northstar · Overview</title></head><body>
    <header><div class="brand">✳ Northstar</div><nav>Overview <span>Customers</span> <span>Reports</span></nav><div class="avatar">ES</div></header>
    <main><section class="heading"><div><p class="eyebrow">YOUR WORKSPACE / SEPTEMBER 2026</p><h1>Good morning, Alex</h1><p class="subtitle">Here’s how your business is doing this month.</p></div><button id="report-button">↓ Export report</button></section>
    <section class="metrics" data-testid="metrics"><article class="card"><p>Total revenue</p><h2>$48,250</h2><small>↗ 12.8% vs. last month</small></article><article class="card"><p>Active customers</p><h2>1,284</h2><small>↗ 8.2% vs. last month</small></article><article class="card"><p>Conversion rate</p><h2>4.86%</h2><small>↗ 1.4% vs. last month</small></article></section>
    <section class="activity"><div class="section-title"><h2>Recent activity</h2><span>View all →</span></div><div class="row"><b>Acme Studio</b><span>Pro subscription</span><strong>$249.00</strong><em>Completed</em></div><div class="row"><b>Orbit Design</b><span>Team subscription</span><strong>$499.00</strong><em>Completed</em></div><div class="row"><b>Forma Labs</b><span>Pro subscription</span><strong>$249.00</strong><em>Completed</em></div></section>
    <p id="report-status" role="status">All systems operational · Updated September 16</p></main><script src="app.js"></script></body></html>
    """#
    static let goodCSS = """
    * { box-sizing: border-box; }
    body { margin: 0; background: #f7f8fc; color: #172033; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
    header { height: 88px; padding: 0 48px; display: flex; align-items: center; border-bottom: 1px solid #e6e8ef; background: white; gap: 80px; }
    .brand { font-size: 22px; font-weight: 750; letter-spacing: -.7px; }
    nav { font-size: 14px; color: #6555da; display: flex; gap: 32px; }
    nav span { color: #7b8192; }
    .avatar { margin-left: auto; border-radius: 50%; background: #eeeafe; color: #6555da; padding: 12px; font-size: 13px; font-weight: 650; }
    main { padding: 42px 48px; }
    .heading { display: flex; justify-content: space-between; align-items: center; margin-bottom: 34px; }
    .eyebrow { color: #868c9d; font-size: 10px; font-weight: 650; letter-spacing: 1.6px; margin: 0 0 12px; }
    h1 { font-size: 36px; line-height: 1.2; letter-spacing: -1px; margin: 0 0 12px; }
    .subtitle { font-size: 14px; color: #7b8192; margin: 0; }
    button { background: #6855de; color: white; border: 0; border-radius: 10px; padding: 15px 22px; font-size: 14px; font-weight: 600; cursor: pointer; }
    .metrics { display: grid; grid-template-columns: repeat(3, 1fr); gap: 22px; margin-bottom: 32px; }
    .card { background: white; border: 1px solid #e6e8ef; border-radius: 14px; padding: 26px; }
    .card p { margin: 0 0 16px; color: #7b8192; font-size: 13px; }
    .card h2 { font-size: 32px; letter-spacing: -1px; margin: 0 0 14px; }
    small { color: #248268; font-size: 11px; }
    .activity { padding: 12px 26px; background: white; border: 1px solid #e6e8ef; border-radius: 14px; }
    .section-title { display: flex; align-items: center; justify-content: space-between; padding: 8px 0; }
    .section-title h2 { font-size: 17px; } .section-title span { font-size: 12px; color: #6855de; }
    .row { padding: 23px 0; border-top: 1px solid #edf0f6; display: grid; grid-template-columns: 2fr 2fr 1fr 1fr; align-items: center; font-size: 12px; }
    .row span { color: #868c9d; } .row em { justify-self: end; font-style: normal; color: #248268; background: #edf8f1; border-radius: 6px; padding: 6px 10px; font-size: 10px; }
    #report-status { text-align: center; color: #9299a8; font-size: 10px; margin-top: 30px; }
    """
    static var brokenCSS: String {
        goodCSS.replacingOccurrences(of: "grid-template-columns: repeat(3, 1fr)", with: "grid-template-columns: repeat(3, 420px)")
            .replacingOccurrences(of: "h1 { font-size: 36px; line-height: 1.2", with: "h1 { font-size: 18px; line-height: 1.8")
            .replacingOccurrences(of: "background: #6855de; color: white", with: "background: #e4e6ee; color: #777f90")
    }
    static let js = "document.getElementById('report-button').addEventListener('click',()=>{document.getElementById('report-status').textContent='Report is ready';});"

    static func create() throws -> URL {
        let parent = try EvidenceStore.privateDirectory(EvidenceStore.sampleDirectory)
        // Each sample run gets a fresh folder; earlier ones are never read
        // again, so drop them instead of accumulating copies.
        for old in (try? FileManager.default.contentsOfDirectory(at:parent,includingPropertiesForKeys:nil)) ?? [] {
            try? FileManager.default.removeItem(at:old)
        }
        let root = parent.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try Data(html.utf8).write(to:root.appendingPathComponent("index.html"),options:.atomic)
        try Data(goodCSS.utf8).write(to:root.appendingPathComponent("styles.css"),options:.atomic)
        try Data(js.utf8).write(to:root.appendingPathComponent("app.js"),options:.atomic)
        return root
    }
    // Independent fixture checks; these expected values are never sent to Astra.
    static func check(_ capture: AstraCapture) -> [String] {
        var failures: [String] = []
        let elements = capture.context["elements"] as? [[String:Any]] ?? []
        if (capture.context["documentWidth"] as? Int ?? Int.max) > capture.width + 1 { failures.append("Horizontal overflow remains") }
        let cards = elements.filter { ($0["className"] as? String) == "card" }
        if cards.count != 3 || cards.contains(where: { ($0["width"] as? Double ?? 0) > 400 }) { failures.append("Card layout is not restored") }
        let title = elements.first { $0["tag"] as? String == "H1" }
        if (title?["styles"] as? [String:Any])?["fontSize"] as? String != "36px" { failures.append("Heading hierarchy is not restored") }
        let button = elements.first { $0["selector"] as? String == "#report-button" }
        if (button?["styles"] as? [String:Any])?["backgroundColor"] as? String != "rgb(104, 85, 222)" { failures.append("CTA styling is not restored") }
        return failures
    }
}
