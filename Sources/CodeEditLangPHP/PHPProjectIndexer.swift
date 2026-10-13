import Foundation
import CodeEditLang

/// Builds and maintains a `SymbolIndex` for a PHP project.
///
/// Parses `.php` files and stores lightweight symbol records. Keeps no file contents in
/// memory; memory is bounded by `SymbolIndex.maxSymbols`.
public final class PHPProjectIndexer {
    private let index: SymbolIndex
    private let ignoredRelativePaths: Set<String>

    public init(
        index: SymbolIndex = SymbolIndex(),
        ignoredRelativePaths: Set<String> = [".git", "vendor", "node_modules"]
    ) {
        self.index = index
        self.ignoredRelativePaths = ignoredRelativePaths
    }

    /// The shared symbol table the indexer writes into.
    public var symbolIndex: SymbolIndex { index }

    /// Scans a folder and indexes all `.php` files into the shared index.
    public func buildIndex(at root: URL) {
        let previous = index.symbols(inFile: root)
        _ = previous // placeholder; full rebuild below clears the store in place.
        index.clear()

        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard let enumerator else { return }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "php" else { continue }

            // Honor the ignore set without walking into those directories.
            if isIgnored(fileURL, relativeTo: root) {
                enumerator.skipDescendants()
                continue
            }

            guard let data = try? Data(contentsOf: fileURL),
                  let source = String(data: data, encoding: .utf8) else {
                continue
            }
            let parsed = PHPFileParser.parse(source, fileURL: fileURL)
            for symbol in parsed.symbols {
                index.add(symbol)
            }
        }
    }

    /// Re-parses a single file and applies the difference to the index. Call on save.
    public func refreshFile(at url: URL) {
        index.removeFile(url)
        guard let data = try? Data(contentsOf: url),
              let source = String(data: data, encoding: .utf8) else {
            return
        }
        let parsed = PHPFileParser.parse(source, fileURL: url)
        for symbol in parsed.symbols {
            index.add(symbol)
        }
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