import Foundation

// MARK: - Issues

/// A validation finding for a language-extension pack.
public struct LanguageExtensionIssue: Equatable, Sendable {
    public enum Severity: String, Sendable {
        case error
        case warning
    }

    public let severity: Severity
    public let message: String
    /// The manifest key or pack-relative path the issue refers to, when applicable.
    public let location: String?

    public init(severity: Severity, message: String, location: String? = nil) {
        self.severity = severity
        self.message = message
        self.location = location
    }

    public static func error(_ message: String, at location: String? = nil) -> Self {
        .init(severity: .error, message: message, location: location)
    }

    public static func warning(_ message: String, at location: String? = nil) -> Self {
        .init(severity: .warning, message: message, location: location)
    }

    /// A single-line rendering used by the CLI and diagnostics: `location: message`.
    public var description: String {
        location.map { "\($0): \(message)" } ?? message
    }
}

/// The outcome of validating a pack.
public struct LanguageExtensionValidationResult: Sendable {
    public let issues: [LanguageExtensionIssue]

    public init(issues: [LanguageExtensionIssue]) {
        self.issues = issues
    }

    public var errors: [LanguageExtensionIssue] { issues.filter { $0.severity == .error } }
    public var warnings: [LanguageExtensionIssue] { issues.filter { $0.severity == .warning } }
    public var isValid: Bool { !issues.contains { $0.severity == .error } }
}

// MARK: - Path resolution

/// Resolves and containment-checks the pack-relative paths a manifest refers to.
///
/// A pack must never be able to read or load a file outside its own root, so every contributed path
/// goes through ``resolve(_:in:)`` before it is opened.
public enum LanguageExtensionPaths {
    /// Resolves a pack-relative path into an absolute URL, rejecting absolute paths and any `..`
    /// component. Returns `nil` when the path escapes the pack root.
    public static func resolve(_ path: String, in root: URL) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { return nil }

        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !components.contains("..") else { return nil }

        let rootPath = root.standardizedFileURL.path
        let candidate = root.appendingPathComponent(trimmed).standardizedFileURL
        guard candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/") else { return nil }
        return candidate
    }

    /// Whether `url` still lives inside `root` after resolving symlinks (for files that exist).
    public static func isContained(_ url: URL, in root: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved == rootPath || resolved.hasPrefix(rootPath + "/")
    }
}

// MARK: - Context

/// The built-in language mappings a pack is checked against.
///
/// The app supplies these from its language catalog; the CLI leaves them empty because it does not
/// link the tree-sitter grammars.
public struct LanguageExtensionKnownLanguages: Sendable {
    public var identifiers: Set<String>
    public var extensions: Set<String>
    public var fileNames: Set<String>

    public init(identifiers: Set<String> = [], extensions: Set<String> = [], fileNames: Set<String> = []) {
        self.identifiers = identifiers
        self.extensions = extensions
        self.fileNames = fileNames
    }

    public static let empty = LanguageExtensionKnownLanguages()
}

/// Where a pack was installed from. Only globally installed packs may load native grammars.
public enum LanguageExtensionPackScope: String, Sendable {
    case global
    case workspace
}

/// Options controlling how strictly a pack is validated.
public struct LanguageExtensionValidationContext: Sendable {
    public var known: LanguageExtensionKnownLanguages
    /// Whether this build supports native grammar packs at all.
    public var allowsNativeGrammars: Bool
    /// The pack's installation scope. Workspace packs are query-only.
    public var scope: LanguageExtensionPackScope
    /// The running CodeEdit version, when known. Used to enforce `engines.codeedit`; the CLI leaves
    /// it `nil` because it is not running inside the app.
    public var hostVersion: String?

    public init(
        known: LanguageExtensionKnownLanguages = .empty,
        allowsNativeGrammars: Bool = false,
        scope: LanguageExtensionPackScope = .global,
        hostVersion: String? = nil
    ) {
        self.known = known
        self.allowsNativeGrammars = allowsNativeGrammars
        self.scope = scope
        self.hostVersion = hostVersion
    }

    public static let `default` = LanguageExtensionValidationContext()
}

// MARK: - Validator

