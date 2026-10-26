import Foundation
import CodeEditLang

/// Placeholder Swift references engine.
///
/// Swift support is not yet wired for find-references; this exists so the Swift provider can
/// declare `supportsReferences == true` and the aggregator has something concrete to call without
/// a compile-time gap. It will be replaced by a real index/scanner when Swift reference support
/// lands.
public enum SwiftReferenceEngine {

    public static func references(for query: ReferenceQuery) async -> ReferenceQueryOutcome {
        .unsupported(reason: "Find references isn't supported for Swift yet.")
    }
}
