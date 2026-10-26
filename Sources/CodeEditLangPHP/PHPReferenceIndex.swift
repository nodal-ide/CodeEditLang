import Foundation
import CodeEditLang

/// A single file posting in the reference index.
public struct PHPReferencePosting: Sendable, Codable {
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
/// postings here is guarded by `lock`. The per-file reverse map doubles as the
/// deduplication set, keeping add O(1) per (name, file) pair, and as the eviction
/// guide so removing a file touches only the names that file actually posted.
public final class PHPReferenceIndex: @unchecked Sendable {
    /// Opaque lookup result so the public API surface stays stable even if the internal
    /// posting representation changes. Callers inspect `postings` and `isComplete`.
    public typealias LookupResult = (postings: [PHPReferencePosting], isComplete: Bool)

    /// The indexer hands out a stable reference to the index so consumers can read postings
    /// without triggering a rebuild. This is not a copy — mutations to the index are still
    /// reflected, but the caller must treat the reference as read-only.
    public var referenceIndex: PHPReferenceIndex { self }

    private let lock = NSLock()

    /// Normalized short name (lowercased, unbackslashed) -> postings.
    private var postings: [String: [PHPReferencePosting]] = [:]

    /// Per-file reverse map: fileURL -> normalized names that reference it.
    /// Used for deduplication, targeted eviction, and the
    /// "name matches (receiver type unknown)" collapsed group.
    private var fileNames: [String: Set<String>] = [:]

    /// Maximum number of postings per name to cap memory. Names exceeding this cap
    /// are still tracked but the posting list is truncated; callers must check `isComplete`.
    private let maxPostings: Int

    /// When postings for a name exceed maxPostings, `isComplete` is false for that name.
    /// The reference engine reports the overall result set is incomplete.
    private var isCompleteForName: [String: Bool] = [:]

    public init(maxPostings: Int = 500) {
        self.maxPostings = maxPostings
    }

    /// Opaque lookup result so the public API surface stays stable even if the internal
    /// posting representation changes. Callers inspect `postings` and `isComplete`.
    
    /// Total stored postings across all names. Exposed for budget/regression tests.
    public var postingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return postings.values.reduce(0) { $0 + $1.count }
    }

    /// Insert a reference posting for a given name in a file.
    /// Called by the project indexer after parsing a file. Re-adding a (name, file)
    /// pair that is already indexed is a no-op.
    func addPosting(name: String, fileURL: URL, container: String? = nil, fullyQualifiedName: String? = nil) {
        let shortName = normalized(name: name)
        guard !shortName.isEmpty else { return }
        let path = fileURL.path(percentEncoded: false)

        lock.lock()
        defer { lock.unlock() }

        if fileNames[path]?.contains(shortName) == true { return }

        var existing = postings[shortName] ?? []
        if existing.count >= maxPostings {
            isCompleteForName[shortName] = false
        } else {
            existing.append(
                PHPReferencePosting(
                    fileURL: path,
                    container: container,
                    fullyQualifiedName: fullyQualifiedName
                )
            )
            postings[shortName] = existing
            isCompleteForName[shortName] = true
        }

        fileNames[path, default: []].insert(shortName)
    }

    /// Insert several reference postings for one file under a single lock acquisition.
    /// This is the indexer's hot path: one call per parsed file instead of one per name.
    public func addPostings(names: [String], fileURL: URL, container: String? = nil, fullyQualifiedName: String? = nil) {
        guard !names.isEmpty else { return }
        let path = fileURL.path(percentEncoded: false)

        lock.lock()
        defer { lock.unlock() }

        var fileSet = fileNames[path] ?? []
        var changed = false
        for raw in names {
            let shortName = normalized(name: raw)
            guard !shortName.isEmpty, !fileSet.contains(shortName) else { continue }

            var existing = postings[shortName] ?? []
            if existing.count >= maxPostings {
                isCompleteForName[shortName] = false
            } else {
                existing.append(
                    PHPReferencePosting(
                        fileURL: path,
                        container: container,
                        fullyQualifiedName: fullyQualifiedName
                    )
                )
                postings[shortName] = existing
                isCompleteForName[shortName] = true
            }

            fileSet.insert(shortName)
            changed = true
        }
        if changed || fileNames[path] == nil {
            fileNames[path] = fileSet
        }
    }

    /// Remove all postings for a file (called when a file is deleted or re-indexed).
    /// Only the names this file posted are touched, so cost scales with the file, not the project.
    func removeFile(_ fileURL: URL) {
        let path = fileURL.path(percentEncoded: false)
        lock.lock()
        defer { lock.unlock() }

        guard let names = fileNames.removeValue(forKey: path) else { return }
        for shortName in names {
            guard var list = postings[shortName] else { continue }
            list.removeAll { $0.fileURL == path }
            if list.isEmpty {
                postings.removeValue(forKey: shortName)
                isCompleteForName.removeValue(forKey: shortName)
            } else {
                postings[shortName] = list
            }
        }
    }

    /// Look up the candidate files that reference the given short name.
    /// - Returns: (postings, isComplete) where postings are capped at maxPostings.
    /// `isComplete` is derived from this index's cap state for the name; the query engine promotes
    /// it to a result-level completeness flag together with whether any candidates were found.
    public func lookUp(_ name: String) -> LookupResult {
        let shortName = normalized(name: name)
        lock.lock()
        defer { lock.unlock() }
        return (postings[shortName] ?? [], isCompleteForName[shortName] ?? true)
    }

    /// Returns the set of short names referenced in a given file (for the collapsed
    /// "Name matches (receiver type unknown)" group).
    public func names(inFile fileURL: URL) -> Set<String> {
        let path = fileURL.path(percentEncoded: false)
        lock.lock()
        defer { lock.unlock() }
        return fileNames[path] ?? []
    }


    /// Opaque lookup result so the public API surface stays stable even if the internal
    /// posting representation changes. Callers inspect `postings` and `isComplete`.


        /// Normalize a name for indexing: lowercased, backslashes removed.
    private func normalized(name: String) -> String {
        var result = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix("\\") {
            result.removeFirst()
        }
        return result
    }
}