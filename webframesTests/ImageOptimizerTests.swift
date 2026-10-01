import AppKit
import Testing
@testable import Web_Frames

@Suite("Image optimizer") @MainActor struct ImageOptimizerTests {
    private func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemOrange.setFill(); NSRect(x: 0, y: 0, width: width / 2, height: height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func wideScreenshotsShrinkToTheCap() throws {
        let result = try #require(ImageOptimizer.optimize(png(width: 4000, height: 2500), mime: "image/png"))
        #expect(result.pixelWidth == ImageOptimizer.maxLongEdge && result.pixelHeight == 1280)
    }

    @Test func phoneScreenshotsCapTheLongEdge() throws {
        let result = try #require(ImageOptimizer.optimize(png(width: 1290, height: 2796), mime: "image/png"))
        #expect(result.pixelHeight == ImageOptimizer.maxLongEdge && abs(result.pixelWidth - 945) <= 1)
    }

    @Test func commentScreenshotsStayPNG() throws {
        let result = try #require(ImageOptimizer.optimize(png(width: 3000, height: 2000), mime: "image/png", use: .commentScreenshot))
        #expect(result.mime == "image/png")
    }

    @Test func tallCapturesRespectThePixelBudget() throws {
        let result = try #require(ImageOptimizer.optimize(png(width: 1600, height: 20000), mime: "image/png"))
        #expect(result.pixelWidth * result.pixelHeight <= ImageOptimizer.maxPixels + 20_000)
        #expect(result.pixelWidth >= 800)   // page captures keep readable width
    }

    @Test func smallAndVectorImagesStayAsTheyAre() {
        #expect(ImageOptimizer.optimize(png(width: 800, height: 600), mime: "image/png") == nil)
        #expect(ImageOptimizer.optimize(Data("<svg/>".utf8), mime: "image/svg+xml") == nil)
        let url = "data:image/png;base64," + png(width: 300, height: 200).base64EncodedString()
        #expect(ImageOptimizer.optimize(dataURL: url) == url)
    }

    @Test func replacingImagesIsOneUndoableStep() throws {
        let document = makeTestDocument()
        let big = "data:image/png;base64," + png(width: 3000, height: 1000).base64EncodedString()
        _ = document.workspace.createFrame(FrameModel(id: "f", url: "image://f", label: "f", x: 0, y: 0, w: 1440, h: 480, num: 1,
                                                      isImage: true, filePath: nil, extras: ["imgUrl": .string(big)]))
        document.workspace.createAnnotation(AnnotationModel(id: "a", num: 1, frameId: "f", xPct: 1, yPct: 1, color: "blue", comment: "c",
                                                            resolved: false, edits: [:], extras: ["element": .object(["screenshot": .string(big)])]))
        document.undoManager?.removeAllActions()
        #expect(Set(document.workspace.imageDataURLs) == [big])
        let small = ImageOptimizer.optimize(dataURL: big)
        #expect(small.utf8.count < big.utf8.count)
        document.workspace.replaceImages([big: small])
        #expect(Set(document.workspace.imageDataURLs) == [small])
        #expect(document.workspace.frames.first?.w == 1440)   // layout unchanged
        document.undoManager?.undo()
        #expect(Set(document.workspace.imageDataURLs) == [big])
    }
}
