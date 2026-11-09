import Foundation
import ZIPFoundation

enum ZIPExtractor {
    static func extract(_ archiveURL: URL, to destination: URL) throws {
        let size = try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, UInt64(size) <= archiveLimit else {
            throw EPUBError.invalid("The archive is empty or exceeds the 128 MB import limit.")
        }

        let archive = try Archive(url: archiveURL, accessMode: .read, pathEncoding: .utf8)
        let entries = Array(archive.prefix(entryCountLimit + 1))
        guard !entries.isEmpty, entries.count <= entryCountLimit else {
            throw EPUBError.invalid("The archive has too many entries or is empty.")
        }

        // Normalize first: /private aliases can differ for not-yet-created children.
        let root = destination.standardizedFileURL
        var written = Set<String>()
        var total: UInt64 = 0
        var targets: [(Entry, URL)] = []
        // Check the entire visible catalog before writing any publication files.
        for entry in entries {
            let name = entry.path(using: .utf8)
            let path = name.hasSuffix("/") ? String(name.dropLast()) : name
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            // ZIP filenames are literal filesystem names, not percent-encoded URLs.
            let target = root.appendingPathComponent(name).standardizedFileURL
            guard !name.isEmpty, !name.contains("\\"), !name.contains(":"),
                  !name.unicodeScalars.contains(where: { $0.value < 32 }),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  target.path.hasPrefix(root.path + "/") else {
                throw EPUBError.invalid("The archive contains an unsafe file path.")
            }
            guard entry.type != .symlink else {
                throw EPUBError.invalid("Archive links are not supported.")
            }
            // Reject names that collide on the case-insensitive iOS filesystem.
            let key = name.precomposedStringWithCanonicalMapping.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard written.insert(key).inserted else {
                throw EPUBError.invalid("The archive contains conflicting file paths.")
            }
            guard entry.uncompressedSize <= entryLimit, total <= totalLimit - entry.uncompressedSize else {
                throw EPUBError.invalid("The book exceeds the extraction size limits.")
            }
            total += entry.uncompressedSize
            targets.append((entry, target))
        }

        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for (entry, target) in targets {
            if entry.type == .directory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            // Bound actual output too: a forged size must not permit a decompression bomb.
            var bytes = Data()
            let checksum = try archive.extract(entry) { chunk in
                guard UInt64(bytes.count) + UInt64(chunk.count) <= entry.uncompressedSize else {
                    throw EPUBError.invalid("The book exceeds the extraction size limits.")
                }
                bytes.append(chunk)
            }
            guard UInt64(bytes.count) == entry.uncompressedSize, checksum == entry.checksum else {
                throw EPUBError.invalid("A book resource is damaged (size or checksum mismatch).")
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target, options: .withoutOverwriting)
        }
        let mime = root.appendingPathComponent("mimetype")
        guard (try? String(contentsOf: mime, encoding: .utf8)) == "application/epub+zip" else {
            throw EPUBError.invalid("This ZIP file is not an EPUB publication.")
        }
    }

    private static let archiveLimit: UInt64 = 128 * 1024 * 1024
    private static let entryLimit: UInt64 = 32 * 1024 * 1024
    private static let totalLimit: UInt64 = 256 * 1024 * 1024
    private static let entryCountLimit = 10_000
}
