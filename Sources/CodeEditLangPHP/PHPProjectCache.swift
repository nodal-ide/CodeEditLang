//
//  PHPProjectCache.swift
//  CodeEditLangPHP
//
//  On-disk cache of a project's PHP symbols + diagnostics (binary property list).
//

import Foundation
import CodeEditLang

/// Persisted per-project index + diagnostics, stored at `<project>/.codeedit/cache/php/cache.bin`.
struct PHPProjectCache: Codable {
    /// Bump when the persisted shape changes to invalidate old caches.
    static let version = 1

    var version: Int = PHPProjectCache.version
    var files: [FileEntry]

    struct FileEntry: Codable {
        var path: String
        var modified: Date
        var symbols: [SymbolInfo]
        var diagnostics: [PHPDiagnostic]
    }

    static func cacheURL(for root: URL) -> URL {
        root.appending(path: ".codeedit/cache/php/cache.bin")
    }

    static func load(for root: URL) -> PHPProjectCache? {
        let url = cacheURL(for: root)
        guard let data = try? Data(contentsOf: url),
              let cache = try? PropertyListDecoder().decode(PHPProjectCache.self, from: data),
              cache.version == version else {
            return nil
        }
        return cache
    }

    static func save(_ entries: [FileEntry], for root: URL) {
        let url = cacheURL(for: root)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(PHPProjectCache(files: entries)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
