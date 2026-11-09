import XCTest
import SwiftUI
import WebKit
@testable import Bookpane

final class EPUBParserTests: XCTestCase {
    private var working: URL!

    override func setUpWithError() throws {
        working = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: working) }

    func testPrivatePathExtraction() throws {
        #if targetEnvironment(simulator) || os(macOS)
        let parent = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        #else
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        #endif
        let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "A Quiet Beginning - EPUB 3", withExtension: "epub"))

        // An existing root may normalize /private away before its new children do.
        try ZIPExtractor.extract(archive, to: root)
        let book = try parse(root)
        XCTAssertEqual(book.title, "A Quiet Beginning")
        XCTAssertEqual(book.chapters.count, 3)
    }

    private func sample(_ version: Int) throws -> URL {
        let archive = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "A Quiet Beginning - EPUB \(version)", withExtension: "epub"))
        let root = working.appendingPathComponent("book", isDirectory: true)
        try ZIPExtractor.extract(archive, to: root)
        return root
    }
    private func parse(_ root: URL) throws -> Book {
        try EPUBParser.parse(root: root, id: UUID(), fingerprint: "test")
    }
    func testEPUB3SpineAndNavigation() throws {
        let book = try parse(sample(3))
        XCTAssertEqual(book.title, "A Quiet Beginning")
        XCTAssertEqual(book.author, "Bookpane Studio")
        XCTAssertEqual(book.chapters.map(\.id), ["c1", "c2", "c3"])
        XCTAssertEqual(book.chapters.first?.path, "EPUB/text/chapter1.xhtml")
        XCTAssertEqual(book.contents.count, 3)
        XCTAssertEqual(book.chapters[1].title, "Room to wander")
    }
    func testEPUB2NCX() throws {
        let book = try parse(sample(2))
        XCTAssertEqual(book.contents.map(\.title), ["A quiet beginning", "Room to wander", "A place to return"])
        XCTAssertEqual(book.chapters.count, 3)
    }
    func testRejectsResourceTraversal() throws {
        let base = working.appendingPathComponent("chapter.xhtml")
        for reference in ["../outside", "%2e%2e/outside", "file:///etc/passwd", "https://example.com/book"] {
            XCTAssertThrowsError(try BookPaths.resolve(reference, relativeTo: base, root: working), reference)
        }
    }
    func testSpacesAndFragmentsRoundTrip() throws {
        let url = try BookPaths.resolve("a%20chapter.xhtml#section", relativeTo: working.appendingPathComponent(""), root: working)
        XCTAssertEqual(url.lastPathComponent, "a chapter.xhtml")
        XCTAssertEqual(url.fragment, "section")
        XCTAssertEqual(BookPaths.relative(url, root: working), "a%20chapter.xhtml#section")
    }
    func testRejectsEncryptedResources() throws {
        let root = try sample(3)
        try Data("<encryption/>".utf8).write(to: root.appendingPathComponent("META-INF/encryption.xml"))
        XCTAssertThrowsError(try parse(root))
    }
    func testRejectsFixedLayout() throws {
        let root = try sample(3)
        let package = root.appendingPathComponent("EPUB/package.opf")
        let text = try String(contentsOf: package, encoding: .utf8)
            .replacingOccurrences(of: "</metadata>", with: "<meta property=\"rendition:layout\">pre-paginated</meta></metadata>")
        try text.write(to: package, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try parse(root))
    }
    func testRejectsMissingChapter() throws {
        let root = try sample(3)
        try FileManager.default.removeItem(at: root.appendingPathComponent("EPUB/text/chapter2.xhtml"))
        XCTAssertThrowsError(try parse(root))
    }
    func testMalformedMetadata() throws {
        let root = try sample(3)
        try Data("<package>".utf8).write(to: root.appendingPathComponent("EPUB/package.opf"))
        XCTAssertThrowsError(try parse(root))
    }
}

final class PageIndexTests: XCTestCase {
    func testChapterOffsetsAndPartialPages() {
        let index = PageIndex(heights: [250, 20, 300], screenHeight: 100)
        XCTAssertEqual(index.total, 7)
        XCTAssertEqual(index.page(chapter: 0, fraction: 0), 1)
        XCTAssertEqual(index.page(chapter: 0, fraction: 0.8), 2)
        XCTAssertEqual(index.page(chapter: 0, fraction: 1), 3)
        XCTAssertEqual(index.page(chapter: 1, fraction: 0), 4)
        XCTAssertEqual(index.page(chapter: 2, fraction: 0), 5)
        XCTAssertEqual(index.page(chapter: 2, fraction: 1), 7)
    }

    func testShortAndEmptyChapters() {
        let index = PageIndex(heights: [0, 40, 100], screenHeight: 100)
        XCTAssertEqual(index.total, 3)
        XCTAssertEqual(index.page(chapter: 0, fraction: 0), 1)
        XCTAssertEqual(index.page(chapter: 1, fraction: 1), 2)
        XCTAssertEqual(index.page(chapter: 2, fraction: 0.5), 3)
    }

    func testProgressClamping() {
        let index = PageIndex(heights: [250], screenHeight: 100)
        XCTAssertEqual(index.page(chapter: 0, fraction: -1), 1)
        XCTAssertEqual(index.page(chapter: 0, fraction: 2), 3)
        XCTAssertEqual(index.page(chapter: 0, fraction: .nan), 1)
    }
}

final class ReaderSettingsTests: XCTestCase {
    func testFontDefaultsAndCoding() throws {
        XCTAssertEqual(ReaderSettings.standard.fontMode, .publisher)
        XCTAssertEqual(ReaderSettings.standard.fontFamily, "Georgia")
        let legacy = try JSONDecoder().decode(ReaderSettings.self, from: Data("{\"textScale\":150}".utf8))
        XCTAssertEqual(legacy.fontMode, .publisher)
        XCTAssertEqual(legacy.fontFamily, "Georgia")

        let settings = ReaderSettings(textScale: 120, fontMode: .custom, fontFamily: "Avenir Next")
        XCTAssertEqual(try JSONDecoder().decode(ReaderSettings.self, from: JSONEncoder().encode(settings)), settings)
        for change in [FontSizeChange.increase, .decrease, .reset] {
            XCTAssertEqual(settings.changed(change).fontMode, .custom)
            XCTAssertEqual(settings.changed(change).fontFamily, "Avenir Next")
        }
    }

    @MainActor
    func testAppThemePersistence() throws {
        let suite = "BookpaneTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.theme, .system)
        for theme in [AppTheme.dark, .light, .system] {
            settings.changeTheme(theme)
            let reopened = AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
            XCTAssertEqual(reopened.theme, theme)
        }
        defaults.set("unknown", forKey: "theme")
        XCTAssertEqual(AppSettings(defaults: defaults).theme, .system)
    }

