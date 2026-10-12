import AppKit
import Testing
import WebKit
@testable import Web_Frames

/// The live test is opt-in: ordinary regression runs never spend an agent call.
@Suite("WF-02 scenario", .serialized) @MainActor struct WF02ScenarioTests {
    func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wf02-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func startClient(at root: URL) async throws -> (Process, AstraCodexClient) {
        let bridgeRoot = root.appendingPathComponent("connector"), bridge = Process()
        bridge.executableURL = try BundledTools.node(); bridge.arguments = [try BundledTools.script("codex-bridge.mjs").path]
        bridge.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin",
            "WEBFRAMES_BRIDGE_ROOT": bridgeRoot.path, "WEBFRAMES_CODEX_BINARY": try BundledTools.codex().path]
        bridge.standardInput = FileHandle.nullDevice; bridge.standardOutput = FileHandle.nullDevice; bridge.standardError = FileHandle.nullDevice
        try bridge.run()
        do {
            let connectionFile = bridgeRoot.appendingPathComponent("connection.json")
            for _ in 0..<100 {
                if FileManager.default.fileExists(atPath: connectionFile.path) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let connection = try JSONDecoder().decode(AstraCodexConnection.self, from: Data(contentsOf: connectionFile))
            let client = try AstraCodexClient(connection: connection); try await client.health()
            return (bridge, client)
        } catch { if bridge.isRunning { bridge.terminate() }; throw error }
    }

    @Test func pngPasteUndoRedoAndPackageReopen() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        // Keep managed test files until the host exits: NSDocument can queue
        // an autosave check after close, as in the existing image MCP tests.
        let doc = makeTestDocument(); defer { doc.updateChangeCount(.changeCleared); doc.close() }
        let undo = try #require(doc.undoManager); undo.groupsByEvent = false
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<16 { for y in 0..<16 { bitmap.setColor(.systemGreen, atX: x, y: y) } }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        board.setData(png, forType: .png)
        let host = CanvasHost(document: doc)
        #expect(host.pasteImageFrames(from: board))
        let frame = try #require(doc.workspace.frames.first)
        #expect(frame.isImage && doc.workspace.frames.count == 1)
        undo.undo(); #expect(doc.workspace.frames.isEmpty)
        undo.redo(); #expect(doc.workspace.frames.first?.id == frame.id)
        let reopened = makeTestDocument(); defer { reopened.updateChangeCount(.changeCleared); reopened.close() }
        try reopened.read(from: doc.fileWrapper(ofType: WebFramesDocument.fileTypeIdentifier), ofType: WebFramesDocument.fileTypeIdentifier)
        #expect(reopened.workspace.frames.first?.isImage == true)
        #expect(reopened.workspace.frames.first?.id == frame.id)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WEBFRAMES_LIVE_AGENT_SMOKE"] == "1"))
    func screenshotSourceRealAgentReviewApplyAndUndo() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let html = #"<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="styles.css"><title>WF02 Screenshot QA</title></head><body><h1>Release checklist</h1><p>Disposable screenshot source</p><button id="save" class="primary" onclick="document.querySelector('#status').textContent='Saved locally'">Save checklist</button><p id="status">No changes saved</p></body></html>"#
        let css = "body { margin: 32px; background: #f5f5f3; color: #202822; font: 16px system-ui; }\n.primary { height: 28px; border: 0; border-radius: 2px; background: #b73535; color: white; padding: 0 16px; }\n"
        try Data(html.utf8).write(to: source.appendingPathComponent("index.html"))
        try Data(css.utf8).write(to: source.appendingPathComponent("styles.css"))
        let workspace = try AstraWorkspace(root: source)
        let server = AstraDemoServer(root: source); defer { server.stop() }
        let url = try await server.start()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web; window.orderFront(nil); defer { window.orderOut(nil); web.stopLoading() }
        web.load(URLRequest(url: url))
        let capture = AstraCaptureService(), before = try await capture.capture(web)
        let doc = makeTestDocument(); defer { doc.updateChangeCount(.changeCleared); doc.close() }
        let host = CanvasHost(document: doc), pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setData(before.png, forType: .png)
        #expect(host.pasteImageFrames(from: pasteboard))
        let image = try #require(doc.workspace.frames.first)
        let originalImage = image.extras["imgUrl"]
        doc.workspace.createAnnotation(AnnotationModel(id: "screenshot-comment", num: 1, frameId: image.id,
            xPct: 8, yPct: 18, color: "blue",
            comment: "Make Save checklist green (#256b4b), 44px high, with an 8px radius. Preserve its label and click behavior.",
            resolved: false, edits: [:]))
        #expect(doc.resolvedFixSource() == nil)
        doc.setFixSource(source)
        let reopened = makeTestDocument(); defer { reopened.updateChangeCount(.changeCleared); reopened.close() }
        try reopened.read(from: doc.fileWrapper(ofType: WebFramesDocument.fileTypeIdentifier), ofType: WebFramesDocument.fileTypeIdentifier)
        #expect(reopened.resolvedFixSource()?.standardizedFileURL.resolvingSymlinksInPath() == source.standardizedFileURL.resolvingSymlinksInPath())
        let screenshots = try CodexCommentImages.make(frames: reopened.workspace.frames)
        let context = CodexCommentContextBuilder.make(annotations: reopened.workspace.annotations, frames: reopened.workspace.frames,
            projectName: "WF02 Screenshot QA", frameScreenshots: screenshots)
        #expect(context.images.count == 1 && context.comments.first?.screenshotIndex == 0)

