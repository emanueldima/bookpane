import Foundation

private final class XMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [XMLNode] = []
    init(_ name: String, _ attributes: [String: String]) {
        self.name = name; self.attributes = attributes
    }
    var value: String { (text + children.map(\.value).joined(separator: " ")).trimmingCharacters(in: .whitespacesAndNewlines) }
    func descendants(_ name: String) -> [XMLNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) }
    }
    func first(_ name: String) -> XMLNode? { descendants(name).first }
    func attribute(_ localName: String) -> String? {
        attributes.first { $0.key.split(separator: ":").last.map(String.init) == localName }?.value
    }
}

private final class XMLTree: NSObject, XMLParserDelegate {
    var root: XMLNode?
    var stack: [XMLNode] = []
    var count = 0
    static func read(_ url: URL) throws -> XMLNode {
        let data = try Data(contentsOf: url)
        guard data.count <= 8 * 1024 * 1024 else { throw EPUBError.invalid("The book's XML metadata is too large.") }
        let delegate = XMLTree()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else {
            throw EPUBError.invalid("The book contains invalid XML metadata or navigation.")
        }
        return root
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        count += 1
        guard stack.count < 100, count < 100_000 else { parser.abortParsing(); return }
        let node = XMLNode(elementName, attributeDict)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        stack.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        _ = stack.popLast()
    }
}

enum EPUBParser {
    static func parse(root: URL, id: UUID, fingerprint: String) throws -> Book {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.appendingPathComponent("META-INF/encryption.xml").path) else {
            throw EPUBError.invalid("This book declares encrypted or obfuscated resources. Bookpane currently supports unencrypted EPUBs only.")
        }
        let container = try XMLTree.read(root.appendingPathComponent("META-INF/container.xml"))
        guard let packagePath = container.descendants("rootfile").first(where: {
            $0.attributes["media-type"] == "application/oebps-package+xml"
        })?.attributes["full-path"] else { throw EPUBError.invalid("The EPUB package could not be found.") }
        let packageURL = try BookPaths.resolve(packagePath, relativeTo: root.appendingPathComponent(""), root: root)
        let package = try XMLTree.read(packageURL)
        guard package.name == "package", ["2.0", "3.0"].contains(package.attributes["version"] ?? ""),
              let metadata = package.first("metadata"), let manifest = package.first("manifest"), let spine = package.first("spine") else {
            throw EPUBError.invalid("The EPUB is missing its metadata, manifest, or reading order.")
        }
        if metadata.descendants("meta").contains(where: {
            $0.attributes["property"] == "rendition:layout" && $0.value == "pre-paginated"
        }) || spine.children.contains(where: { ($0.attributes["properties"] ?? "").contains("rendition:layout-pre-paginated") }) {
            throw EPUBError.invalid("Fixed-layout books are not supported yet. Please choose a reflowable EPUB.")
        }
        var items: [String: XMLNode] = [:]
        for item in manifest.children where item.name == "item" {
            guard let key = item.attributes["id"], items[key] == nil else { throw EPUBError.invalid("The book has an invalid manifest.") }
            items[key] = item
        }
        var chapters: [Chapter] = []
        for ref in spine.children where ref.name == "itemref" && ref.attributes["linear"] != "no" {
            guard let key = ref.attributes["idref"], let item = items[key],
                  item.attributes["media-type"] == "application/xhtml+xml", let href = item.attributes["href"] else {
                throw EPUBError.invalid("A chapter is missing or uses an unsupported content type.")
            }
            let url = try BookPaths.resolve(href, relativeTo: packageURL, root: root)
            guard fm.fileExists(atPath: url.path) else { throw EPUBError.invalid("A chapter file is missing from the book.") }
            chapters.append(Chapter(id: key, path: BookPaths.relative(url, root: root), title: "Chapter \(chapters.count + 1)"))
        }
        guard !chapters.isEmpty else { throw EPUBError.invalid("This book has no readable chapters.") }
        var contents: [ContentsEntry] = []
        if let nav = items.values.first(where: { ($0.attributes["properties"] ?? "").split(separator: " ").contains("nav") }), let href = nav.attributes["href"] {
            let url = try BookPaths.resolve(href, relativeTo: packageURL, root: root)
            let tree = try XMLTree.read(url)
            if let toc = tree.descendants("nav").first(where: { ($0.attribute("type") ?? "").split(separator: " ").contains("toc") }), let list = toc.children.first(where: { $0.name == "ol" }) {
                contents = try navigation(list, base: url, root: root)
            }
        } else if let ncxID = spine.attributes["toc"], let href = items[ncxID]?.attributes["href"] {
            let url = try BookPaths.resolve(href, relativeTo: packageURL, root: root)
            let tree = try XMLTree.read(url)
            if let map = tree.first("navMap") { contents = try ncx(map, base: url, root: root) }
        }
        let flattened = flatten(contents)
        chapters = chapters.map { chapter in
            let title = flattened.first { $0.href.components(separatedBy: "#")[0] == chapter.path }?.title ?? chapter.title
            return Chapter(id: chapter.id, path: chapter.path, title: title)
        }
        if contents.isEmpty { contents = chapters.map { ContentsEntry(title: $0.title, href: $0.path, children: []) } }
        let oldCoverID = metadata.descendants("meta").first { $0.attributes["name"] == "cover" }?.attributes["content"]
        let cover = items.values.first { ($0.attributes["properties"] ?? "").split(separator: " ").contains("cover-image") } ?? oldCoverID.flatMap { items[$0] }
        var coverPath: String?
        if let href = cover?.attributes["href"] {
            let url = try BookPaths.resolve(href, relativeTo: packageURL, root: root)
            coverPath = BookPaths.relative(url, root: root)
        }
        return Book(id: id, fingerprint: fingerprint, title: metadata.first("title")?.value.nonEmpty ?? "Untitled book",
                    author: metadata.first("creator")?.value.nonEmpty ?? "Unknown author", chapters: chapters,
                    contents: contents, coverPath: coverPath, importedAt: Date())
    }

    private static func navigation(_ list: XMLNode, base: URL, root: URL) throws -> [ContentsEntry] {
        try list.children.filter { $0.name == "li" }.flatMap { li -> [ContentsEntry] in
            let children = try li.children.filter { $0.name == "ol" }.flatMap { try navigation($0, base: base, root: root) }
            guard let anchor = li.children.first(where: { $0.name == "a" }), let href = anchor.attributes["href"] else { return children }
            let url = try BookPaths.resolve(href, relativeTo: base, root: root)
            return [ContentsEntry(title: anchor.value.nonEmpty ?? "Untitled section", href: BookPaths.relative(url, root: root), children: children)]
        }
    }
    private static func ncx(_ node: XMLNode, base: URL, root: URL) throws -> [ContentsEntry] {
        try node.children.filter { $0.name == "navPoint" }.flatMap { point -> [ContentsEntry] in
            let children = try ncx(point, base: base, root: root)
            guard let href = point.children.first(where: { $0.name == "content" })?.attributes["src"] else { return children }
            let url = try BookPaths.resolve(href, relativeTo: base, root: root)
            return [ContentsEntry(title: point.first("navLabel")?.value.nonEmpty ?? "Untitled section", href: BookPaths.relative(url, root: root), children: children)]
        }
    }
    static func flatten(_ entries: [ContentsEntry]) -> [ContentsEntry] {
        entries.flatMap { [$0] + flatten($0.children) }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
