import Foundation
import CodeEditLang

/// Orchestrates a find-references query for PHP files.
///
/// Each query is value-based and reads-only from the project index + parse cache — nothing is
/// mutated. The happy path is:
///
/// 1. Resolve the cursor position to a `ReferenceTarget` (from the cached parse of the target file).
/// 2. Look up candidate file postings from the native name index (`PHPReferenceIndex`).
/// 3. Scan each candidate file for name occurrences (parse cache hits are reused, disk reads are
///    limited and skipped for oversized files).
/// 4. Resolve each occurrence against the target using the pure `PHPReferenceResolution` rules.
/// 5. Map accepted occurrences to `EditorReference` rows in document order.
///
/// The first provider to answer wins (including an empty result set — that means "PHP knows, and
/// there are none"). Providers that can't answer (`.unsupported`) are skipped; failures are retried
/// by the aggregator. The result is capped to `query.maxResults`; truncation clears `isComplete`.
public enum PHPReferenceEngine {

    /// File posting + whether the name index is complete for that name.
    public struct Candidate {
        let posting: PHPReferencePosting
        let isComplete: Bool
    }

    /// Resolve `query.target` to a native PHP target, then find and resolve references.
    static func references(for query: ReferenceQuery, index: SymbolIndex, referenceIndex: PHPReferenceIndex) async -> ReferenceQueryOutcome {
        guard let cachedSource = readSource(for: query.target.fileURL),
              let cached = PHPParseCache.shared.cached(for: query.target.fileURL, source: cachedSource),
              let resolved = PHPTargetResolver.resolveTarget(
                at: query.target.range.location,
                source: query.source,
                info: cached,
                fileURL: query.target.fileURL
            ) else {
            return .unsupported(reason: "Place the cursor on a resolvable PHP symbol to find its references.")
        }

        guard resolved.target.fullyQualifiedName != nil || resolved.target.kind != ReferenceTarget.Kind.unknown else {
            return .unsupported(reason: "The symbol under the cursor could not be resolved to a PHP declaration.")
        }

        let targetFQNs = targetFQNs(for: resolved.target, aliases: resolved.aliases, namespace: resolved.namespace, container: resolved.target.container)

        let candidates = lookupCandidates(named: normalized(resolved.target.identifier), in: referenceIndex, limit: query.maxCandidateFiles)
        // The index reports name-level completeness; the query engine promotes that to a result-level
        // completeness flag together with whether any candidates were found.
        let nameLevelComplete = candidates.allSatisfy { $0.isComplete }
        let anyCandidates = !candidates.isEmpty

        let rows = await resolveCandidates(
            candidates: candidates,
            target: resolved.target,
            targetFQNs: targetFQNs,
            targetFileAliases: resolved.aliases,
            targetFileNamespace: resolved.namespace,
            targetContainer: resolved.target.container,
            index: index,
            referenceIndex: referenceIndex
        )

        let capped = rows.count > query.maxResults
            ? Array(rows.prefix(query.maxResults))
            : rows
        let resultComplete = nameLevelComplete && anyCandidates && capped.count == rows.count
        return .results(capped, isComplete: resultComplete)
    }

    // MARK: - Candidates

    // MARK: - Source

    private static func lookupCandidates(named shortName: String, in index: PHPReferenceIndex, limit: Int) -> [Candidate] {
        let (postings, isComplete) = index.lookUp(shortName)
        return postings.prefix(limit).map { Candidate(posting: $0, isComplete: isComplete) }
    }

    // MARK: - Resolution

    private static func resolveCandidates(
        candidates: [Candidate],
        target: ReferenceTarget,
        targetFQNs: Set<String>,
        targetFileAliases: [String: String],
        targetFileNamespace: String?,
        targetContainer: String?,
        index: SymbolIndex,
        referenceIndex: PHPReferenceIndex
    ) async -> [EditorReference] {
        var rows: [EditorReference] = []
        var sourceTexts: [URL: String] = [:]
        var cachedInfos: [URL: PHPFileSymbols] = [:]

        for candidate in candidates {
            if Task.isCancelled { return rows }

            let fileURL = URL(fileURLWithPath: candidate.posting.fileURL)
            if sourceTexts[fileURL] == nil {
                guard let source = readSource(for: fileURL) else { continue }
                let info = PHPParseCache.shared.cached(for: fileURL, source: source)
                sourceTexts[fileURL] = source
                cachedInfos[fileURL] = info
            }
            let source = sourceTexts[fileURL]!
            let info = cachedInfos[fileURL]

            let occurrences = scanOccurrences(in: source, fileURL: fileURL, info: info)

            let lineIndex = SourceLineIndex(source)

            for occurrence in occurrences {
                if Task.isCancelled { return rows }
                let (matches, isHeuristic) = occurrenceMatches(
                    occurrence: occurrence,
                    target: target,
                    targetFQNs: targetFQNs,
                    targetAliases: targetFileAliases,
                    targetNamespace: targetFileNamespace,
                    targetContainer: targetContainer,
                    occurrenceAliases: info?.aliases ?? [:],
                    occurrenceNamespace: info?.namespace,
                    occurrenceContainer: enclosingFQN(info: info, at: occurrence.range.location),
                    occurrenceTraits: TraitSet.from(info: info, fqn: enclosingFQN(info: info, at: occurrence.range.location))
                )
                if matches {
                    if let ref = lineIndex.reference(for: occurrence.range, in: source, fileURL: fileURL, kind: referenceKind(for: occurrence, target: target), container: candidate.posting.container ?? candidate.posting.fullyQualifiedName, isHeuristic: isHeuristic) {
                        rows.append(ref)
                    }
                }
            }
        }

        return rows.sorted()
    }

