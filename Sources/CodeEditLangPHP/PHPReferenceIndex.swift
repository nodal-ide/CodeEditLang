//////
//  PHPReferenceIndex.swift
//  CodeEditLangPHP
////
//  Interned inverted index for find-references: name -> [file postings].
//  Built as a by-product of the PHP project indexer; persists alongside the symbol cache.
//  Provides bounded candidate files for the reference engine without re-parsing the entire project.
//

import Foundation
import CodeEditLang

/// A single file posting in the reference index.
struct PHPReferencePosting: Sendable, Codable {
    let fileURL: String          // path(percentEncoded: false) of the file
    let container: String?       // enclosing type / function, or nil
    let fullyQualifiedName: String?  // e.g. "App\Models\User::charge"
}

/// Interned inverted index: normalized short name -> file postings.
/// This is the index that enables O(candidate-files) reference resolution instead of
/// O(project-parse). The index is tiny (interned strings + posting arrays) and is
/// maintained alongside the SymbolIndex in the project cache.
///
/// The project indexer parses files concurrently, so every mutation and read of the
/// postings here is guarded by `lock`.
final class PHPReferenceIndex: @unchecked Sendable {
    private let lock = NSLock()

    /// Normalized short name (lowercased, unbackslashed) -> postings.
    private var postings: [String: [PHPReferencePosting]] = [:]

    /// Per-file reverse map: fileURL -> normalized names that reference it.
    /// Used for eviction and for "name matches (receiver type unknown)" collapsed group.
    private var fileNames: [String: Set<String>] = [:]

    /// Maximum number of postings per name to cap memory. Names exceeding this cap
    /// are still tracked but the posting list is truncated; callers must check `isComplete`.
    private let maxPostings: Int

    /// When postings for a name exceed maxPostings, `isComplete` is false for that name.
    /// The reference engine reports the overall result set is incomplete.
    private var isCompleteForName: [String: Bool] = [:]

    init(maxPostings: Int = 500) {
        self.maxPostings = maxPostings
    }

    /// Insert a reference posting for a given name in a file.
    /// Called by the project indexer after parsing a file.
    func addPosting(name: String, fileURL: URL, container: String? = nil, fullyQualifiedName: String? = nil) {
        let shortName = normalized(name: name)
        guard !shortName.isEmpty else { return }

        let posting = PHPReferencePosting(
            fileURL: fileURL.path(percentEncoded: false),
            container: container,
            fullyQualifiedName: fullyQualifiedName
        )

        lock.lock()
        defer { lock.unlock() }

        var existing = postings[shortName] ?? []
        if !existing.contains(where: { $0.fileURL == posting.fileURL }) {
            existing.append(posting)
        }

        if existing.count > maxPostings {
            postings[shortName] = Array(existing.prefix(maxPostings))
            isCompleteForName[shortName] = false
        } else {
            postings[shortName] = existing
            isCompleteForName[shortName] = true
        }

        fileNames[posting.fileURL, default: []].insert(shortName)
    }

    /// Remove all postings for a file (called when a file is deleted or re-indexed).
    func removeFile(_ fileURL: URL) {
        let path = fileURL.path(percentEncoded: false)
        lock.lock()
        defer { lock.unlock() }
        postings = postings.mapValues { $0.filter { $0.fileURL != path } }
        fileNames.removeValue(forKey: path)
    }

    /// Look up the candidate files that reference the given short name.
    /// - Returns: (postings, isComplete) where postings are capped at maxPostings.
    func lookUp(_ name: String) -> ([PHPReferencePosting], isComplete: Bool) {
        let shortName = normalized(name: name)
        lock.lock()
        defer { lock.unlock() }
        return (postings[shortName] ?? [], isCompleteForName[shortName] ?? true)
    }

    /// Returns the set of short names referenced in a given file (for the collapsed
    /// "Name matches (receiver type unknown)" group).
    func names(inFile fileURL: URL) -> Set<String> {
        let path = fileURL.path(percentEncoded: false)
        lock.lock()
        defer { lock.unlock() }
        return fileNames[path] ?? []
    }

    /// Normalize a name for indexing: lowercased, backslashes removed.
    private func normalized(name: String) -> String {
        var result = name.lowercased()
        while result.hasPrefix("\\") {
            result.removeFirst()
        }
        return result
    }
}