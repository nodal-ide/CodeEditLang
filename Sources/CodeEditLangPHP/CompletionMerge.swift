//
//  CompletionMerge.swift
//  CodeEditLangPHP
//

import Foundation
import SwiftUI
import CodeEditSourceEditor

/// How completion sources are ordered when more than one provider can answer.
///
/// `.automatic` keeps the built-in engine first (it owns language semantics), then a running language
/// server, then user extensions. The other cases let a user prefer a different primary source.
public enum CompletionSourcePreference: String, Codable, CaseIterable, Sendable {
    case automatic
    case languageServerFirst
    case extensionFirst
}

public struct CompletionMergePolicy: Sendable {
    public var preference: CompletionSourcePreference

    public init(preference: CompletionSourcePreference = .automatic) {
        self.preference = preference
    }

    /// Lower tiers are merged first and win duplicate labels.
    public func tier(for priority: LanguageProviderPriority) -> Int {
        switch preference {
        case .automatic:
            switch priority {
            case .internalLanguage: return 0
            case .lsp: return 1
            case .languageExtension: return 2
            }
        case .languageServerFirst:
            switch priority {
            case .lsp: return 0
            case .internalLanguage: return 1
            case .languageExtension: return 2
            }
        case .extensionFirst:
            switch priority {
            case .languageExtension: return 0
            case .internalLanguage: return 1
            case .lsp: return 2
            }
        }
    }
}

/// A completion entry that remembers which provider produced it so accepting it routes the edit back
/// to the right provider after a merge.
public struct AttributedCompletionEntry: CodeSuggestionEntry {
    public let ownerID: String
    public let base: any CodeSuggestionEntry

    public init(ownerID: String, base: any CodeSuggestionEntry) {
        self.ownerID = ownerID
        self.base = base
    }

    public var label: String { base.label }
    public var detail: String? { base.detail }
    public var documentation: String? { base.documentation }
    public var pathComponents: [String]? { base.pathComponents }
    public var targetPosition: CursorPosition? { base.targetPosition }
    public var sourcePreview: String? { base.sourcePreview }
    public var image: Image { base.image }
    public var imageColor: Color { base.imageColor }
    public var deprecated: Bool { base.deprecated }
    public var kind: CompletionItemKind { base.kind }
    public var filterText: String? { base.filterText }
    public var sortText: String? { base.sortText }
    public var preselect: Bool { base.preselect }
    public var isSnippet: Bool { base.isSnippet }
}

enum CompletionMerge {
    struct Group {
        let tier: Int
        let order: Int
        let ownerID: String
        let items: [any CodeSuggestionEntry]
        let isIncomplete: Bool
    }

    /// Merges provider results by tier, then provider order, dropping duplicate labels.
    ///
    /// The highest tier present supplies the primary list; remaining providers are appended up to
    /// `appendedLimit` items. Ordering inside a group is preserved.
    static func merge(
        groups: [Group],
        appendedLimit: Int = 100,
        totalLimit: Int = 400
    ) -> (items: [any CodeSuggestionEntry], isIncomplete: Bool)? {
        let ordered = groups
            .filter { !$0.items.isEmpty }
            .sorted { lhs, rhs in
                lhs.tier == rhs.tier ? lhs.order < rhs.order : lhs.tier < rhs.tier
            }
        guard let primary = ordered.first else { return nil }

        var seen = Set<String>()
        var merged: [any CodeSuggestionEntry] = []
        merged.reserveCapacity(min(totalLimit, primary.items.count + appendedLimit))

        func append(_ item: any CodeSuggestionEntry, ownerID: String) -> Bool {
            let key = dedupeKey(for: item)
            guard seen.insert(key).inserted else { return true }
            merged.append(AttributedCompletionEntry(ownerID: ownerID, base: item))
            return merged.count < totalLimit
        }

        for item in primary.items where append(item, ownerID: primary.ownerID) {
            if merged.count >= totalLimit { break }
        }

        var appended = 0
        for group in ordered.dropFirst() {
            for item in group.items {
                guard appended < appendedLimit, merged.count < totalLimit else { break }
                let before = merged.count
                _ = append(item, ownerID: group.ownerID)
                if merged.count > before { appended += 1 }
            }
            if appended >= appendedLimit || merged.count >= totalLimit { break }
        }

        return (merged, primary.isIncomplete)
    }

    static func dedupeKey(for item: any CodeSuggestionEntry) -> String {
        "\(item.label.lowercased())\u{1}\(item.detail ?? "")"
    }
}
