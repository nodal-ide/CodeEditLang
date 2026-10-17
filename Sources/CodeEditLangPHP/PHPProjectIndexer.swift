import Foundation
import CodeEditLang

/// Builds and maintains a `SymbolIndex` for a PHP project.
///
/// Parses `.php` files concurrently (bounded by CPU count), skips files whose modification date
/// is unchanged since the last run, and updates per-file (no full clear). Keeps no file contents
/// in memory; memory is bounded by `SymbolIndex.maxSymbols`.
public final class PHPProjectIndexer: @unchecked Sendable {
    private let index: SymbolIndex
    private let ignoredRelativePaths: Set<String>
    private let stateLock = NSLock()
    private var modTimes: [URL: Date] = [:]
    private var diagnosticsByFile: [URL: [PHPDiagnostic]] = [:]

    public init(
        index: SymbolIndex = SymbolIndex(),
        ignoredRelativePaths: Set<String> = [".git", "vendor", "node_modules"]
    ) {
        self.index = index
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
                stateLock.lock()
                modTimes[url] = entry.modified
                diagnosticsByFile[url] = entry.diagnostics
                stateLock.unlock()
                onDiagnostics?(url, entry.diagnostics)
            }
        }

        let files = phpFiles(at: root)
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

    /// Persists the index + diagnostics for the scanned files.
    private func saveCache(for root: URL, files: [URL]) {
        let entries = files.map { file -> PHPProjectCache.FileEntry in
            stateLock.lock()
            let mtime = modTimes[file] ?? .distantPast
            let diagnostics = diagnosticsByFile[file] ?? []
            stateLock.unlock()
            return PHPProjectCache.FileEntry(
                path: file.path(percentEncoded: false),
                modified: mtime,
                symbols: index.symbols(inFile: file),
                diagnostics: diagnostics
            )
        }
        PHPProjectCache.save(entries, for: root)
    }

    /// Re-parses a single file unconditionally and applies the difference. Call on save/edit.
    public func refreshFile(at url: URL) {
        indexFile(url, force: true)
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
    }

    // MARK: - Private

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
        stateLock.lock()
        modTimes[file] = mtime
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
        let relative = fileURL.path(percentEncoded: false)
            .replacingOccurrences(of: root.path(percentEncoded: false), with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for ignored in ignoredRelativePaths {
            if relative == ignored || relative.hasPrefix(ignored + "/") {
                return true
            }
        }
        return false
    }
}