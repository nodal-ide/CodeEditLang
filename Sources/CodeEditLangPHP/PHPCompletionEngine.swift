import Foundation
import AppKit
import SwiftUI
import CodeEditLang

/// Builds context-aware PHP completion items for a cursor position.
///
/// Replaces the naive "all project symbols by prefix" behaviour with scoped results:
/// - member access (`->`, `?->`, `::`) resolves the receiver type and offers its members
/// - otherwise offers local variables, the file's own symbols, imported symbols,
///   current-namespace symbols, and keywords
public enum PHPCompletionEngine {
    public enum Access {
        case none
        case instance
        case `static`
    }

    public struct Analysis {
        public var prefix: String
        public var prefixStart: Int
        public var access: Access
        public var receiver: String?
        public var contextClass: String?
    }

    // MARK: - Parse cache

    private static let cacheLock = NSLock()
    private static var parseCache: [Int: (source: String, info: PHPFileSymbols)] = [:]

    private static func fileInfo(for source: String, fileURL: URL) -> PHPFileSymbols {
        let key = source.hashValue
        cacheLock.lock()
        if let cached = parseCache[key], cached.source == source {
            cacheLock.unlock()
            return cached.info
        }
        cacheLock.unlock()

        let info = PHPFileParser.parse(source, fileURL: fileURL)

        cacheLock.lock()
        if parseCache.count > 16 { parseCache.removeAll() }
        parseCache[key] = (source, info)
        cacheLock.unlock()
        return info
    }

    // MARK: - Public

    public static func items(
        source: String,
        cursorOffset: Int,
        fileURL: URL,
        index: SymbolIndex
    ) -> [PHPCompletionItem] {
        let info = fileInfo(for: source, fileURL: fileURL)
        let analysis = analyze(source: source, offset: cursorOffset, fileInfo: info)

        switch analysis.access {
        case .instance:
            return memberItems(source: source, staticAccess: false, analysis: analysis, info: info, index: index)
        case .static:
            return memberItems(source: source, staticAccess: true, analysis: analysis, info: info, index: index)
        case .none:
            return generalItems(analysis: analysis, info: info, index: index)
        }
    }

    // MARK: - Analysis

    public static func analyze(source: String, offset: Int, fileInfo: PHPFileSymbols) -> Analysis {
        let ns = source as NSString
        let safeOffset = min(max(offset, 0), ns.length)

        var start = safeOffset
        while start > 0, isIdentifierChar(ns.character(at: start - 1)) {
            start -= 1
        }
        let prefix = ns.substring(with: NSRange(location: start, length: safeOffset - start))

        var access: Access = .none
        var receiver: String?
        var operatorStart = start
        if start >= 2, ns.substring(with: NSRange(location: start - 2, length: 2)) == "->" {
            access = .instance
            operatorStart = start - 2
        } else if start >= 3, ns.substring(with: NSRange(location: start - 3, length: 3)) == "?->" {
            access = .instance
            operatorStart = start - 3
        } else if start >= 2, ns.substring(with: NSRange(location: start - 2, length: 2)) == "::" {
            access = .static
            operatorStart = start - 2
        }

        if access != .none {
            var recvStart = operatorStart
            while recvStart > 0, isIdentifierChar(ns.character(at: recvStart - 1)) {
                recvStart -= 1
            }
            receiver = ns.substring(with: NSRange(location: recvStart, length: operatorStart - recvStart))
        }

        return Analysis(
            prefix: prefix.replacingOccurrences(of: "$", with: ""),
            prefixStart: start,
            access: access,
            receiver: receiver,
            contextClass: fileInfo.classContaining(offset: safeOffset)
        )
    }

    // MARK: - Member completion

    private static func memberItems(
        source: String,
        staticAccess: Bool,
        analysis: Analysis,
        info: PHPFileSymbols,
        index: SymbolIndex
    ) -> [PHPCompletionItem] {
        guard let receiver = analysis.receiver, !receiver.isEmpty else { return [] }
        guard let typeFQN = resolveReceiverType(
            receiver,
            source: source,
            analysis: analysis,
            info: info,
            index: index
        ) else { return [] }

        var members = index.members(ofType: typeFQN)
        if members.isEmpty, let classSymbol = index.symbols(fullyQualified: typeFQN).first {
            members = index.members(ofType: classSymbol.container ?? classSymbol.fullyQualifiedName)
        }

        let prefix = analysis.prefix
        let filtered = prefix.isEmpty
            ? members
            : members.filter { $0.name.lowercased().hasPrefix(prefix.lowercased()) }

        return filtered.map { member in
            PHPCompletionItem(
                label: member.name,
                detail: member.fullyQualifiedName,
                documentation: member.documentation,
                insertText: member.kind == .method ? "\(member.name)()" : member.name,
                image: Self.image(for: member.kind),
                imageColor: Self.imageColor(for: member.kind)
            )
        }
    }

    private static func resolveReceiverType(
        _ receiver: String,
        source: String,
        analysis: Analysis,
        info: PHPFileSymbols,
        index: SymbolIndex
    ) -> String? {
        let trimmed = receiver.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "$this", "self", "static":
            return analysis.contextClass
        case "parent":
            return nil // v1: parent resolution not implemented
        default:
            break
        }

