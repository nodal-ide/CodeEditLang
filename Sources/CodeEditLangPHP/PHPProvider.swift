import Foundation
import AppKit
import SwiftUI
import CodeEditSourceEditor
import CodeEditTextView
import CodeEditLang

/// A native completion popover entry for PHP.
public struct PHPCompletionItem: CodeSuggestionEntry {
    public let label: String
    public let detail: String?
    public let documentation: String?
    public let image: Image
    public let imageColor: Color
    /// Text inserted when accepted. Defaults to `label`.
    public let insertText: String

    public var pathComponents: [String]? { nil }
    public var targetPosition: CursorPosition? { nil }
    public var sourcePreview: String? { nil }
    public var deprecated: Bool { false }

    public init(
        label: String,
        detail: String? = nil,
        documentation: String? = nil,
        insertText: String? = nil,
        image: Image = Image(systemName: "text.alignleft"),
        imageColor: Color = Color(NSColor.systemGray)
    ) {
        self.label = label
        self.detail = detail
        self.documentation = documentation
        self.insertText = insertText ?? label
        self.image = image
        self.imageColor = imageColor
    }
}

/// Native PHP provider that plugs into the editor's existing completion popup and
/// jump-to-definition system through `CodeSuggestionDelegate`/`JumpToDefinitionDelegate`.
///
/// One instance is bound to an open file and a project `SymbolIndex`. Cross-file
/// definition navigation is routed through `openLinkHandler` (supplied by the app, which
/// owns the editor/document model).
public final class PHPProvider: NativeLanguageProvider, JumpToDefinitionDelegate, CodeSuggestionDelegate, HoverDelegate,
    SignatureHelpDelegate, CodeActionDelegate, DiagnosticsDelegate, SymbolsDelegate {
    public let languageID = "php"

    private let currentFileURL: URL
    private let index: SymbolIndex
    private let openLinkHandler: (JumpToDefinitionLink) -> Void

    public init(
        fileURL: URL,
        index: SymbolIndex,
        openLink: @escaping (JumpToDefinitionLink) -> Void
    ) {
        self.currentFileURL = fileURL
        self.index = index
        self.openLinkHandler = openLink

        // Warm the bundled stub index off the main thread so the first completion doesn't hitch.
        Task.detached(priority: .utility) {
            _ = PHPStubIndex.shared()
        }
    }

    // MARK: - JumpToDefinitionDelegate

    public func queryLinks(
        forRange range: NSRange,
        textView: TextViewController
    ) async -> [JumpToDefinitionLink]? {
        let source = textView.textView.string
        let identifier = (source as NSString).substring(with: range)
        guard !identifier.isEmpty else { return nil }

        let parsed = PHPFileParser.parse(source, fileURL: currentFileURL)
        let symbols = PHPSymbolResolver.resolve(
            identifier: identifier,
            namespace: parsed.namespace,
            aliases: parsed.aliases,
            index: index,
            stubIndex: PHPStubIndex.shared()
        ).filter { !PHPStubIndex.isStub($0) }
        guard !symbols.isEmpty else { return nil }

        return symbols.map { symbol in
            JumpToDefinitionLink(
                url: symbol.fileURL == currentFileURL ? nil : symbol.fileURL,
                targetRange: CursorPosition(range: symbol.nameRange),
                typeName: symbol.name,
                sourcePreview: symbol.fullyQualifiedName,
                documentation: symbol.documentation,
                image: PHPCompletionEngine.image(for: symbol.kind),
                imageColor: PHPCompletionEngine.imageColor(for: symbol.kind)
            )
        }
    }

    public func openLink(link: JumpToDefinitionLink) {
        openLinkHandler(link)
    }

    // MARK: - HoverDelegate

    @MainActor
    public func hoverInfo(forRange range: NSRange, textView: TextViewController) async -> HoverInfo? {
        let source = textView.textView.string
        let identifier = (source as NSString).substring(with: range)
        guard !identifier.isEmpty else { return nil }

        let parsed = PHPFileParser.parse(source, fileURL: currentFileURL)
        let symbols = PHPSymbolResolver.resolve(
            identifier: identifier,
            namespace: parsed.namespace,
            aliases: parsed.aliases,
            index: index,
            stubIndex: PHPStubIndex.shared()
        )
        guard let symbol = symbols.first else { return nil }

        var sections: [String] = []
        if symbol.kind == .function || symbol.kind == .method {
            sections.append("\(symbol.kind.rawValue) \(symbol.name)(\(symbol.parameters.joined(separator: ", ")))")
        } else {
            sections.append("\(symbol.kind.rawValue) \(symbol.fullyQualifiedName)")
        }
        if let documentation = symbol.documentation, !documentation.isEmpty {
            sections.append(documentation)
        }
        return HoverInfo(contents: sections.joined(separator: "\n\n"), range: range)
    }

    // MARK: - SignatureHelpDelegate

    @MainActor
    public func signatureHelp(
        calleeRange: NSRange,
        argumentIndex: Int,
        textView: TextViewController
    ) async -> SignatureHelpInfo? {
        let source = textView.textView.string
        let callee = (source as NSString).substring(with: calleeRange)
        guard !callee.isEmpty else { return nil }

        let parsed = PHPFileParser.parse(source, fileURL: currentFileURL)
        let symbols = PHPSymbolResolver.resolve(
            identifier: callee,
            namespace: parsed.namespace,
            aliases: parsed.aliases,
            index: index,
            stubIndex: PHPStubIndex.shared()
        )
        guard let symbol = symbols.first(where: { $0.kind == .method || $0.kind == .function }) ?? symbols.first else {
            return nil
        }
        let signature = "\(symbol.name)(\(symbol.parameters.joined(separator: ", ")))"
        let active = symbol.parameters.isEmpty ? 0 : min(max(argumentIndex, 0), symbol.parameters.count - 1)
        return SignatureHelpInfo(signature: signature, parameters: symbol.parameters, activeParameter: active)
    }

    // MARK: - SymbolsDelegate

    @MainActor
    public func documentSymbols(for textView: TextViewController) async -> [EditorSymbol] {
        let source = textView.textView.string
        let info = PHPFileParser.parse(source, fileURL: currentFileURL)
        return info.symbols.compactMap { symbol in
            guard symbol.nameRange.length > 0 else { return nil }
            let detail = symbol.container.map { "\($0) — \(symbol.kind.rawValue)" } ?? symbol.kind.rawValue
            return EditorSymbol(
                name: symbol.name,
                detail: detail,
                position: CursorPosition(range: symbol.nameRange)
            )
        }
    }

    // MARK: - DiagnosticsDelegate

    @MainActor
    public func diagnostics(for textView: TextViewController) async -> [EditorDiagnostic] {
        let source = textView.textView.string
        let info = PHPFileParser.parse(source, fileURL: currentFileURL)
        let stubIndex = PHPStubIndex.shared()

        var result: [EditorDiagnostic] = []
        for range in info.parseErrors {
            result.append(
                EditorDiagnostic(range: range, severity: .error, message: "Syntax error")
            )
        }
        for reference in info.classReferences where !Self.isPrimitiveType(reference.name) {
            if !isClassDefined(reference.name, info: info, stubIndex: stubIndex) {
                result.append(
                    EditorDiagnostic(
                        range: reference.range,
                        severity: .warning,
                        message: "Undefined class '\(reference.name)'"
                    )
                )
            }
        }
        return result
    }

    private func isClassDefined(_ name: String, info: PHPFileSymbols, stubIndex: SymbolIndex) -> Bool {
        if info.symbols.contains(where: { $0.name == name && $0.container == nil }) { return true }
        return !PHPSymbolResolver.resolve(
            identifier: name,
            namespace: info.namespace,
            aliases: info.aliases,
            index: index,
            stubIndex: stubIndex
        ).isEmpty
    }

    nonisolated static func isPrimitiveType(_ name: String) -> Bool {
        let lower = name.lowercased().replacingOccurrences(of: "\\", with: "")
        return [
            "string", "int", "float", "bool", "array", "mixed", "void", "object",
            "iterable", "callable", "null", "self", "static", "parent", "true", "false", "never"
        ].contains(lower)
    }

    // MARK: - CodeActionDelegate

    @MainActor
    public func codeActions(forRange range: NSRange, textView: TextViewController) async -> [CodeActionInfo] {
        let source = textView.textView.string
        let ns = source as NSString
        guard let (identifier, _) = Self.identifier(at: range, in: ns), !identifier.isEmpty,
              !identifier.contains("\\") else {
            return []
        }

        let parsed = PHPFileParser.parse(source, fileURL: currentFileURL)
        // Already imported by this short name.
        if parsed.aliases[identifier] != nil { return [] }

        var candidates = index.symbols(named: identifier)
        candidates.append(contentsOf: PHPStubIndex.shared().symbols(named: identifier))

        let importableKinds: Set<SymbolKind> = [.class, .interface, .trait, .enum]
        let importedFQNs = Set(parsed.aliases.values.map { $0.lowercased() })

        var seen = Set<String>()
        let importable = candidates.filter { symbol in
            guard importableKinds.contains(symbol.kind), symbol.container == nil else { return false }
            let key = symbol.fullyQualifiedName.lowercased()
            guard !importedFQNs.contains(key), seen.insert(key).inserted else { return false }
            return true
        }

        guard !importable.isEmpty else { return [] }
        let offset = Self.useInsertionOffset(in: source)
        let editRange = NSRange(location: offset, length: 0)

        return importable.map { symbol in
            CodeActionInfo(
                title: "Import '\(symbol.fullyQualifiedName)'",
                kind: "quickfix",
                edits: [CodeActionEdit(range: editRange, text: "use \(symbol.fullyQualifiedName);\n")]
            )
        }
    }

    /// The identifier token at (or immediately before) `range`.
    nonisolated static func identifier(at range: NSRange, in ns: NSString) -> (String, NSRange)? {
        func isIdentifier(_ char: unichar) -> Bool {
            guard let scalar = UnicodeScalar(char) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "\\"
        }

        if range.length > 0, range.location + range.length <= ns.length {
            let text = ns.substring(with: range)
            return (text, range)
        }

        let offset = min(max(range.location, 0), ns.length)
        var anchor = offset
        if anchor > 0, anchor <= ns.length,
           (anchor == ns.length || !isIdentifier(ns.character(at: anchor))),
           isIdentifier(ns.character(at: anchor - 1)) {
            anchor -= 1
        }
        guard anchor < ns.length, isIdentifier(ns.character(at: anchor)) else { return nil }

        var start = anchor
        while start > 0, isIdentifier(ns.character(at: start - 1)) { start -= 1 }
        var end = anchor
        while end < ns.length, isIdentifier(ns.character(at: end)) { end += 1 }
        guard end > start else { return nil }
        let range = NSRange(location: start, length: end - start)
        return (ns.substring(with: range), range)
    }

    /// Offset at which a new `use ...;` statement should be inserted.
    nonisolated static func useInsertionOffset(in source: String) -> Int {
        let ns = source as NSString
        let whole = NSRange(location: 0, length: ns.length)

        let anchors = [
            "(?m)^use\\s+[^;\\n]+;",
            "(?m)^namespace\\s+[^;\\n]+;"
        ]
        for pattern in anchors {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: source, range: whole)
            if let last = (pattern.contains("namespace") ? matches.first : matches.last) {
                return endOfLine(after: last.range.location + last.range.length, in: ns)
            }
        }

        if let phpRegex = try? NSRegularExpression(pattern: "\\A<\\?php[^\\n]*\\n?"),
           let match = phpRegex.firstMatch(in: source, range: whole) {
            return endOfLine(after: match.range.location + match.range.length, in: ns)
        }
        return 0
    }

    nonisolated private static func endOfLine(after index: Int, in ns: NSString) -> Int {
        var i = index
        while i < ns.length, ns.character(at: i) != 0x0A { i += 1 }
        return i < ns.length ? i + 1 : ns.length
    }

    // MARK: - CodeSuggestionDelegate

    @MainActor
    public func completionTriggerCharacters() -> Set<String> { ["\\", ">", ":"] }

    @MainActor
    public func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        let items = items(textView: textView, cursorPosition: cursorPosition)
        return items.isEmpty ? nil : (cursorPosition, items)
    }

    @MainActor
    public func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        let items = items(textView: textView, cursorPosition: cursorPosition)
        return items.isEmpty ? nil : items
    }

    @MainActor
    public func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {
        guard let cursorPosition else { return }
        let location = cursorPosition.range.location
        let prefixStart = Self.prefixStart(at: location, text: textView.textView.string)
        let insertText = (item as? PHPCompletionItem)?.insertText ?? item.label
        let range = NSRange(location: prefixStart, length: location - prefixStart)
        textView.textView.replaceCharacters(in: range, with: insertText)
    }

    // MARK: - Items

    @MainActor
    private func items(textView: TextViewController, cursorPosition: CursorPosition) -> [PHPCompletionItem] {
        PHPCompletionEngine.items(
            source: textView.textView.string,
            cursorOffset: cursorPosition.range.location,
            fileURL: currentFileURL,
            index: index,
            stubIndex: PHPStubIndex.shared()
        )
    }

    private static func prefixStart(at location: Int, text: String) -> Int {
        let nsText = text as NSString
        var start = min(max(location, 0), nsText.length)
        while start > 0 {
            let char = nsText.character(at: start - 1)
            let isWord: Bool
            if let scalar = UnicodeScalar(char) {
                isWord = CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "_" || scalar == "\\" || scalar == "$"
            } else {
                isWord = false
            }
            guard isWord else { break }
            start -= 1
        }
        return start
    }
}