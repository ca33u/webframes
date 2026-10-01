import Foundation
import CoreGraphics

@MainActor enum ProjectMapBuilder {
    static func merged(_ scan: ProjectMapSnapshot, previous: ProjectMapSnapshot?) -> ProjectMapSnapshot {
        guard let previous, previous.rootPath == scan.rootPath else {
            var result = scan
            for i in result.routes.indices where !result.routes[i].dynamic {
                result.routes[i].selected = result.routes.prefix(i).filter(\.selected).count < 10
            }
            return result
        }
        var result = scan
        result.id = previous.id; result.bookmark = previous.bookmark; result.baseURL = previous.baseURL; result.webSource = previous.webSource; result.catalogURL = previous.catalogURL
        for i in result.routes.indices {
            if let old = previous.routes.first(where: { $0.path == result.routes[i].path }) {
                result.routes[i].frameID = old.frameID
                result.routes[i].examplePath = old.examplePath
                result.routes[i].selected = old.selected
            }
        }
        for var old in previous.routes where !result.routes.contains(where: { $0.path == old.path }) {
            old.missing = true; old.selected = false; result.routes.append(old)
        }
        return result
    }
    static func pageURL(base: String, path: String) throws -> URL {
        guard var parts = URLComponents(string: base), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              parts.host != nil, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\"), !path.contains("["),
              let relative = URLComponents(string: path), relative.host == nil, relative.scheme == nil,
              !relative.path.components(separatedBy: "/").contains("..") else {
            throw NSError(domain: "ProjectMap", code: 2, userInfo: [NSLocalizedDescriptionKey: "Use an http(s) site address and concrete page paths beginning with /."])
        }
        parts.path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty ? relative.path : "/" + parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + relative.path
        parts.query = relative.query; parts.fragment = relative.fragment
        guard let url = parts.url else { throw URLError(.badURL) }; return url
    }
    @discardableResult static func build(_ input: ProjectMapSnapshot, store: WorkspaceStore) throws -> ProjectMapSnapshot {
        var map = input
        var source = map.effectiveWebSource
        source.name = map.name.isEmpty ? source.name : map.name
        source.address = map.baseURL
        map.webSource = source
        let selected = map.routes.indices.filter { map.routes[$0].selected && !map.routes[$0].missing }
        guard !selected.isEmpty, selected.count <= 10 else {
            throw NSError(domain: "ProjectMap", code: 3, userInfo: [NSLocalizedDescriptionKey: "Select between 1 and 10 pages for the live map."])
        }
        // Validate every URL before changing the document.
        let urls = try selected.map { i -> URL in
            guard let path = map.routes[i].concretePath else {
                throw NSError(domain: "ProjectMap", code: 4, userInfo: [NSLocalizedDescriptionKey: "Enter the page URL to open for \(map.routes[i].path)."]) 
            }
            return try pageURL(base: map.baseURL, path: path)
        }
        let top = (store.frames.map { $0.y + $0.h }.max().map { $0 + 160 }) ?? 80
        var added = 0
        for (offset, i) in selected.enumerated() {
            let id = map.routes[i].frameID ?? "map-\(UUID().uuidString)"
            map.routes[i].frameID = id
            if store.frame(id: id) != nil {
                store.setFrameSource(id: id, url: urls[offset].absoluteString)
                store.setFrameWebSource(id: id, sourceID: source.id)
            } else {
                store.createFrame(FrameModel(id: id, url: urls[offset].absoluteString, label: map.routes[i].path, x: CGFloat(added % 3) * 1440 + 80, y: top + CGFloat(added / 3) * 1020, w: 1280, h: 800, num: store.nextFrameNum, isImage: false, filePath: nil, extras: ["webSourceID": .string(source.id)]))
                added += 1
            }
        }
        // Only replace our inferred edges; user-authored links are preserved.
        let prefix = "map-edge-\(map.id)-"
        var expected = Set<String>()
        for route in map.routes where !route.missing {
            guard let from = route.frameID, store.frame(id: from) != nil else { continue }
            for target in route.links {
                let path = URLComponents(string: target)?.path ?? target
                guard let destination = map.routes.first(where: { !$0.missing && $0.concretePath == path }), let to = destination.frameID,
                      store.frame(id: to) != nil, from != to else { continue }
                let linkID = prefix + from + "-" + to
                expected.insert(linkID)
                store.createLink(LinkModel(id: linkID, fromId: from, fromSide: .right, toId: to, toSide: .left))
            }
        }
        for link in store.links where link.id.hasPrefix(prefix) && !expected.contains(link.id) { store.deleteLink(id: link.id) }
        store.setProjectMap(map)
        return map
    }
}
