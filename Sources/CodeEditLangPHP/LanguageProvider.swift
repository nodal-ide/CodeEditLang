//
//  LanguageProvider.swift
//  CodeEditLangPHP
//
//  The language-provider SPI: the abstraction a native engine or a language extension
//  implements so it can plug into the editor's completion/hover/definition/diagnostics
//  pipeline. Providers are merged by `LanguageProviderAggregator`.
//

import Foundation
import CodeEditLang
import CodeEditSourceEditor

/// Priority of a language provider. Higher-priority providers are consulted first for
/// single-result queries (completion, hover, signature help, jump-to-definition).
public enum LanguageProviderPriority: Int, Comparable, Sendable {
    /// A language server (lowest; used only when nothing native handles the language).
    case lsp = 0
    /// The app's built-in engine for the language (e.g. the native PHP engine).
    case internalLanguage = 100
    /// A user-installed extension.
    case languageExtension = 200

    public static func < (lhs: LanguageProviderPriority, rhs: LanguageProviderPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The SPI a language provider implements.
///
/// It bundles the editor's delegate protocols so a single object can contribute completion,
/// jump-to-definition, hover, signature help, code actions, diagnostics and document symbols
/// for one language. Register providers in the app and merge them with
/// ``LanguageProviderAggregator``.
///
/// References are a command-driven data capability rather than an editor delegate, so they come from
/// ``CodeEditLang/ReferenceProviding``. The defaults below keep every existing provider compiling;
/// a provider that implements `references(for:)` must also override `supportsReferences`.
public protocol LanguageProvider: AnyObject,
    CodeSuggestionDelegate,
    JumpToDefinitionDelegate,
    HoverDelegate,
    SignatureHelpDelegate,
    CodeActionDelegate,
    DiagnosticsDelegate,
    SymbolsDelegate,
    InlayHintDelegate,
    FoldRangeDelegate,
    DocumentHighlightDelegate,
    ReferenceProviding {

    /// The language this provider serves, e.g. `"php"`.
    var languageID: String { get }

    /// All language zones this provider can serve. Defaults to the root language above.
    var supportedLanguageIDs: Set<String> { get }

    /// Merge priority. See ``LanguageProviderPriority``.
    var priority: LanguageProviderPriority { get }
}

public extension LanguageProvider {
    var priority: LanguageProviderPriority { .internalLanguage }
    var supportedLanguageIDs: Set<String> { [languageID] }

    /// Providers opt into find-references by implementing `references(for:)` **and** returning
    /// `true` here. The aggregator skips providers whose flag is `false` without querying them.
    var supportsReferences: Bool { false }

    func references(for query: ReferenceQuery) async -> ReferenceQueryOutcome {
        .unsupported(reason: "Find references isn't supported for \(languageID) yet.")
    }

    /// Providers opt into inlay hints by overriding this. Default: none.
    @MainActor
    func inlayHints(forVisibleRange range: NSRange, textView: TextViewController) async -> [EditorInlayHint] {
        []
    }

    /// Providers opt into language-server folding ranges by overriding this. Default: none.
    @MainActor
    func foldRanges(for textView: TextViewController) async -> [EditorFoldRange] {
        []
    }

    /// Providers opt into document highlights by overriding this. Default: none.
    @MainActor
    func documentHighlights(
        at position: CursorPosition,
        textView: TextViewController
    ) async -> [EditorDocumentHighlight] {
        []
    }
}
