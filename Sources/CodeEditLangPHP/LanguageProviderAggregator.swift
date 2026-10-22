//
//  LanguageProviderAggregator.swift
//  CodeEditLangPHP
//
//  Merges the results of several `LanguageProvider`s into the editor's delegate protocols.
//

import Foundation
import CodeEditSourceEditor

/// Aggregates multiple ``LanguageProvider``s and presents them to the editor as a single
/// delegate object.
///
/// Merge rules:
/// - **Completion, hover, signature help, jump-to-definition:** first non-empty result wins,
///   consulting providers in priority order (extension → built-in engine → LSP).
/// - **Diagnostics, document symbols, code actions:** results are concatenated (these are
///   additive lists with no per-item callbacks).
///
/// Because completion and definition callbacks (`completionWindowApplyCompletion`,
/// `openLink`) are routed back by item/link, the aggregator remembers which provider served
/// the active completion/definition session and forwards those callbacks to it.
public final class LanguageProviderAggregator: NSObject {
    /// Providers sorted by descending priority.
    private let providers: [any LanguageProvider]
    private let providersByLanguage: [String: [any LanguageProvider]]

    /// The provider that produced the current completion session’s items.
    private var activeCompletionProvider: (any LanguageProvider)?
    /// The provider that produced the most recent jump-to-definition links.
    private var activeDefinitionProvider: (any LanguageProvider)?

    public init(providers: [any LanguageProvider]) {
        var seen = Set<ObjectIdentifier>()
        let orderedProviders = providers
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
            .sorted { $0.priority > $1.priority }
        self.providers = orderedProviders
        var providersByLanguage: [String: [any LanguageProvider]] = [:]
        for provider in orderedProviders {
            for languageID in provider.supportedLanguageIDs {
                providersByLanguage[languageID, default: []].append(provider)
            }
        }
        self.providersByLanguage = providersByLanguage
        super.init()
    }

    private func providers(for textView: TextViewController, at location: Int) -> [any LanguageProvider] {
        let languageIDs = textView.languageIDs(at: location)
        return languageIDs.flatMap { providersByLanguage[$0.rawValue] ?? [] }
    }

    private func rootProviders(for textView: TextViewController) -> [any LanguageProvider] {
        providersByLanguage[textView.language.id.rawValue] ?? []
    }

}

// MARK: - CodeSuggestionDelegate

extension LanguageProviderAggregator: CodeSuggestionDelegate {
    @MainActor
    public func completionTriggerCharacters() -> Set<String> {
        providers.reduce(into: Set<String>()) { $0.formUnion($1.completionTriggerCharacters()) }
    }

    @MainActor
    public func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        for provider in providers(for: textView, at: cursorPosition.range.location) {
            if let result = await provider.completionSuggestionsRequested(
                textView: textView,
                cursorPosition: cursorPosition
            ), !result.items.isEmpty {
                activeCompletionProvider = provider
                return result
            }
        }
        activeCompletionProvider = nil
        return nil
    }

    @MainActor
    public func completionOnCursorMove(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) -> [CodeSuggestionEntry]? {
        guard let activeCompletionProvider,
              providers(for: textView, at: cursorPosition.range.location).contains(
                where: { ObjectIdentifier($0) == ObjectIdentifier(activeCompletionProvider) }
              ) else {
            self.activeCompletionProvider = nil
            return nil
        }
        return activeCompletionProvider.completionOnCursorMove(textView: textView, cursorPosition: cursorPosition)
    }

    @MainActor
    public func completionWindowDidClose() {
        activeCompletionProvider?.completionWindowDidClose()
        activeCompletionProvider = nil
    }

    @MainActor
    public func completionWindowApplyCompletion(
        item: CodeSuggestionEntry,
        textView: TextViewController,
        cursorPosition: CursorPosition?
    ) {
        activeCompletionProvider?.completionWindowApplyCompletion(
            item: item,
            textView: textView,
            cursorPosition: cursorPosition
        )
    }

    @MainActor
    public func completionWindowDidSelect(item: CodeSuggestionEntry) {
        activeCompletionProvider?.completionWindowDidSelect(item: item)
    }
}

// MARK: - JumpToDefinitionDelegate

