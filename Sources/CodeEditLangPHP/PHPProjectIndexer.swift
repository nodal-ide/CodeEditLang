import Foundation
import CodeEditLang

/// Builds and maintains a `SymbolIndex` for a PHP project.
///
/// Parses `.php` files concurrently (bounded by CPU count), skips files whose modification date
/// is unchanged since the last run, and updates per-file (no full clear). Keeps no file contents
/// in memory; memory is bounded by `SymbolIndex.maxSymbols`.
/// Also maintains a `PHPReferenceIndex` that powers fast find-references queries.
public final class PHPProjectIndexer: @unchecked Sendable {
    private let index: SymbolIndex
    /// The reference name index maintained alongside ``symbolIndex``. Read-only for the query
    /// engine (RF4); all writes go through this indexer so the two indexes stay in sync.
    public let referenceIndex: PHPReferenceIndex
    private let ignoredRelativePaths: Set<String>
    private let stateLock = NSLock()
    private var modTimes: [URL: Date] = [:]
    private var diagnosticsByFile: [URL: [PHPDiagnostic]] = [:]
    private var referenceNamesByFile: [URL: [String]] = [:]

    public init(
        index: SymbolIndex = SymbolIndex(),
        ignoredRelativePaths: Set<String> = [".git", "vendor", "node_modules"]
    ) {
        self.index = index
        self.referenceIndex = PHPReferenceIndex()
        self.ignoredRelativePaths = ignoredRelativePaths
    }

    /// The shared symbol table the indexer writes into.
    public var symbolIndex: SymbolIndex { index }

    /// When set, code-quality diagnostics are computed for every indexed file and delivered to
    /// ``onDiagnostics`` (on a background thread).
    public var diagnosticsConfig: PHPDiagnosticsConfig?

    /// Called with each file's diagnostics during indexing. Invoked off the main thread.
    public var onDiagnostics: (@Sendable (URL, [PHPDiagnostic]) -> Void)?

    /// Reports `(completed, total)` file counts as indexing/diagnosing progresses. Off the main thread.
    public var onProgress: (@Sendable (Int, Int) -> Void)?

    /// Scans a folder and indexes all `.php` files, concurrently and incrementally.
    public func buildIndex(at root: URL) async {
        // Load the persisted cache first: instant symbols + diagnostics for unchanged files.
        if let cache = PHPProjectCache.load(for: root) {
            for entry in cache.files {
                let url = URL(fileURLWithPath: entry.path)
                index.add(entry.symbols)
                referenceIndex.addPostings(names: entry.referenceNames, fileURL: url, fullyQualifiedName: nil)
                stateLock.lock()
                modTimes[url] = entry.modified
                diagnosticsByFile[url] = entry.diagnostics
                referenceNamesByFile[url] = entry.referenceNames
                stateLock.unlock()
                onDiagnostics?(url, entry.diagnostics)
            }
        }

        let files = phpFiles(at: root)
        evictDeletedFiles(notIn: files)
        guard !files.isEmpty else { return }
        // Keep concurrency modest so indexing doesn't starve the UI while it runs in the
        // background (it starts when the first PHP file is opened).
        let maxConcurrent = min(4, max(2, ProcessInfo.processInfo.activeProcessorCount - 1))
        let total = files.count
        onProgress?(0, total)

        await withTaskGroup(of: Void.self) { group in
            var next = 0
            var completed = 0
            func addTask(_ file: URL) {
                group.addTask { [weak self] in self?.indexFile(file) }
            }
            while next < min(maxConcurrent, files.count) {
                addTask(files[next])
                next += 1
            }
            while await group.next() != nil {
                completed += 1
                onProgress?(completed, total)
                if next < files.count {
                    addTask(files[next])
                    next += 1
                }
            }
        }

        saveCache(for: root, files: files)
        onProgress?(total, total)
    }

    /// Persists the index + diagnostics + reference postings for the scanned files.
    private func saveCache(for root: URL, files: [URL]) {
        let entries = files.map { file -> PHPProjectCache.FileEntry in
            stateLock.lock()
            let mtime = modTimes[file] ?? .distantPast
            let diagnostics = diagnosticsByFile[file] ?? []
            let names = referenceNamesByFile[file] ?? []
            stateLock.unlock()
            let isComplete: Bool
            if names.isEmpty {
                isComplete = true
            } else {
                let (_, complete) = referenceIndex.lookUp(names.first!)
                isComplete = complete
            }
            return PHPProjectCache.FileEntry(
                path: file.path(percentEncoded: false),
                modified: mtime,
                symbols: index.symbols(inFile: file),
                diagnostics: diagnostics,
                referenceNames: names,
                referenceIndexComplete: isComplete
            )
        }
        PHPProjectCache.save(entries, for: root)
    }

    /// Re-parses a single file unconditionally and applies the difference. Call on save/edit.
    public func refreshFile(at url: URL) {
        indexFile(url, force: true)
    }

