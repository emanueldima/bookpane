import Foundation

/// Stores folder permissions without enumerating their contents.
struct FolderAccess: Sendable {
    private let bookmarkURL: URL

    init(bookmarkURL: URL) {
        self.bookmarkURL = bookmarkURL
    }

    func folders() throws -> [ImportFolder] {
        try readBookmarks().map { ImportFolder(id: $0.id, name: $0.name) }
    }

    func addFolder(_ url: URL) throws -> [ImportFolder] {
        let location = FolderLocation(id: UUID(), url: url)
        try validate(location.url)
        var records = try readBookmarks()
        let index = records.firstIndex { record in
            var stale = false
            return (try? resolve(record.bookmark, stale: &stale).standardizedFileURL) == url.standardizedFileURL
        }
        let record = try bookmark(location.url, id: index.map { records[$0].id } ?? location.id)
        if let index { records[index] = record }
        else { records.append(record) }
        try save(records)
        return records.map { ImportFolder(id: $0.id, name: $0.name) }
    }

    func removeFolder(_ folder: ImportFolder) throws -> [ImportFolder] {
        let records = try readBookmarks().filter { $0.id != folder.id }
        try save(records)
        return records.map { ImportFolder(id: $0.id, name: $0.name) }
    }

    func openFolder(_ folder: ImportFolder) throws -> FolderLocation {
        var records = try readBookmarks()
        guard let index = records.firstIndex(where: { $0.id == folder.id }) else {
            throw EPUBError.invalid("This folder is no longer saved.")
        }
        var stale = false
        let url = try resolve(records[index].bookmark, stale: &stale)
        let location = FolderLocation(id: folder.id, url: url)
        try validate(location.url)

        if stale || records[index].name != location.url.lastPathComponent {
            records[index] = try bookmark(location.url, id: folder.id)
            try save(records)
        }
        return location
    }

    private func readBookmarks() throws -> [FolderBookmark] {
        guard FileManager.default.fileExists(atPath: bookmarkURL.path) else { return [] }
        let data = try Data(contentsOf: bookmarkURL)
        if let records = try? JSONDecoder().decode([FolderBookmark].self, from: data) { return records }

        // Migrate the previously saved single folder without opening its files.
        var stale = false
        let url = try resolve(data, stale: &stale)
        let location = FolderLocation(id: UUID(), url: url)
        let record = stale ? try bookmark(location.url, id: location.id)
            : FolderBookmark(id: location.id, name: location.url.lastPathComponent, bookmark: data)
        try save([record])
        return [record]
    }

    private func bookmark(_ url: URL, id: UUID) throws -> FolderBookmark {
        let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        let name = url.standardizedFileURL.lastPathComponent

        return FolderBookmark(id: id, name: name, bookmark: data)
    }

    private func resolve(_ data: Data, stale: inout Bool) throws -> URL {
        try URL(resolvingBookmarkData: data,
                options: [.withoutUI, .withoutImplicitStartAccessing],
                relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    private func validate(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw EPUBError.invalid("Select a folder to import books from.")
        }
    }

    private func save(_ records: [FolderBookmark]) throws {
        try FileManager.default.createDirectory(at: bookmarkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: bookmarkURL, options: .atomic)
    }
}

struct ImportFolder: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
}

// Keep permission alive while the system picker browses the folder.
final class FolderLocation: Identifiable, Sendable {
    let id: UUID
    let url: URL
    private let scoped: Bool

    fileprivate init(id: UUID, url: URL) {
        self.id = id
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if scoped { url.stopAccessingSecurityScopedResource() }
    }
}

private struct FolderBookmark: Codable {
    let id: UUID
    let name: String
    let bookmark: Data
}
