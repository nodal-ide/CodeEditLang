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
        index: SymbolIndex,
        stubIndex: SymbolIndex? = nil
    ) -> [SymbolInfo] {
        var trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix("\\") { trimmed.removeFirst() }
        guard !trimmed.isEmpty else { return [] }

        // 1. `use` alias (highest confidence).
        if let fqn = aliases[trimmed] {
            let matches = index.symbols(fullyQualified: fqn)
            if !matches.isEmpty { return deduped(matches) }
            if let stubIndex {
                let stubMatches = stubIndex.symbols(fullyQualified: fqn)
                if !stubMatches.isEmpty { return deduped(stubMatches) }
            }
        }

        // 2. Explicit fully-qualified name.
        if trimmed.contains("\\") {
            let qualified = deduped(index.symbols(fullyQualified: trimmed))
                + deduped(trimmed.components(separatedBy: "\\").last.flatMap { index.symbols(named: $0) } ?? [])
            if !qualified.isEmpty { return qualified }
        }

        // 3. Current namespace.
        if let ns = namespace, !ns.isEmpty {
            let matches = index.symbols(fullyQualified: "\(ns)\\\(trimmed)")
            if !matches.isEmpty { return deduped(matches) }
        }

        // 4. Global / short-name fallback (workspace first).
        let local = deduped(index.symbols(named: trimmed))
        if !local.isEmpty { return local }
        if let stubIndex {
            return deduped(stubIndex.symbols(named: trimmed))
        }
        return []
    }

    private static func deduped(_ symbols: [SymbolInfo]) -> [SymbolInfo] {
        var seen = Set<String>()
        return symbols.filter { seen.insert($0.fullyQualifiedName.lowercased() + "|\($0.nameRange.location)").inserted == true }
    }
}