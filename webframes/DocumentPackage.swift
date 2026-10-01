import CryptoKit
import Foundation

/// `.webframes` package layout (format version 2):
///
///     Project.webframes/
///       document.json      the DocumentPayload, images replaced by references
///       images/<sha256>.<ext>
///
/// In memory the payload keeps images as `data:` URLs, so nothing outside
/// reading and writing changes. On disk each distinct image is stored once as
/// raw bytes (no base64 inflation), unchanged images are not rewritten, and
/// document.json stays small enough for the Start window and the comments MCP
/// to read instantly. Version 1 files (one JSON with inline base64) still open
/// and are converted on the next save.
enum DocumentPackage {
    static let documentName = "document.json"
    static let imagesFolder = "images"
    /// JSON strings of the form `wf-image:images/<name>` point into the package.
    static let referencePrefix = "wf-image:"
    /// Inline images smaller than this stay inline; not worth a file.
    static let minimumExternalBytes = 1_024

    private static let extensions: [String: String] = [
        "image/png": "png", "image/jpeg": "jpg", "image/jpg": "jpg", "image/webp": "webp",
        "image/gif": "gif", "image/svg+xml": "svg", "image/heic": "heic",
    ]

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        default: return "image/" + ext.lowercased()
        }
    }

    // MARK: Externalize (memory → disk)

    /// Replaces large `data:image/…;base64,` strings anywhere in `value` with
    /// references, collecting the decoded bytes in `images` keyed by the
    /// package-relative path.
    static func externalize(_ value: JSONValue, images: inout [String: Data]) -> JSONValue {
        switch value {
        case .string(let string):
            guard string.hasPrefix("data:image/"), string.utf8.count > minimumExternalBytes,
                  let comma = string.firstIndex(of: ","),
                  string[..<comma].hasSuffix(";base64") else { return value }
            let mime = String(string[string.index(string.startIndex, offsetBy: 5)..<comma].dropLast(";base64".count)).lowercased()
            guard let ext = extensions[mime],
                  let data = Data(base64Encoded: String(string[string.index(after: comma)...])) else { return value }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let path = imagesFolder + "/" + digest + "." + ext
            images[path] = data
            return .string(referencePrefix + path)
        case .array(let items):
            return .array(items.map { externalize($0, images: &images) })
        case .object(let object):
            return .object(object.mapValues { externalize($0, images: &images) })
        default:
            return value
        }
    }

    // MARK: Internalize (disk → memory)

    static func internalize(_ value: JSONValue, images: [String: Data]) -> JSONValue {
        switch value {
        case .string(let string):
            guard string.hasPrefix(referencePrefix) else { return value }
            let path = String(string.dropFirst(referencePrefix.count))
            guard let data = images[path] else { return .null }
            let mime = mimeType(forExtension: (path as NSString).pathExtension)
            return .string("data:\(mime);base64," + data.base64EncodedString())
        case .array(let items):
            return .array(items.map { internalize($0, images: images) })
        case .object(let object):
            return .object(object.mapValues { internalize($0, images: images) })
        default:
            return value
        }
    }

    // MARK: Payload helpers

    static func externalized(_ payload: DocumentPayload) -> (DocumentPayload, [String: Data]) {
        var images: [String: Data] = [:]
        var copy = payload
        copy.version = DocumentPayload.currentVersion
        copy.frames = copy.frames.map { externalize($0, images: &images) }
        copy.annotations = copy.annotations.map { externalize($0, images: &images) }
        return (copy, images)
    }

    static func internalized(_ payload: DocumentPayload, images: [String: Data]) -> DocumentPayload {
        var copy = payload
        copy.frames = copy.frames.map { internalize($0, images: images) }
        copy.annotations = copy.annotations.map { internalize($0, images: images) }
        return copy
    }

    static func encode(_ payload: DocumentPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    /// Reads either layout: a package directory or a version-1 JSON file.
    /// Returns the in-memory payload and, for a package, its wrapper so the
    /// next save can update it in place.
    static func read(_ wrapper: FileWrapper) throws -> (DocumentPayload, FileWrapper?) {
        if wrapper.isRegularFile {
            guard let data = wrapper.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
            return (try JSONDecoder().decode(DocumentPayload.self, from: data), nil)
        }
        guard wrapper.isDirectory,
              let json = wrapper.fileWrappers?[documentName]?.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let stored = try JSONDecoder().decode(DocumentPayload.self, from: json)
        var images: [String: Data] = [:]
        for (name, file) in wrapper.fileWrappers?[imagesFolder]?.fileWrappers ?? [:] {
            guard file.isRegularFile, let data = file.regularFileContents else { continue }
            images[imagesFolder + "/" + name] = data
        }
        return (internalized(stored, images: images), wrapper)
    }

    /// Writes `payload` into `existing` (updated in place, the pattern AppKit
    /// expects for incremental package saves: untouched image files keep
    /// their wrappers and are not rewritten) or into a new package.
    static func wrapper(for payload: DocumentPayload, updating existing: FileWrapper?) throws -> FileWrapper {
        let (stored, images) = externalized(payload)
        let package = existing?.isDirectory == true ? existing! : FileWrapper(directoryWithFileWrappers: [:])

        if let old = package.fileWrappers?[documentName] { package.removeFileWrapper(old) }
        let document = FileWrapper(regularFileWithContents: try encode(stored))
        document.preferredFilename = documentName
        package.addFileWrapper(document)

        let imagesDirectory: FileWrapper
        if let current = package.fileWrappers?[imagesFolder], current.isDirectory {
            imagesDirectory = current
        } else {
            if let stale = package.fileWrappers?[imagesFolder] { package.removeFileWrapper(stale) }
            imagesDirectory = FileWrapper(directoryWithFileWrappers: [:])
            imagesDirectory.preferredFilename = imagesFolder
            package.addFileWrapper(imagesDirectory)
        }
        let wanted = Dictionary(uniqueKeysWithValues: images.map { (($0.key as NSString).lastPathComponent, $0.value) })
        for (name, file) in imagesDirectory.fileWrappers ?? [:] where wanted[name] == nil {
            imagesDirectory.removeFileWrapper(file)
        }
        for (name, data) in wanted where imagesDirectory.fileWrappers?[name] == nil {
            let file = FileWrapper(regularFileWithContents: data)
            file.preferredFilename = name
            imagesDirectory.addFileWrapper(file)
        }
        return package
    }
}
