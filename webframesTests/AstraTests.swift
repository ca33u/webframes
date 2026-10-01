import Testing
import Foundation
import AppKit
import WebKit
@testable import Web_Frames

@Suite("Astra source and approval boundaries")
@MainActor
struct AstraTests {
    func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    func proposal(_ workspace:AstraWorkspace,old:String = ".grid { width: 1400px; }",new:String = ".grid { width: 100%; }") throws -> AstraProposal {
        AstraProposal(summary:"Fix overflow",findings:[AstraFinding(id:"overflow",selector:".grid",mismatch:"Overflows viewport",expected:"Fits viewport")],path:"styles.css",beforeHash:try workspace.read("styles.css").hash,edits:[AstraEdit(oldText:old,newText:new)])
    }
    @Test func approvalStalenessAndUndo() throws {
        let root = try temporary();defer {try? FileManager.default.removeItem(at:root)}
        let file = root.appendingPathComponent("styles.css")
        let original = Data(".grid { width: 1400px; }".utf8)
        try original.write(to:file)
        let workspace = try AstraWorkspace(root:root),service = AstraPatchService()
        let patch = try service.prepare(proposal(workspace),workspace:workspace)
        #expect(try Data(contentsOf:file) == original)
        #expect(throws:(any Error).self) {try service.apply(patch,approvedID:UUID(),workspace:workspace,artifacts:root)}
        #expect(try Data(contentsOf:file) == original)
        try service.apply(patch,approvedID:patch.id,workspace:workspace,artifacts:root)
        #expect(try workspace.read("styles.css").hash == patch.afterHash)
        #expect(throws:(any Error).self) {try service.apply(patch,approvedID:patch.id,workspace:workspace,artifacts:root)}
        try Data(".grid { width: 92%; }".utf8).write(to:file)
        #expect(throws:(any Error).self) {try service.undo(workspace:workspace)}
        #expect(try String(contentsOf:file,encoding:.utf8) == ".grid { width: 92%; }")
        try patch.after.write(to:file);try service.undo(workspace:workspace)
        #expect(try Data(contentsOf:file) == original)
        #expect(service.applied == nil)
    }
    @Test func stalePatchNeverWrites() throws {
        let root = try temporary();defer {try? FileManager.default.removeItem(at:root)}
        let file = root.appendingPathComponent("styles.css")
        try Data(".grid { width: 1400px; }".utf8).write(to:file)
        let workspace = try AstraWorkspace(root:root),service = AstraPatchService()
        let patch = try service.prepare(proposal(workspace),workspace:workspace)
        let userEdit = Data(".grid { width: 90%; }".utf8);try userEdit.write(to:file)
        #expect(throws:(any Error).self) {try service.apply(patch,approvedID:patch.id,workspace:workspace,artifacts:root)}
        #expect(try Data(contentsOf:file) == userEdit)
    }
    @Test func reviewedCommentFixAppliesMultipleFilesAndUndoes() throws {
        let root = try temporary();defer {try? FileManager.default.removeItem(at:root)}
        let css = root.appendingPathComponent("styles.css")
        let component = root.appendingPathComponent("Card.tsx")
        try Data(".card { width: 420px; }".utf8).write(to:css)
        try Data("export const Card = () => <div className=\"card\">Old</div>".utf8).write(to:component)
        let workspace = try AstraWorkspace(root:root)
        let proposal = CodexCommentFixProposal(
            summary:"Make the card fluid and update its label",
            addressedCommentIDs:["comment-1"],
            files:[
                CodexFixFileProposal(path:"styles.css",beforeHash:try workspace.read("styles.css").hash,
                                     edits:[AstraEdit(oldText:"width: 420px",newText:"width: 100%")]),
                CodexFixFileProposal(path:"Card.tsx",beforeHash:try workspace.read("Card.tsx").hash,
                                     edits:[AstraEdit(oldText:">Old<",newText:">Current<")]),
            ]
        )
        let service = CodexCommentFixService()
        let patch = try service.prepare(proposal,allowedCommentIDs:["comment-1"],workspace:workspace)
        #expect(try String(contentsOf:css,encoding:.utf8).contains("420px"))
        #expect(throws:(any Error).self) {
            try service.apply(patch,approvedID:UUID(),workspace:workspace,artifacts:root)
        }
        try service.apply(patch,approvedID:patch.id,workspace:workspace,artifacts:root)
        #expect(try String(contentsOf:css,encoding:.utf8).contains("100%"))
        #expect(try String(contentsOf:component,encoding:.utf8).contains("Current"))
        try service.undo(workspace:workspace)
        #expect(try String(contentsOf:css,encoding:.utf8).contains("420px"))
        #expect(try String(contentsOf:component,encoding:.utf8).contains("Old"))
    }

    @Test func commentFixRejectsUnknownCommentAndStaleSource() throws {
        let root = try temporary();defer {try? FileManager.default.removeItem(at:root)}
        let file = root.appendingPathComponent("app.tsx")
        try Data("const title = 'Old'".utf8).write(to:file)
        let workspace = try AstraWorkspace(root:root)
        let proposal = CodexCommentFixProposal(
            summary:"Update title",addressedCommentIDs:["unknown"],
            files:[CodexFixFileProposal(path:"app.tsx",beforeHash:try workspace.read("app.tsx").hash,
                                        edits:[AstraEdit(oldText:"'Old'",newText:"'New'")])]
        )
        let service = CodexCommentFixService()
        #expect(throws:(any Error).self) {
            _ = try service.prepare(proposal,allowedCommentIDs:["comment-1"],workspace:workspace)
        }
        let allowed = CodexCommentFixProposal(summary:proposal.summary,addressedCommentIDs:["comment-1"],files:proposal.files)
        let patch = try service.prepare(allowed,allowedCommentIDs:["comment-1"],workspace:workspace)
        try Data("const title = 'User edit'".utf8).write(to:file)
        #expect(throws:(any Error).self) {
            try service.apply(patch,approvedID:patch.id,workspace:workspace,artifacts:root)
        }
        #expect(try String(contentsOf:file,encoding:.utf8).contains("User edit"))
    }

    @Test func commentContextIncludesAtMostFiveScreenshots() {
        let png = "data:image/png;base64,iVBORw0KGgo="
        let annotations = (0..<7).map { index in
            AnnotationModel(id:"a\(index)",num:index+1,frameId:"f",xPct:0.5,yPct:0.5,
                            color:"blue",comment:"Comment \(index)",resolved:false,edits:[:],
                            extras:["element":.object(["path":.string(".card"),"screenshot":.string(png)])])
        }
        let frame = FrameModel(id:"f",url:"http://localhost:3000",label:"Home",x:0,y:0,w:1280,h:800,num:1,isImage:false,filePath:nil)
        let context = CodexCommentContextBuilder.make(annotations:annotations,frames:[frame])
        #expect(context.comments.count == 7)
        #expect(context.images.count == 5)
        #expect(context.comments[4].screenshotIndex == 4)
        #expect(context.comments[5].screenshotIndex == nil)
    }

    @Test func screenshotCommentsShareFullFrameImageAndKeepTheirLocations() {
        let png = "data:image/png;base64,iVBORw0KGgo="
        let frame = FrameModel(id:"image",url:"image://settings",label:"Settings",x:0,y:0,w:390,h:844,num:1,isImage:true,filePath:nil)
        let comments = (0..<2).map { i in
            AnnotationModel(id:"a\(i)",num:i+1,frameId:"image",xPct:0.25,yPct:0.75,color:"blue",comment:"Fix label",resolved:false,edits:[:])
        }
        let result = CodexCommentContextBuilder.make(annotations:comments,frames:[frame],projectName:"Pala",frameScreenshots:["image":png])
        #expect(result.images == [png])
        #expect(result.comments.allSatisfy { $0.screenshotIndex == 0 && $0.projectName == "Pala" && $0.xPct == 0.25 && $0.yPct == 0.75 })
    }

    @Test func sourceBindingSurvivesPayloadRoundTrip() throws {
        var payload = DocumentPayload.empty
        payload.fixSource = FixSourceReference(path:"/project/Palo",bookmark:Data([1,2,3]))
        let loaded = try JSONDecoder().decode(DocumentPayload.self,from:JSONEncoder().encode(payload))
        #expect(loaded.fixSource == payload.fixSource)
        #expect(DocumentPayload(fromDictionary:payload.asDictionary).fixSource == payload.fixSource)
        #expect(try JSONDecoder().decode(DocumentPayload.self,from:JSONEncoder().encode(DocumentPayload.empty)).fixSource == nil)
    }

    @Test func commentFixEvidenceTargetsAreUniqueLiveFramesInCanvasOrder() {
        let frames = [
            FrameModel(id:"web-2",url:"http://localhost:3000/settings",label:"Settings",x:0,y:0,w:1280,h:800,num:2,isImage:false,filePath:nil),
            FrameModel(id:"reference",url:"image://reference",label:"Reference",x:0,y:0,w:1280,h:800,num:1,isImage:true,filePath:nil),
            FrameModel(id:"web-1",url:"http://localhost:3000",label:"Home",x:0,y:0,w:1280,h:800,num:3,isImage:false,filePath:nil),
        ]
        let annotations = [
            AnnotationModel(id:"a1",num:1,frameId:"web-1",xPct:0.5,yPct:0.5,color:"orange",comment:"One",resolved:false,edits:[:]),
            AnnotationModel(id:"a2",num:2,frameId:"web-1",xPct:0.6,yPct:0.6,color:"orange",comment:"Two",resolved:false,edits:[:]),
            AnnotationModel(id:"a3",num:3,frameId:"reference",xPct:0.4,yPct:0.4,color:"orange",comment:"Static",resolved:false,edits:[:]),
            AnnotationModel(id:"a4",num:4,frameId:"web-2",xPct:0.4,yPct:0.4,color:"orange",comment:"Not addressed",resolved:false,edits:[:]),
        ]
        let patch = CodexCommentFixPatch(id:UUID(),summary:"Fix",addressedCommentIDs:["a2","a1","a3"],entries:[])
        let targets = CodexCommentFixEvidencePlanner.targets(for:patch,annotations:annotations,frames:frames)
        #expect(targets == [CodexCommentFixEvidenceTarget(frameID:"web-1",label:"Home")])
    }
    @Test func scopeAndAmbiguousEdits() throws {
        let root = try temporary(),outside = try temporary()
        defer {try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:outside)}
        try Data("secret".utf8).write(to:outside.appendingPathComponent("private.css"))
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("link.css"),withDestinationURL:outside.appendingPathComponent("private.css"))
        try Data(".grid { width: 1400px; }\n.grid { width: 1400px; }".utf8).write(to:root.appendingPathComponent("styles.css"))
        try Data("const x=1".utf8).write(to:root.appendingPathComponent("app.js"))
        let workspace = try AstraWorkspace(root:root)
        for path in ["../private.css","/etc/passwd","link.css",".env",".git/config","foo/../styles.css"] {
            #expect(throws:(any Error).self) {_ = try workspace.resolve(path)}
        }
        #expect(throws:(any Error).self) {_ = try workspace.resolve("app.js",writing:true)}
        #expect(throws:(any Error).self) {_ = try AstraPatchService().prepare(proposal(workspace),workspace:workspace)}
    }
    @Test func pairingRejectsRemoteEndpoints() throws {
        let token = String(repeating:"a",count:64)
        #expect(throws:(any Error).self) {_ = try AstraCodexConnection(version:1,url:"http://example.com:1234",token:token).validatedURL()}
        #expect(throws:(any Error).self) {_ = try AstraCodexConnection(version:1,url:"http://127.0.0.1:1234/evil",token:token).validatedURL()}
        #expect(try AstraCodexConnection(version:1,url:"http://127.0.0.1:1234",token:token).validatedURL().host == "127.0.0.1")
    }

    @Test func canvasPairSelectionAndRemoval() {
        let document = makeTestDocument()
        for (index, id) in ["reference","implementation","third"].enumerated() {
            _ = document.workspace.createFrame(FrameModel(id:id,url:"image://\(id)",label:id,x:CGFloat(index*1400),y:0,w:1280,h:800,num:index+1,isImage:true,filePath:nil))
        }
        let host = CanvasHost(document:document)
        var changes = 0
        host.onFrameSelectionChanged = {changes += 1}
        host.selectFrame("reference",additive:false)
        host.selectFrame("implementation",additive:true)
        #expect(host.selectedFrameIDs == ["reference","implementation"])
        #expect(host.selectedFrameId == "implementation")
        #expect(changes == 2)
        // Shift/⌘-click on a selected frame removes it; the same mouse event
        // reported twice (window monitor + card) is deduplicated in selectFrame(_:).
        host.selectFrame("implementation",additive:true)
        #expect(host.selectedFrameIDs == ["reference"])
        host.selectFrame("implementation",additive:true)
        host.selectFrame("third",additive:true)
        #expect(host.selectedFrameIDs == ["reference","implementation","third"])
        // Unknown ids never enter the selection.
        host.selectFrame("missing",additive:true)
        #expect(host.selectedFrameIDs == ["reference","implementation","third"])
        host.closeFrame(id:"third")
        #expect(host.selectedFrameIDs == ["reference","implementation"])
        host.clearFrameSelectionIfNeeded()
        #expect(host.selectedFrameIDs.isEmpty)
        #expect(host.selectedFrameId == nil)
    }

    @Test func realLocalhostCaptureApplyReloadUndo() async throws {
        let root = try AstraDemoFixture.create();defer {try? FileManager.default.removeItem(at:root)}
        let server = AstraDemoServer(root:root);defer {server.stop()}
        let url = try await server.start()
        let web = WKWebView(frame:NSRect(x:0,y:0,width:1280,height:800))
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:800),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = web;window.orderFront(nil);defer {window.orderOut(nil);web.stopLoading()}
        web.load(URLRequest(url:url))
        let capture = AstraCaptureService()
        let good = try await capture.capture(web)
        #expect(AstraDemoFixture.check(good).isEmpty)
        var rounded = good.context; rounded["timeOrigin"] = (good.context["timeOrigin"] as? Double ?? 0) + 1
        let timerOnly = AstraCapture(id:UUID(),image:good.image,png:good.png,context:rounded)
        #expect(good.matchesPageState(of:timerOnly))
        let samePage = try await capture.capture(web)
        #expect(good.matchesPageState(of:samePage))
        // Page scripts cannot forge or see the isolated navigation identity.
        let isolated = try await web.evaluateJavaScript("typeof globalThis.__webFramesAstraDocumentID") as? String
        #expect(isolated == "undefined")
        try Data(AstraDemoFixture.brokenCSS.utf8).write(to:root.appendingPathComponent("styles.css"),options:.atomic)
        try await capture.reload(web)
        let before = try await capture.capture(web)
        #expect(AstraDemoFixture.check(before).count == 4)
        #expect(before.png != good.png)
        let workspace = try AstraWorkspace(root:root),service = AstraPatchService()
        // An explicit fixture patch tests the native path, not the model's ability.
        let patch = try service.prepare(proposal(workspace,old:AstraDemoFixture.brokenCSS,new:AstraDemoFixture.goodCSS),workspace:workspace)
        try service.apply(patch,approvedID:patch.id,workspace:workspace,artifacts:root)
        try await capture.reload(web)
        let after = try await capture.capture(web)
        #expect(AstraDemoFixture.check(after).isEmpty)
        #expect(!after.matchesPageState(of:before))
        #expect(after.context["documentID"] as? String != before.context["documentID"] as? String)
        let clicked = try await web.evaluateJavaScript("document.getElementById('report-button').click();document.getElementById('report-status').textContent") as? String
        #expect(clicked == "Report is ready")
        try service.undo(workspace:workspace)
        #expect(try workspace.read("styles.css").text == AstraDemoFixture.brokenCSS)
    }
}