    // MARK: - Source

    private static func readSource(for fileURL: URL) -> String? {
        DiskSourceTextProvider(maxByteCount: 8 * 1024 * 1024).text(for: fileURL)
    }

    // MARK: - Occurrences

    private static func scanOccurrences(in source: String, fileURL: URL, info: PHPFileSymbols?) -> [PHPReferenceOccurrence] {
        PHPFileParserOccurrences.from(info: info ?? PHPFileSymbols.empty, source: source as NSString, fileURL: fileURL)
    }

    private static func enclosingFQN(info: PHPFileSymbols?, at offset: Int) -> String? {
        info?.scopes.first(where: { $0.range.location <= offset && offset < $0.range.location + $0.range.length })?.fullyQualifiedName
    }

    // MARK: - Matching

    private static func occurrenceMatches(
        occurrence: PHPReferenceOccurrence,
        target: ReferenceTarget,
        targetFQNs: Set<String>,
        targetAliases: [String: String],
        targetNamespace: String?,
        targetContainer: String?,
        occurrenceAliases: [String: String],
        occurrenceNamespace: String?,
        occurrenceContainer: String?,
        occurrenceTraits: TraitSet
    ) -> (matches: Bool, isHeuristic: Bool) {
        // Declaration match: the target's own file and range.
        if occurrence.fileURL == target.fileURL && occurrence.range == target.range {
            return (true, false)
        }

        let lowerName = occurrence.name.lowercased()

        // Member call on $this/self/static or ClassName::member — match by short name, heuristic.
        if occurrence.isMemberCall,
           target.isMember,
           lowerName == target.identifier.lowercased() {
            return (true, true)
        }

        // Name-only match for non-member targets (functions, classes, constants).
        if !target.isMember,
           lowerName == target.identifier.lowercased(),
           occurrence.isTypeReference || occurrence.isFunctionCall {
            return (true, true)
        }

        return (false, false)
    }

    private static func resolveOccurrenceFQN(
        name: String,
        aliases: [String: String],
        namespace: String?,
        container: String?,
        traits: TraitSet
    ) -> String? {
        let lower = name.lowercased()

        if let fqn = aliases[name] { return fqn }
        if let fqn = aliases[lower] { return fqn }
        if name.contains("\\") { return name }

        if let container = container {
            if let ns = namespace, !ns.isEmpty { return "\\(ns)\\\(container)::\\(name)" }
            return "\\(container)::\\(name)"
        }
        if let ns = namespace, !ns.isEmpty { return "\\(ns)\\\(name)" }
        return name
    }

    private static func matchesFQN(_ fqn: String, targetFQNs: Set<String>) -> Bool {
        return targetFQNs.contains(fqn.lowercased())
    }

    private static func referenceKind(for occurrence: PHPReferenceOccurrence, target: ReferenceTarget) -> EditorReference.Kind {
        if occurrence.fileURL == target.fileURL && occurrence.range == target.range { return .declaration }
        if occurrence.isTypeReference { return .read }
        if occurrence.isFunctionCall || occurrence.isMemberCall { return .read }
        return .text
    }

    // MARK: - FQNs

    private static func targetFQNs(
        for target: ReferenceTarget,
        aliases: [String: String],
        namespace: String?,
        container: String?
    ) -> Set<String> {
        var names = Set<String>()
        if let fqn = target.fullyQualifiedName { names.insert(fqn.lowercased()) }
        if let container = container { names.insert(container.lowercased()) }
        if let fqn = target.fullyQualifiedName {
            for (alias, resolved) in aliases where resolved.lowercased() == fqn.lowercased() {
                names.insert(alias.lowercased())
            }
        }
        names.insert(target.identifier.lowercased())
        return names
    }

    private static func normalized(_ name: String) -> String {
        var result = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix("\\") { result.removeFirst() }
        return result
    }
}

// MARK: - Small helpers

private struct TraitSet {
    let names: Set<String>
    static func from(info: PHPFileSymbols?, fqn: String?) -> TraitSet {
        var s: Set<String> = []
        if let fqn = fqn, let traits = info?.classTraits[fqn] {
            s = Set(traits.map { $0.lowercased() })
        }
        return TraitSet(names: s)
    }
}


