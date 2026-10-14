import Foundation
import AppKit
import SwiftUI
import os
import CodeEditLang

/// Builds context-aware PHP completion items for a cursor position.
///
/// Replaces the naive "all project symbols by prefix" behaviour with scoped results:
/// - member access (`->`, `?->`, `::`) resolves the receiver type and offers its members
/// - otherwise offers local variables, the file's own symbols, imported symbols,
///   current-namespace symbols, and keywords
public enum PHPCompletionEngine {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "CodeEdit",
        category: "PHPCompletion"
    )
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

    private static func fileInfo(for source: String, fileURL: URL) -> PHPFileSymbols {
        PHPParseCache.shared.info(for: fileURL, source: source)
    }

    // MARK: - Public

    /// Synchronous entry point; parses via the shared cache on a miss.
    public static func items(
        source: String,
        cursorOffset: Int,
        fileURL: URL,
        index: SymbolIndex,
        stubIndex: SymbolIndex? = nil
    ) -> [PHPCompletionItem] {
        let info = fileInfo(for: source, fileURL: fileURL)
        return items(
            info: info, source: source, cursorOffset: cursorOffset,
            fileURL: fileURL, index: index, stubIndex: stubIndex
        )
    }

    /// Builds items from already-parsed file info. Lets callers parse off the main thread and
    /// then do the (cheap) item building here.
    public static func items(
        info: PHPFileSymbols,
        source: String,
        cursorOffset: Int,
        fileURL: URL,
        index: SymbolIndex,
        stubIndex: SymbolIndex?
    ) -> [PHPCompletionItem] {
        let analysis = analyze(source: source, offset: cursorOffset, fileInfo: info)
        Self.logger.notice(
            // swiftlint:disable:next line_length
            "analysis: prefix='\(analysis.prefix, privacy: .public)' access=\(String(describing: analysis.access), privacy: .public) receiver='\(analysis.receiver ?? "nil", privacy: .public)' contextClass=\(analysis.contextClass ?? "nil", privacy: .public) ns=\(info.namespace ?? "nil", privacy: .public)"
        )

        switch analysis.access {
        case .instance:
            return memberItems(
                source: source, staticAccess: false, analysis: analysis, info: info,
                index: index, stubIndex: stubIndex
            )
        case .static:
            return memberItems(
                source: source, staticAccess: true, analysis: analysis, info: info,
                index: index, stubIndex: stubIndex
            )
        case .none:
            return generalItems(analysis: analysis, info: info, index: index, stubIndex: stubIndex)
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
        index: SymbolIndex,
        stubIndex: SymbolIndex?
    ) -> [PHPCompletionItem] {
        guard let receiver = analysis.receiver, !receiver.isEmpty else {
            Self.logger.notice("member: no receiver parsed")
            return []
        }
        guard let typeFQN = resolveReceiverType(
            receiver,
            source: source,
            analysis: analysis,
            info: info,
            index: index,
            stubIndex: stubIndex
        ) else {
            Self.logger.notice(
                // swiftlint:disable:next line_length
                "member: unresolved receiver '\(receiver, privacy: .public)' (contextClass=\(analysis.contextClass ?? "nil", privacy: .public))"
            )
            return []
        }

        let members = membersForType(typeFQN, info: info, index: index, stubIndex: stubIndex)
        Self.logger.notice(
            "member: receiver='\(receiver, privacy: .public)' type=\(typeFQN, privacy: .public) members=\(members.count, privacy: .public)"
        )

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
        index: SymbolIndex,
        stubIndex: SymbolIndex?
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
            let inferred = inferVariableType(
                trimmed, source: source, analysis: analysis, info: info, index: index, stubIndex: stubIndex
            )
            Self.logger.notice("receiver: '\(trimmed, privacy: .public)' -> \(inferred ?? "nil", privacy: .public)")
            return inferred
        }

        // A bare name after `->` is often a property access (`$this->session->`), so try to
        // resolve its declared type before treating it as a class name.
        if let context = analysis.contextClass {
            let contextMembers = membersForType(context, info: info, index: index, stubIndex: stubIndex)
            if let property = contextMembers.first(where: { $0.name == trimmed && $0.kind == .property }) {
                guard let type = property.signature, !type.isEmpty else {
                    Self.logger.notice("receiver: property '\(trimmed, privacy: .public)' has no resolvable type")
                    return nil
                }
                let resolved = resolveClassFQN(stripType(type), info: info, index: index, stubIndex: stubIndex)
                Self.logger.notice(
                    // swiftlint:disable:next line_length
                    "receiver: property '\(trimmed, privacy: .public)' type '\(type, privacy: .public)' -> \(resolved ?? "nil", privacy: .public)"
                )
                return resolved
            }
        }

        let resolved = resolveClassFQN(trimmed, info: info, index: index, stubIndex: stubIndex)
        Self.logger.notice("receiver: class/alias '\(trimmed, privacy: .public)' -> \(resolved ?? "nil", privacy: .public)")
        return resolved
    }

    /// Members of a type: its own members plus those contributed by used traits.
    /// Falls back to the bundled stubs when the type isn't in the workspace.
    private static func membersForType(
        _ typeFQN: String,
        info: PHPFileSymbols,
        index: SymbolIndex,
        stubIndex: SymbolIndex?
    ) -> [SymbolInfo] {
        var members = index.members(ofType: typeFQN)
        if members.isEmpty, let classSymbol = index.symbols(fullyQualified: typeFQN).first {
            let container = classSymbol.container ?? classSymbol.fullyQualifiedName
            members = index.members(ofType: container)
        }

        if members.isEmpty, let stubIndex {
            members = stubIndex.members(ofType: typeFQN)
            if members.isEmpty, let classSymbol = stubIndex.symbols(fullyQualified: typeFQN).first {
                members = stubIndex.members(ofType: classSymbol.container ?? classSymbol.fullyQualifiedName)
            }
        }

        if let traits = info.classTraits[typeFQN] {
            for trait in traits {
                if let traitFQN = resolveClassFQN(trait, info: info, index: index, stubIndex: nil) {
                    members.append(contentsOf: index.members(ofType: traitFQN))
                }
            }
        }
        return members
    }

    /// Reduces a type expression (`?Foo`, `Foo|null`, `Foo|Bar`) to a single class name.
    private static func stripType(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespaces)
        while text.hasPrefix("?") { text.removeFirst() }
        if let first = text.split(separator: "|").first {
            text = String(first).trimmingCharacters(in: .whitespaces)
        }
        return text.lowercased() == "null" ? "" : text
    }

    private static func resolveClassFQN(
        _ name: String,
        info: PHPFileSymbols,
        index: SymbolIndex,
        stubIndex: SymbolIndex?
    ) -> String? {
        if name.hasPrefix("\\") {
            return String(name.dropFirst())
        }
        if let aliasTarget = info.aliases[name] {
            return aliasTarget
        }
        if name.contains("\\") {
            if !index.symbols(fullyQualified: name).isEmpty { return name }
            if let stubIndex, !stubIndex.symbols(fullyQualified: name).isEmpty { return name }
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
        // Stub fallback (built-in global functions/classes).
        if let stubIndex {
            if !stubIndex.symbols(fullyQualified: name).isEmpty { return name }
            if let symbol = stubIndex.symbols(named: name).first {
                return symbol.container ?? symbol.fullyQualifiedName
            }
        }
        return name
    }

    // MARK: - General completion

    private static func generalItems(
        analysis: Analysis,
        info: PHPFileSymbols,
        index: SymbolIndex,
        stubIndex: SymbolIndex?
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

        // Workspace/project symbols and injected language-extension symbols (the `index`), offered
        // regardless of the file's namespace: global and same-namespace matches first, then other
        // namespaced matches (e.g. framework helpers contributed by a language pack).
        let fileNamespace = info.namespace ?? ""
        let indexMatches = index.symbols(prefix: prefix).filter { $0.container == nil }
        for symbol in indexMatches
        where (symbol.namespace ?? "").isEmpty || symbol.namespace == fileNamespace {
            append(item(for: symbol))
        }
        for symbol in indexMatches
        where !((symbol.namespace ?? "").isEmpty || symbol.namespace == fileNamespace) {
            append(item(for: symbol))
        }

        for keyword in keywords where prefix.isEmpty || keyword.lowercased().hasPrefix(prefix.lowercased()) {
            append(PHPCompletionItem(label: keyword, detail: "keyword"))
        }

        // Bundled stubs (built-in functions/classes/constants) — lowest priority.
        if let stubIndex, !prefix.isEmpty {
            for symbol in stubIndex.symbols(prefix: prefix) where symbol.container == nil {
                append(item(for: symbol))
            }
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
        index: SymbolIndex,
        stubIndex: SymbolIndex?
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
                return resolveClassFQN(typeName, info: info, index: index, stubIndex: stubIndex)
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

    private static let classImage = Image(systemName: "cube")
    private static let functionImage = Image(systemName: "function")
    private static let propertyImage = Image(systemName: "square.on.square")
    private static let constantImage = Image(systemName: "number")
    private static let variableImage = Image(systemName: "v.square")
    private static let namespaceImage = Image(systemName: "folder")

    private static let typeColor = Color(NSColor.systemBlue)
    private static let callableColor = Color(NSColor.systemPurple)
    private static let valueColor = Color(NSColor.systemTeal)
    private static let memberColor = Color(NSColor.systemOrange)

    static func image(for kind: SymbolKind) -> Image {
        switch kind {
        case .class, .trait, .interface, .enum: return classImage
        case .function, .method: return functionImage
        case .property: return propertyImage
        case .constant: return constantImage
        case .variable: return variableImage
        case .namespace: return namespaceImage
        }
    }

    static func imageColor(for kind: SymbolKind) -> Color {
        switch kind {
        case .class, .trait, .interface, .enum: return typeColor
        case .function, .method: return callableColor
        case .property, .variable: return valueColor
        case .constant, .namespace: return memberColor
        }
    }
}