import Foundation

/// A producer of symbol references (native engine, language server, extension).
///
/// The contract is intentionally small and value-based: capture the editor state once into a
/// ``ReferenceQuery``, then answer off the main actor. Implementations must be thread-safe because a
/// query runs outside the main actor, and must never report a partial answer as complete.
///
/// The aggregator consults providers in priority order and treats the **first answered** outcome as
/// authoritative — including an empty result set, which means "this provider knows, and there are
/// none". That prevents a slower provider from contradicting a more specific one.
public protocol ReferenceProviding: AnyObject {
    /// Cheap capability flag used to enable UI and to skip providers without paying for a query.
    ///
    /// The default implementation in `LanguageProvider` returns `false`; a provider that implements
    /// `references(for:)` must also return `true` here, or the aggregator will never call it.
    var supportsReferences: Bool { get }

    /// Resolves references for a snapshotted query.
    func references(for query: ReferenceQuery) async -> ReferenceQueryOutcome
}
