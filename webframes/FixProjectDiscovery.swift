import Foundation

/// Directory names are suggestions only; the user confirms the source root.
enum FixProjectDiscovery {
    static func normalized(_ value: String) -> String {
        let latin = value.applyingTransform(.toLatin, reverse: false) ?? value
        return latin.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    static func score(projectName: String, folderName: String) -> Int {
        let a = normalized(projectName), b = normalized(folderName)
        guard a.count >= 3, b.count >= 3, !["untitled", "project", "newproject"].contains(a) else { return 0 }
        if a == b { return 100 }
        if a.count >= 4 && b.contains(a) { return 70 }
        let lhs = Array(a), rhs = Array(b)
        guard abs(lhs.count - rhs.count) <= 1 else { return 0 }
        var row = Array(0...rhs.count)
        for (i, ch) in lhs.enumerated() {
            var next = [i + 1]
            for (j, other) in rhs.enumerated() {
                next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (ch == other ? 0 : 1)))
            }
            row = next
        }
        return row.last == 1 ? 50 : 0
    }

    static func suggestions(projectName: String, directory: URL) -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
        return folders.compactMap { url -> (URL, Int)? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { return nil }
            let score = score(projectName: projectName, folderName: url.lastPathComponent)
            return score > 0 ? (url, score) : nil
        }.sorted { $0.1 == $1.1 ? $0.0.path < $1.0.path : $0.1 > $1.1 }.prefix(5).map(\.0)
    }
}