    /// Derive reference names from a parsed PHP file symbols.
    internal func deriveReferenceNames(from symbols: PHPFileSymbols, fileURL: URL) -> [String] {
        var names = Set<String>(symbols.referenceNames)
        for importRef in symbols.imports {
            names.insert(importRef.name)
        }
        for call in symbols.functionCalls {
            names.insert(call.name)
        }
        for method in symbols.thisMethodCalls {
            names.insert(method.name)
        }
        for cref in symbols.classReferences {
            names.insert(cref.name)
        }
        for symbol in symbols.symbols {
            names.insert(symbol.name)
        }
        return Array(names)
    }

    /// Removes a file from both indexes and its cached bookkeeping. Call on delete.
    public func removeFile(_ file: URL) {
        index.removeFile(file)
        referenceIndex.removeFile(file)
        stateLock.lock()
        modTimes.removeValue(forKey: file)
        diagnosticsByFile.removeValue(forKey: file)
        referenceNamesByFile.removeValue(forKey: file)
        stateLock.unlock()
    }

    /// Clears cached modification times so the next ``buildIndex(at:)`` re-parses (and re-diagnoses) every file.
    public func reprocessAll() {
        stateLock.lock()
        modTimes.removeAll()
        stateLock.unlock()
    }

    /// Replaces a file's symbols using already-parsed results (e.g. from the edit buffer).
    public func replace(file: URL, with symbols: [SymbolInfo]) {
        index.removeFile(file)
        index.add(symbols)
        referenceIndex.removeFile(file)
        stateLock.lock()
        referenceNamesByFile.removeValue(forKey: file)
        stateLock.unlock()
    }

    /// Replaces a file's symbols and rebuilds its reference postings from a full parse result.
    public func replace(file: URL, with info: PHPFileSymbols) {
        index.removeFile(file)
        index.add(info.symbols)
        let names = deriveReferenceNames(from: info, fileURL: file)
        referenceIndex.removeFile(file)
        referenceIndex.addPostings(names: names, fileURL: file)
        stateLock.lock()
        referenceNamesByFile[file] = names
        stateLock.unlock()
    }

    // MARK: - Private

    /// Drops tracked files that no longer exist in the current scan from both indexes, so
    /// deleting a file clears its symbols and reference postings on the next build.
    private func evictDeletedFiles(notIn files: [URL]) {
        let current = Set(files.map { $0.path(percentEncoded: false) })
        stateLock.lock()
        let stale = referenceNamesByFile.keys
            .filter { !current.contains($0.path(percentEncoded: false)) }
        stateLock.unlock()
        for url in stale {
            removeFile(url)
        }
    }

    private func indexFile(_ file: URL, force: Bool = false) {
        let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast

        stateLock.lock()
        let unchanged = !force && modTimes[file] == mtime && !index.symbols(inFile: file).isEmpty
        stateLock.unlock()
        if unchanged { return }

        guard let data = try? Data(contentsOf: file),
              let source = String(data: data, encoding: .utf8) else {
            return
        }
        let parsed = PHPFileParser.parse(source, fileURL: file)
        index.removeFile(file)
        index.add(parsed.symbols)
        let names = deriveReferenceNames(from: parsed, fileURL: file)
        referenceIndex.removeFile(file)
        referenceIndex.addPostings(names: names, fileURL: file)
        stateLock.lock()
        modTimes[file] = mtime
        referenceNamesByFile[file] = names
        stateLock.unlock()

        // Code-quality diagnostics (skip very large files to bound work).
        var issues: [PHPDiagnostic] = []
        if let diagnosticsConfig, data.count < 1_000_000 {
            issues = PHPDiagnosticsEngine.run(
                source: source,
                info: parsed,
                fileURL: file,
                settings: diagnosticsConfig
            )
        }
        stateLock.lock()
        diagnosticsByFile[file] = issues
        stateLock.unlock()
        onDiagnostics?(file, issues)
    }

    private func phpFiles(at root: URL) -> [URL] {
        var files: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard let enumerator else { return [] }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "php" else { continue }
            if isIgnored(fileURL, relativeTo: root) {
                enumerator.skipDescendants()
                continue
            }
            files.append(fileURL)
        }
        return files
    }

    private func isIgnored(_ fileURL: URL, relativeTo root: URL) -> Bool {
        // Resolve symlinks so /var and /private/var compare equal.
        let fileResolved = fileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let rootResolved = root.resolvingSymlinksInPath().path(percentEncoded: false)
        guard fileResolved.hasPrefix(rootResolved) else { return false }
        var relative = String(fileResolved.dropFirst(rootResolved.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for ignored in ignoredRelativePaths {
            if relative == ignored || relative.hasPrefix(ignored + "/") {
                return true
            }
        }
        return false
    }
}