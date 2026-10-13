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

    public init(
        index: SymbolIndex = SymbolIndex(),
        ignoredRelativePaths: Set<String> = [".git", "vendor", "node_modules"]
    ) {
        self.index = index
        self.ignoredRelativePaths = ignoredRelativePaths
    }

    /// The shared symbol table the indexer writes into.
    public var symbolIndex: SymbolIndex { index }

    /// Scans a folder and indexes all `.php` files, concurrently and incrementally.
    public func buildIndex(at root: URL) async {
        let files = phpFiles(at: root)
        guard !files.isEmpty else { return }
        let maxConcurrent = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)

        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func addTask(_ file: URL) {
                group.addTask { [weak self] in self?.indexFile(file) }
            }
            while next < min(maxConcurrent, files.count) {
                addTask(files[next])
                next += 1
            }
            while await group.next() != nil {
                if next < files.count {
                    addTask(files[next])
                    next += 1
                }
            }
        }
    }

    /// Re-parses a single file unconditionally and applies the difference. Call on save/edit.
    public func refreshFile(at url: URL) {
        indexFile(url, force: true)
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