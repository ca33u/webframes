import Foundation
import Testing
@testable import Web_Frames

@Suite("Frame bridge limits") struct BridgeLimitsTests {
    @Test func screenshotsMustBeSmallPNGDataURLs() {
        #expect(NativeBridge.acceptsScreenshot("data:image/png;base64,iVBORw0KGgo="))
        #expect(!NativeBridge.acceptsScreenshot("data:image/svg+xml;base64,PHN2Zz4="))
        #expect(!NativeBridge.acceptsScreenshot("https://example.com/shot.png"))
        let huge = NativeBridge.screenshotPrefix + String(repeating: "A", count: NativeBridge.maxScreenshotBytes)
        #expect(!NativeBridge.acceptsScreenshot(huge))
    }

    @Test func elementContextIsCappedAt64KB() {
        #expect(NativeBridge.contextFitsLimit(["tagName": "DIV", "path": "main > .card"]))
        #expect(!NativeBridge.contextFitsLimit(["html": String(repeating: "x", count: NativeBridge.maxContextBytes)]))
    }
}
