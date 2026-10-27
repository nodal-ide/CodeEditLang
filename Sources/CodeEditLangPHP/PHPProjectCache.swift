//
//  PHPProjectCache.swift
//  CodeEditLangPHP
//
//  On-disk cache of a project's PHP symbols + diagnostics + reference index postings (binary property list).

import Foundation
import CodeEditLang

/// Persisted per-project index + diagnostics + reference index postings, stored at `<project>/.codeedit/cache/php/cache.bin`.
struct PHPProjectCache {
    /// Bump when the persisted shape changes to invalidate old caches.
    static let version = 3

    var version: Int
    var files: [FileEntry]

    struct FileEntry: Codable {
        var path: String
        var modified: Date
        var symbols: [SymbolInfo]
        var diagnostics: [PHPDiagnostic]
        /// The set of distinct names referenced in the file (functions, methods, classes, traits,
        /// aliases) — replayed into the reference index on cache load so the name index survives
        /// restarts without re-parsing.
        var referenceNames: [String]
        /// Replayed postings for the file. Storing postings directly makes warm-start
        /// hydration a single append into the reference index instead of re-deriving names.
        var postings: [PHPReferencePosting]

        enum CodingKeys: String, CodingKey {
            case path
            case modified
            case symbols
            case diagnostics
            case referenceNames
            case referenceIndexComplete
            case postings
        }

        init(path: String, modified: Date, symbols: [SymbolInfo], diagnostics: [PHPDiagnostic], referenceNames: [String], postings: [PHPReferencePosting]) {
            self.path = path
            self.modified = modified
            self.symbols = symbols
            self.diagnostics = diagnostics
            self.referenceNames = referenceNames
            self.postings = postings
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            modified = try container.decode(Date.self, forKey: .modified)
            symbols = try container.decode([SymbolInfo].self, forKey: .symbols)
            diagnostics = try container.decode([PHPDiagnostic].self, forKey: .diagnostics)
            referenceNames = try container.decode([String].self, forKey: .referenceNames)
            if let existing = try? container.decode([PHPReferencePosting].self, forKey: .postings) {
                postings = existing
            } else {
                postings = []
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(path, forKey: .path)
            try container.encode(modified, forKey: .modified)
            try container.encode(symbols, forKey: .symbols)
            try container.encode(diagnostics, forKey: .diagnostics)
            try container.encode(referenceNames, forKey: .referenceNames)
            try container.encode(postings, forKey: .postings)
        }
    }

    init(files: [FileEntry]) {
        self.version = PHPProjectCache.version
        self.files = files
    }

    private struct _CacheWrapper: Codable {
        let version: Int
        let files: [FileEntry]
    }

    static func cacheURL(for root: URL) -> URL {
        root.appending(path: ".codeedit/cache/php/cache.bin")
    }

    static func load(for root: URL) -> PHPProjectCache? {
        let url = cacheURL(for: root)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = PropertyListDecoder()
        guard let wrapper = try? decoder.decode(_CacheWrapper.self, from: data) else { return nil }
        guard wrapper.version == version else { return nil }
        return PHPProjectCache(files: wrapper.files)
    }

    static func save(_ entries: [FileEntry], for root: URL) {
        let url = cacheURL(for: root)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let wrapper = _CacheWrapper(version: version, files: entries)
        guard let data = try? encoder.encode(wrapper) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
