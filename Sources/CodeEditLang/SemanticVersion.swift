import Foundation

/// A minimal semantic version (`major.minor.patch`) used to evaluate `engines.codeedit`.
///
/// Extension manifests only need numeric release versions here; prerelease/build metadata is not
/// interpreted, and a requirement containing it is reported as invalid rather than guessed at.
struct SemanticVersion: Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("-"),
              !trimmed.contains("+"),
              !trimmed.contains("*") else {
            return nil
        }

        let components = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count),
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }

        let numbers = components.compactMap { Int($0) }
        guard numbers.count == components.count, numbers.allSatisfy({ $0 >= 0 }) else {
            return nil
        }
        self.major = numbers[0]
        self.minor = numbers.count > 1 ? numbers[1] : 0
        self.patch = numbers.count > 2 ? numbers[2] : 0
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// A small semver range evaluator for manifest `engines` requirements.
///
/// Supports exact versions plus `>`, `>=`, `<`, `<=`, `=`, `^` and `~`, separated by commas and/or
/// whitespace (for example `>=0.18.0 <0.19.0`). This intentionally implements the subset extension
/// authors need; anything else is rejected by the validator instead of silently ignored.
struct VersionRequirement {
    private enum Constraint {
        case lessThan(SemanticVersion)
        case lessThanOrEqual(SemanticVersion)
        case greaterThan(SemanticVersion)
        case greaterThanOrEqual(SemanticVersion)
        case equal(SemanticVersion)
    }

    private let constraints: [Constraint]

    init?(_ raw: String) {
        let tokens = raw
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return nil }

        var constraints: [Constraint] = []
        for token in tokens {
            guard let constraint = Self.constraint(from: String(token)) else { return nil }
            constraints.append(contentsOf: constraint)
        }
        self.constraints = constraints
    }

    func isSatisfied(by version: SemanticVersion) -> Bool {
        constraints.allSatisfy { constraint in
            switch constraint {
            case .lessThan(let bound): version < bound
            case .lessThanOrEqual(let bound): version <= bound
            case .greaterThan(let bound): version > bound
            case .greaterThanOrEqual(let bound): version >= bound
            case .equal(let bound): version == bound
            }
        }
    }

    private static func constraint(from token: String) -> [Constraint]? {
        let operators = [">=", "<=", "^", "~", ">", "<", "="]
        let matched = operators.first { token.hasPrefix($0) }
        let versionText = matched.map { String(token.dropFirst($0.count)) } ?? token
        guard let version = SemanticVersion(versionText) else { return nil }

        switch matched {
        case ">="?: return [.greaterThanOrEqual(version)]
        case "<="?: return [.lessThanOrEqual(version)]
        case ">"?: return [.greaterThan(version)]
        case "<"?: return [.lessThan(version)]
        case "="?: return [.equal(version)]
        case "^"?:
            return [.greaterThanOrEqual(version), .lessThan(caretUpperBound(for: version))]
        case "~"?:
            return [.greaterThanOrEqual(version), .lessThan(tildeUpperBound(for: version))]
        default:
            return [.equal(version)]
        }
    }

    private static func caretUpperBound(for version: SemanticVersion) -> SemanticVersion {
        if version.major > 0 {
            return SemanticVersion("\(version.major + 1).0.0")!
        }
        if version.minor > 0 {
            return SemanticVersion("0.\(version.minor + 1).0")!
        }
        return SemanticVersion("0.0.\(version.patch + 1)")!
    }

    private static func tildeUpperBound(for version: SemanticVersion) -> SemanticVersion {
        SemanticVersion("\(version.major).\(version.minor + 1).0")!
    }
}
