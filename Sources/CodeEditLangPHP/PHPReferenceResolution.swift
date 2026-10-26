import Foundation
import CodeEditLang

/// Pure functions that decide whether a scanned occurrence matches a reference target.
///
/// These rules are unit-tested in isolation from the index, the scanner, and the editor.
/// The policy is deliberately conservative: false positives (reporting a reference that
/// isn't one) are worse than false negatives (missing a reference), so exact matches are
/// required except for `$this`/`self`/`static` member calls whose receiver type is unknown
/// — those become `isHeuristic: true` rows.
enum PHPReferenceResolution {

    /// Whether `occurrence` at `offset` in `sourceFile` is an exact reference to `target`.
    ///
    /// - Parameters:
    ///   - occurrence: A single name occurrence from `PHPReferenceScanner`.
    ///   - target: The symbol being searched for.
    ///   - targetAliases: `use` aliases from the target's file (`alias → FQN`).
    ///   - targetNamespace: Namespace of the target's file.
    ///   - targetContainer: Enclosing type of a member target, if any.
    ///   - sourceFileFQN: The FQN of the class the occurrence is inside (if any).
    ///   - sourceFileAliases: `use` aliases from the occurrence's file.
    ///   - sourceFileNamespace: Namespace of the occurrence's file.
    ///   - traitsOfSourceClass: Trait names used by `sourceFileFQN` (if it's a class).
    ///   - unresolvedReceivers: Set of short names whose receiver type is unresolved across
    ///     the occurrence's file (used to decide heuristic matches).
    static func occurrenceMatches(
        occurrence: PHPReferenceOccurrence,
        target: ReferenceTarget,
        targetAliases: [String: String],
        targetNamespace: String?,
        targetContainer: String?,
        sourceFileFQN: String?,
        sourceFileAliases: [String: String],
        sourceFileNamespace: String?,
        traitsOfSourceClass: Set<String>,
        unresolvedReceivers: Set<String>
    ) -> (matches: Bool, isHeuristic: Bool) {
        let name = occurrence.name
        let lowerName = name.lowercased()

        // Declaration match: the target's own file and range.
        if occurrence.fileURL == target.fileURL && occurrence.range == target.range {
            return (true, false)
        }

        // Resolve what this occurrence actually refers to.
        let resolved = resolveOccurrenceFQN(
            name: name,
            aliases: sourceFileAliases,
            namespace: sourceFileNamespace,
            container: sourceFileFQN,
            traits: traitsOfSourceClass
        )

        // Exact FQN match.
        if let resolvedFQN = resolved {
            if matchesFQN(resolvedFQN, target: target, targetFQNs: targetFQNs(
                target: target,
                aliases: targetAliases,
                namespace: targetNamespace,
                container: targetContainer
            )) {
                return (true, false)
            }
        }

        // Short-name + container match for member targets: the occurrence is inside the
        // same type as the target, and the short names match.
        if target.isMember, let targetContainer = target.container {
            let targetContainerLower = targetContainer.lowercased()
            if let sfFQN = sourceFileFQN, sfFQN.lowercased() == targetContainerLower,
               occurrence.name.lowercased() == target.identifier.lowercased() {
                return (true, false)
            }
        }

        // Heuristics: a name-only match when the receiver type is unknown.
        // For `$this->method()` / `self::method()` / `static::method()` calls where we
        // cannot determine the receiver's type, we still report a heuristic match if the
        // member name matches the target's short name.
        if unresolvedReceivers.contains(lowerName),
           target.isMember,
           occurrence.name.lowercased() == target.identifier.lowercased() {
            return (true, true)
        }

        // Name-only match for non-member targets (functions, classes, constants):
        // if the short name matches and the occurrence is a type reference or function call,
        // report it as a heuristic match.
        if !target.isMember,
           occurrence.name.lowercased() == target.identifier.lowercased(),
           occurrence.isTypeReference || occurrence.isFunctionCall {
            return (true, true)
        }

        return (false, false)
    }

    /// All fully-qualified names the target might be known by, for exact matching.
    /// Includes the target's own FQN, any `use`-alias expansions, and the short name.
    private static func targetFQNs(
        target: ReferenceTarget,
        aliases: [String: String],
        namespace: String?,
        container: String?
    ) -> Set<String> {
        var names = Set<String>()

        if let fqn = target.fullyQualifiedName {
            names.insert(fqn.lowercased())
        }

        if let container = container {
            names.insert(container.lowercased())
        }

        // Aliases that point to the same FQN.
        if let fqn = target.fullyQualifiedName {
            for (alias, resolved) in aliases {
                if resolved.lowercased() == fqn.lowercased() {
                    names.insert(alias.lowercased())
                }
            }
        }

        // Short name.
        names.insert(target.identifier.lowercased())

        return names
    }

    /// Resolves an occurrence name to a fully-qualified name given the file's context.
    private static func resolveOccurrenceFQN(
        name: String,
        aliases: [String: String],
        namespace: String?,
        container: String?,
        traits: Set<String>
    ) -> String? {
        let lower = name.lowercased()

        // `use` alias.
        if let fqn = aliases[name] {
            return fqn
        }
        if let fqn = aliases[lower] {
            return fqn
        }

        // If the name is fully qualified, use it.
        if name.contains("\\") {
            return name
        }

        // Inside a class: resolve via namespace + class name.
        if let container = container {
            if let ns = namespace, !ns.isEmpty {
                return "\(ns)\\\(container)::\(name)"
            }
            return "\(container)::\(name)"
        }

        // Global namespace.
        if let ns = namespace, !ns.isEmpty {
            return "\(ns)\\\(name)"
        }

        return name
    }

    /// Whether `fqn` (lowercased) matches any of the target's known FQNs.
    private static func matchesFQN(_ fqn: String, target: ReferenceTarget, targetFQNs: Set<String>) -> Bool {
        if targetFQNs.contains(fqn) {
            return true
        }

        // Trait match: if the occurrence's class uses a trait, and the target is a member
        // of that trait, the occurrence references the target via the trait.
        if target.isMember {
            let fqnEndsWithTraitMember = fqn.hasSuffix("::\(target.identifier)")
            if fqnEndsWithTraitMember {
                return true
            }
        }

        return false
    }
}

/// An occurrence of a name in a PHP file, produced by `PHPReferenceScanner`.
struct PHPReferenceOccurrence: Sendable {
    let name: String
    let range: NSRange
    let fileURL: URL
    let isTypeReference: Bool
    let isFunctionCall: Bool
    let isMemberCall: Bool
    let receiverType: String?  // resolved receiver type for `$this->foo()`, `self::foo()`, etc.
    let containerFQN: String?   // enclosing class FQN
}
