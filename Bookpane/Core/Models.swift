import Foundation

struct Book: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let fingerprint: String
    let title: String
    let author: String
    let chapters: [Chapter]
    let contents: [ContentsEntry]
    let coverPath: String?
    let importedAt: Date
}

struct Chapter: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let path: String
    let title: String
}

struct ContentsEntry: Identifiable, Codable, Hashable, Sendable {
    var id: String { href }
    let title: String
    let href: String
    var children: [ContentsEntry]
}

struct ReadingProgress: Codable, Sendable {
    var chapterID: String
    var scrollFraction: Double
    var updatedAt: Date
}

struct ReaderSettings: Codable, Equatable, Sendable {
    static let standard = ReaderSettings(textScale: 100)
    static let marginRange = 0...48
    static let marginStep = 4
    static let defaultFont = "Georgia"
    private static let limits = 80...250
    private static let step = 10
    let textScale: Int
    let colorMode: ReaderColorMode
    let marginMode: ReaderMarginMode
    let sideMargin: Int
    let fontMode: ReaderFontMode
    let fontFamily: String

    var canDecrease: Bool { textScale > Self.limits.lowerBound }
    var canIncrease: Bool { textScale < Self.limits.upperBound }

    init(textScale: Int, colorMode: ReaderColorMode = .publisher, marginMode: ReaderMarginMode = .publisher, sideMargin: Int = 0,
         fontMode: ReaderFontMode = .publisher, fontFamily: String = ReaderSettings.defaultFont) {
        let bounded = min(Self.limits.upperBound, max(Self.limits.lowerBound, textScale))
        self.textScale = ((bounded + Self.step / 2) / Self.step) * Self.step
        self.colorMode = colorMode
        self.marginMode = marginMode
        self.fontMode = fontMode
        self.fontFamily = fontFamily

        let margin = min(Self.marginRange.upperBound, max(Self.marginRange.lowerBound, sideMargin))
        self.sideMargin = ((margin + Self.marginStep / 2) / Self.marginStep) * Self.marginStep
    }

    func changed(_ change: FontSizeChange) -> ReaderSettings {
        let scale: Int
        switch change {
        case .decrease: scale = textScale - Self.step
        case .increase: scale = textScale + Self.step
        case .reset: scale = Self.standard.textScale
        }
        return ReaderSettings(textScale: scale, colorMode: colorMode, marginMode: marginMode, sideMargin: sideMargin,
                              fontMode: fontMode, fontFamily: fontFamily)
    }

    // Validate saved values through the same bounds as interactive changes.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(textScale: try values.decode(Int.self, forKey: .textScale),
                  colorMode: try values.decodeIfPresent(ReaderColorMode.self, forKey: .colorMode) ?? .publisher,
                  marginMode: try values.decodeIfPresent(ReaderMarginMode.self, forKey: .marginMode) ?? .publisher,
                  sideMargin: try values.decodeIfPresent(Int.self, forKey: .sideMargin) ?? 0,
                  fontMode: try values.decodeIfPresent(ReaderFontMode.self, forKey: .fontMode) ?? .publisher,
                  fontFamily: try values.decodeIfPresent(String.self, forKey: .fontFamily) ?? Self.defaultFont)
    }

    private enum CodingKeys: String, CodingKey { case textScale, colorMode, marginMode, sideMargin, fontMode, fontFamily }
}

enum ReaderFontMode: String, Codable, Sendable {
    case publisher
    case custom
}

enum ReaderColorMode: String, Codable, Sendable {
    case publisher
    case monochrome
}

enum ReaderMarginMode: String, Codable, Sendable {
    case publisher
    case custom
}

enum FontSizeChange {
    case decrease
    case increase
    case reset
}

enum EPUBError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

enum BookPaths {
    static var root: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Bookpane", isDirectory: true)
    }
    static func directory(_ id: UUID) -> URL {
        root.appendingPathComponent("Books/\(id.uuidString)", isDirectory: true)
    }
    static func content(_ id: UUID) -> URL {
        directory(id).appendingPathComponent("content", isDirectory: true)
    }

    /// Resolve publication URLs while restricting access to this book's directory.
    static func resolve(_ reference: String, relativeTo base: URL, root: URL) throws -> URL {
        guard let url = URL(string: reference, relativeTo: base)?.absoluteURL,
              url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil else {
            throw EPUBError.invalid("The book contains an unsupported resource address.")
        }
        let normalized = URL(fileURLWithPath: url.path).standardizedFileURL
        let rootPath = root.standardizedFileURL.path + "/"
        guard normalized.path.hasPrefix(rootPath) else {
            throw EPUBError.invalid("A book resource points outside the book directory.")
        }
        // Normalize the filesystem path without losing an XHTML anchor fragment.
        var components = URLComponents(url: normalized, resolvingAgainstBaseURL: true)!
        components.percentEncodedFragment = URLComponents(url: url, resolvingAgainstBaseURL: true)?.percentEncodedFragment
        guard let result = components.url else { throw EPUBError.invalid("Invalid book resource address.") }
        return result
    }

    static func relative(_ url: URL, root: URL) -> String {
        let path = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#%"))) ?? path
        return encoded + (url.fragment.map { "#" + $0 } ?? "")
    }
}
