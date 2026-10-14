//
//  LanguageProvider.swift
//  CodeEditLangPHP
//
//  The language-provider SPI: the abstraction a native engine or a language extension
//  implements so it can plug into the editor's completion/hover/definition/diagnostics
//  pipeline. Providers are merged by `LanguageProviderAggregator`.
//

import Foundation
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
public protocol LanguageProvider: AnyObject,
    CodeSuggestionDelegate,
    JumpToDefinitionDelegate,
    HoverDelegate,
    SignatureHelpDelegate,
    CodeActionDelegate,
    DiagnosticsDelegate,
    SymbolsDelegate {

    /// The language this provider serves, e.g. `"php"`.
    var languageID: String { get }

    /// Merge priority. See ``LanguageProviderPriority``.
    var priority: LanguageProviderPriority { get }
}

public extension LanguageProvider {
    var priority: LanguageProviderPriority { .internalLanguage }
}