extension LanguageProviderAggregator: JumpToDefinitionDelegate {
    public func queryLinks(
        forRange range: NSRange,
        textView: TextViewController
    ) async -> [JumpToDefinitionLink]? {
        for provider in providers(for: textView, at: range.location) {
            if let links = await provider.queryLinks(forRange: range, textView: textView), !links.isEmpty {
                activeDefinitionProvider = provider
                return links
            }
        }
        activeDefinitionProvider = nil
        return nil
    }

    public func openLink(link: JumpToDefinitionLink) {
        (activeDefinitionProvider ?? providers.first)?.openLink(link: link)
    }
}

// MARK: - HoverDelegate

extension LanguageProviderAggregator: HoverDelegate {
    @MainActor
    public func hoverInfo(forRange range: NSRange, textView: TextViewController) async -> HoverInfo? {
        for provider in providers(for: textView, at: range.location) {
            if let info = await provider.hoverInfo(forRange: range, textView: textView) {
                return info
            }
        }
        return nil
    }
}

// MARK: - SignatureHelpDelegate

extension LanguageProviderAggregator: SignatureHelpDelegate {
    @MainActor
    public func signatureHelp(
        calleeRange: NSRange,
        argumentIndex: Int,
        textView: TextViewController
    ) async -> SignatureHelpInfo? {
        for provider in providers(for: textView, at: calleeRange.location) {
            if let info = await provider.signatureHelp(
                calleeRange: calleeRange,
                argumentIndex: argumentIndex,
                textView: textView
            ) {
                return info
            }
        }
        return nil
    }
}

// MARK: - CodeActionDelegate

extension LanguageProviderAggregator: CodeActionDelegate {
    @MainActor
    public func codeActions(forRange range: NSRange, textView: TextViewController) async -> [CodeActionInfo] {
        var actions: [CodeActionInfo] = []
        for provider in providers(for: textView, at: range.location) {
            actions.append(contentsOf: await provider.codeActions(forRange: range, textView: textView))
        }
        return actions
    }
}

// MARK: - InlayHintDelegate

extension LanguageProviderAggregator: InlayHintDelegate {
    @MainActor
    public func inlayHints(
        forVisibleRange range: NSRange,
        textView: TextViewController
    ) async -> [EditorInlayHint] {
        // Inlay hints are additive but mixing providers would duplicate/conflict, so the
        // highest-priority provider with hints for the range wins.
        for provider in providers(for: textView, at: range.location) {
            let hints = await provider.inlayHints(forVisibleRange: range, textView: textView)
            if !hints.isEmpty {
                return hints
            }
        }
        return []
    }
}

// MARK: - FoldRangeDelegate

extension LanguageProviderAggregator: FoldRangeDelegate {
    @MainActor
    public func foldRanges(for textView: TextViewController) async -> [EditorFoldRange] {
        // Folding ranges are document-wide; prefer the highest-priority provider that has any.
        for provider in rootProviders(for: textView) {
            let ranges = await provider.foldRanges(for: textView)
            if !ranges.isEmpty {
                return ranges
            }
        }
        return []
    }
}

// MARK: - DocumentHighlightDelegate

extension LanguageProviderAggregator: DocumentHighlightDelegate {
    @MainActor
    public func documentHighlights(
        at position: CursorPosition,
        textView: TextViewController
    ) async -> [EditorDocumentHighlight] {
        for provider in providers(for: textView, at: position.range.location) {
            let highlights = await provider.documentHighlights(at: position, textView: textView)
            if !highlights.isEmpty {
                return highlights
            }
        }
        return []
    }
}

// MARK: - DiagnosticsDelegate

extension LanguageProviderAggregator: DiagnosticsDelegate {
    @MainActor
    public func diagnostics(for textView: TextViewController) async -> [EditorDiagnostic] {
        var diagnostics: [EditorDiagnostic] = []
        for provider in rootProviders(for: textView) {
            diagnostics.append(contentsOf: await provider.diagnostics(for: textView))
        }
        return diagnostics
    }
}

// MARK: - SymbolsDelegate

extension LanguageProviderAggregator: SymbolsDelegate {
    @MainActor
    public func documentSymbols(for textView: TextViewController) async -> [EditorSymbol] {
        var symbols: [EditorSymbol] = []
        for provider in rootProviders(for: textView) {
            symbols.append(contentsOf: await provider.documentSymbols(for: textView))
        }
        return symbols
    }
}
