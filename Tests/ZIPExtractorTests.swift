import XCTest
@testable import Bookpane

final class ZIPExtractorTests: XCTestCase {
    private var working: URL!

    override func setUpWithError() throws {
        working = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: working)
    }

    func testStoredAndDeflated() throws {
        for name in ["stored", "deflated"] {
            let root = working.appendingPathComponent(name)
            try ZIPExtractor.extract(fixture(name), to: root)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("text/chapter.xhtml"), encoding: .utf8),
                           String(repeating: "<p>Hello</p>", count: 1000))
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("empty")), Data())
        }
    }

    func testDirectoriesAndLiteralPaths() throws {
        try ZIPExtractor.extract(fixture("directories"), to: working.appendingPathComponent("directories"))
        XCTAssertEqual(try String(contentsOf: working.appendingPathComponent("directories/text/chapter.xhtml"), encoding: .utf8), "Chapter")

        try ZIPExtractor.extract(fixture("literal-path"), to: working.appendingPathComponent("paths"))
        XCTAssertEqual(try String(contentsOf: working.appendingPathComponent("paths/a%20chapter.xhtml"), encoding: .utf8), "Literal")
        XCTAssertEqual(try String(contentsOf: working.appendingPathComponent("paths/caf\u{e9}.xhtml"), encoding: .utf8), "Unicode")
    }

    func testDescriptorsAndZIP64() throws {
        for (name, content) in [("descriptors", "Descriptor"), ("zip64-comment", "ZIP64")] {
            let root = working.appendingPathComponent(name)
            try ZIPExtractor.extract(fixture(name), to: root)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("chapter.xhtml"), encoding: .utf8), content)
        }
    }

    func testEmbeddedSignatureComment() throws {
        try XCTExpectFailure("ZIPFoundation 0.9.20 mistakes a signature inside the ZIP comment for the directory end.") {
            XCTAssertNoThrow(try ZIPExtractor.extract(fixture("embedded-signature-comment"), to: working.appendingPathComponent("comment")))
        }
    }

    func testRejectsUnsafePaths() throws {
        for index in 0..<8 {
            let root = working.appendingPathComponent("unsafe-\(index)")
            XCTAssertThrowsError(try ZIPExtractor.extract(fixture("unsafe-\(index)"), to: root))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Validate paths before writing")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: working.appendingPathComponent("escape").path))
    }

    func testRejectsCollisionsAndLinks() throws {
        for name in ["duplicate", "case-collision", "unicode-collision", "type-collision", "symlink"] {
            let root = working.appendingPathComponent(name)
            XCTAssertThrowsError(try ZIPExtractor.extract(fixture(name), to: root), name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Validate catalog before writing")
        }
    }

    func testRejectsDeclaredLimits() throws {
        for name in ["oversized-entry", "oversized-total", "too-many-entries"] {
            let root = working.appendingPathComponent(name)
            XCTAssertThrowsError(try ZIPExtractor.extract(fixture(name), to: root)) { error in
                XCTAssertTrue(error.localizedDescription.contains("size limits") || error.localizedDescription.contains("too many entries"))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Validate limits before writing")
        }
    }

    func testRejectsOversizedArchive() throws {
        let source = working.appendingPathComponent("oversized.epub")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let file = try FileHandle(forWritingTo: source)
        defer { try? file.close() }
        // A sparse file exercises the input limit without allocating 128 MiB.
        try file.truncate(atOffset: 128 * 1024 * 1024 + 1)
        let root = working.appendingPathComponent("output")
        XCTAssertThrowsError(try ZIPExtractor.extract(source, to: root)) { error in
            XCTAssertTrue(error.localizedDescription.contains("128 MB"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testRejectsDamagedOutput() throws {
        for name in ["damaged-crc", "overreported-size", "underreported-size"] {
            let root = working.appendingPathComponent(name)
            XCTAssertThrowsError(try ZIPExtractor.extract(fixture(name), to: root), name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("chapter.xhtml").path))
        }
    }

    func testRejectsInvalidPublications() throws {
        for name in ["missing-mimetype", "wrong-mimetype", "empty-archive"] + (0..<6).map({ "truncated-\($0)" }) {
            XCTAssertThrowsError(try ZIPExtractor.extract(fixture(name), to: working.appendingPathComponent(name)), name)
        }
    }

    private func fixture(_ name: String) throws -> URL {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "epub", subdirectory: "ZIP")
        return try XCTUnwrap(url)
    }
}
