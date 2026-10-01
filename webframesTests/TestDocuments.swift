import AppKit
@testable import Web_Frames

/// A document whose managed file exists on disk, like one the app has saved.
///
/// `WebFramesDocument()` only assigns a URL; the app writes the file on the
/// first change once the project has a window. Test documents have no window,
/// so without a file NSDocument's change tracking reports it as missing in a
/// modal alert that blocks the rest of the run. Under XCTest the projects
/// folder is a temporary directory (see `ProjectStorage.projectsDirectory`).
@MainActor
func makeTestDocument() -> WebFramesDocument {
    let document = WebFramesDocument()
    if let url = document.fileURL,
       let data = try? JSONEncoder().encode(DocumentPayload.empty),
       (try? data.write(to: url, options: .atomic)) != nil {
        document.fileModificationDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
    return document
}
