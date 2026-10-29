//
//  LanguageProviderAggregator.swift
//  CodeEditLangPHP
//
//  Merges the results of several `LanguageProvider`s into the editor's delegate protocols.
//

import Foundation
import CodeEditLang
import CodeEditSourceEditor
import CodeEditLanguages

/// Aggregates multiple ``LanguageProvider``s and presents them to the editor as a single
/// delegate object.
///
/// Merge rules:
/// - **Completion, hover, signature help, jump-to-definition:** first non-empty result wins,
///   consulting providers in priority order (extension → built-in engine → LSP).
/// - **Diagnostics, document symbols, code actions:** results are concatenated (these are
///   additive lists with no per-item callbacks).
/// - **References:** the first provider that *answers* wins, including an empty result set; providers
///   that decline or fail are skipped, so a slower server can't contradict a more specific engine.
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

    private let completionPolicy: CompletionMergePolicy
    private let completionDeadline: Duration
    private var completionInFlight: Set<ObjectIdentifier> = []
    private var completionOwnerIDs: [ObjectIdentifier: String] = [:]
    private var completionProvidersByOwner: [String: any LanguageProvider] = [:]

    public init(
        providers: [any LanguageProvider],
        completionPolicy: CompletionMergePolicy = CompletionMergePolicy(),
        completionDeadline: Duration = .milliseconds(400)
    ) {
        var seen = Set<ObjectIdentifier>()
        let orderedProviders = providers
            .filter { seen.insert(ObjectIdentifier($0)).inserted }
            .sorted { $0.priority > $1.priority }
        self.providers = orderedProviders
        self.completionPolicy = completionPolicy
        self.completionDeadline = completionDeadline
        var providersByLanguage: [String: [any LanguageProvider]] = [:]
        var ownerIDs: [ObjectIdentifier: String] = [:]
        var providersByOwner: [String: any LanguageProvider] = [:]
        for (index, provider) in orderedProviders.enumerated() {
            let ownerID = "provider-\(index)"
            ownerIDs[ObjectIdentifier(provider)] = ownerID
            providersByOwner[ownerID] = provider
            for languageID in provider.supportedLanguageIDs {
                providersByLanguage[languageID, default: []].append(provider)
            }
        }
        self.providersByLanguage = providersByLanguage
        self.completionOwnerIDs = ownerIDs
        self.completionProvidersByOwner = providersByOwner
        super.init()
    }

    private func routedProviders(
        for textView: TextViewController,
        at location: Int
    ) -> [(provider: any LanguageProvider, context: LanguageZoneContext)] {
        let contexts = textView.languageContexts(at: location)
        let activeContexts = contexts.isEmpty
            ? [LanguageZoneContext(languageID: textView.language.id)]
            : contexts
        var seen = Set<ObjectIdentifier>()
        var matchingProviders: [(provider: any LanguageProvider, context: LanguageZoneContext)] = []
        for context in activeContexts {
            for provider in providersByLanguage[context.languageID.rawValue] ?? [] {
                guard Self.shouldRoute(
                    providerPriority: provider.priority,
                    context: context,
                    rootLanguageID: textView.language.id
                ) else {
                    continue
                }
                if seen.insert(ObjectIdentifier(provider)).inserted {
                    matchingProviders.append((provider, context))
                }
            }
        }
        return matchingProviders
    }

    private func providers(for textView: TextViewController, at location: Int) -> [any LanguageProvider] {
        routedProviders(for: textView, at: location).map(\.provider)
    }

    static func shouldRoute(
        providerPriority: LanguageProviderPriority,
        context: LanguageZoneContext,
        rootLanguageID: LanguageID
    ) -> Bool {
        providerPriority != .lsp || (context.depth == 0 && context.languageID == rootLanguageID)
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

    public var supportsCompletionRefresh: Bool { true }

    @MainActor
    public func completionResultRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> CompletionResult? {
        await mergedCompletion(textView: textView, cursorPosition: cursorPosition)
    }

    @MainActor
    public func completionRefreshRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> CompletionResult? {
        await mergedCompletion(textView: textView, cursorPosition: cursorPosition)
    }

    @MainActor
    public func completionSuggestionsRequested(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> (windowPosition: CursorPosition, items: [CodeSuggestionEntry])? {
        guard let result = await mergedCompletion(textView: textView, cursorPosition: cursorPosition) else {
            return nil
        }
        return (cursorPosition, result.items)
    }

    /// Queries every routed provider concurrently (bounded by ``completionDeadline``) and merges the
    /// results in tier order: built-in engine, language server, extensions by default.
    @MainActor
    private func mergedCompletion(
        textView: TextViewController,
        cursorPosition: CursorPosition
    ) async -> CompletionResult? {
        let routed = providers(for: textView, at: cursorPosition.range.location)
        guard !routed.isEmpty else {
            activeCompletionProvider = nil
            return nil
        }

        var tasks: [Task<CompletionResult?, Never>] = []
        tasks.reserveCapacity(routed.count)
        for provider in routed {
            tasks.append(Task { await self.queryCompletion(provider, textView: textView, position: cursorPosition) })
        }

        var groups: [CompletionMerge.Group] = []
        groups.reserveCapacity(routed.count)
        for (order, provider) in routed.enumerated() {
            guard let result = await tasks[order].value, !result.items.isEmpty else { continue }
            groups.append(CompletionMerge.Group(
                tier: completionPolicy.tier(for: provider.priority),
                order: order,
                ownerID: completionOwnerIDs[ObjectIdentifier(provider)] ?? "provider",
                items: result.items,
                isIncomplete: result.isIncomplete
            ))
        }

        guard let merged = CompletionMerge.merge(groups: groups) else {
            activeCompletionProvider = nil
            return nil
        }
        let ownerID = (merged.items.first as? AttributedCompletionEntry)?.ownerID
        activeCompletionProvider = ownerID.flatMap { completionProvidersByOwner[$0] }
        return CompletionResult(items: merged.items, isIncomplete: merged.isIncomplete)
    }

    @MainActor
    private func queryCompletion(
        _ provider: any LanguageProvider,
        textView: TextViewController,
        position: CursorPosition
    ) async -> CompletionResult? {
        let key = ObjectIdentifier(provider)
        guard !completionInFlight.contains(key) else { return nil }
        completionInFlight.insert(key)

        let gate = CompletionResumeGate()
        let deadline = completionDeadline
        return await withCheckedContinuation { continuation in
            Task { @MainActor in
                let result = await provider.completionResultRequested(
                    textView: textView,
                    cursorPosition: position
                )
                completionInFlight.remove(key)
                gate.resume(result, continuation)
            }
            Task { @MainActor in
                try? await Task.sleep(for: deadline)
                gate.resume(nil, continuation)
            }
        }
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
        let attributed = item as? AttributedCompletionEntry
        let provider = attributed.flatMap { completionProvidersByOwner[$0.ownerID] }
            ?? activeCompletionProvider
        provider?.completionWindowApplyCompletion(
            item: attributed?.base ?? item,
            textView: textView,
            cursorPosition: cursorPosition
        )
    }

    @MainActor
    public func completionWindowDidSelect(item: CodeSuggestionEntry) {
        let attributed = item as? AttributedCompletionEntry
        let provider = attributed.flatMap { completionProvidersByOwner[$0.ownerID] }
            ?? activeCompletionProvider
        provider?.completionWindowDidSelect(item: attributed?.base ?? item)
    }
}

/// Resumes a completion race exactly once.
private final class CompletionResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume(
        _ value: CompletionResult?,
        _ continuation: CheckedContinuation<CompletionResult?, Never>
    ) {
        lock.lock()
        if resumed {
            lock.unlock()
            return
        }
        resumed = true
        lock.unlock()
        continuation.resume(returning: value)
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
        for (provider, context) in routedProviders(for: textView, at: range.location) {
            actions.append(contentsOf: await provider.codeActions(forRange: range, textView: textView).map {
                guard $0.languageContext == nil else { return $0 }
                return CodeActionInfo(title: $0.title, kind: $0.kind, edits: $0.edits, languageContext: context)
            })
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
        let rootContext = LanguageZoneContext(languageID: textView.language.id)
        for provider in rootProviders(for: textView) {
            diagnostics.append(contentsOf: await provider.diagnostics(for: textView).map {
                guard $0.languageContext == nil else { return $0 }
                return EditorDiagnostic(
                    range: $0.range,
                    severity: $0.severity,
                    message: $0.message,
                    line: $0.line,
                    ruleID: $0.ruleID,
                    languageContext: rootContext
                )
            })
        }
        return diagnostics
    }
}

// MARK: - SymbolsDelegate

extension LanguageProviderAggregator: SymbolsDelegate {
    @MainActor
    public func documentSymbols(for textView: TextViewController) async -> [EditorSymbol] {
        var symbols: [EditorSymbol] = []
        let rootContext = LanguageZoneContext(languageID: textView.language.id)
        for provider in rootProviders(for: textView) {
            symbols.append(contentsOf: await provider.documentSymbols(for: textView).map {
                guard $0.languageContext == nil else { return $0 }
                return EditorSymbol(name: $0.name, detail: $0.detail, position: $0.position, languageContext: rootContext)
            })
        }
        return symbols
    }
}

// MARK: - ReferenceProviding

extension LanguageProviderAggregator: ReferenceProviding {
    /// `true` when at least one registered provider can answer references queries.
    public var supportsReferences: Bool {
        providers.contains { $0.supportsReferences }
    }

    /// Routes the query to the providers registered for its language zone, then merges.
    public func references(for query: ReferenceQuery) async -> ReferenceQueryOutcome {
        let candidates = providersForReferences(query).map { $0 as any ReferenceProviding }
        return await Self.mergeReferences(query: query, providers: candidates)
    }

    /// Providers that may answer this query: registered for the target's language zone, in priority
    /// order, subject to the same root-zone rule the interactive delegates use for LSP providers.
    func providersForReferences(_ query: ReferenceQuery) -> [any LanguageProvider] {
        let rootLanguageID = LanguageID(rawValue: query.rootLanguageID ?? query.languageID)
        let context = LanguageZoneContext(
            languageID: LanguageID(rawValue: query.languageID),
            depth: query.zoneDepth
        )
        return (providersByLanguage[query.languageID] ?? []).filter { provider in
            Self.shouldRoute(
                providerPriority: provider.priority,
                context: context,
                rootLanguageID: rootLanguageID
            )
        }
    }

    /// The merge policy, separated from routing so it can be tested without editor infrastructure.
    ///
    /// - Providers are consulted in the given order (highest priority first).
    /// - `.unsupported` is skipped; `.failed` is remembered and the next provider is tried.
    /// - The first `.results` outcome wins **even when empty**: an authoritative “none” must stop the
    ///   search rather than let a lower-priority provider contradict it.
    /// - Results are defensively capped to `query.maxResults`; truncation clears `isComplete`.
    static func mergeReferences(
        query: ReferenceQuery,
        providers: [any ReferenceProviding]
    ) async -> ReferenceQueryOutcome {
        var lastFailure: ReferenceQueryError?
        var declineReason: String?
        var sawCapability = false

        for provider in providers {
            if Task.isCancelled { return .failed(.cancelled) }
            guard provider.supportsReferences else { continue }
            sawCapability = true

            switch await provider.references(for: query) {
            case .results(let references, let isComplete):
                if Task.isCancelled { return .failed(.cancelled) }
                let capped = references.count > query.maxResults
                    ? Array(references.prefix(max(0, query.maxResults)))
                    : references
                return .results(capped, isComplete: isComplete && capped.count == references.count)
            case .unsupported(let reason):
                if declineReason == nil, !reason.isEmpty { declineReason = reason }
            case .failed(.cancelled):
                return .failed(.cancelled)
            case .failed(let error):
                lastFailure = error
            }
        }

        if let lastFailure { return .failed(lastFailure) }
        if let declineReason { return .unsupported(reason: declineReason) }
        if !sawCapability {
            return .unsupported(reason: "Find references isn't available for this file.")
        }
        return .unsupported(reason: "No language provider returned references for this symbol.")
    }
}
