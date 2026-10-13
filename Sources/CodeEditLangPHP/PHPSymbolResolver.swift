import Foundation
import CodeEditLang

/// Resolves an identifier at a point in a PHP file to indexed symbols.
public enum PHPSymbolResolver {
    /// Resolves `identifier` against the current file's namespace + `use` aliases
    /// and the shared project index. Returns all plausible targets (the editor shows a
    /// picker when more than one is found).
    public static func resolve(
        identifier: String,
        namespace: String?,
        aliases: [String: String],
        index: SymbolIndex
    ) -> [SymbolInfo] {
        var trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix("\\") { trimmed.removeFirst() }
        guard !trimmed.isEmpty else { return [] }

        // 1. `use` alias (highest confidence).
        if let fqn = aliases[trimmed] {
            let matches = index.symbols(fullyQualified: fqn)
            if !matches.isEmpty { return deduped(matches) }
        }

        // 2. Explicit fully-qualified name.
        if trimmed.contains("\\") {
            return deduped(index.symbols(fullyQualified: trimmed)) +
                deduped(trimmed.components(separatedBy: "\\").last.flatMap { index.symbols(named: $0) } ?? [])
        }

        // 3. Current namespace.
        if let ns = namespace, !ns.isEmpty {
            let matches = index.symbols(fullyQualified: "\(ns)\\\(trimmed)")
            if !matches.isEmpty { return deduped(matches) }
        }

        // 4. Global / short-name fallback (classes imported with a different name resolve here).
        return deduped(index.symbols(named: trimmed))
    }

    private static func deduped(_ symbols: [SymbolInfo]) -> [SymbolInfo] {
        var seen = Set<String>()
        return symbols.filter { seen.insert($0.fullyQualifiedName.lowercased() + "|\($0.nameRange.location)").inserted == true }
    }
}