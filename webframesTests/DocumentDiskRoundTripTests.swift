import AppKit
import Testing
@testable import Web_Frames

/// Opens a real file through NSDocumentController (without a window), saves
/// it back and reopens it: the path users actually take.
@Suite("Document disk round-trip") @MainActor struct DocumentDiskRoundTripTests {
    @Test func unknownFrameAndCommentFieldsSurviveOpenAndSave() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let url = folder.appendingPathComponent("From Future.webframes")
        let json = """
        {"version":1,"name":"From Future","nextNum":2,"annNext":2,"canvas":null,"links":[],
         "frames":[{"id":"f1","url":"https://example.com","label":"Home","x":0,"y":0,"w":1280,"h":800,"num":1,
                    "futureFrameField":{"kept":true}}],
         "annotations":[{"id":"a1","num":1,"frameId":"f1","xPct":10,"yPct":20,"color":"blue","comment":"Hi",
                         "resolved":false,"edits":{},"futureCommentField":"kept"}]}
        """
        try Data(json.utf8).write(to: url)

        let controller = NSDocumentController.shared
        let opened = try #require(try controller.makeDocument(withContentsOf: url, ofType: WebFramesDocument.fileTypeIdentifier) as? WebFramesDocument)
        #expect(opened.payload.name == "From Future")
        #expect(opened.workspace.frames.first?.label == "Home")

        let copy = folder.appendingPathComponent("Copy.webframes")
        try opened.data(ofType: WebFramesDocument.fileTypeIdentifier).write(to: copy)
        let reopened = try #require(try controller.makeDocument(withContentsOf: copy, ofType: WebFramesDocument.fileTypeIdentifier) as? WebFramesDocument)
        #expect(reopened.workspace.frames.first?.extras["futureFrameField"] == .object(["kept": .bool(true)]))
        #expect(reopened.workspace.annotations.first?.extras["futureCommentField"] == .string("kept"))
        #expect(reopened.workspace.annotations.first?.comment == "Hi")
    }

    @Test func filesFromANewerVersionAreRefusedWithAClearError() throws {
        let json = #"{"version":3,"name":"Future","frames":[],"annotations":[],"links":[],"canvas":null,"nextNum":1,"annNext":1}"#
        let document = makeTestDocument()
        do {
            try document.read(from: Data(json.utf8), ofType: WebFramesDocument.fileTypeIdentifier)
            Issue.record("a version 3 file must not open")
        } catch {
            #expect(error.localizedDescription.contains("newer version of Web Frames"))
        }
        #expect(document.payload.name == "Untitled")
    }

    @Test func unknownLinkAndCanvasFieldsSurvive() {
        let link = LinkModel(jsonValue: .object(["fromId": .string("a"), "toId": .string("b"), "style": .string("dashed")]))
        #expect(link?.jsonValue == .object(["id": .string("lna-b"), "fromId": .string("a"), "fromSide": .string(LinkSide.defaultFrom.rawValue),
                                            "toId": .string("b"), "toSide": .string(LinkSide.defaultTo.rawValue), "style": .string("dashed")]))
        let viewport = ViewportModel(jsonValue: .object(["scale": .number(1), "px": .number(0), "py": .number(0), "grid": .bool(false)]))
        guard case .object(let o) = viewport.panned(byX: 10, byY: 0).jsonValue else { Issue.record("not an object"); return }
        #expect(o["grid"] == .bool(false) && o["px"] == .number(10))
    }

    @Test func packagesStoreEachImageOnceAndReopenIdentically() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let pixels = Data((0..<4_000).map { UInt8($0 % 251) })
        let dataURL = "data:image/png;base64," + pixels.base64EncodedString()
        let document = makeTestDocument()
        _ = document.workspace.createFrame(FrameModel(id: "shot", url: "image://shot", label: "Shot", x: 0, y: 0, w: 390, h: 844,
                                                      num: 1, isImage: true, filePath: nil, extras: ["imgUrl": .string(dataURL)]))
        document.workspace.createAnnotation(AnnotationModel(id: "a1", num: 1, frameId: "shot", xPct: 10, yPct: 10, color: "blue",
                                                            comment: "Same pixels", resolved: false, edits: [:],
                                                            extras: ["element": .object(["screenshot": .string(dataURL)])]))

        let url = folder.appendingPathComponent("Shots.webframes")
        try document.fileWrapper(ofType: WebFramesDocument.fileTypeIdentifier).write(to: url, options: .atomic, originalContentsURL: nil)
        let images = try fm.contentsOfDirectory(atPath: url.appendingPathComponent("images").path)
        #expect(images.count == 1)   // frame image and comment screenshot share one file
        let json = try String(contentsOf: url.appendingPathComponent(DocumentPackage.documentName), encoding: .utf8)
        #expect(!json.contains("base64") && json.contains(#"wf-image:images\/"#))
        #expect(json.utf8.count < 4_000)

        let reopened = try #require(try NSDocumentController.shared.makeDocument(withContentsOf: url, ofType: WebFramesDocument.fileTypeIdentifier) as? WebFramesDocument)
        #expect(reopened.workspace.frames.first?.extras["imgUrl"] == .string(dataURL))
        #expect(reopened.payload.version == DocumentPayload.currentVersion)
        #expect(ProjectStorage.readDisplayName(at: url) == reopened.payload.name)
    }

    @Test func versionOneFilesOpenAndConvertOnSave() throws {
        let pixels = Data((0..<3_000).map { UInt8($0 % 7) })
        let json = #"{"version":1,"name":"Legacy","nextNum":2,"annNext":1,"canvas":null,"links":[],"annotations":[],"frames":[{"id":"f","url":"image://f","label":"F","x":0,"y":0,"w":10,"h":10,"num":1,"isImage":true,"imgUrl":"data:image/png;base64,"#
            + pixels.base64EncodedString() + #""}]}"#
        let document = makeTestDocument()
        try document.read(from: Data(json.utf8), ofType: WebFramesDocument.fileTypeIdentifier)
        #expect(document.payload.name == "Legacy")
        let package = try document.fileWrapper(ofType: WebFramesDocument.fileTypeIdentifier)
        #expect(package.isDirectory)
        #expect(package.fileWrappers?["images"]?.fileWrappers?.count == 1)
        // Saving again updates the same package; the image file is kept.
        let image = package.fileWrappers?["images"]?.fileWrappers?.values.first
        let again = try document.fileWrapper(ofType: WebFramesDocument.fileTypeIdentifier)
        let samePackage = again === package
        let sameImage = image != nil && again.fileWrappers?["images"]?.fileWrappers?.values.first === image
        #expect(samePackage && sameImage)
    }

    @Test func packagesAreRecognizedEvenWhenLaunchServicesSaysFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".webframes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let type = try WebFramesDocumentController().typeForContents(of: folder)
        #expect(type == WebFramesDocument.fileTypeIdentifier)
    }
}
