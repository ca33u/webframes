import XCTest
import Testing
@testable import Web_Frames

final class ComponentCatalogueTests: XCTestCase {
    func testCatalogueOriginRejectsRemoteURLsCredentialsAndPaths() {
        XCTAssertNotNil(ComponentCatalogueController.localOrigin("http://127.0.0.1:4319/"))
        for input in ["http://example.com:4319", "https://127.0.0.1:4319", "http://user@127.0.0.1:4319", "http://127.0.0.1:4319/preview.html", "http://127.0.0.1:4319?token=x", "http://127.0.0.1:80", "http://127.0.0.1:99999"] {
            XCTAssertNil(ComponentCatalogueController.localOrigin(input), input)
        }
    }
    @MainActor func testCatalogueConnectionPersistsAcrossScanAndOldDocumentsDecode() throws {
        let old = Data(#"{"id":"old","name":"Demo","rootPath":"/tmp/demo","baseURL":"http://localhost:3000","scannedAt":0,"framework":"React","routes":[],"components":[],"tokens":[],"warnings":[]}"#.utf8)
        var previous = try JSONDecoder().decode(ProjectMapSnapshot.self, from: old)
        XCTAssertNil(previous.catalogURL)
        previous.catalogURL = "http://127.0.0.1:4319"
        let scan = ProjectMapSnapshot(name: "Demo", rootPath: "/tmp/demo", framework: "React")
        let merged = ProjectMapBuilder.merged(scan, previous: previous)
        XCTAssertEqual(merged.catalogURL, previous.catalogURL)
        XCTAssertEqual(try JSONDecoder().decode(ProjectMapSnapshot.self, from: JSONEncoder().encode(merged)), merged)
        let other = ProjectMapSnapshot(name: "Other", rootPath: "/tmp/other", framework: "React")
        XCTAssertNil(ProjectMapBuilder.merged(other, previous: previous).catalogURL)
    }
}

@Suite("Library helper port") struct LibraryHelperPortTests {
    @Test func readsThePortTheHelperBound() {
        #expect(ComponentCatalogueController.reportedPort(in: "WEBFRAMES_CATALOG_PORT=4562\nWeb Frames component catalog: …") == 4562)
        #expect(ComponentCatalogueController.reportedPort(in: "Web Frames component catalog: http://127.0.0.1:4562") == nil)
        #expect(ComponentCatalogueController.reportedPort(in: "WEBFRAMES_CATALOG_PORT=80") == nil)
    }
}
