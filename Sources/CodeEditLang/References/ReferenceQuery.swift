import Foundation

/// Everything a references provider needs, snapshotted from the editor on the main actor.
///
/// The query carries a copy of the originating file's live buffer so providers never have to reach
/// back into `TextViewController` (which is main-actor AppKit) while searching, and so unsaved edits
/// are honored.
public struct ReferenceQuery: Sendable {
    /// Default number of rows kept per query. Providers may stop earlier; the aggregator enforces it.
    public static let defaultMaxResults = 2_000
    /// Default number of candidate files a native engine may parse for one query.
    public static let defaultMaxCandidateFiles = 3_000

    public let target: ReferenceTarget
    /// The language of the zone the target lives in (e.g. `php`, `typescript`).
    public let languageID: String
    /// The document's root language; `nil` means the same as `languageID`.
    public let rootLanguageID: String?
    /// Zone nesting depth: `0` is the document's root language, `> 0` is an embedded zone.
    public let zoneDepth: Int
    /// Live text of the target's file (unsaved changes included).
    public let source: String
    public let workspaceRoot: URL?
    public let includeDeclaration: Bool
    public let maxResults: Int
    public let maxCandidateFiles: Int

    public init(
        target: ReferenceTarget,
        languageID: String,
        rootLanguageID: String? = nil,
        zoneDepth: Int = 0,
        source: String,
        workspaceRoot: URL? = nil,
        includeDeclaration: Bool = true,
        maxResults: Int = ReferenceQuery.defaultMaxResults,
        maxCandidateFiles: Int = ReferenceQuery.defaultMaxCandidateFiles
    ) {
        self.target = target
        self.languageID = languageID
        self.rootLanguageID = rootLanguageID
        self.zoneDepth = zoneDepth
        self.source = source
        self.workspaceRoot = workspaceRoot
        self.includeDeclaration = includeDeclaration
        self.maxResults = maxResults
        self.maxCandidateFiles = maxCandidateFiles
    }
}

/// The result of a references query, preserving *why* there is nothing to show.
///
/// The app must be able to distinguish "no references" from "not supported", "failed", and
/// "cancelled"; collapsing all of them into an empty array is what makes the old implementation
/// unable to render an honest empty state.
public enum ReferenceQueryOutcome: Sendable, Equatable {
    /// Occurrences. `isComplete == false` means the provider truncated or could not finish
    /// (indexing in progress, candidate/result caps). Never report a partial answer as complete.
    case results([EditorReference], isComplete: Bool)
    /// The provider cannot answer this query (no capability, unsupported symbol kind, server not ready).
    case unsupported(reason: String)
    case failed(ReferenceQueryError)

    /// The references, when the query produced a result set.
    public var references: [EditorReference]? {
        guard case .results(let references, _) = self else { return nil }
        return references
    }

    /// Whether the provider produced an authoritative answer.
    public var isAnswered: Bool { references != nil }

    /// Whether the result set is known to be complete.
    public var isComplete: Bool {
        guard case .results(_, let isComplete) = self else { return false }
        return isComplete
    }
}

/// Why a references query could not produce results.
public enum ReferenceQueryError: Error, Sendable, Equatable {
    /// The transport (language server pipe) failed.
    case transport(String)
    /// The provider did not answer in time.
    case timedOut
    /// The query was superseded or the session closed.
    case cancelled
    /// The provider exists but is not ready yet (server starting, index warming).
    case notReady(String)

    /// Short, user-facing description. The list UI shows this in its failure state.
    public var message: String {
        switch self {
        case .transport(let detail):
            return detail.isEmpty ? "The language server could not complete the request." : detail
        case .timedOut:
            return "The search timed out before any references were returned."
        case .cancelled:
            return "The search was cancelled."
        case .notReady(let detail):
            return detail.isEmpty ? "The language engine is still starting." : detail
        }
    }
}
