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
    /// Presentation kind; defaults to `.unknown`.
    public let kind: CompletionItemKind
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
        kind: CompletionItemKind = .unknown,
        image: Image = Image(systemName: "text.alignleft"),
        imageColor: Color = Color(NSColor.systemGray)
    ) {
        self.label = label
        self.detail = detail
        self.documentation = documentation
        self.insertText = insertText ?? label
        self.kind = kind
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
public final class PHPProvider: NativeLanguageProvider, LanguageProvider {
    public let languageID = "php"

    /// The built-in engine ranks above LSP but below user extensions.
    public var priority: LanguageProviderPriority { .internalLanguage }
    /// Expose the native reference engine through the generic reference-providing API so editor code
    /// can ask for references without special-casing PHP.
    public var nativeReferenceEngine: (any ReferenceProviding)? { self }

    private let currentFileURL: URL
    private let index: SymbolIndex
    private let referenceIndex: PHPReferenceIndex
    private let openLinkHandler: (JumpToDefinitionLink) -> Void

    /// Called with the file's diagnostics after each computation (for a problems panel).
    public var onDiagnostics: ((URL, [EditorDiagnostic]) -> Void)?

    /// Code-quality rule configuration (thresholds, enabled rules, skip paths). Injected by the app.
    public var diagnosticsConfig: PHPDiagnosticsConfig = .default

    /// Coalesces the two completion callbacks that fire per keystroke
    /// (`completionSuggestionsRequested` + `completionOnCursorMove`).
    private var lastItemsSignature: String?
    private var lastItems: [PHPCompletionItem] = []

    public init(
        fileURL: URL,
        index: SymbolIndex,
        referenceIndex: PHPReferenceIndex,
        openLink: @escaping (JumpToDefinitionLink) -> Void
    ) {
        self.currentFileURL = fileURL
        self.index = index
        self.referenceIndex = referenceIndex
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

        let parsed = await PHPParseCache.shared.infoAsync(for: currentFileURL, source: source)
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

        let parsed = await PHPParseCache.shared.infoAsync(for: currentFileURL, source: source)
        let symbols = PHPSymbolResolver.resolve(
            identifier: identifier,
            namespace: parsed.namespace,
            aliases: parsed.aliases,
            index: index,
            stubIndex: PHPStubIndex.shared()
        )
        guard let symbol = symbols.first else { return nil }
        return HoverInfo(content: PHPHoverMapper.content(for: symbol), range: range)
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

        let parsed = await PHPParseCache.shared.infoAsync(for: currentFileURL, source: source)
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
        let info = await PHPParseCache.shared.infoAsync(for: currentFileURL, source: source)
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
        let fileURL = currentFileURL
        let config = diagnosticsConfig
        let info = await PHPParseCache.shared.infoAsync(for: fileURL, source: source)
        let stubIndex = PHPStubIndex.shared()

        let lineStarts = Self.lineStartOffsets(in: source)
        func line(at offset: Int) -> Int { Self.lineNumber(for: offset, in: lineStarts) }

        var result: [EditorDiagnostic] = []

        // 1. Syntax errors.
        for range in info.parseErrors {
            result.append(
                EditorDiagnostic(range: range, severity: .error, message: "Syntax error", line: line(at: range.location))
            )
        }

        // 2. Undefined variables.
        for variable in info.undefinedVariables {
            result.append(
                EditorDiagnostic(
                    range: variable.range,
                    severity: .warning,
                    message: "Undefined variable '$\(variable.name)'",
                    line: line(at: variable.range.location)
                )
            )
        }

        // 3. Undefined classes.
        for reference in info.classReferences where !Self.isPrimitiveType(reference.name) {
            if !isClassDefined(reference.name, info: info, stubIndex: stubIndex) {
                result.append(
                    EditorDiagnostic(
                        range: reference.range,
                        severity: .warning,
                        message: "Undefined class '\(reference.name)'",
                        line: line(at: reference.range.location)
                    )
                )
            }
        }

        // 4. Undefined functions.
        for call in info.functionCalls where !Self.isPrimitiveType(call.name) {
            if !isFunctionDefined(call.name, info: info, stubIndex: stubIndex) {
                result.append(
                    EditorDiagnostic(
                        range: call.range,
                        severity: .warning,
                        message: "Undefined function '\(call.name)'",
                        line: line(at: call.range.location)
                    )
                )
            }
        }

        // 5. Unused imports.
        for unused in info.unusedImports {
            result.append(
                EditorDiagnostic(
                    range: unused.range,
                    severity: .hint,
                    message: "Unused import '\(unused.name)'",
                    line: line(at: unused.range.location)
                )
            )
        }

        // 6. Code-quality rules (length, complexity, strict types, TODO, …). This is the regex-heavy
        // part, so run it off the main actor (the engine is pure over Sendable inputs).
        let quality = await Task.detached(priority: .userInitiated) {
            PHPDiagnosticsEngine.run(source: source, info: info, fileURL: fileURL, settings: config)
        }.value
        result.append(contentsOf: quality.map {
            EditorDiagnostic(
                range: $0.range,
                severity: $0.severity,
                message: $0.message,
                line: $0.line,
                ruleID: $0.ruleID
            )
        })

        onDiagnostics?(fileURL, result)
        return result
    }

    nonisolated private static func lineStartOffsets(in source: String) -> [Int] {
        let ns = source as NSString
        var starts: [Int] = [0]
        var index = 0
        while index < ns.length {
            if ns.character(at: index) == 0x0A { starts.append(index + 1) }
            index += 1
        }
        return starts
    }

    nonisolated private static func lineNumber(for offset: Int, in starts: [Int]) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] <= offset {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return max(1, low)
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

    private func isFunctionDefined(_ name: String, info: PHPFileSymbols, stubIndex: SymbolIndex) -> Bool {
        if info.symbols.contains(where: { $0.name == name && $0.kind == .function && $0.container == nil }) {
            return true
        }
        if index.symbols(named: name).contains(where: { $0.kind == .function && $0.container == nil }) {
            return true
        }
        return stubIndex.symbols(named: name).contains { $0.kind == .function }
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
        let parsed = await PHPParseCache.shared.infoAsync(for: currentFileURL, source: source)
        let lineStarts = PHPDiagnosticsEngine.lineStartOffsets(in: source)
        let cursorLine = PHPDiagnosticsEngine.lineNumber(for: range.location, in: lineStarts)

        var actions: [CodeActionInfo] = []

        // 1. Add `declare(strict_types=1);` (offered near the top of a file that's missing it).
        if cursorLine <= 2, source.contains("<?php"), !Self.hasStrictTypes(source) {
            let offset = Self.phpOpenTagEnd(in: source)
            actions.append(
                CodeActionInfo(
                    title: "Add 'declare(strict_types=1);'",
                    kind: "quickfix",
                    edits: [
                        CodeActionEdit(range: NSRange(location: offset, length: 0), text: "declare(strict_types=1);\n")
                    ]
                )
            )
        }

        // 2. Strict comparison for a loose operator at the cursor.
        for operatorRange in parsed.looseComparisons
        where range.location >= operatorRange.location - 1
            && range.location <= operatorRange.location + operatorRange.length {
            let op = ns.substring(with: operatorRange)
            let strict = op == "==" ? "===" : "!=="
            actions.append(
                CodeActionInfo(
                    title: "Replace '\(op)' with '\(strict)'",
                    kind: "quickfix",
                    edits: [CodeActionEdit(range: operatorRange, text: strict)]
                )
            )
            break
        }

        // 3. Remove an unused import on the cursor's line.
        for unused in parsed.unusedImports
        where PHPDiagnosticsEngine.lineNumber(for: unused.range.location, in: lineStarts) == cursorLine {
            let lineRange = Self.fullLineRange(containing: unused.range, in: ns)
            actions.append(
                CodeActionInfo(
                    title: "Remove unused import '\(unused.name)'",
                    kind: "quickfix",
                    edits: [CodeActionEdit(range: lineRange, text: "")]
                )
            )
        }

        // 4. Import an unresolved identifier.
        if let (identifier, _) = Self.identifier(at: range, in: ns),
           !identifier.isEmpty, !identifier.contains("\\"), parsed.aliases[identifier] == nil {
            actions.append(contentsOf: importActions(identifier: identifier, parsed: parsed, source: source))
        }

        return actions
    }

    /// Quick fixes that import a symbol by its short name.
    @MainActor
    private func importActions(
        identifier: String,
        parsed: PHPFileSymbols,
        source: String
    ) -> [CodeActionInfo] {
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

        let editRange = NSRange(location: Self.useInsertionOffset(in: source), length: 0)
        return importable.map { symbol in
            CodeActionInfo(
                title: "Import '\(symbol.fullyQualifiedName)'",
                kind: "quickfix",
                edits: [CodeActionEdit(range: editRange, text: "use \(symbol.fullyQualifiedName);\n")]
            )
        }
    }

    /// Whether the source already declares `strict_types=1`.
    nonisolated static func hasStrictTypes(_ source: String) -> Bool {
        let head = source.prefix(2000)
        return head.contains("declare(strict_types=1)") || head.contains("declare(strict_types = 1)")
    }

    /// Offset just after the `<?php` opening line.
    nonisolated static func phpOpenTagEnd(in source: String) -> Int {
        let ns = source as NSString
        let range = ns.range(of: "<?php")
        guard range.location != NSNotFound else { return 0 }
        return endOfLine(after: range.location + range.length, in: ns)
    }

    /// The full line (including its newline) containing `range`.
    nonisolated static func fullLineRange(containing range: NSRange, in ns: NSString) -> NSRange {
        var start = min(max(range.location, 0), ns.length)
        while start > 0, ns.character(at: start - 1) != 0x0A { start -= 1 }
        var end = min(range.location + max(range.length, 0), ns.length)
        while end < ns.length, ns.character(at: end) != 0x0A { end += 1 }
        if end < ns.length { end += 1 }
        return NSRange(location: start, length: max(0, end - start))
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

    // MARK: - ReferenceProviding

    public var supportsReferences: Bool { true }

    public func references(for query: ReferenceQuery) async -> ReferenceQueryOutcome {
        await PHPReferenceEngine.references(
            for: query,
            index: index,
            referenceIndex: referenceIndex
        )
    }

    // MARK: - CodeSuggestionDelegate

    @MainActor
    public func completionTriggerCharacters() -> Set<String> { ["\\", ">", ":"] }

    public var supportsCompletionRefresh: Bool { true }

    @MainActor
    public func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        guard let result = await completionResultRequested(
            textView: textView,
            cursorPosition: cursorPosition
        ) else {
            return nil
        }
        return (cursorPosition, result.items)
    }

    @MainActor
    public func completionResultRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> CompletionResult? {
        let items = await asyncItems(textView: textView, cursorPosition: cursorPosition)
        return items.isEmpty ? nil : CompletionResult(items: items)
    }

    @MainActor
    public func completionRefreshRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> CompletionResult? {
        let items = syncItems(textView: textView, cursorPosition: cursorPosition)
        return items.isEmpty ? nil : CompletionResult(items: items)
    }

    @MainActor
    public func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        let items = syncItems(textView: textView, cursorPosition: cursorPosition)
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

    /// Async path: parse off the main thread, then build (cheap) items here.
    @MainActor
    private func asyncItems(textView: TextViewController, cursorPosition: CursorPosition) async -> [PHPCompletionItem] {
        let source = textView.textView.string
        let offset = cursorPosition.range.location
        let signature = Self.signature(source: source, offset: offset)
        if signature == lastItemsSignature { return lastItems }

        let info = await PHPParseCache.shared.infoAsync(for: currentFileURL, source: source)
        let built = PHPCompletionEngine.items(
            info: info,
            source: source,
            cursorOffset: offset,
            fileURL: currentFileURL,
            index: index,
            stubIndex: PHPStubIndex.shared()
        )
        return finalize(signature: signature, built: built)
    }

    /// Sync path (cursor-move filtering): reuses the cache warmed by the async path.
    @MainActor
    private func syncItems(textView: TextViewController, cursorPosition: CursorPosition) -> [PHPCompletionItem] {
        let source = textView.textView.string
        let offset = cursorPosition.range.location
        let signature = Self.signature(source: source, offset: offset)
        if signature == lastItemsSignature { return lastItems }

        let built = PHPCompletionEngine.items(
            source: source,
            cursorOffset: offset,
            fileURL: currentFileURL,
            index: index,
            stubIndex: PHPStubIndex.shared()
        )
        return finalize(signature: signature, built: built)
    }

    @MainActor
    private func finalize(signature: String, built: [PHPCompletionItem]) -> [PHPCompletionItem] {
        let capped = built.count > Self.maxItems ? Array(built.prefix(Self.maxItems)) : built
        lastItemsSignature = signature
        lastItems = capped
        return capped
    }

    private nonisolated static func signature(source: String, offset: Int) -> String {
        "\(source.utf16.count):\(offset):\(prefixStart(at: offset, text: source))"
    }

    private static let maxItems = 200

    nonisolated private static func prefixStart(at location: Int, text: String) -> Int {
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
