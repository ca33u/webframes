import Foundation

/// Bounded static index. Never runs package scripts or follows symbolic links.
nonisolated enum WebProjectScanner {
    static let ignored: Set<String> = ["node_modules", ".git", ".next", "dist", "build", "coverage", "vendor", "Pods", ".turbo"]
    static func matches(_ pattern: String, _ text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
        }
    }
    // Mask comments and optionally literals, preserving newlines and UTF-16 offsets.
    static func masked(_ text: String, literals: Bool) -> String {
        let pattern = literals ? #"//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"# : #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`|//[^\n]*|/\*[\s\S]*?\*/"#
        let result = NSMutableString(string: text)
        let re = try! NSRegularExpression(pattern: pattern)
        for m in re.matches(in: text, range: NSRange(location: 0, length: result.length)).reversed() {
            let s = result.substring(with: m.range)
            if literals || s.hasPrefix("//") || s.hasPrefix("/*") {
                result.replaceCharacters(in: m.range, with: String(s.utf16.map { $0 == 10 ? "\n" : " " }.joined()))
            }
        }
        return result as String
    }
    static func scan(root: URL) throws -> ProjectMapSnapshot {
        let fm = FileManager.default
        // FileManager's enumerator yields fully resolved paths
        // (/private/var/… for /var/…), so the root must be resolved the same
        // way or every relative path would be cut at the wrong offset.
        let root = URL(fileURLWithPath: realPath(of: root), isDirectory: true)
        var output = ProjectMapSnapshot(name: root.lastPathComponent, rootPath: root.path, framework: "Unknown")
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            throw NSError(domain: "ProjectMap", code: 1, userInfo: [NSLocalizedDescriptionKey: "This folder could not be read."])
        }
        var sources: [String: String] = [:], bytes = 0, visited = 0
        let extensions: Set<String> = ["tsx", "jsx", "ts", "js", "mjs", "css", "scss", "html"]
        for case let file as URL in walker {
            visited += 1
            if visited > 12000 || sources.count >= 2000 || bytes >= 12_000_000 {
                output.warnings.append("Scan limit reached; this is a partial inventory."); break
            }
            let info = try file.resourceValues(forKeys: Set(keys))
            if info.isSymbolicLink == true || ignored.contains(file.lastPathComponent) {
                walker.skipDescendants(); continue
            }
            guard info.isRegularFile == true, extensions.contains(file.pathExtension), !file.lastPathComponent.hasSuffix(".d.ts") else { continue }
            guard (info.fileSize ?? 0) <= 300_000 else {
                output.warnings.append("Skipped large file: \(file.lastPathComponent)"); continue
            }
            guard file.path.hasPrefix(root.path + "/") else { continue }
            let relative = String(file.path.dropFirst(root.path.count + 1))
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            sources[relative] = text; bytes += text.utf8.count
        }
        let isNext = sources.keys.contains { $0.hasPrefix("app/") || $0.hasPrefix("src/app/") || $0.hasPrefix("pages/") || $0.hasPrefix("src/pages/") }
        output.framework = isNext ? "Next.js routes" : "Static HTML"
        for file in sources.keys.sorted() {
            guard let path = routePath(file, next: isNext) else { continue }
            if output.routes.contains(where: { $0.path == path }) {
                output.warnings.append("Ambiguous route \(path): \(file)"); continue
            }
            output.routes.append(ProjectRoute(path: path, source: file, dynamic: path.contains("[")))
        }
        output.routes.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        var imports: [String: [String]] = [:]
        for (file, text) in sources {
            let clean = masked(text, literals: false)
            let specs = matches(#"\b(?:import|export)\s+(?:[^;\n]*?\s+from\s*)?["']([^"']+)["']|\b(?:import|require)\s*\(\s*["']([^"']+)["']\s*\)"#, clean).map { $0[1].isEmpty ? $0[2] : $0[1] }
            let htmlSpecs = file.hasSuffix(".html") ? matches(#"<(?:script|link)\b[^>]*\b(?:src|href)=["']([^"']+)["']"#, clean).map { $0[1].hasPrefix(".") ? $0[1] : "./" + $0[1] } : []
            imports[file] = (specs + htmlSpecs).compactMap { resolve($0, from: file, root: root, files: sources) }
        }
        var used: [String: Set<String>] = [:]
        for index in output.routes.indices {
            let route = output.routes[index]
            var pending = [route.source]
            if isNext {
                var dir = (route.source as NSString).deletingLastPathComponent
                while !dir.isEmpty && dir != "." {
                    pending += sources.keys.filter { ($0 as NSString).deletingLastPathComponent == dir && ["layout", "template", "_app"].contains(URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent) }
                    dir = (dir as NSString).deletingLastPathComponent
                }
            }
            var seen = Set<String>(), links = Set<String>()
            while let file = pending.popLast() {
                guard seen.insert(file).inserted else { continue }
                used[file, default: []].insert(route.path)
                pending += imports[file] ?? []
                for m in matches(#"\bhref\s*=\s*(?:\{\s*)?["'](/[^"']*)["']"#, masked(sources[file] ?? "", literals: false)) {
                    if !m[1].hasPrefix("//") { links.insert(m[1]) }
                }
            }
            output.routes[index].links = links.sorted()
        }
        for (file, text) in sources.sorted(by: { $0.key < $1.key }) {
            if ["css", "scss"].contains(URL(fileURLWithPath: file).pathExtension) {
                for (i, line) in masked(text, literals: false).components(separatedBy: "\n").enumerated() {
                    for m in matches(#"(--[\w-]+)\s*:\s*([^;{}]+)"#, line) {
                        output.tokens.append(ProjectToken(name: m[1], value: m[2].trimmingCharacters(in: .whitespaces), source: file, line: i + 1))
                    }
                    // Keep literal palette values visible too. They are common in
                    // Tailwind projects even when no custom property was declared.
                    for declaration in matches(#"(?:^|[;{])\s*([A-Za-z-]+)\s*:\s*([^;{}]+)"#, line) {
                        let property = declaration[1]
                        // Custom properties were recorded above under their own name.
                        guard !property.hasPrefix("--") else { continue }
                        for color in matches(#"(#[0-9A-Fa-f]{3,8}\b|(?:rgb|hsl)a?\([^)]*\))"#, declaration[2]) {
                            output.tokens.append(ProjectToken(name: "\(property) · \(color[1])", value: color[1], source: file, line: i + 1))
                        }
                    }
                }
                continue
            }
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                // Named constants used by generated images and inline styles are
                // part of the project's visual vocabulary even when they live in TSX.
                for m in matches(#"\b(?:const|let)\s+([A-Z][A-Z0-9_]*)\s*(?::[^=]+)?=\s*[\"'](#[0-9A-Fa-f]{3,8}|(?:rgb|hsl)a?\([^\"']*\))[\"']"#, line) {
                    output.tokens.append(ProjectToken(name: m[1], value: m[2], source: file, line: i + 1))
                }
                // Tailwind arbitrary values are explicit project values, unlike
                // named utilities that merely reference Tailwind's default theme.
                for m in matches(#"\b((?:bg|text|border|ring|fill|stroke)-\[(#[0-9A-Fa-f]{3,8})\])"#, line) {
                    output.tokens.append(ProjectToken(name: m[1], value: m[2], source: file, line: i + 1))
                }
            }
            let stem = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
            let isAppEntry = (file.hasPrefix("app/") || file.hasPrefix("src/app/")) && ["page", "layout", "route", "error", "not-found", "loading", "template", "default", "opengraph-image"].contains(stem)
            if routePath(file, next: isNext) != nil || isAppEntry { continue }
            let clean = masked(text, literals: true)
            for (i, line) in clean.components(separatedBy: "\n").enumerated() {
                let declarations = matches(#"\b(?:function|class)\s+([A-Z][A-Za-z0-9_]*)\b|\b(?:const|let)\s+([A-Z][A-Za-z0-9_]*)\s*(?::[^=]+)?=\s*(?:\([^;]*\)\s*(?::[^=]+)?=>|(?:React\.)?(?:memo|forwardRef)\s*\()"#, line)
                for d in declarations {
                    let name = d[1].isEmpty ? d[2] : d[1]
                    // Conservative candidates: the file must contain JSX or a React factory.
                    guard text.contains("<") || text.contains("createElement") else { continue }
                    output.components.append(ProjectComponent(name: name, source: file, line: i + 1, pages: (used[file] ?? []).sorted()))
                }
            }
        }
        output.components.sort { ($0.name, $0.source) < ($1.name, $1.source) }
        var seenTokens = Set<String>()
        output.tokens = output.tokens.filter {
            seenTokens.insert("\($0.name)\u{0}\($0.value)").inserted
        }.sorted { ($0.name, $0.source, $0.line) < ($1.name, $1.source, $1.line) }
        if output.routes.isEmpty { output.warnings.append("No supported routes found. Choose a Next.js app folder or a folder containing HTML pages.") }
        output.warnings.append("Static inventory: conditional rendering, custom aliases and generated routes may be incomplete. Nothing in this folder was executed.")
        return output
    }
    static func routePath(_ file: String, next: Bool) -> String? {
        let url = URL(fileURLWithPath: file)
        if !next {
            guard url.pathExtension == "html", !file.hasPrefix("public/") else { return nil }
            return "/" + (file == "index.html" ? "" : file)
        }
        guard ["tsx", "jsx", "ts", "js"].contains(url.pathExtension) else { return nil }
        for prefix in ["app/", "src/app/", "pages/", "src/pages/"] where file.hasPrefix(prefix) {
            var parts = String(file.dropFirst(prefix.count)).components(separatedBy: "/")
            let leaf = (parts.removeLast() as NSString).deletingPathExtension
            if prefix.contains("app/") {
                guard leaf == "page", !parts.contains(where: { $0.hasPrefix("_") || $0.hasPrefix("@") || $0.hasPrefix("(.") }) else { return nil }
                parts.removeAll { $0.hasPrefix("(") && $0.hasSuffix(")") }
            } else {
                guard parts.first != "api", !leaf.hasPrefix("_") else { return nil }
                if leaf != "index" { parts.append(leaf) }
            }
            return "/" + parts.joined(separator: "/")
        }
        return nil
    }
    static func resolve(_ spec: String, from file: String, root: URL, files: [String: String]) -> String? {
        var candidates: [String] = []
        if spec.hasPrefix(".") {
            // `standardized` only folds "." and ".."; `standardizedFileURL`
            // would also drop /private when the target exists, and a spec
            // without its extension does not.
            let base = root.standardized.path
            let path = root.appendingPathComponent(file).deletingLastPathComponent().appendingPathComponent(spec).standardized.path
            guard path.hasPrefix(base + "/") else { return nil }
            candidates = [String(path.dropFirst(base.count + 1))]
        } else if spec.hasPrefix("@/") || spec.hasPrefix("~/") {
            let relative = String(spec.dropFirst(2)); candidates = ["src/" + relative, relative]
        }
        for path in candidates {
            for suffix in ["", ".tsx", ".jsx", ".ts", ".js", ".css", "/index.tsx", "/index.jsx", "/index.ts", "/index.js"] where files[path + suffix] != nil { return path + suffix }
        }
        return nil
    }
}
