import CryptoKit
import Foundation
import Observation

@MainActor @Observable
final class LibraryStore {
    private(set) var books: [Book] = []
    private(set) var progress: [UUID: ReadingProgress] = [:]
    private(set) var folders: [ImportFolder] = []
    private(set) var isLoadingFolder = false
    private let folderAccess = FolderAccess(bookmarkURL: BookPaths.root.appendingPathComponent("folder.bookmark"))
    private static let settingsFilename = "settings.json"
    var isImporting = false
    var error: String?

    init() {
        do {
            try FileManager.default.createDirectory(at: BookPaths.root.appendingPathComponent("Books"), withIntermediateDirectories: true)
            let url = BookPaths.root.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: url.path) {
                books = try JSONDecoder().decode([Book].self, from: Data(contentsOf: url))
            }
            for book in books {
                let url = BookPaths.directory(book.id).appendingPathComponent("progress.json")
                if FileManager.default.fileExists(atPath: url.path) {
                    progress[book.id] = try JSONDecoder().decode(ReadingProgress.self, from: Data(contentsOf: url))
                }
            }
        } catch { self.error = "Could not load your library: \(error.localizedDescription)" }
    }

    var recentBooks: [Book] {
        books.sorted {
            let first = progress[$0.id]?.updatedAt ?? $0.importedAt
            let second = progress[$1.id]?.updatedAt ?? $1.importedAt
            if first != second { return first > second }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// Adds a book without navigating; identical archives reuse the existing copy.
    func importBook(_ url: URL) async -> Book? {
        guard !isImporting else { return nil }
        isImporting = true
        defer { isImporting = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let existing = books
        do {
            let book = try await Task.detached(priority: .userInitiated) {
                try EPUBImporter.importBook(url, existing: existing)
            }.value
            if books.contains(where: { $0.id == book.id }) { return book }
            let updated = [book] + books
            do { try persist(updated) }
            catch {
                try? FileManager.default.removeItem(at: BookPaths.directory(book.id))
                throw error
            }
            books = updated
        } catch { self.error = error.localizedDescription }
        return nil
    }

    func loadFolders(_ request: FolderRequest = .restore) async {
        guard !isLoadingFolder, !isImporting else { return }
        isLoadingFolder = true
        defer { isLoadingFolder = false }
        let access = folderAccess
        do {
            folders = try await Task.detached(priority: .userInitiated) {
                switch request {
                case .restore: return try access.folders()
                case .choose(let url): return try access.addFolder(url)
                }
            }.value
        } catch { self.error = "Could not save or restore folders: \(error.localizedDescription)" }
    }

    func removeFolder(_ folder: ImportFolder) {
        guard !isLoadingFolder, !isImporting else { return }
        do { folders = try folderAccess.removeFolder(folder) }
        catch { self.error = "Could not remove the folder: \(error.localizedDescription)" }
    }

    func openFolder(_ folder: ImportFolder) async -> FolderLocation? {
        guard !isLoadingFolder, !isImporting else { return nil }
        isLoadingFolder = true
        defer { isLoadingFolder = false }
        let access = folderAccess
        do {
            let location = try await Task.detached(priority: .userInitiated) {
                try access.openFolder(folder)
            }.value
            folders = try access.folders()
            return location
        } catch {
            self.error = "Could not open the folder. Remove it and add it again. \(error.localizedDescription)"
            return nil
        }
    }

    func loadReaderSettings(for book: Book) throws -> ReaderSettings {
        let url = BookPaths.directory(book.id).appendingPathComponent(Self.settingsFilename)
        guard FileManager.default.fileExists(atPath: url.path) else { return .standard }
        return try JSONDecoder().decode(ReaderSettings.self, from: Data(contentsOf: url))
    }

    func saveReaderSettings(_ value: ReaderSettings, for book: Book) throws {
        let url = BookPaths.directory(book.id).appendingPathComponent(Self.settingsFilename)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }

    func saveProgress(_ value: ReadingProgress, for book: Book) {
        do {
            try JSONEncoder().encode(value).write(to: BookPaths.directory(book.id).appendingPathComponent("progress.json"), options: .atomic)
            progress[book.id] = value
        } catch { self.error = "Could not save your reading position: \(error.localizedDescription)" }
    }

    func remove(_ book: Book) {
        do {
            // Move to a temporary name first, allowing rollback if the library write fails.
            let directory = BookPaths.directory(book.id)
            let trash = directory.deletingLastPathComponent().appendingPathComponent("removed-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: directory, to: trash)
            let updated = books.filter { $0.id != book.id }
            do { try persist(updated) }
            catch { try? FileManager.default.moveItem(at: trash, to: directory); throw error }
            books = updated
            progress.removeValue(forKey: book.id)
            try FileManager.default.removeItem(at: trash)
        } catch { self.error = "Could not remove the book: \(error.localizedDescription)" }
    }

    private func persist(_ books: [Book]) throws {
        try JSONEncoder().encode(books).write(to: BookPaths.root.appendingPathComponent("library.json"), options: .atomic)
    }
}

enum FolderRequest: Sendable {
    case restore
    case choose(URL)
}

private enum EPUBImporter {
    static func importBook(_ source: URL, existing: [Book]) throws -> Book {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("Bookpane-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let copy = staging.appendingPathComponent("book.epub")
        // File coordination supports imports from Files providers such as iCloud Drive.
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            do {
                let size = try readable.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 128 * 1024 * 1024 else { throw EPUBError.invalid("This book exceeds the 128 MB import limit.") }
                try fm.copyItem(at: readable, to: copy)
            } catch { copyError = error }
        }
        if let error = coordinationError { throw error }
        if let error = copyError { throw error }
        let data = try Data(contentsOf: copy, options: .mappedIfSafe)
        guard data.count <= 128 * 1024 * 1024 else { throw EPUBError.invalid("This book exceeds the 128 MB import limit.") }
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let duplicate = existing.first(where: { $0.fingerprint == fingerprint }) { return duplicate }
        let content = staging.appendingPathComponent("content", isDirectory: true)
        try ZIPExtractor.extract(copy, to: content)
        let id = UUID()
        let book = try EPUBParser.parse(root: content, id: id, fingerprint: fingerprint)
        try JSONEncoder().encode(book).write(to: staging.appendingPathComponent("metadata.json"), options: .atomic)
        try fm.removeItem(at: copy)
        try fm.moveItem(at: staging, to: BookPaths.directory(id))
        return book
    }
}