    func testMarginDefaultsAndCoding() throws {
        XCTAssertEqual(ReaderSettings.standard.marginMode, .publisher)
        XCTAssertEqual(ReaderSettings.standard.sideMargin, 0)
        let legacy = try JSONDecoder().decode(ReaderSettings.self, from: Data("{\"textScale\":150,\"colorMode\":\"monochrome\"}".utf8))
        XCTAssertEqual(legacy, ReaderSettings(textScale: 150, colorMode: .monochrome))

        let settings = ReaderSettings(textScale: 120, colorMode: .monochrome, marginMode: .custom, sideMargin: 28)
        let saved = try JSONDecoder().decode(ReaderSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(saved, settings)
        for change in [FontSizeChange.increase, .decrease, .reset] {
            XCTAssertEqual(settings.changed(change).marginMode, .custom)
            XCTAssertEqual(settings.changed(change).sideMargin, 28)
        }
        for (input, expected) in [(Int.min, 0), (-1, 0), (0, 0), (1, 0), (2, 4), (46, 48), (48, 48), (49, 48), (Int.max, 48)] {
            let bounded = ReaderSettings(textScale: 100, marginMode: .custom, sideMargin: input)
            XCTAssertEqual(bounded.sideMargin, expected)
        }
        let bounded = try JSONDecoder().decode(ReaderSettings.self, from: Data("{\"textScale\":100,\"marginMode\":\"custom\",\"sideMargin\":999}".utf8))
        XCTAssertEqual(bounded.sideMargin, 48)
    }

    func testColorDefaultsAndCoding() throws {
        XCTAssertEqual(ReaderSettings.standard.colorMode, .publisher)
        let legacy = try JSONDecoder().decode(ReaderSettings.self, from: Data("{\"textScale\":150}".utf8))
        XCTAssertEqual(legacy.textScale, 150)
        XCTAssertEqual(legacy.colorMode, .publisher)

        let settings = ReaderSettings(textScale: 120, colorMode: .monochrome)
        let saved = try JSONDecoder().decode(ReaderSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(saved, settings)
        for change in [FontSizeChange.increase, .decrease, .reset] {
            XCTAssertEqual(settings.changed(change).colorMode, .monochrome)
        }
        XCTAssertEqual(settings.changed(.reset).textScale, ReaderSettings.standard.textScale)
    }

    func testScaleBoundsAndReset() throws {
        var settings = ReaderSettings.standard
        for _ in 0..<30 { settings = settings.changed(.increase) }
        XCTAssertEqual(settings.textScale, 250)
        XCTAssertFalse(settings.canIncrease)
        for _ in 0..<30 { settings = settings.changed(.decrease) }
        XCTAssertEqual(settings.textScale, 80)
        XCTAssertFalse(settings.canDecrease)
        XCTAssertEqual(settings.changed(.reset), .standard)

        let saved = try JSONDecoder().decode(ReaderSettings.self, from: Data("{\"textScale\":999}".utf8))
        XCTAssertEqual(saved.textScale, 250)
        XCTAssertEqual(ReaderSettings(textScale: Int.min).textScale, 80)
    }
}

final class LibraryOrderTests: XCTestCase {
    @MainActor
    func testRecentAccessOrder() throws {
        let index = BookPaths.root.appendingPathComponent("library.json")
        let original = try? Data(contentsOf: index)
        let books = (1...2).map { number in
            Book(id: UUID(), fingerprint: "order-\(number)", title: "Book \(number)", author: "Test",
                 chapters: [Chapter(id: "chapter", path: "chapter.xhtml", title: "Chapter")],
                 contents: [], coverPath: nil, importedAt: Date(timeIntervalSince1970: Double(number)))
        }
        defer {
            if let original { try? original.write(to: index, options: .atomic) }
            else { try? FileManager.default.removeItem(at: index) }
            for book in books { try? FileManager.default.removeItem(at: BookPaths.directory(book.id)) }
        }
        for book in books { try FileManager.default.createDirectory(at: BookPaths.directory(book.id), withIntermediateDirectories: true) }
        try JSONEncoder().encode(books).write(to: index, options: .atomic)
        let library = LibraryStore()
        XCTAssertEqual(library.recentBooks.map(\.id), books.reversed().map(\.id))

        library.saveProgress(ReadingProgress(chapterID: "chapter", scrollFraction: 0.5, updatedAt: Date(timeIntervalSince1970: 3)), for: books[0])
        XCTAssertEqual(library.recentBooks.map(\.id), books.map(\.id))
        XCTAssertEqual(LibraryStore().recentBooks.map(\.id), books.map(\.id))
        library.saveProgress(ReadingProgress(chapterID: "chapter", scrollFraction: 0, updatedAt: Date(timeIntervalSince1970: 4)), for: books[1])
        XCTAssertEqual(library.recentBooks.map(\.id), books.reversed().map(\.id))
        XCTAssertNil(library.error)
    }
}

final class ChapterWebViewTests: XCTestCase {
    @MainActor
    func testWholeBookPages() async throws {
        let paragraphs = String(repeating: "<p>A long chapter with enough text to span multiple screens.</p>", count: 120)
        try await checkChapter("<img src=\"image.png\" style=\"height:1200px;width:100px\"/>" + paragraphs, inspect: { model, view in
            try await self.waitForPages(model)
            let height = try await self.evaluate("document.documentElement.scrollHeight", in: view, world: .defaultClient) as! Double
            let screen = try await self.evaluate("innerHeight", in: view, world: .defaultClient) as! Double
            XCTAssertEqual(model.pageNumber, 1)
            XCTAssertEqual(model.pageTotal, Int(ceil(height / screen)) + 1)

            _ = try await self.evaluate("scrollTo(0, document.documentElement.scrollHeight); window.bookpaneReport()", in: view, world: .defaultClient)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(model.pageNumber, try XCTUnwrap(model.pageTotal) - 1)

            let total = model.pageTotal
            model.move(1)
            try await self.waitForChapter(model)
            try await self.waitForPages(model)
            XCTAssertEqual(model.pageTotal, total)
            XCTAssertEqual(model.pageNumber, total)

            let saved = try JSONDecoder().decode(ReadingProgress.self, from: Data(contentsOf:
                BookPaths.directory(model.book.id).appendingPathComponent("progress.json")))
            XCTAssertEqual(saved.chapterID, model.book.chapters[1].id)
            let reopened = ReaderModel(book: model.book, library: model.library)
            XCTAssertEqual(reopened.target.index, 1, "Measuring chapters must not overwrite reading progress")
            XCTAssertEqual(reopened.target.fraction, 0)
        })
    }

    @MainActor
    func testPageCountReflow() async throws {
        let paragraphs = String(repeating: "<p>Text wraps into different numbers of pages as the reader changes font and margins.</p>", count: 120)
        try await checkChapter(paragraphs, inspect: { model, view in
            try await self.waitForPages(model)
            let original = try XCTUnwrap(model.pageTotal)
            _ = try await self.evaluate("scrollTo(0, (document.documentElement.scrollHeight - innerHeight) / 2); window.bookpaneReport()", in: view, world: .defaultClient)
            try await Task.sleep(for: .milliseconds(100))
            model.changeFontSize(.increase)
            model.changeMargins(.custom, width: 48)

            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while model.pageTotal == original, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            try await self.waitForPages(model)
            XCTAssertGreaterThan(try XCTUnwrap(model.pageTotal), original)
            let fraction = try await self.evaluate("scrollY / (document.documentElement.scrollHeight - innerHeight)", in: view, world: .defaultClient) as! Double
            XCTAssertEqual(fraction, 0.5, accuracy: 0.02)
            let reopened = ReaderModel(book: model.book, library: model.library)
            XCTAssertEqual(reopened.target.fraction, 0.5, accuracy: 0.02)
        })
    }

    @MainActor
    func testPageCountViewport() async throws {
        let paragraphs = String(repeating: "<p>Changing the viewport must recalculate every chapter at the new screen size.</p>", count: 120)
        try await checkChapter(paragraphs, inspect: { model, view in
            try await self.waitForPages(model)
            let initial = try XCTUnwrap(model.pageTotal)
            view.frame.size = CGSize(width: 700, height: 300)

            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while model.pageTotal == initial, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            try await self.waitForPages(model)
            let metrics = try await self.evaluate("[document.documentElement.scrollHeight, innerHeight]", in: view, world: .defaultClient) as! [Double]
            XCTAssertNotEqual(model.pageTotal, initial)
            XCTAssertEqual(model.pageTotal, Int(ceil(metrics[0] / metrics[1])) + 1)
        })
    }

    @MainActor
    func testPageCountFailure() async throws {
        try await checkChapter("<p>Reading remains available if another chapter cannot be measured.</p>", inspect: { model, _ in
            let next = model.root.appendingPathComponent("next.xhtml")
            let original = try Data(contentsOf: next)
            try FileManager.default.removeItem(at: next)
            defer { try? original.write(to: next) }

            let deadline = ContinuousClock.now.advanced(by: .seconds(17))
            while model.pageState == .calculating, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(model.pageState, .unavailable)
            XCTAssertNil(model.pageNumber)
            XCTAssertNil(model.error)
            XCTAssertFalse(model.isLoading)
        })
    }

    @MainActor
    func testJustifiedBodyText() async throws {
        try await checkChapter("""
        <style>p { text-align: left !important; } h1 { text-align: center !important; }</style>
        <p id="paragraph">Publisher paragraph.</p>
        <p id="inline" style="text-align:center !important">Inline alignment.</p>
        <div id="container" style="text-align:left !important">Text without a paragraph.</div>
        <blockquote id="quote" style="text-align:center"><p>Quoted text.</p></blockquote>
        <ul><li id="item" style="text-align:left">List text.</li></ul>
        <h1>Centered <span>heading</span></h1><h2>Inherited alignment</h2>
        <h3 style="text-align:left !important">Inline heading</h3>
        <h4>Fourth heading</h4><h5>Fifth heading</h5><h6>Sixth heading</h6>
        <svg xmlns="http://www.w3.org/2000/svg"><text id="art" style="text-align:end">Art</text></svg>
        """, bodyStyle: "text-align:right !important", inspect: { _, view in
            let alignment = try await self.evaluate("""
            ['body', '#paragraph', '#inline', '#container', '#quote', '#quote p', '#item',
             'h1', 'h1 span', 'h2', 'h3', 'h4', 'h5', 'h6', '#art']
              .map(selector => getComputedStyle(document.querySelector(selector)).textAlign)
            """, in: view, world: .defaultClient) as? [String]
            XCTAssertEqual(alignment, Array(repeating: "justify", count: 7) +
                           ["center", "center", "right", "left", "right", "right", "right", "end"])
        })
    }

    @MainActor
    func testLibraryStartsAtTop() async throws {
        let index = BookPaths.root.appendingPathComponent("library.json")
        let original = try? Data(contentsOf: index)
        let book = Book(id: UUID(), fingerprint: "layout-test", title: "First book", author: "Test",
                        chapters: [Chapter(id: "chapter", path: "chapter.xhtml", title: "Chapter")],
                        contents: [], coverPath: nil, importedAt: Date())
        try FileManager.default.createDirectory(at: BookPaths.directory(book.id), withIntermediateDirectories: true)
        defer {
            if let original { try? original.write(to: index, options: .atomic) }
            else { try? FileManager.default.removeItem(at: index) }
            try? FileManager.default.removeItem(at: BookPaths.directory(book.id))
        }
        try JSONEncoder().encode([book]).write(to: index, options: .atomic)
        let controller = UIHostingController(rootView: LibraryView(library: LibraryStore())
            .environment(AppSettings()).preferredColorScheme(.light))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()

        let navigation = try XCTUnwrap(findNavigation(controller))
        XCTAssertTrue(navigation.navigationBar.isHidden, "Library must not reserve a title or toolbar row")
        XCTAssertFalse(navigation.navigationBar.topItem?.rightBarButtonItems?.contains { $0.title == "Import EPUB" } == true)

        // A black placeholder cover must start immediately below the status bar.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let sample = CGRect(x: 32, y: window.safeAreaInsets.top + 8, width: 1, height: 1)
        let pixel = try XCTUnwrap(image.cgImage?.cropping(to: sample))
        var rgba = [UInt8](repeating: 0, count: 4)
        let bitmap = try XCTUnwrap(CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(rgba[3], 255, "The sampled cover must be opaque")
        XCTAssertEqual(Array(rgba.prefix(3)), [0, 0, 0], "Extra space appears above the first book")
    }

    @MainActor
    func testLiveFontFamily() async throws {
        let paragraphs = String(repeating: "<p>A paragraph that wraps differently in different fonts. Keep the reading position.</p>", count: 80)
        try await checkChapter("""
        <style>p { font-family: Palatino !important; }</style>
        <p id="family-probe" style="font:italic bold 20px/30px 'Times New Roman' !important">Publisher text <b>bold</b> <em>italic</em></p>
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20"><text id="art" style="font-family:Courier">Art</text></svg>
        \(paragraphs)
        """, inspect: { model, view in
            let original = try await self.familyMetrics(view)
            XCTAssertTrue(original[0].contains("Times New Roman"))
            let token = model.target.token
            _ = try await self.evaluate("scrollTo(0, 0.4 * (document.documentElement.scrollHeight - innerHeight))", in: view, world: .defaultClient)
            var widths: [Double] = []

            for family in ["Georgia", "Helvetica", "Avenir Next"] {
                model.changeFont(.custom, family: family)
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                var values: [String] = []
                repeat {
                    values = try await self.familyMetrics(view)
                    if values.first?.contains(family) == true { break }
                    try await Task.sleep(for: .milliseconds(50))
                } while ContinuousClock.now < deadline
                XCTAssertTrue(values[0].contains(family))
                XCTAssertEqual(Array(values.dropFirst()), Array(original.dropFirst()))
                let families = try await self.evaluate("['body', '#family-probe b', '#family-probe em', 'svg + p'].map(selector => getComputedStyle(document.querySelector(selector)).fontFamily)", in: view, world: .defaultClient) as? [String]
                XCTAssertTrue(try XCTUnwrap(families).allSatisfy { $0.contains(family) })
                let fraction = try await self.evaluate("scrollY / Math.max(1, document.documentElement.scrollHeight - innerHeight)", in: view, world: .defaultClient) as? Double
                XCTAssertEqual(try XCTUnwrap(fraction), 0.4, accuracy: 0.02)
                let width = try await self.evaluate("(() => { const range = document.createRange(); range.selectNodeContents(document.getElementById('family-probe')); return range.getBoundingClientRect().width; })()", in: view, world: .defaultClient) as? Double
                widths.append(try XCTUnwrap(width))
                XCTAssertEqual(model.target.token, token)
                XCTAssertFalse(model.isLoading)
                XCTAssertNil(model.error)
            }
            XCTAssertGreaterThan(Set(widths).count, 1, "Font changes must affect text layout")

            model.changeFont(.publisher, family: model.settings.fontFamily)
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            var restored: [String] = []
            repeat {
                restored = try await self.familyMetrics(view)
                if restored == original { break }
                try await Task.sleep(for: .milliseconds(50))
            } while ContinuousClock.now < deadline
            XCTAssertEqual(restored, original)
            model.changeFont(.custom, family: "Avenir Next")
        })
    }

    @MainActor
    func testSavedFontFamily() async throws {
        try await checkChapter("<p id=\"family-probe\" style=\"font-family:Palatino !important\">Saved font.</p>",
                               fontMode: .custom, fontFamily: "Avenir Next", inspect: { _, view in
            let family = try await self.evaluate("getComputedStyle(document.getElementById('family-probe')).fontFamily", in: view, world: .defaultClient) as? String
            XCTAssertTrue(try XCTUnwrap(family).contains("Avenir Next"))
        })
    }

    @MainActor
    func testFontFamilyPersistence() throws {
        let first = try makeModel("<p>First book.</p>")
        let second = try makeModel("<p>Second book.</p>")
        defer {
            try? FileManager.default.removeItem(at: BookPaths.directory(first.book.id))
            try? FileManager.default.removeItem(at: BookPaths.directory(second.book.id))
        }
        XCTAssertEqual(first.settings.fontMode, .publisher)
        first.changeFont(.custom, family: "Avenir Next")
        first.changeFontSize(.increase)
        first.changeColors(.monochrome)
        first.changeMargins(.custom, width: 28)
        let reopened = ReaderModel(book: first.book, library: LibraryStore())
        XCTAssertEqual(reopened.settings, ReaderSettings(textScale: 110, colorMode: .monochrome, marginMode: .custom, sideMargin: 28,
                                                        fontMode: .custom, fontFamily: "Avenir Next"))
        XCTAssertEqual(second.settings, .standard)
        reopened.changeFontSize(.reset)
        reopened.changeFont(.publisher, family: reopened.settings.fontFamily)
        let disabled = ReaderModel(book: first.book, library: LibraryStore())
        XCTAssertEqual(disabled.settings.fontMode, .publisher)
        XCTAssertEqual(disabled.settings.fontFamily, "Avenir Next")
        XCTAssertEqual(disabled.settings.textScale, 100)
        disabled.changeFont(.custom, family: disabled.settings.fontFamily)
        XCTAssertEqual(ReaderModel(book: first.book, library: LibraryStore()).settings.fontMode, .custom)
        XCTAssertNil(disabled.error)
    }

    @MainActor
    func testFontFamilySaveFailure() throws {
        let model = try makeModel("<p>Unavailable book directory.</p>")
        try FileManager.default.removeItem(at: BookPaths.directory(model.book.id))
        model.changeFont(.custom, family: "Helvetica")
        XCTAssertEqual(model.settings, .standard)
        XCTAssertNotNil(model.error)
    }

    @MainActor
    func testLiveTheme() async throws {
        let model = try makeModel("""
        <p id="theme-probe" style="color:red !important">Publisher text.</p>
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20"><rect id="art" width="20" height="20" fill="red" /></svg>
        \(String(repeating: "<p>Keep this position while switching themes.</p>", count: 80))
        """)
        let suite = "BookpaneTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        let controller = UIHostingController(rootView: NavigationStack {
            ReaderView(book: model.book, library: model.library)
        }.modifier(ThemeStyle(settings: settings)))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: BookPaths.directory(model.book.id))
        }

