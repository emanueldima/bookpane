import XCTest
import SwiftUI
@testable import Bookpane

final class FolderAccessTests: XCTestCase {
    private var working: URL!
    private var source: URL!
    private var bookmark: URL!
    private var access: FolderAccess!

    override func setUpWithError() throws {
        working = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        source = working.appendingPathComponent("Books", isDirectory: true)
        bookmark = working.appendingPathComponent("Settings/folder.bookmark")
        access = FolderAccess(bookmarkURL: bookmark)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: working)
    }

    func testNoInitialFolders() throws {
        XCTAssertEqual(try access.folders(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: bookmark.path))
    }

    func testMultipleFoldersPersist() throws {
        let second = working.appendingPathComponent("More books", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let first = try access.addFolder(source)
        let both = try access.addFolder(second)
        XCTAssertEqual(both.map(\.name), ["Books", "More books"])
        XCTAssertEqual(both.first, first.first)
        XCTAssertNotEqual(both[0].id, both[1].id)
        XCTAssertEqual(try FolderAccess(bookmarkURL: bookmark).folders(), both)
        XCTAssertEqual(try access.openFolder(both[0]).url.standardizedFileURL, source.standardizedFileURL)
        XCTAssertEqual(try access.openFolder(both[1]).url.standardizedFileURL, second.standardizedFileURL)
    }

    func testDuplicateFolderKeepsIdentity() throws {
        let first = try access.addFolder(source)
        XCTAssertEqual(try access.addFolder(source), first)
        XCTAssertEqual(try access.addFolder(source.appendingPathComponent(".")), first)
        XCTAssertEqual(try access.folders(), first)
    }

    func testRemovalPreservesFiles() throws {
        let file = source.appendingPathComponent("Keep.epub")
        try Data("original".utf8).write(to: file)
        let second = working.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        _ = try access.addFolder(source)
        let both = try access.addFolder(second)
        XCTAssertEqual(try access.removeFolder(both[0]), [both[1]])
        XCTAssertEqual(try FolderAccess(bookmarkURL: bookmark).folders(), [both[1]])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
        XCTAssertThrowsError(try access.openFolder(both[0]))
        XCTAssertEqual(try access.removeFolder(both[1]), [])
    }

    func testMigratesLegacyFolder() throws {
        try FileManager.default.createDirectory(at: bookmark.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacy = try source.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        try legacy.write(to: bookmark)
        let migrated = try access.folders()
        XCTAssertEqual(migrated.map(\.name), ["Books"])
        XCTAssertEqual(try FolderAccess(bookmarkURL: bookmark).folders(), migrated)
        XCTAssertEqual(try access.openFolder(migrated[0]).url.standardizedFileURL, source.standardizedFileURL)
        XCTAssertEqual(try access.removeFolder(migrated[0]), [])
        XCTAssertEqual(try access.folders(), [])
    }

    func testUnavailableFolderIsNotScanned() throws {
        let folders = try access.addFolder(source)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try FolderAccess(bookmarkURL: bookmark).folders(), folders)
        XCTAssertThrowsError(try access.openFolder(folders[0]))
        XCTAssertEqual(try access.folders(), folders)
        XCTAssertEqual(try access.removeFolder(folders[0]), [])
    }

    func testInvalidChoicePreservesFolders() throws {
        let folders = try access.addFolder(source)
        let file = working.appendingPathComponent("Not a folder.epub")
        try Data().write(to: file)
        for invalid in [file, working.appendingPathComponent("Missing")] {
            XCTAssertThrowsError(try access.addFolder(invalid))
            XCTAssertEqual(try access.folders(), folders)
        }
        XCTAssertThrowsError(try access.openFolder(ImportFolder(id: UUID(), name: "Unknown")))
    }

    func testCorruptStoreIsPreserved() throws {
        try FileManager.default.createDirectory(at: bookmark.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data("invalid bookmark".utf8)
        try data.write(to: bookmark)
        XCTAssertThrowsError(try access.folders())
        XCTAssertThrowsError(try access.addFolder(source))
        XCTAssertEqual(try Data(contentsOf: bookmark), data)
    }

    @MainActor
    func testLibraryFolderImport() async throws {
        let index = BookPaths.root.appendingPathComponent("library.json")
        let saved = BookPaths.root.appendingPathComponent("folder.bookmark")
        let originalIndex = try? Data(contentsOf: index)
        let originalFolders = try? Data(contentsOf: saved)
        var imported: [Book] = []
        defer {
            if let originalIndex { try? originalIndex.write(to: index, options: .atomic) }
            else { try? FileManager.default.removeItem(at: index) }
            if let originalFolders { try? originalFolders.write(to: saved, options: .atomic) }
            else { try? FileManager.default.removeItem(at: saved) }
            for book in imported { try? FileManager.default.removeItem(at: BookPaths.directory(book.id)) }
        }
        try FileManager.default.createDirectory(at: BookPaths.root, withIntermediateDirectories: true)
        try JSONEncoder().encode([Book]()).write(to: index, options: .atomic)
        if FileManager.default.fileExists(atPath: saved.path) { try FileManager.default.removeItem(at: saved) }
        let archive = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "A Quiet Beginning - EPUB 3", withExtension: "epub"))
        let file = source.appendingPathComponent("Book.epub")
        try FileManager.default.copyItem(at: archive, to: file)
        let second = working.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)

        let library = LibraryStore()
        await library.loadFolders(.choose(source))
        await library.loadFolders(.choose(second))
        await library.loadFolders(.choose(source))
        XCTAssertEqual(library.folders.map(\.name), ["Books", "Other"])
        let reopened = LibraryStore()
        await reopened.loadFolders()
        XCTAssertEqual(reopened.folders, library.folders)
        let location = await library.openFolder(library.folders[0])
        XCTAssertEqual(try XCTUnwrap(location).url.standardizedFileURL, source.standardizedFileURL)

        let firstImport = await library.importBook(file)
        imported = library.books
        XCTAssertNil(firstImport)
        XCTAssertEqual(imported.count, 1)
        XCTAssertTrue(library.progress.isEmpty, "Import must not start reading")
        let duplicate = await library.importBook(file)
        XCTAssertEqual(duplicate?.id, imported.first?.id)
        XCTAssertEqual(library.books.count, 1)
        XCTAssertTrue(library.progress.isEmpty)
        library.removeFolder(library.folders[0])
        XCTAssertEqual(library.folders.map(\.name), ["Other"])
        XCTAssertEqual(library.books.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertNil(library.error)
    }

    @MainActor
    func testSystemPicker() async throws {
        let folders = try access.addFolder(source)
        let location = try access.openFolder(folders[0])
        var choices: [URL?] = []
        let controller = UIHostingController(rootView: EPUBPicker(location: location) { choices.append($0) })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(500))
        let picker = try XCTUnwrap(findPicker(controller))
        XCTAssertEqual(picker.directoryURL?.standardizedFileURL, source.standardizedFileURL)
        XCTAssertFalse(picker.allowsMultipleSelection)
        let file = source.appendingPathComponent("Chosen.epub")
        picker.delegate?.documentPicker?(picker, didPickDocumentsAt: [file])
        XCTAssertEqual(choices.count, 1)
        XCTAssertEqual(choices[0], file)
        picker.delegate?.documentPickerWasCancelled?(picker)
        XCTAssertEqual(choices.count, 2)
        XCTAssertNil(choices[1])
    }

    @MainActor
    private func findPicker(_ controller: UIViewController) -> UIDocumentPickerViewController? {
        if let picker = controller as? UIDocumentPickerViewController { return picker }
        return controller.children.lazy.compactMap(findPicker).first
    }
}
