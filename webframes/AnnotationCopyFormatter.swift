import Foundation

/// Phase 6e Step 70a: Swift port of `annotationToCopyLine` /
/// `buildCopyText` in `Renderer/index.html` (~line 2113). Formats an
/// annotation (or a list of them) for clipboard output — the same
/// byte-exact shape the JS path used to emit so downstream agents /
/// human readers see no difference across the flip.
///
/// Reads the JS-originated `element` DOM snapshot out of
/// `AnnotationModel.extras["element"]` (populated at inspect time in
/// `CanvasHost.handleInspectContext`), which carries `tagName`,
/// `textContent`, `attributes.class`, `path`, `componentName`, and
/// `computedStyles`. Missing fields fall back exactly the way the JS
/// did (empty strings, `(none)`, `'element'` placeholder).
enum AnnotationCopyFormatter {

    /// Single-annotation copy — mirrors `annotationToCopyLine(a, idx)`
    /// with `idx` unset (so numbering falls back to `a.num`). The
    /// caller passes in the freshest `comment` / `edits` so mid-edit
    /// Copy from the pin editor doesn't lag behind the user's typing.
    ///
    /// `nonisolated` because under SWIFT_DEFAULT_ACTOR_ISOLATION =
    /// MainActor the formatter would otherwise pin to @MainActor and
    /// warn when called from inference-nonisolated closures (e.g. the
    /// `.map` closure in `fullText`). This is pure value-type work on
    /// `AnnotationModel` / `JSONValue` with no shared state, matching
    /// the `nonisolated` pattern already applied to `JSONValue.from`.
    nonisolated static func line(for annotation: AnnotationModel,
                                 comment: String,
                                 edits: [String: String],
                                 index: Int? = nil) -> String {
        let num = index.map { $0 + 1 } ?? annotation.num
        let element = elementDict(annotation)
        let tagName = (element?["tagName"]).flatMap(stringValue) ?? ""
        let textContent = (element?["textContent"]).flatMap(stringValue) ?? ""
        let elDesc = element != nil ? "<\(tagName)>" : "element"
        let trimmedText = textContent.isEmpty
            ? ""
            : { () -> String in
                let clipped = String(textContent.prefix(80))
                let collapsed = clipped
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                return " \"\(collapsed)\""
            }()
        var line = "\(num). \(elDesc)\(trimmedText)"
        line += "\n   Comment: \(comment.isEmpty ? "(none)" : comment)"
        if let area = annotation.areaSummary { line += "\n   Area: \(area)" }

        if let element {
            let attrs = (element["attributes"]).flatMap(dictValue) ?? [:]
            let classes = (attrs["class"]).flatMap(stringValue) ?? ""
            let clsPart: String
            if !classes.isEmpty {
                let head = classes
                    .split(separator: " ")
                    .prefix(3)
                    .joined(separator: " ")
                clsPart = " class=\"\(head)\""
            } else {
                clsPart = ""
            }
            line += "\n   Selector: <\(tagName)\(clsPart)>"
            if let path = (element["path"]).flatMap(stringValue), !path.isEmpty {
                line += "\n   Path: \(path)"
            }
            if let componentName = (element["componentName"]).flatMap(stringValue),
               !componentName.isEmpty {
                line += "\n   Component: <\(componentName)>"
            }
        }

        if !edits.isEmpty {
            let styles = (element?["computedStyles"]).flatMap(dictValue) ?? [:]
            line += "\n   Edits:"
            // Stable key order so clipboard output is deterministic.
            for k in edits.keys.sorted() {
                let from = (styles[k]).flatMap(stringValue) ?? ""
                let to = edits[k] ?? ""
                line += "\n     - \(k): `\(from)` → `\(to)`"
            }
        }
        return line
    }

    /// All-annotations copy — mirrors `buildCopyText()`. Groups by
    /// frame, header per group with url/viewport/count, body is the
    /// numbered list. Returns `"No comments."` when the active set
    /// is empty (resolved annotations are excluded, matching JS).
    nonisolated static func fullText(annotations: [AnnotationModel],
                                     frames: [FrameModel]) -> String {
        let active = annotations.filter { !$0.resolved }
        guard !active.isEmpty else { return "No comments." }
        // Preserve first-encounter frame order.
        var groupOrder: [String] = []
        var groups: [String: (frameId: String, url: String?, label: String?,
                              anns: [AnnotationModel])] = [:]
        for a in active {
            if groups[a.frameId] == nil {
                groupOrder.append(a.frameId)
                groups[a.frameId] = (a.frameId, a.frameUrl, a.frameLabel, [])
            }
            groups[a.frameId]?.anns.append(a)
        }

        var sections: [String] = []
        for key in groupOrder {
            guard let g = groups[key] else { continue }
            let frame = frames.first(where: { $0.id == g.frameId })
                     ?? frames.first(where: { f in g.url.map { f.url == $0 } ?? false })
            let label = frame?.label.nonEmpty
                     ?? g.label?.nonEmpty
                     ?? "page"
            let url = frame?.url ?? g.url ?? ""
            let viewport = frame.map { "\(Int($0.w))×\(Int($0.h))" } ?? ""
            let count = g.anns.count
            let plural = count > 1 ? "s" : ""
            var header = "# Web Frames — \(label)\n\(url)"
            if !viewport.isEmpty { header += " · \(viewport)" }
            header += " · \(count) comment\(plural)"
            header += "\nFollow my instructions on these elements."
            header += "\nWhen applying design changes, map values to the project design system (Tailwind classes, CSS variables, or design tokens)."
            header += "\n---"

            let lines = g.anns.enumerated().map { (i, a) in
                line(for: a, comment: a.comment, edits: a.edits, index: i)
            }
            sections.append(header + "\n" + lines.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    // MARK: - Helpers

    /// Pulls the JS-originated element DOM snapshot out of
    /// `AnnotationModel.extras["element"]`. Returns nil when the pin
    /// was created without an inspect context (shouldn't happen in
    /// normal flow, but browser-preview / test fixtures may not set
    /// it, and the JS path handled that gracefully).
    nonisolated private static func elementDict(_ ann: AnnotationModel) -> [String: JSONValue]? {
        guard case .object(let dict) = ann.extras["element"] ?? .null else {
            return nil
        }
        return dict
    }

    nonisolated private static func stringValue(_ v: JSONValue) -> String? {
        if case .string(let s) = v { return s }
        return nil
    }

    nonisolated private static func dictValue(_ v: JSONValue) -> [String: JSONValue]? {
        if case .object(let d) = v { return d }
        return nil
    }
}

private extension String {
    nonisolated var nonEmpty: String? { isEmpty ? nil : self }
}