        let view = try XCTUnwrap(findWebView(controller.view))
        let coordinator = try XCTUnwrap(view.navigationDelegate as? ChapterWebView.Coordinator)
        try await waitForChapter(coordinator.model)
        XCTAssertNil(coordinator.model.error)
        let token = coordinator.model.target.token
        _ = try await evaluate("scrollTo(0, 400)", in: view, world: .defaultClient)
        let steps: [(AppTheme, UIUserInterfaceStyle, UIUserInterfaceStyle)] = [
            (.system, .light, .light), (.dark, .light, .dark), (.light, .dark, .light),
            (.system, .dark, .dark), (.system, .light, .light)
        ]
        for mode in [ReaderColorMode.publisher, .monochrome] {
            coordinator.model.changeColors(mode)
            for (theme, system, expectedStyle) in steps {
                window.overrideUserInterfaceStyle = system
                settings.changeTheme(theme)
                let dark = expectedStyle == .dark
                let ink = dark ? "rgb(255, 255, 255)" : "rgb(0, 0, 0)"
                let paper = dark ? "rgb(0, 0, 0)" : "rgb(255, 255, 255)"
                let expected = [dark ? "dark" : "light", paper, ink,
                                mode == .publisher ? "rgb(255, 0, 0)" : ink, "rgb(255, 0, 0)"]
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                var values: [String] = []
                repeat {
                    let result = try await evaluate("""
                    [matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light',
                     getComputedStyle(document.documentElement).backgroundColor,
                     getComputedStyle(document.body).color,
                     getComputedStyle(document.getElementById('theme-probe')).color,
                     getComputedStyle(document.getElementById('art')).fill]
                    """, in: view, world: .defaultClient)
                    values = try XCTUnwrap(result as? [String])
                    if values == expected, view.traitCollection.userInterfaceStyle == expectedStyle { break }
                    try await Task.sleep(for: .milliseconds(50))
                } while ContinuousClock.now < deadline
                XCTAssertEqual(values, expected, "\(theme), \(mode)")
                XCTAssertEqual(view.traitCollection.userInterfaceStyle, expectedStyle)
                let position = try await evaluate("scrollY", in: view, world: .defaultClient) as? Double
                XCTAssertEqual(try XCTUnwrap(position), 400, accuracy: 1)
                XCTAssertEqual(coordinator.model.target.token, token)
                XCTAssertFalse(coordinator.model.isLoading)
                XCTAssertNil(coordinator.model.error)
            }
        }
    }

    @MainActor
    func testLiveMargins() async throws {
        let paragraphs = String(repeating: "<p>Keep the reading position while side margins reflow this paragraph across several lines.</p>", count: 80)
        try await checkChapter("""
        <style>html { margin: 0 6px !important; padding: 0 4px !important; } p { margin: 0; text-indent: 12px; }</style>
        <p id="margin-probe">Publisher spacing.</p>
        <img id="image-probe" src="image.png" width="20" height="20" alt="" />
        \(paragraphs)
        """, bodyStyle: "margin:13px 18px 17px 22px !important; padding:19px 9px 23px 7px !important; max-inline-size:280px !important; color:red !important", inspect: { model, view in
            let original = try await self.marginMetrics(view)
            let token = model.target.token
            _ = try await self.evaluate("scrollTo(0, 0.4 * (document.documentElement.scrollHeight - innerHeight))", in: view, world: .defaultClient)

            for width in stride(from: 0, through: 48, by: 4) {
                model.changeMargins(.custom, width: width)
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                var values: [Double] = []
                repeat {
                    values = try await self.marginMetrics(view)
                    if abs(values[0] - Double(width)) < 1, abs(values[1] - Double(width)) < 1 { break }
                    try await Task.sleep(for: .milliseconds(50))
                } while ContinuousClock.now < deadline
                XCTAssertEqual(values[0], Double(width), accuracy: 1)
                XCTAssertEqual(values[1], Double(width), accuracy: 1)
                XCTAssertEqual(Array(values[2...7]), Array(original[2...7]))
                XCTAssertEqual(values[8], 0.4, accuracy: 0.02)
                XCTAssertEqual(model.target.token, token)
                XCTAssertFalse(model.isLoading)
                XCTAssertNil(model.error)
            }

            model.changeColors(.monochrome)
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            var color = "rgb(255, 0, 0)"
            repeat {
                color = try await self.evaluate("getComputedStyle(document.body).color", in: view, world: .defaultClient) as? String ?? ""
                if color != "rgb(255, 0, 0)" { break }
                try await Task.sleep(for: .milliseconds(50))
            } while ContinuousClock.now < deadline
            XCTAssertNotEqual(color, "rgb(255, 0, 0)")

            model.changeMargins(.publisher, width: 48)
            let restoreDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            var restored: [Double] = []
            repeat {
                restored = try await self.marginMetrics(view)
                if Array(restored[0...7]) == Array(original[0...7]) { break }
                try await Task.sleep(for: .milliseconds(50))
            } while ContinuousClock.now < restoreDeadline
            XCTAssertEqual(Array(restored[0...7]), Array(original[0...7]))
            XCTAssertEqual(restored[8], 0.4, accuracy: 0.02)
            let keptColor = try await self.evaluate("getComputedStyle(document.body).color", in: view, world: .defaultClient) as? String
            XCTAssertEqual(keptColor, color)
            model.changeMargins(.custom, width: 48)
        })
    }

    @MainActor
    func testSavedMargins() async throws {
        try await checkChapter("<p id=\"margin-probe\">Saved spacing.</p><img id=\"image-probe\" src=\"image.png\" width=\"20\" height=\"20\" alt=\"\" />",
                               marginMode: .custom, sideMargin: 32, inspect: { _, view in
            let values = try await self.marginMetrics(view)
            XCTAssertEqual(values[0], 32, accuracy: 1)
            XCTAssertEqual(values[1], 32, accuracy: 1)
        })
    }

    @MainActor
    func testMarginPersistence() throws {
        let first = try makeModel("<p>First book.</p>")
        let second = try makeModel("<p>Second book.</p>")
        defer {
            try? FileManager.default.removeItem(at: BookPaths.directory(first.book.id))
            try? FileManager.default.removeItem(at: BookPaths.directory(second.book.id))
        }
        first.changeMargins(.custom, width: 28)
        first.changeFontSize(.increase)
        first.changeColors(.monochrome)
        let reopened = ReaderModel(book: first.book, library: LibraryStore())
        XCTAssertEqual(reopened.settings, ReaderSettings(textScale: 110, colorMode: .monochrome, marginMode: .custom, sideMargin: 28))
        XCTAssertEqual(second.settings, .standard)
        reopened.changeFontSize(.reset)
        reopened.changeColors(.publisher)
        XCTAssertEqual(reopened.settings, ReaderSettings(textScale: 100, marginMode: .custom, sideMargin: 28))
        reopened.changeMargins(.publisher, width: reopened.settings.sideMargin)
        let disabled = ReaderModel(book: first.book, library: LibraryStore())
        XCTAssertEqual(disabled.settings, ReaderSettings(textScale: 100, sideMargin: 28))
        disabled.changeMargins(.custom, width: disabled.settings.sideMargin)
        XCTAssertEqual(ReaderModel(book: first.book, library: LibraryStore()).settings, ReaderSettings(textScale: 100, marginMode: .custom, sideMargin: 28))
        XCTAssertNil(disabled.error)
    }

    @MainActor
    func testMarginSaveFailure() throws {
        let model = try makeModel("<p>Unavailable book directory.</p>")
        try FileManager.default.removeItem(at: BookPaths.directory(model.book.id))
        model.changeMargins(.custom, width: 16)
        XCTAssertEqual(model.settings, .standard)
        XCTAssertNotNil(model.error)
    }

    @MainActor
    func testPublisherMargins() async throws {
        try await checkChapter("""
        <style>html { margin: 0; padding: 0; } body { margin: 0 20px !important; }</style>
        <p id="margin-probe">Publisher margins.</p>
        """, inspect: { _, view in
            let values = try await self.evaluate("""
            [getComputedStyle(document.body).paddingLeft,
             getComputedStyle(document.body).paddingRight,
             document.getElementById('margin-probe').getBoundingClientRect().left,
             innerWidth - document.getElementById('margin-probe').getBoundingClientRect().right]
            """, in: view, world: .defaultClient) as? [Any]
            let margins = try XCTUnwrap(values)
            XCTAssertEqual(margins[0] as? String, "0px")
            XCTAssertEqual(margins[1] as? String, "0px")
            XCTAssertEqual(margins[2] as? Double, 20)
            XCTAssertEqual(margins[3] as? Double, 20)
        })
    }

    @MainActor
    func testMonochromeColors() async throws {
        try await checkChapter(Self.coloredChapter, colorMode: .monochrome, inspect: { _, view in
            let window = try XCTUnwrap(view.window)
            let originalStyle = window.overrideUserInterfaceStyle
            defer { window.overrideUserInterfaceStyle = originalStyle }
            for (mode, paper, ink) in [(UIUserInterfaceStyle.light, "rgb(255, 255, 255)", "rgb(0, 0, 0)"),
                                       (.dark, "rgb(0, 0, 0)", "rgb(255, 255, 255)"),
                                       (.light, "rgb(255, 255, 255)", "rgb(0, 0, 0)")] {
                window.overrideUserInterfaceStyle = mode
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                var colors: [String] = []
                let expected = [paper, ink, ink, "rgba(0, 0, 0, 0)", ink, "rgb(255, 0, 0)", "20"]
                repeat {
                    colors = try await self.colors(view)
                    if colors == expected { break }
                    try await Task.sleep(for: .milliseconds(50))
                } while ContinuousClock.now < deadline
                XCTAssertEqual(colors, expected)
            }
        })
    }

    @MainActor
    func testPublisherColors() async throws {
        let paragraphs = String(repeating: "<p>Keep this reading position while switching colors.</p>", count: 80)
        try await checkChapter(Self.coloredChapter + paragraphs, inspect: { model, view in
            let original = try await self.colors(view)
            XCTAssertEqual(Array(original.dropFirst()), ["rgb(255, 0, 0)", "rgb(255, 0, 0)", "rgb(255, 255, 0)", "rgb(0, 0, 255)", "rgb(255, 0, 0)", "20"])
            let token = model.target.token
            _ = try await self.evaluate("scrollTo(0, 400)", in: view, world: .defaultClient)
            let position = try await self.evaluate("scrollY", in: view, world: .defaultClient) as? Double
            let styles = try await self.evaluate("document.getElementById('text').style.cssText", in: view, world: .defaultClient) as? String

            for mode in [ReaderColorMode.monochrome, .publisher, .monochrome, .publisher] {
                model.changeColors(mode)
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                var colors: [String] = []
                repeat {
                    colors = try await self.colors(view)
                    if (mode == .publisher && colors == original) || (mode == .monochrome && colors[1] != original[1]) { break }
                    try await Task.sleep(for: .milliseconds(50))
                } while ContinuousClock.now < deadline
                if mode == .publisher {
                    XCTAssertEqual(colors, original)
                    let restored = try await self.evaluate("document.getElementById('text').style.cssText", in: view, world: .defaultClient) as? String
                    XCTAssertEqual(restored, styles)
                } else {
                    XCTAssertNotEqual(colors[1], original[1])
                }
                let current = try await self.evaluate("scrollY", in: view, world: .defaultClient) as? Double
                XCTAssertEqual(try XCTUnwrap(current), try XCTUnwrap(position), accuracy: 1)
                XCTAssertEqual(model.target.token, token)
                XCTAssertFalse(model.isLoading)
                XCTAssertNil(model.error)
            }
        })
    }

    @MainActor
    func testColorPersistence() throws {
        let first = try makeModel("<p>First book.</p>")
        let second = try makeModel("<p>Second book.</p>")
        defer {
            try? FileManager.default.removeItem(at: BookPaths.directory(first.book.id))
            try? FileManager.default.removeItem(at: BookPaths.directory(second.book.id))
        }
        XCTAssertEqual(first.settings.colorMode, .publisher)
        first.changeFontSize(.increase)
        first.changeColors(.monochrome)
        let reopened = ReaderModel(book: first.book, library: LibraryStore())
        XCTAssertEqual(reopened.settings, ReaderSettings(textScale: 110, colorMode: .monochrome))
        XCTAssertEqual(second.settings.colorMode, .publisher)
        reopened.changeFontSize(.reset)
        XCTAssertEqual(reopened.settings, ReaderSettings(textScale: 100, colorMode: .monochrome))
        reopened.changeColors(.publisher)
        XCTAssertEqual(ReaderModel(book: first.book, library: LibraryStore()).settings, .standard)
        XCTAssertNil(reopened.error)
    }

    @MainActor
    func testColorSaveFailure() throws {
        let model = try makeModel("<p>Unavailable book directory.</p>")
        try FileManager.default.removeItem(at: BookPaths.directory(model.book.id))
        model.changeColors(.monochrome)
        XCTAssertEqual(model.settings.colorMode, .publisher)
        XCTAssertNotNil(model.error)
    }

    @MainActor
    func testControlTaps() async throws {
        var toggles = 0
        try await checkChapter("<p id=\"text\">Selectable text.</p><a id=\"link\" href=\"#text\">Link</a>", toggleControls: { toggles += 1 }) { model, view in
            try await self.click(in: view)
            try await Task.sleep(for: .milliseconds(450))
            XCTAssertEqual(toggles, 1)

            try await self.click(x: 20, in: view)
            try await self.click(on: "#link", in: view)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !model.target.href.hasSuffix("#text"), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            try await self.waitForChapter(model)
            XCTAssertTrue(model.target.href.hasSuffix("#text"))
            XCTAssertNil(model.error)
            XCTAssertFalse(model.isLoading)
            _ = try await self.evaluate("const range = document.createRange(); range.selectNodeContents(document.getElementById('text')); getSelection().addRange(range);", in: view, world: .defaultClient)
            try await self.click(in: view)
            try await Task.sleep(for: .milliseconds(450))
            XCTAssertEqual(toggles, 1)

            _ = try await self.evaluate("getSelection().removeAllRanges()", in: view, world: .defaultClient)
            try await self.click(in: view)
            try await self.click(detail: 2, in: view)
            try await Task.sleep(for: .milliseconds(450))
            XCTAssertEqual(toggles, 1)

            try await self.click(in: view)
            try await Task.sleep(for: .milliseconds(450))
            XCTAssertEqual(toggles, 2)
        }
    }

    @MainActor
    func testChapterSwipes() async throws {
        try await checkChapter("<p id=\"text\">Swipe without disturbing selection or scrolling.</p>", inspect: { model, view in
            let initial = model.target.token
            for offset in [CGSize(width: 5, height: -150), CGSize(width: -30, height: 0), CGSize(width: -80, height: -100), CGSize(width: 140, height: 0)] {
                try await self.swipe(offset, in: view)
            }
            _ = try await self.evaluate("const range = document.createRange(); range.selectNodeContents(document.getElementById('text')); getSelection().addRange(range);", in: view, world: .defaultClient)
            try await self.swipe(CGSize(width: -140, height: 0), in: view)
            XCTAssertEqual(model.target.token, initial)
            _ = try await self.evaluate("getSelection().removeAllRanges()", in: view, world: .defaultClient)

            try await self.swipe(CGSize(width: -140, height: 0), in: view)
            try await self.waitForChapter(model)
            XCTAssertEqual(model.target.index, 1)
            XCTAssertNil(model.error)
            let last = model.target.token
            try await self.swipe(CGSize(width: -140, height: 0), in: view)
            XCTAssertEqual(model.target.token, last)

            try await self.swipe(CGSize(width: 140, height: 0), in: view)
            try await self.waitForChapter(model)
            XCTAssertEqual(model.target.index, 0)
            XCTAssertNil(model.error)
        })
    }

    @MainActor
    func testFullscreenControls() async throws {
        let model = try makeModel(String(repeating: "<p>Fullscreen reading uses the screen from top to bottom.</p>", count: 80))
        let controller = UIHostingController(rootView: NavigationStack { ReaderView(book: model.book, library: model.library) }.modifier(ThemeStyle(settings: AppSettings())))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            try? FileManager.default.removeItem(at: BookPaths.directory(model.book.id))
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(17))
        var readyView: WKWebView?
        while readyView == nil, ContinuousClock.now < deadline {
            if let view = findWebView(controller.view),
               let ready = try? await evaluate("typeof window.bookpaneReport === 'function'", in: view, world: .defaultClient), ready as? Bool == true,
               model.library.progress[model.book.id] != nil {
                readyView = view
            } else { try await Task.sleep(for: .milliseconds(50)) }
        }
        let view = try XCTUnwrap(readyView)
        let reader = try XCTUnwrap(view.navigationDelegate as? ChapterWebView.Coordinator).model
        try await waitForPages(reader)
        let pageTotal = reader.pageTotal
        let navigation = try XCTUnwrap(findNavigation(controller))
        _ = try await evaluate("scrollTo(0, 400)", in: view, world: .defaultClient)
        var position: [Double]?
        for (step, hidden) in [true, false, true].enumerated() {
            if step > 0 { try await click(x: Double(view.bounds.midX), in: view) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < deadline {
                window.layoutIfNeeded()
                let frame = view.convert(view.bounds, to: window)
                let matchesFrame = abs(frame.minY - window.bounds.minY) < 1 && abs(frame.maxY - window.bounds.maxY) < 1
                if navigation.navigationBar.isHidden == hidden, matchesFrame {
                    let height = try await evaluate("innerHeight", in: view, world: .defaultClient) as? Double
                    if let height, abs(height - Double(frame.height)) < 1 { break }
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(navigation.navigationBar.isHidden, hidden)
            XCTAssertEqual(reader.pageTotal, pageTotal, "Controls must not change the page count")
            XCTAssertEqual(reader.pageState, .ready)
            let frame = view.convert(view.bounds, to: window)
            XCTAssertEqual(frame.minY, window.bounds.minY, accuracy: 1)
            XCTAssertEqual(frame.maxY, window.bounds.maxY, accuracy: 1)
            if hidden {
                XCTAssertEqual(view.scrollView.adjustedContentInset.top, 0, accuracy: 1)
                XCTAssertEqual(view.scrollView.adjustedContentInset.bottom, 0, accuracy: 1)
            } else {
                let bar = navigation.navigationBar.convert(navigation.navigationBar.bounds, to: window)
                XCTAssertEqual(view.scrollView.adjustedContentInset.top, bar.maxY, accuracy: 1)
                XCTAssertGreaterThan(view.scrollView.adjustedContentInset.bottom, window.safeAreaInsets.bottom)
            }
            let height = try await evaluate("innerHeight", in: view, world: .defaultClient) as? Double
            XCTAssertEqual(try XCTUnwrap(height), Double(window.bounds.height), accuracy: 1)

            // Controls must preserve both scroll position and the text's screen position.
            let metrics = try await evaluate("[scrollY, document.querySelector('p').getBoundingClientRect().top]", in: view, world: .defaultClient) as? [Double]
            let current = try XCTUnwrap(metrics)
            if let position {
                XCTAssertEqual(current[0], position[0], accuracy: 1)
                XCTAssertEqual(current[1] + Double(frame.minY), position[1], accuracy: 1)
            } else {
                position = [current[0], current[1] + Double(frame.minY)]
            }

            if !hidden {
                let insets = view.scrollView.adjustedContentInset
                let offset = view.scrollView.contentOffset
                view.scrollView.setContentOffset(CGPoint(x: 0, y: -insets.top), animated: false)
                try await Task.sleep(for: .milliseconds(100))
                let first = try await evaluate("document.querySelector('p').getBoundingClientRect().top + scrollY", in: view, world: .defaultClient) as? Double
                let top = view.scrollView.convert(CGPoint(x: 0, y: try XCTUnwrap(first)), to: window).y
                XCTAssertGreaterThanOrEqual(top, insets.top)
                try await checkControlOffset(view, navigation: navigation)

                let end = view.scrollView.contentSize.height - view.bounds.height + insets.bottom
                view.scrollView.setContentOffset(CGPoint(x: 0, y: end), animated: false)
                try await Task.sleep(for: .milliseconds(100))
                let last = try await evaluate("document.querySelector('p:last-of-type').getBoundingClientRect().bottom + scrollY", in: view, world: .defaultClient) as? Double
                let bottom = view.scrollView.convert(CGPoint(x: 0, y: try XCTUnwrap(last)), to: window).y
                XCTAssertLessThanOrEqual(bottom, window.bounds.height - insets.bottom)
                try await checkControlOffset(view, navigation: navigation)
                view.scrollView.setContentOffset(offset, animated: false)
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    @MainActor
    func testLoadingIndicator() async throws {
        let model = try makeModel("<p>Delayed loading feedback.</p>")
        let controller = UIHostingController(rootView: NavigationStack { ReaderView(book: model.book, library: model.library) }.modifier(ThemeStyle(settings: AppSettings())))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            try? FileManager.default.removeItem(at: BookPaths.directory(model.book.id))
        }

        let view = try XCTUnwrap(findWebView(controller.view))
        let coordinator = try XCTUnwrap(view.navigationDelegate as? ChapterWebView.Coordinator)
        // Hold readiness so loading duration is independent of WebKit's speed.
        view.configuration.userContentController.removeScriptMessageHandler(forName: "progress", contentWorld: .defaultClient)
        XCTAssertNil(findSpinner(controller.view))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(findSpinner(controller.view))

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while findSpinner(controller.view) == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotNil(findSpinner(controller.view))

        coordinator.model.move(1)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(findSpinner(controller.view))
        coordinator.finish()
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(findSpinner(controller.view))
        XCTAssertFalse(coordinator.model.isLoading)
        XCTAssertNil(coordinator.model.error)
    }

    @MainActor
    func testLiveFontSize() async throws {
        let paragraphs = String(repeating: "<p>A paragraph long enough to wrap when text grows. Keep this position while resizing.</p>", count: 80)
        try await checkChapter("""
        <h2><span id="heading-probe" style="font-size:32px !important">Heading</span></h2>
        <span id="font-probe" style="font-size:16px !important; -webkit-text-size-adjust:none">Text</span>
        <img id="image-probe" src="image.png" width="20" height="20" alt="" />
        \(paragraphs)
        """, inspect: { model, view in
            let initial = try await self.fontMetrics(view)
            let token = model.target.token
            _ = try await self.evaluate("scrollTo(0, 0.4 * (document.documentElement.scrollHeight - innerHeight)); window.bookpaneReport();", in: view, world: .defaultClient)
            let position = try await self.waitForMetrics(view) { abs($0[3] - 0.4) < 0.02 }
            XCTAssertEqual(position[3], 0.4, accuracy: 0.02)
            for _ in 0..<10 { model.changeFontSize(.increase) }

            let enlarged = try await self.waitForMetrics(view) { $0[0] > initial[0] * 1.7 && abs($0[3] - position[3]) < 0.02 }
            XCTAssertGreaterThan(enlarged[0], initial[0] * 1.7)
            XCTAssertEqual(enlarged[1] / enlarged[0], initial[1] / initial[0], accuracy: 0.15)
            XCTAssertEqual(enlarged[2], initial[2], accuracy: 1)
            XCTAssertEqual(enlarged[3], position[3], accuracy: 0.02)
            XCTAssertEqual(model.target.token, token)
            XCTAssertFalse(model.isLoading)
            XCTAssertNil(model.error)

            model.changeFontSize(.reset)
            let reset = try await self.waitForMetrics(view) { abs($0[0] - initial[0]) < 1 && abs($0[3] - position[3]) < 0.02 }
            XCTAssertEqual(reset[0], initial[0], accuracy: 1)
            XCTAssertEqual(reset[3], position[3], accuracy: 0.02)
        })
    }

    @MainActor
    func testBookFontSizePersistence() throws {
        let first = try makeModel("<p>First book.</p>")
        let second = try makeModel("<p>Second book.</p>")
        defer {
            try? FileManager.default.removeItem(at: BookPaths.directory(first.book.id))
            try? FileManager.default.removeItem(at: BookPaths.directory(second.book.id))
        }
        first.changeFontSize(.increase)
        first.changeFontSize(.increase)
        XCTAssertEqual(first.settings.textScale, 120)
        XCTAssertEqual(second.settings, .standard)
        let reopened = ReaderModel(book: first.book, library: LibraryStore())
        XCTAssertEqual(reopened.settings.textScale, 120)
        reopened.changeFontSize(.reset)
        XCTAssertEqual(ReaderModel(book: first.book, library: LibraryStore()).settings, .standard)
        XCTAssertNil(reopened.error)
    }

    @MainActor
    func testFontSaveFailure() throws {
        let model = try makeModel("<p>Unavailable book directory.</p>")
        try FileManager.default.removeItem(at: BookPaths.directory(model.book.id))
        model.changeFontSize(.increase)
        XCTAssertEqual(model.settings, .standard)
        XCTAssertNotNil(model.error)
    }

    @MainActor
    func testTextChapterReady() async throws {
        try await checkChapter("<p>A short chapter.</p>")
    }

    @MainActor
    func testSVGCoverReady() async throws {
        try await checkChapter("""
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 20 20">
          <image width="20" height="20" xlink:href="image.png" />
        </svg>
        """)
    }

    @MainActor
    func testLazyImageReady() async throws {
        try await checkChapter("""
        <div style="height: 10000px"></div>
        <img loading="lazy" src="image.png" width="20" height="20" alt="" />
        """)
    }

    @MainActor
    func testReaderTimeout() async throws {
        let model = try makeModel("<p>Missing message bridge.</p>")
        defer { try? FileManager.default.removeItem(at: BookPaths.directory(model.book.id)) }
        let coordinator = ChapterWebView.Coordinator(model: model)
        // Omit the script handler so readiness cannot reach the model.
        let view = WKWebView()
        view.navigationDelegate = coordinator
        coordinator.webView = view
        coordinator.ready = true
        coordinator.loadIfNeeded(model.target)

        try await waitForChapter(model, timeout: .seconds(17))
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.error?.contains("too long") == true)
        view.stopLoading()
    }

    @MainActor
    private func checkChapter(_ content: String, colorMode: ReaderColorMode = .publisher, marginMode: ReaderMarginMode = .publisher, sideMargin: Int = 0, fontMode: ReaderFontMode = .publisher, fontFamily: String = ReaderSettings.defaultFont, bodyStyle: String = "", toggleControls: @escaping () -> Void = {}, inspect: @MainActor (ReaderModel, WKWebView) async throws -> Void = { _, _ in }) async throws {
        let model = try makeModel(content, bodyStyle: bodyStyle)
        model.changeColors(colorMode)
        model.changeMargins(marginMode, width: sideMargin)
        model.changeFont(fontMode, family: fontFamily)
        let controller = UIHostingController(rootView: ChapterWebView(model: model, toggleControls: toggleControls))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            try? FileManager.default.removeItem(at: BookPaths.directory(model.book.id))
        }

        try await waitForChapter(model)
        let view = try XCTUnwrap(findWebView(controller.view))
        let status = try await evaluate("[document.readyState, document.visibilityState, document.fonts.status].join('|')", in: view, world: .defaultClient)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isLoading, "Chapter never reported ready: \(status)")
        let width = try await evaluate("window.innerWidth", in: view, world: .defaultClient)
        XCTAssertEqual(try XCTUnwrap(width as? Double), Double(view.bounds.width), accuracy: 1)
        XCTAssertFalse(view.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        let pageScript = try await evaluate("typeof window.bookScriptRan", in: view, world: .page)
        let appScript = try await evaluate("typeof window.bookpaneReport", in: view, world: .defaultClient)
        XCTAssertEqual(pageScript as? String, "undefined")
        XCTAssertEqual(appScript as? String, "function")
        try await inspect(model, view)

        model.move(1)
        try await waitForChapter(model)
        XCTAssertEqual(model.target.index, 1)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isLoading, "Next chapter never reported ready")
        XCTAssertEqual(view.url?.lastPathComponent, "next.xhtml")
        let color = try await evaluate("getComputedStyle(document.body).color", in: view, world: .defaultClient)
        let dark = view.traitCollection.userInterfaceStyle == .dark
        XCTAssertEqual(color as? String, dark ? "rgb(255, 255, 255)" : "rgb(0, 0, 0)")
        let padding = try await evaluate("getComputedStyle(document.body).paddingLeft", in: view, world: .defaultClient) as? String
        XCTAssertEqual(padding, model.settings.marginMode == .custom ? "\(model.settings.sideMargin)px" : "0px")
        let family = try await evaluate("getComputedStyle(document.body).fontFamily", in: view, world: .defaultClient) as? String
        XCTAssertTrue(try XCTUnwrap(family).contains(model.settings.fontMode == .custom ? model.settings.fontFamily : "Georgia"))
    }

    @MainActor
    private func makeModel(_ content: String, bodyStyle: String = "") throws -> ReaderModel {
        let id = UUID()
        let root = BookPaths.content(id)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let document = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Reader test</title></head>
        <body style="\(bodyStyle)">\(content)<script>window.bookScriptRan = true;</script></body></html>
        """
        try document.write(to: root.appendingPathComponent("chapter.xhtml"), atomically: true, encoding: .utf8)
        try "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Next chapter.</p></body></html>"
            .write(to: root.appendingPathComponent("next.xhtml"), atomically: true, encoding: .utf8)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        try XCTUnwrap(image.pngData()).write(to: root.appendingPathComponent("image.png"))
        let book = Book(id: id, fingerprint: "reader-test", title: "Reader test", author: "Bookpane",
                        chapters: [Chapter(id: "chapter", path: "chapter.xhtml", title: "Chapter"),
                                   Chapter(id: "next", path: "next.xhtml", title: "Next")],
                        contents: [], coverPath: nil, importedAt: Date())
        return ReaderModel(book: book, library: LibraryStore())
    }

    @MainActor
    private func waitForPages(_ model: ReaderModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while model.pageNumber == nil && model.pageState != .unavailable && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.pageState, .ready)
        XCTAssertNotNil(model.pageNumber)
    }

    @MainActor
    private func waitForChapter(_ model: ReaderModel, timeout: Duration = .seconds(17)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while model.isLoading && model.error == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @MainActor
    private func waitForMetrics(_ view: WKWebView, until matches: ([Double]) -> Bool) async throws -> [Double] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var values = try await fontMetrics(view)
        while !matches(values), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            values = try await fontMetrics(view)
        }
        return values
    }

    @MainActor
    private func familyMetrics(_ view: WKWebView) async throws -> [String] {
        let values = try await evaluate("""
        (() => {
          const text = document.getElementById('family-probe');
          const style = getComputedStyle(text);
          return [style.fontFamily, style.fontWeight, style.fontStyle, style.fontSize, style.lineHeight,
            getComputedStyle(text.querySelector('b')).fontWeight, getComputedStyle(text.querySelector('em')).fontStyle,
            getComputedStyle(document.getElementById('art')).fontFamily];
        })()
        """, in: view, world: .defaultClient)
        return try XCTUnwrap(values as? [String])
    }

    @MainActor
    private func fontMetrics(_ view: WKWebView) async throws -> [Double] {
        let values = try await evaluate("""
        [document.getElementById('font-probe').getBoundingClientRect().height,
         document.getElementById('heading-probe').getBoundingClientRect().height,
         document.getElementById('image-probe').getBoundingClientRect().width,
         scrollY / Math.max(1, document.documentElement.scrollHeight - innerHeight)]
        """, in: view, world: .defaultClient)
        return try XCTUnwrap(values as? [Double])
    }

    @MainActor
    private func marginMetrics(_ view: WKWebView) async throws -> [Double] {
        let values = try await evaluate("""
        (() => {
          const body = getComputedStyle(document.body);
          const text = document.getElementById('margin-probe');
          const rect = text.getBoundingClientRect();
          return [rect.left, innerWidth - rect.right,
            parseFloat(body.marginTop), parseFloat(body.marginBottom),
            parseFloat(body.paddingTop), parseFloat(body.paddingBottom),
            parseFloat(getComputedStyle(text).textIndent), document.getElementById('image-probe').width,
            scrollY / Math.max(1, document.documentElement.scrollHeight - innerHeight)];
        })()
        """, in: view, world: .defaultClient)
        return try XCTUnwrap(values as? [Double])
    }

    @MainActor
    private func colors(_ view: WKWebView) async throws -> [String] {
        let result = try await evaluate("""
        [getComputedStyle(document.documentElement).backgroundColor,
         getComputedStyle(document.getElementById('text')).color,
         getComputedStyle(document.getElementById('text')).webkitTextFillColor,
         getComputedStyle(document.getElementById('text')).backgroundColor,
         getComputedStyle(document.getElementById('link')).color,
         getComputedStyle(document.getElementById('art')).fill,
         document.getElementById('image').width.toString()]
        """, in: view, world: .defaultClient)
        return try XCTUnwrap(result as? [String])
    }

    @MainActor
    private func evaluate(_ script: String, in view: WKWebView, world: WKContentWorld) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(script, in: nil, in: world) { result in
                continuation.resume(with: result)
            }
        }
    }

    @MainActor
    private func click(detail: Int = 1, x: Double = 195, on selector: String = "body", in view: WKWebView) async throws {
        _ = try await evaluate("document.querySelector('\(selector)').dispatchEvent(new MouseEvent('click', {bubbles:true, detail:\(detail), clientX:\(x), clientY:200}))", in: view, world: .defaultClient)
    }

    @MainActor
    private func swipe(_ offset: CGSize, in view: WKWebView) async throws {
        _ = try await evaluate("""
        (() => {
          const start = new Event('touchstart', {bubbles:true});
          Object.defineProperty(start, 'touches', {value:[{clientX:195, clientY:300}]});
          document.body.dispatchEvent(start);
          const end = new Event('touchend', {bubbles:true});
          Object.defineProperty(end, 'touches', {value:[]});
          Object.defineProperty(end, 'changedTouches', {value:[{clientX:195 + \(offset.width), clientY:300 + \(offset.height)}]});
          document.body.dispatchEvent(end);
        })()
        """, in: view, world: .defaultClient)
    }

    @MainActor
    private func checkControlOffset(_ view: WKWebView, navigation: UINavigationController) async throws {
        let offset = view.scrollView.contentOffset
        let insets = view.scrollView.contentInset
        let end = max(0, view.scrollView.contentSize.height - view.bounds.height)
        let hiddenInsets = UIEdgeInsets(top: max(0, -offset.y), left: 0, bottom: max(0, offset.y - end), right: 0)
        for hidden in [true, false] {
            try await click(x: Double(view.bounds.midX), in: view)
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < deadline {
                if navigation.navigationBar.isHidden == hidden,
                   view.scrollView.contentInset == (hidden ? hiddenInsets : insets) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(navigation.navigationBar.isHidden, hidden)
            XCTAssertEqual(view.scrollView.contentOffset.y, offset.y, accuracy: 1)
        }
    }

    @MainActor
    private func findNavigation(_ controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap(findNavigation).first
    }

    @MainActor
    private func findWebView(_ view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        return view.subviews.lazy.compactMap(findWebView).first
    }

    @MainActor
    private func findSpinner(_ view: UIView) -> UIActivityIndicatorView? {
        if let spinner = view as? UIActivityIndicatorView { return spinner }
        return view.subviews.lazy.compactMap(findSpinner).first
    }

    private static let coloredChapter = """
    <p id="text" style="color:red !important; background-color:yellow !important; -webkit-text-fill-color:red !important">Text</p>
    <a id="link" href="#text" style="color:blue !important">Link</a>
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20"><rect id="art" width="20" height="20" fill="red" /></svg>
    <img id="image" src="image.png" width="20" height="20" alt="" />
    """
}
