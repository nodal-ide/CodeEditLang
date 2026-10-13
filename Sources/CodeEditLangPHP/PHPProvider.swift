import Foundation
import AppKit
import SwiftUI
import os
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
public final class PHPProvider: NativeLanguageProvider, JumpToDefinitionDelegate, CodeSuggestionDelegate, HoverDelegate {
    public let languageID = "php"

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "CodeEdit",
        category: "PHP"
    )

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
    }

    // MARK: - JumpToDefinitionDelegate

    public func queryLinks(
        forRange range: NSRange,
        textView: TextViewController
    ) async -> [JumpToDefinitionLink]? {
        let source = textView.textView.string
        let identifier = (source as NSString).substring(with: range)
        Self.logger.notice(
            "definition: range=\(NSStringFromRange(range), privacy: .public) identifier='\(identifier, privacy: .public)'"
        )
        guard !identifier.isEmpty else {
            Self.logger.notice("definition: empty identifier")
            return nil
        }

        let parsed = PHPFileParser.parse(source, fileURL: currentFileURL)
        let symbols = PHPSymbolResolver.resolve(
            identifier: identifier,
            namespace: parsed.namespace,
            aliases: parsed.aliases,
            index: index
        )
        Self.logger.notice(
            // swiftlint:disable:next line_length
            "definition: ns=\(parsed.namespace ?? "nil", privacy: .public) aliases=\(parsed.aliases, privacy: .public) -> \(symbols.map(\.fullyQualifiedName), privacy: .public)"
        )
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
        Self.logger.notice(
            "hover: range=\(NSStringFromRange(range), privacy: .public) identifier='\(identifier, privacy: .public)'"
        )
        guard !identifier.isEmpty else {
            Self.logger.notice("hover: empty identifier")
            return nil
        }

        let parsed = PHPFileParser.parse(source, fileURL: currentFileURL)
        let symbols = PHPSymbolResolver.resolve(
            identifier: identifier,
            namespace: parsed.namespace,
            aliases: parsed.aliases,
            index: index
        )
        Self.logger.notice("hover: resolved \(symbols.map(\.fullyQualifiedName), privacy: .public)")
        guard let symbol = symbols.first else {
            Self.logger.notice("hover: no symbol resolved for '\(identifier, privacy: .public)'")
            return nil
        }

        var sections: [String] = []
        sections.append("\(symbol.kind.rawValue) \(symbol.fullyQualifiedName)")
        if let documentation = symbol.documentation, !documentation.isEmpty {
            sections.append(documentation)
        } else {
            Self.logger.notice("hover: symbol has no docblock")
        }
        return HoverInfo(contents: sections.joined(separator: "\n\n"), range: range)
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
        let source = textView.textView.string
        let offset = cursorPosition.range.location
        let result = PHPCompletionEngine.items(
            source: source,
            cursorOffset: offset,
            fileURL: currentFileURL,
            index: index
        )
        Self.logger.notice(
            // swiftlint:disable:next line_length
            "completion: offset=\(offset, privacy: .public) items=\(result.count, privacy: .public) first=\(result.prefix(8).map(\.label), privacy: .public)"
        )
        return result
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