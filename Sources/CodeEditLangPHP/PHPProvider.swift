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
@MainActor
public final class PHPProvider: NativeLanguageProvider, JumpToDefinitionDelegate, CodeSuggestionDelegate {
    public let languageID = "php"

    private let currentFileURL: URL
    private let index: SymbolIndex
    private let openLinkHandler: (JumpToDefinitionLink) -> Void

    private static let keywords: [String] = [
        "abstract", "and", "array", "as", "break", "callable", "case", "catch", "class",
        "clone", "const", "continue", "declare", "default", "do", "echo", "else", "elseif",
        "empty", "enddeclare", "endfor", "endforeach", "endif", "endswitch", "endwhile",
        "enum", "exit", "extends", "final", "finally", "fn", "for", "foreach", "function",
        "global", "goto", "if", "implements", "include", "include_once", "instanceof",
        "insteadof", "interface", "isset", "list", "match", "namespace", "new", "or",
        "print", "private", "protected", "public", "readonly", "require", "require_once",
        "return", "static", "switch", "throw", "trait", "try", "unset", "use", "var",
        "while", "xor", "yield"
    ]

    public init(
        fileURL: URL,
        index: SymbolIndex,
        openLink: @escaping (JumpToDefinitionLink) -> Void
    ) {
        self.currentFileURL = fileURL
        self.index = index
        self.openLinkHandler = openLink
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
            index: index
        )
        guard !symbols.isEmpty else { return nil }

        return symbols.map { symbol in
            JumpToDefinitionLink(
                url: symbol.fileURL == currentFileURL ? nil : symbol.fileURL,
                targetRange: CursorPosition(range: symbol.nameRange),
                typeName: symbol.name,
                sourcePreview: symbol.fullyQualifiedName,
                documentation: symbol.documentation,
                image: Self.image(for: symbol.kind),
                imageColor: Self.imageColor(for: symbol.kind)
            )
        }
    }

    public func openLink(link: JumpToDefinitionLink) {
        openLinkHandler(link)
    }

    // MARK: - CodeSuggestionDelegate

    public func completionTriggerCharacters() -> Set<String> { ["\\"] }

    public func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        let prefix = Self.currentPrefix(at: cursorPosition.range.location, text: textView.textView.string)
        let items = buildCompletionItems(prefix: prefix, currentFileURL: currentFileURL)
        return items.isEmpty ? nil : (cursorPosition, items)
    }

    public func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        let prefix = Self.currentPrefix(at: cursorPosition.range.location, text: textView.textView.string)
        let items = buildCompletionItems(prefix: prefix, currentFileURL: currentFileURL)
        return items.isEmpty ? nil : items
    }

    public func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {
        guard let cursorPosition else { return }
        let location = cursorPosition.range.location
        let prefix = Self.currentPrefix(at: location, text: textView.textView.string)
        let insertText = (item as? PHPCompletionItem)?.insertText ?? item.label
        let range = NSRange(location: location - (prefix as NSString).length, length: (prefix as NSString).length)
        textView.textView.replaceCharacters(in: range, with: insertText)
    }

    // MARK: - Items

    private func buildCompletionItems(prefix: String, currentFileURL: URL) -> [PHPCompletionItem] {
        let normalized = prefix.replacingOccurrences(of: "\\", with: "")
        if normalized.isEmpty {
            return Self.keywords.map { PHPCompletionItem(label: $0) }
        }

        var items: [PHPCompletionItem] = []

        // Symbol matches (classes, functions, enums, ...).
        for symbol in index.symbols(prefix: normalized) where !symbol.name.isEmpty {
            items.append(
                PHPCompletionItem(
                    label: symbol.name,
                    detail: symbol.fullyQualifiedName,
                    documentation: symbol.documentation,
                    image: Self.image(for: symbol.kind),
                    imageColor: Self.imageColor(for: symbol.kind)
                )
            )
        }

        // Keywords matching the prefix.
        for keyword in Self.keywords where keyword.hasPrefix(normalized) {
            items.append(PHPCompletionItem(label: keyword, detail: "keyword"))
        }

        return items
    }

    // MARK: - Static helpers

    private static func currentPrefix(at location: Int, text: String) -> String {
        let nsText = text as NSString
        var start = min(max(location, 0), nsText.length)
        while start > 0 {
            let char = nsText.character(at: start - 1)
            let isWord: Bool
            if let scalar = UnicodeScalar(char) {
                isWord = CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "_" || scalar == "\\"
            } else {
                isWord = false
            }
            guard isWord else { break }
            start -= 1
        }
        return nsText.substring(with: NSRange(location: start, length: location - start))
    }

    private static func image(for kind: SymbolKind) -> Image {
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

    private static func imageColor(for kind: SymbolKind) -> Color {
        switch kind {
        case .class, .trait, .interface, .enum: return Color(NSColor.systemBlue)
        case .function, .method: return Color(NSColor.systemPurple)
        case .property, .variable: return Color(NSColor.systemTeal)
        case .constant, .namespace: return Color(NSColor.systemOrange)
        }
    }
}