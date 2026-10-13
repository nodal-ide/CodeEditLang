import Foundation
import CodeEditLang

/// Shared, thread-safe cache of parsed PHP files.
///
/// One parse per `(file, content)` is reused by every feature — completion, definition, hover,
/// signature help, code actions, diagnostics, and document symbols — instead of each reparsing.
/// Async callers parse on a background queue; the synchronous completion path reuses a warm entry.
public final class PHPParseCache: @unchecked Sendable {
    public static let shared = PHPParseCache()

    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]
    private var order: [URL] = []
    private let maxEntries = 24

    private struct Entry {
        let source: String
        let info: PHPFileSymbols
    }

    private init() {}

    /// Cached result if the content matches; otherwise `nil`.
    public func cached(for fileURL: URL, source: String) -> PHPFileSymbols? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[fileURL], entry.source == source else { return nil }
        return entry.info
    }

    /// Synchronous lookup/parse. Parses on the calling thread only on a miss.
    public func info(for fileURL: URL, source: String) -> PHPFileSymbols {
        if let cached = cached(for: fileURL, source: source) { return cached }
        let info = PHPFileParser.parse(source, fileURL: fileURL)
        store(info, fileURL: fileURL, source: source)
        return info
    }

    /// Asynchronous lookup/parse. Parses on a background queue only on a miss.
    public func infoAsync(for fileURL: URL, source: String) async -> PHPFileSymbols {
        if let cached = cached(for: fileURL, source: source) { return cached }
        let info = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: PHPFileParser.parse(source, fileURL: fileURL))
            }
        }
        store(info, fileURL: fileURL, source: source)
        return info
    }

    private func store(_ info: PHPFileSymbols, fileURL: URL, source: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[fileURL] = Entry(source: source, info: info)
        order.removeAll { $0 == fileURL }
        order.append(fileURL)
        while order.count > maxEntries {
            let evicted = order.removeFirst()
            entries.removeValue(forKey: evicted)
        }
    }
}