        if trimmed.hasPrefix("$") {
            return inferVariableType(trimmed, source: source, analysis: analysis, info: info, index: index)
        }
        return resolveClassFQN(trimmed, info: info, index: index)
    }

    private static func resolveClassFQN(
        _ name: String,
        info: PHPFileSymbols,
        index: SymbolIndex
    ) -> String? {
        if name.hasPrefix("\\") {
            return String(name.dropFirst())
        }
        if let aliasTarget = info.aliases[name] {
            return aliasTarget
        }
        if name.contains("\\") {
            if !index.symbols(fullyQualified: name).isEmpty { return name }
            if let namespace = info.namespace, !namespace.isEmpty { return "\(namespace)\\\(name)" }
            return name
        }
        if let namespace = info.namespace, !namespace.isEmpty {
            let candidate = "\(namespace)\\\(name)"
            if !index.symbols(fullyQualified: candidate).isEmpty { return candidate }
        }
        if let symbol = index.symbols(named: name).first {
            return symbol.container ?? symbol.fullyQualifiedName
        }
        return name
    }

    // MARK: - General completion

    private static func generalItems(
        analysis: Analysis,
        info: PHPFileSymbols,
        index: SymbolIndex
    ) -> [PHPCompletionItem] {
        let prefix = analysis.prefix
        var items: [PHPCompletionItem] = []
        var seen = Set<String>()

        func append(_ item: PHPCompletionItem) {
            guard seen.insert(item.label.lowercased()).inserted else { return }
            items.append(item)
        }

        for variable in info.variables where prefix.isEmpty || variable.lowercased().hasPrefix(prefix.lowercased()) {
            append(
                PHPCompletionItem(
                    label: variable,
                    detail: "variable",
                    insertText: "$\(variable)",
                    image: Self.image(for: .variable),
                    imageColor: Self.imageColor(for: .variable)
                )
            )
        }

        for symbol in info.symbols where symbol.container == nil
            && (prefix.isEmpty || symbol.name.lowercased().hasPrefix(prefix.lowercased())) {
            append(item(for: symbol))
        }

        for (alias, fqn) in info.aliases where prefix.isEmpty || alias.lowercased().hasPrefix(prefix.lowercased()) {
            append(
                PHPCompletionItem(
                    label: alias,
                    detail: fqn,
                    image: Self.image(for: .class),
                    imageColor: Self.imageColor(for: .class)
                )
            )
        }

        if let namespace = info.namespace, !namespace.isEmpty {
            for symbol in index.symbols(prefix: prefix) where symbol.namespace == namespace && symbol.container == nil {
                append(item(for: symbol))
            }
        }

        for keyword in keywords where prefix.isEmpty || keyword.lowercased().hasPrefix(prefix.lowercased()) {
            append(PHPCompletionItem(label: keyword, detail: "keyword"))
        }

        return items
    }

    private static func item(for symbol: SymbolInfo) -> PHPCompletionItem {
        PHPCompletionItem(
            label: symbol.name,
            detail: symbol.fullyQualifiedName,
            documentation: symbol.documentation,
            image: Self.image(for: symbol.kind),
            imageColor: Self.imageColor(for: symbol.kind)
        )
    }

    // MARK: - Variable type inference

    private static func inferVariableType(
        _ variable: String,
        source: String,
        analysis: Analysis,
        info: PHPFileSymbols,
        index: SymbolIndex
    ) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: variable)
        let patterns = [
            "\(escaped)\\s*=\\s*new\\s+([A-Za-z_\\\\][A-Za-z0-9_\\\\]*)",
            "@var\\s+([A-Za-z_\\\\][A-Za-z0-9_\\\\|]*)\\s+\(escaped)\\b",
            "([A-Za-z_\\\\][A-Za-z0-9_\\\\]*)\\s+\(escaped)\\b"
        ]
        let range = NSRange(location: 0, length: (source as NSString).length)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            if let match = regex.firstMatch(in: source, options: [], range: range),
               match.numberOfRanges > 1,
               let typeRange = Range(match.range(at: 1), in: source) {
                var typeName = String(source[typeRange])
                // Take the first type of a union.
                if let first = typeName.split(separator: "|").first { typeName = String(first) }
                return resolveClassFQN(typeName, info: info, index: index)
            }
        }
        return nil
    }

    // MARK: - Helpers

    private static func isIdentifierChar(_ char: unichar) -> Bool {
        guard let scalar = UnicodeScalar(char) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
            || scalar == "_" || scalar == "\\" || scalar == "$"
    }

    private static let keywords: [String] = [
        "abstract", "and", "array", "as", "break", "callable", "case", "catch", "class",
        "clone", "const", "continue", "declare", "default", "do", "echo", "else", "elseif",
        "empty", "enum", "exit", "extends", "final", "finally", "fn", "for", "foreach",
        "function", "global", "goto", "if", "implements", "include", "include_once",
        "instanceof", "insteadof", "interface", "isset", "list", "match", "namespace", "new",
        "or", "print", "private", "protected", "public", "readonly", "require", "require_once",
        "return", "static", "switch", "throw", "trait", "try", "unset", "use", "var", "while",
        "xor", "yield"
    ]

    static func image(for kind: SymbolKind) -> Image {
        let name: String
        switch kind {
        case .class, .trait, .interface, .enum: name = "cube.box"
        case .function, .method: name = "function"
        case .property: name = "p.square"
        case .constant: name = "number"
        case .variable: name = "variable"
        case .namespace: name = "folder"
        }
        return Image(systemName: name)
    }

    static func imageColor(for kind: SymbolKind) -> Color {
        switch kind {
        case .class, .trait, .interface, .enum: return Color(NSColor.systemBlue)
        case .function, .method: return Color(NSColor.systemPurple)
        case .property, .variable: return Color(NSColor.systemTeal)
        case .constant, .namespace: return Color(NSColor.systemOrange)
        }
    }
}