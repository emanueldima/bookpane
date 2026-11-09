import Foundation
import Observation

struct ReaderTarget: Equatable {
    let token = UUID()
    let index: Int
    let href: String
    let fraction: Double
}

@MainActor @Observable
final class ReaderModel {
    let book: Book
    let library: LibraryStore
    private(set) var target: ReaderTarget
    private(set) var settings: ReaderSettings
    private var fraction: Double
    private var pageIndex: PageIndex?
    private(set) var pageState = PageState.calculating
    var error: String?
    var isLoading = true
    var flush: (() -> Void)?

    init(book: Book, library: LibraryStore) {
        self.book = book; self.library = library
        settings = (try? library.loadReaderSettings(for: book)) ?? .standard
        let saved = library.progress[book.id]
        let index = book.chapters.firstIndex { $0.id == saved?.chapterID } ?? 0
        let fraction = saved?.scrollFraction ?? 0
        let normalized = fraction.isFinite ? min(1, max(0, fraction)) : 0
        self.fraction = normalized
        target = ReaderTarget(index: index, href: book.chapters[index].path, fraction: normalized)
    }
    var chapter: Chapter { book.chapters[target.index] }
    var root: URL { BookPaths.content(book.id) }

    var pageNumber: Int? {
        guard !isLoading, let pageIndex else { return nil }
        return pageIndex.page(chapter: target.index, fraction: fraction)
    }
    var pageTotal: Int? { pageIndex?.total }

    func beginPageCount() {
        pageIndex = nil
        pageState = .calculating
    }

    func receivePages(_ index: PageIndex) {
        pageIndex = index
        pageState = .ready
    }

    func failPageCount() {
        pageIndex = nil
        pageState = .unavailable
    }

    func changeFont(_ mode: ReaderFontMode, family: String) {
        let updated = ReaderSettings(textScale: settings.textScale, colorMode: settings.colorMode,
                                     marginMode: settings.marginMode, sideMargin: settings.sideMargin,
                                     fontMode: mode, fontFamily: family)
        guard updated != settings else { return }
        do {
            try library.saveReaderSettings(updated, for: book)
            settings = updated
        } catch { self.error = "Could not save font: \(error.localizedDescription)" }
    }

    func changeFontSize(_ change: FontSizeChange) {
        let updated = settings.changed(change)
        guard updated != settings else { return }
        do {
            try library.saveReaderSettings(updated, for: book)
            settings = updated
        } catch { self.error = "Could not save font size: \(error.localizedDescription)" }
    }

    func changeColors(_ mode: ReaderColorMode) {
        let updated = ReaderSettings(textScale: settings.textScale, colorMode: mode,
                                     marginMode: settings.marginMode, sideMargin: settings.sideMargin,
                                     fontMode: settings.fontMode, fontFamily: settings.fontFamily)
        guard updated != settings else { return }
        do {
            try library.saveReaderSettings(updated, for: book)
            settings = updated
        } catch { self.error = "Could not save colors: \(error.localizedDescription)" }
    }

    func changeMargins(_ mode: ReaderMarginMode, width: Int) {
        let updated = ReaderSettings(textScale: settings.textScale, colorMode: settings.colorMode,
                                     marginMode: mode, sideMargin: width,
                                     fontMode: settings.fontMode, fontFamily: settings.fontFamily)
        guard updated != settings else { return }
        do {
            try library.saveReaderSettings(updated, for: book)
            settings = updated
        } catch { self.error = "Could not save margins: \(error.localizedDescription)" }
    }

    func move(_ delta: Int) {
        let index = target.index + delta
        guard book.chapters.indices.contains(index) else { return }
        open(book.chapters[index].path)
    }
    func open(_ href: String) {
        do {
            let url = try BookPaths.resolve(href, relativeTo: root.appendingPathComponent(""), root: root)
            guard let index = book.chapters.firstIndex(where: {
                (try? BookPaths.resolve($0.path, relativeTo: root.appendingPathComponent(""), root: root).path) == url.path
            }) else { throw EPUBError.invalid("This link points to a resource outside the supported chapter list.") }
            save()
            fraction = 0
            isLoading = true
            target = ReaderTarget(index: index, href: href, fraction: 0)
            save()
        } catch { self.error = error.localizedDescription }
    }
    func receiveProgress(_ value: Double, token: String) {
        guard token == target.token.uuidString, value.isFinite, !isLoading else { return }
        fraction = min(1, max(0, value))
        save()
    }
    func save() {
        library.saveProgress(ReadingProgress(chapterID: chapter.id, scrollFraction: fraction, updatedAt: Date()), for: book)
    }
}

enum PageState {
    case calculating, ready, unavailable
}