/// Validates `extension.json` manifests and their referenced files.
///
/// Shared by `codeedit-ext validate`, install, discovery and app loading so a pack is judged by the
/// same rules everywhere. Only structural checks live here; query *compilation* happens in the app
/// loader, where the tree-sitter grammars are available.
public enum LanguageExtensionValidator {
    private static let knownCapabilities: Set<String> = [
        "syntax", "nativeGrammars", "symbols", "provider", "snippets", "stubRoots", "knowledge"
    ]

    private static let supportedSchemaVersions = LanguageExtensionSchema.supportedVersions

    /// The largest accepted tree-sitter query file. Queries are compiled on the main actor when a
    /// workspace catalog is built, so an unbounded file would let a pack stall the editor.
    static let maximumQueryFileSize = 1_048_576

    /// Reads and validates the pack at `root` (a directory containing `extension.json`).
    public static func validate(
        packAt root: URL,
        context: LanguageExtensionValidationContext = .default
    ) -> LanguageExtensionValidationResult {
        let manifestURL = root.appendingPathComponent("extension.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            return LanguageExtensionValidationResult(issues: [
                .error("No extension.json found in \(root.lastPathComponent).", at: "extension.json")
            ])
        }
        let manifest: LanguageExtensionManifest
        do {
            manifest = try JSONDecoder().decode(LanguageExtensionManifest.self, from: data)
        } catch {
            return LanguageExtensionValidationResult(issues: [
                .error("extension.json is invalid: \(describe(error))", at: "extension.json")
            ])
        }
        return validate(manifest: manifest, root: root, context: context)
    }

    public static func validate(
        manifest: LanguageExtensionManifest,
        root: URL,
        context: LanguageExtensionValidationContext = .default
    ) -> LanguageExtensionValidationResult {
        var issues: [LanguageExtensionIssue] = []

        validateIdentity(manifest, context: context, into: &issues)
        validateCapabilities(manifest, into: &issues)
        let paths = PackPaths(root: root)
        validateResources(manifest, paths: paths, into: &issues)
        validateSyntax(manifest, paths: paths, context: context, into: &issues)

        return LanguageExtensionValidationResult(issues: issues)
    }

    // MARK: Identity & versioning

    private static func validateIdentity(
        _ manifest: LanguageExtensionManifest,
        context: LanguageExtensionValidationContext,
        into issues: inout [LanguageExtensionIssue]
    ) {
        let version = manifest.schemaVersion ?? 1
        if !supportedSchemaVersions.contains(version) {
            issues.append(.error(
                "Unsupported schemaVersion \(version); this build supports \(supportedSchemaVersions).",
                at: "schemaVersion"
            ))
        } else if version >= 2, manifest.engines?.codeedit == nil {
            issues.append(.warning("Manifest v2 should declare `engines.codeedit`.", at: "engines"))
        }

        validateEngineRequirement(manifest, context: context, into: &issues)

        let packID = manifest.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if packID.isEmpty {
            issues.append(.error("`id` must not be empty.", at: "id"))
        } else if !isValidPackID(packID) {
            // The id is used as the pack's directory name on install, so separators and `..` must
            // never reach a filesystem operation.
            issues.append(.error(
                "`id` must contain only letters, digits, '.', '_' and '-', and must not contain '..'.",
                at: "id"
            ))
        } else if !packID.contains(".") {
            issues.append(.warning("`id` should be a reverse-DNS id, e.g. com.example.pack.", at: "id"))
        }

        if manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.error("`name` must not be empty.", at: "name"))
        }

        if let url = manifest.url, URL(string: url) == nil {
            issues.append(.warning("`url` is not a valid URL: \(url).", at: "url"))
        }

        if let files = manifest.activation?.files {
            for pattern in files where pattern.contains("*") || pattern.contains("?") {
                issues.append(.warning(
                    "`activation.files` pattern '\(pattern)' contains a wildcard and will be ignored.",
                    at: "activation.files"
                ))
            }
        }
    }

    private static func validateEngineRequirement(
        _ manifest: LanguageExtensionManifest,
        context: LanguageExtensionValidationContext,
        into issues: inout [LanguageExtensionIssue]
    ) {
        guard let raw = manifest.engines?.codeedit else { return }
        let requirement = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requirement.isEmpty else {
            issues.append(.error("`engines.codeedit` must not be empty.", at: "engines.codeedit"))
            return
        }
        guard let parsed = VersionRequirement(requirement) else {
            issues.append(.warning(
                "`engines.codeedit` is not a supported version range: \(raw).",
                at: "engines.codeedit"
            ))
            return
        }
        guard let hostVersion = context.hostVersion, let host = SemanticVersion(hostVersion) else {
            return
        }
        if !parsed.isSatisfied(by: host) {
            issues.append(.error(
                "Requires CodeEdit \(requirement), but this is \(hostVersion).",
                at: "engines.codeedit"
            ))
        }
    }

    private static func validateCapabilities(
        _ manifest: LanguageExtensionManifest,
        into issues: inout [LanguageExtensionIssue]
    ) {
        let capabilities = Set(manifest.capabilities ?? [])
        for capability in capabilities.subtracting(knownCapabilities).sorted() {
            issues.append(.warning("Unknown capability '\(capability)'.", at: "capabilities"))
        }

        let version = manifest.schemaVersion ?? 1
        let syntax = manifest.contributes?.syntax ?? []
        if !syntax.isEmpty {
            if version < 2 {
                issues.append(.warning("`contributes.syntax` requires schemaVersion 2.", at: "schemaVersion"))
            }
            if !capabilities.contains("syntax") {
                issues.append(.warning(
                    "Contributes syntax but `capabilities` does not list \"syntax\".",
                    at: "capabilities"
                ))
            }
        }
    }

    // MARK: Files

    private static func validateResources(
        _ manifest: LanguageExtensionManifest,
        paths: PackPaths,
        into issues: inout [LanguageExtensionIssue]
    ) {
        if let icon = manifest.icon {
            validateFile(icon, kind: "icon", required: false, severity: .warning, paths: paths, into: &issues)
        }

        let contributes = manifest.contributes

        for file in contributes?.snippets ?? [] {
            validateFile(file, kind: "Snippet file", required: true, severity: .error, paths: paths, into: &issues)
        }
        for root in contributes?.stubRoots ?? [] {
            validateDirectory(root, kind: "Stub root", paths: paths, into: &issues)
        }

        for file in contributes?.symbols ?? [] {
            guard let url = validateFile(
                file, kind: "Symbol file", required: true, severity: .error, paths: paths, into: &issues
            ) else { continue }
            validateSymbolFile(url, path: file, into: &issues)
        }

        for knowledge in contributes?.knowledge ?? [] {
            validateKnowledge(knowledge, paths: paths, into: &issues)
        }

        if let provider = contributes?.provider {
            if provider.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.error("`contributes.provider.command` must not be empty.", at: "contributes.provider"))
            } else if provider.command.contains("/") {
                validateFile(
                    provider.command, kind: "Provider executable", required: true,
                    severity: .error, paths: paths, into: &issues
                )
            }
            if let languages = provider.languages, languages.isEmpty {
                issues.append(.warning("`contributes.provider.languages` is empty.", at: "contributes.provider"))
            }
        }

        let languages = manifest.languages ?? []
        let hasProvider = contributes?.provider != nil
        let hasSymbols = !(contributes?.symbols ?? []).isEmpty
        let hasSyntax = !(contributes?.syntax ?? []).isEmpty
        if languages.isEmpty, hasSymbols || hasProvider {
            issues.append(.warning(
                "No `languages` declared — symbol/provider contributions will never activate."
            ))
        }
        if !hasSymbols && !hasProvider && !hasSyntax {
            issues.append(.warning(
                "No `contributes.symbols`, `contributes.provider` or `contributes.syntax` — the pack contributes nothing."
            ))
        }
    }

    private static func validateKnowledge(
        _ knowledge: LanguageExtensionManifest.Contributes.Knowledge,
        paths: PackPaths,
        into issues: inout [LanguageExtensionIssue]
    ) {
        let location = "contributes.knowledge[\(knowledge.id)]"
        if knowledge.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.error("Knowledge set `id` must not be empty.", at: location))
        }
        if knowledge.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.error("Knowledge set `title` must not be empty.", at: location))
        }
        let base: URL
        if let root = knowledge.root {
            guard let directory = validateDirectory(
                root, kind: "Knowledge root", paths: paths, into: &issues
            ) else { return }
            base = directory
        } else {
            base = paths.root
        }
        if let index = knowledge.index {
            validateFile(
                index, kind: "Knowledge index", relativeTo: base,
                required: true, severity: .error, paths: paths, into: &issues
            )
        }
    }

    private static func validateSymbolFile(
        _ url: URL,
        path: String,
        into issues: inout [LanguageExtensionIssue]
    ) {
        guard let data = try? Data(contentsOf: url) else {
            issues.append(.error("Symbol file could not be read: \(path)", at: path))
            return
        }
        do {
            let pack = try JSONDecoder().decode(LanguageSymbolPack.self, from: data)
            if pack.symbols.isEmpty {
                issues.append(.warning("Symbol file has no symbols: \(path)", at: path))
            }
            if pack.symbols.contains(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                issues.append(.error("A symbol in \(path) has an empty name.", at: path))
            }
        } catch {
            issues.append(.error("Symbol file \(path) is invalid: \(describe(error))", at: path))
        }
    }

    // MARK: Syntax contributions

    private static func validateSyntax(
        _ manifest: LanguageExtensionManifest,
        paths: PackPaths,
        context: LanguageExtensionValidationContext,
        into issues: inout [LanguageExtensionIssue]
    ) {
        let syntax = manifest.contributes?.syntax ?? []
        guard !syntax.isEmpty else { return }

        var seenIDs = Set<String>()
        var seenExtensions: [String: String] = [:]
        var seenFileNames: [String: String] = [:]

        for (index, contribution) in syntax.enumerated() {
            let location = "contributes.syntax[\(index)]"
            validateSyntaxID(
                contribution.id, location: location, context: context,
                seenIDs: &seenIDs, into: &issues
            )
            validateGrammar(
                contribution.grammar, location: location, context: context, paths: paths, into: &issues
            )
            validateQueries(contribution.queries, paths: paths, into: &issues)
            validateComments(contribution.comments, location: location, into: &issues)
            validateDetection(
                contribution, location: location, context: context,
                seenExtensions: &seenExtensions, seenFileNames: &seenFileNames, into: &issues
            )
        }
    }

    private static func validateSyntaxID(
        _ rawID: String,
        location: String,
        context: LanguageExtensionValidationContext,
        seenIDs: inout Set<String>,
        into issues: inout [LanguageExtensionIssue]
    ) {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else {
            issues.append(.error("Syntax `id` must not be empty.", at: "\(location).id"))
            return
        }
        let key = id.lowercased()
        if !isValidLanguageID(key) {
            issues.append(.error(
                "Syntax `id` '\(id)' is not a valid language id (letters, digits, '.', '_', '+', '-').",
                at: "\(location).id"
            ))
        }
        if !seenIDs.insert(key).inserted {
            issues.append(.error("Duplicate syntax `id` '\(id)'.", at: "\(location).id"))
        }
        if context.known.identifiers.contains(key) {
            issues.append(.error(
                "Syntax `id` '\(id)' collides with a built-in language id.", at: "\(location).id"
            ))
        }
    }

    private static func validateGrammar(
        _ grammar: LanguageExtensionManifest.Contributes.Syntax.Grammar,
        location: String,
        context: LanguageExtensionValidationContext,
        paths: PackPaths,
        into issues: inout [LanguageExtensionIssue]
    ) {
        let grammarLocation = "\(location).grammar"
        switch grammar.kind {
        case "builtin":
            let name = grammar.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if name.isEmpty {
                issues.append(.error("Built-in grammar requires `name`.", at: grammarLocation))
            } else if !context.known.identifiers.isEmpty,
                      !context.known.identifiers.contains(name.lowercased()) {
                issues.append(.error("Unknown built-in grammar '\(name)'.", at: grammarLocation))
            }
        case "native":
            guard context.allowsNativeGrammars else {
                issues.append(.error(
                    "Native grammar packs are not supported in this version of CodeEdit.",
                    at: grammarLocation
                ))
                return
            }
            guard context.scope == .global else {
                issues.append(.error(
                    "Native grammars are only allowed in globally installed extensions; "
                        + "workspace packs must reuse a built-in grammar.",
                    at: grammarLocation
                ))
                return
            }
            if let path = grammar.path {
                guard let url = validateFile(
                    path, kind: "Native grammar", required: true, severity: .error, paths: paths, into: &issues
                ) else { return }
                if url.pathExtension.lowercased() != "dylib" {
                    issues.append(.error(
                        "Native grammar must be a `.dylib`: \(path)", at: grammarLocation
                    ))
                }
            } else {
                issues.append(.error("Native grammar requires `path`.", at: grammarLocation))
            }
            if let symbol = grammar.symbol?.trimmingCharacters(in: .whitespacesAndNewlines) {
                if symbol.isEmpty {
                    issues.append(.error("Native grammar requires `symbol`.", at: grammarLocation))
                } else if !isValidGrammarSymbol(symbol) {
                    issues.append(.error(
                        "Native grammar `symbol` must be an exported `tree_sitter_*` symbol: \(symbol)",
                        at: grammarLocation
                    ))
                }
            } else {
                issues.append(.error("Native grammar requires `symbol`.", at: grammarLocation))
            }
            if let sha256 = grammar.sha256, !isValidSHA256(sha256) {
                issues.append(.error(
                    "Native grammar `sha256` must be 64 lowercase hex characters.", at: grammarLocation
                ))
            }
        default:
            issues.append(.error(
                "Unknown grammar kind '\(grammar.kind)'; expected \"builtin\" or \"native\".",
                at: grammarLocation
            ))
        }
    }

    private static func validateQueries(
        _ queries: LanguageExtensionManifest.Contributes.Syntax.Queries,
        paths: PackPaths,
        into issues: inout [LanguageExtensionIssue]
    ) {
        for (name, path) in queries.namedPaths {
            guard let url = validateFile(
                path, kind: "\(name.capitalized) query", required: true,
                severity: .error, paths: paths, into: &issues
            ) else { continue }

            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = attributes?[.size] as? Int ?? 0
            if size > maximumQueryFileSize {
                issues.append(.error(
                    "\(name.capitalized) query is too large (\(size) bytes; maximum is \(maximumQueryFileSize)).",
                    at: path
                ))
            }
        }
    }

    private static func validateComments(
        _ comments: LanguageExtensionManifest.Contributes.Syntax.Comments?,
        location: String,
        into issues: inout [LanguageExtensionIssue]
    ) {
        guard let block = comments?.block else { return }
        guard block.count == 2, block.allSatisfy({ !$0.isEmpty }) else {
            issues.append(.error(
                "Comment `block` must be a pair of non-empty start and end tokens.",
                at: "\(location).comments.block"
            ))
            return
        }
    }

    private static func validateDetection(
        _ contribution: LanguageExtensionManifest.Contributes.Syntax,
        location: String,
        context: LanguageExtensionValidationContext,
        seenExtensions: inout [String: String],
        seenFileNames: inout [String: String],
        into issues: inout [LanguageExtensionIssue]
    ) {
        let id = contribution.id
        for rawExtension in contribution.extensions ?? [] {
            let ext = normalizeExtension(rawExtension)
            guard !ext.isEmpty else {
                issues.append(.error("Empty extension entry.", at: "\(location).extensions"))
                continue
            }
            if let owner = seenExtensions[ext] {
                issues.append(.error(
                    "Extension '\(ext)' is already mapped by syntax '\(owner)'.", at: "\(location).extensions"
                ))
            } else {
                seenExtensions[ext] = id
            }
            if context.known.extensions.contains(ext) {
                issues.append(.error(
                    "Extension '\(ext)' conflicts with a built-in language mapping.", at: "\(location).extensions"
                ))
            }
        }

        for rawName in contribution.filenames ?? [] {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                issues.append(.error("Empty filename entry.", at: "\(location).filenames"))
                continue
            }
            let key = name.lowercased()
            if let owner = seenFileNames[key] {
                issues.append(.error(
                    "File name '\(name)' is already mapped by syntax '\(owner)'.", at: "\(location).filenames"
                ))
            } else {
                seenFileNames[key] = id
            }
            if context.known.fileNames.contains(key) {
                issues.append(.error(
                    "File name '\(name)' conflicts with a built-in language mapping.", at: "\(location).filenames"
                ))
            }
        }

        for alias in contribution.aliases ?? [] {
            let key = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if key.isEmpty {
                issues.append(.error("Empty alias entry.", at: "\(location).aliases"))
            } else if context.known.identifiers.contains(key) {
                issues.append(.warning(
                    "Alias '\(alias)' shadows a built-in language identifier.", at: "\(location).aliases"
                ))
            }
        }

        for pattern in contribution.firstLinePatterns ?? [] {
            do {
                _ = try NSRegularExpression(pattern: pattern)
            } catch {
                issues.append(.error(
                    "Invalid first-line pattern '\(pattern)': \(error.localizedDescription)",
                    at: "\(location).firstLinePatterns"
                ))
            }
        }

        for shebang in contribution.shebangs ?? []
        where shebang.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.error("Empty shebang entry.", at: "\(location).shebangs"))
        }
    }

    // MARK: File helpers

    @discardableResult
    private static func validateFile(
        _ path: String,
        kind: String,
        relativeTo base: URL? = nil,
        required: Bool,
        severity: LanguageExtensionIssue.Severity,
        paths: PackPaths,
        into issues: inout [LanguageExtensionIssue]
    ) -> URL? {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            issues.append(.init(severity: severity, message: "\(kind) path must not be empty.", location: path))
            return nil
        }
        // Containment violations are always errors, regardless of how optional the file is.
        guard let url = resolve(path, relativeTo: base, paths: paths) else {
            issues.append(.error("\(kind) escapes the pack root: \(path)", at: path))
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue
        else {
            issues.append(.init(
                severity: required ? .error : .warning,
                message: "\(kind) not found: \(path)",
                location: path
            ))
            return nil
        }
        guard LanguageExtensionPaths.isContained(url, in: paths.root) else {
            issues.append(.error(
                "\(kind) resolves outside the pack root via a symlink: \(path)", at: path
            ))
            return nil
        }
        return url
    }

    @discardableResult
    private static func validateDirectory(
        _ path: String,
        kind: String,
        paths: PackPaths,
        into issues: inout [LanguageExtensionIssue]
    ) -> URL? {
        guard let url = resolve(path, relativeTo: nil, paths: paths) else {
            issues.append(.error("\(kind) escapes the pack root: \(path)", at: path))
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            issues.append(.error("\(kind) not found: \(path)", at: path))
            return nil
        }
        guard LanguageExtensionPaths.isContained(url, in: paths.root) else {
            issues.append(.error(
                "\(kind) resolves outside the pack root via a symlink: \(path)", at: path
            ))
            return nil
        }
        return url
    }

    /// Resolves a pack-relative path, or an absolute path *inside* the pack (via `base`).
    private static func resolve(_ path: String, relativeTo base: URL?, paths: PackPaths) -> URL? {
        guard let base else { return LanguageExtensionPaths.resolve(path, in: paths.root) }
        // `base` is itself inside the pack root; resolve `path` against it and re-check containment.
        guard !path.hasPrefix("/") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty, !components.contains("..") else { return nil }
        let candidate = base.appendingPathComponent(path).standardizedFileURL
        let rootPath = paths.root.standardizedFileURL.path
        guard candidate.path == rootPath || candidate.path.hasPrefix(rootPath + "/") else { return nil }
        return candidate
    }

    // MARK: Utilities

    /// A file extension without a leading dot, lowercased.
    ///
    /// Shared with the app loader so a pack's extensions are normalized identically wherever they are
    /// compared or indexed.
    public static func normalizeExtension(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasPrefix(".") { value.removeFirst() }
        return value
    }

    private static func isValidLanguageID(_ id: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._+-")
        guard let first = id.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first),
              id.unicodeScalars.allSatisfy(allowed.contains) else {
            return false
        }
        return true
    }

    private static func isValidPackID(_ id: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard let first = id.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first),
              id.unicodeScalars.allSatisfy(allowed.contains),
              !id.contains("..") else {
            return false
        }
        return true
    }

    /// An exported tree-sitter entry point: `tree_sitter_` + identifier characters only.
    private static func isValidGrammarSymbol(_ symbol: String) -> Bool {
        guard symbol.hasPrefix("tree_sitter_") else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        return symbol.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func isValidSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// A human-readable description of a manifest decoding failure.
    public static func describe(_ error: Error) -> String {
        if let decodingError = error as? DecodingError {
            switch decodingError {
            case .keyNotFound(let key, _):
                return "missing key '\(key.stringValue)'"
            case .typeMismatch(_, let context):
                return "type mismatch at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
            case .dataCorrupted(let context):
                return "data corrupted at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
            default:
                return decodingError.localizedDescription
            }
        }
        return error.localizedDescription
    }

    private struct PackPaths {
        let root: URL
    }
}