        let (bridge, client) = try await startClient(at: root)
        defer { if bridge.isRunning { bridge.terminate() } }
        let artifacts = try AstraRunArtifacts()
        let proposal = try await client.fixComments(context.comments, images: context.images,
            workspace: workspace, artifacts: artifacts, progress: { _ in })
        let service = CodexCommentFixService()
        let patch = try service.prepare(proposal, allowedCommentIDs: ["screenshot-comment"], workspace: workspace)
        #expect(patch.entries.map(\.path) == ["styles.css"])
        #expect(patch.reviewText.contains("--- Before") && patch.reviewText.contains("+++ After"))
        #expect(try workspace.read("styles.css").text == css)
        try service.apply(patch, approvedID: patch.id, workspace: workspace, artifacts: artifacts.url)
        try await capture.reload(web)
        let after = try await capture.capture(web)
        let values = try await web.evaluateJavaScript("JSON.stringify((()=>{let s=getComputedStyle(document.querySelector('#save'));return {height:s.height,radius:s.borderRadius,color:s.backgroundColor}})())") as? String
        #expect(values?.contains("44px") == true && values?.contains("8px") == true && values?.contains("37, 107, 75") == true)
        #expect(before.png != after.png)
        #expect(try await web.evaluateJavaScript("document.querySelector('#save').click();document.querySelector('#status').textContent") as? String == "Saved locally")
        #expect(try workspace.read("index.html").text == html)
        #expect(reopened.workspace.frames.first?.extras["imgUrl"] == originalImage)
        #expect(reopened.workspace.annotations.first?.resolved == false)
        try service.undo(workspace: workspace); try await capture.reload(web)
        #expect(try workspace.read("styles.css").text == css)
        #expect(try workspace.read("index.html").text == html)
        let restoredHeight = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('#save')).height") as? String
        #expect(restoredHeight == "28px")
        try before.save(to: artifacts.url, name: "wf02-screenshot-before")
        try after.save(to: artifacts.url, name: "wf02-screenshot-after")
        try artifacts.save(["result": "passed", "scenario": "PNG paste, source binding, real agent, review, Apply, reload, Undo", "staticScreenshotPreserved": "true"], name: "wf02-result.json")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["WEBFRAMES_LIVE_AGENT_SMOKE"] == "1"))
    func realCompareReviewApplyVerifyAndUndo() async throws {
        let root = try AstraDemoFixture.create(); defer { try? FileManager.default.removeItem(at: root) }
        let server = AstraDemoServer(root: root); defer { server.stop() }
        let url = try await server.start()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = web; window.orderFront(nil); defer { window.orderOut(nil); web.stopLoading() }
        web.load(URLRequest(url: url))
        let capture = AstraCaptureService(), reference = try await capture.capture(web)
        let css = root.appendingPathComponent("styles.css")
        try Data(AstraDemoFixture.brokenCSS.utf8).write(to: css, options: .atomic)
        try await capture.reload(web)
        let before = try await capture.capture(web)
        #expect(AstraDemoFixture.check(before).count == 4)
        let (bridge, client) = try await startClient(at: root)
        defer { if bridge.isRunning { bridge.terminate() } }
        let workspace = try AstraWorkspace(root: root), artifacts = try AstraRunArtifacts()
        let proposal = try await client.analyze(reference: reference, actual: before, workspace: workspace,
            artifacts: artifacts, progress: { _ in })
        let service = AstraPatchService(), patch = try service.prepare(proposal, workspace: workspace)
        #expect(!proposal.findings.isEmpty && patch.reviewText.contains("Before"))
        #expect(try workspace.read("styles.css").text == AstraDemoFixture.brokenCSS)
        try service.apply(patch, approvedID: patch.id, workspace: workspace, artifacts: artifacts.url)
        try await capture.reload(web)
        let after = try await capture.capture(web)
        #expect(AstraDemoFixture.check(after).count < 4)
        let verification = try await client.verify(reference: reference, before: before, after: after,
            proposal: proposal, artifacts: artifacts, progress: { _ in })
        #expect(!verification.checks.isEmpty && verification.checks.allSatisfy { $0.status == "verified" })
        try service.undo(workspace: workspace); try await capture.reload(web)
        #expect(try workspace.read("styles.css").text == AstraDemoFixture.brokenCSS)
        let restored = try await capture.capture(web)
        #expect(AstraDemoFixture.check(restored).count == 4)
        try reference.save(to: artifacts.url, name: "wf02-compare-reference")
        try before.save(to: artifacts.url, name: "wf02-compare-before")
        try after.save(to: artifacts.url, name: "wf02-compare-after")
        try artifacts.save(["result": "passed", "scenario": "real Compare, review, Apply, agent verification, Undo"], name: "wf02-result.json")
    }
}
