import Foundation
import XCTest
@testable import CodeEditLang

final class LanguageExtensionValidatorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Helpers

    @discardableResult
    private func write(_ contents: String, to relativePath: String) throws -> URL {
        let url = directory.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func manifest(
        id: String = "com.example.civet",
        name: String = "Civet",
        schemaVersion: Int? = 2,
        engines: LanguageExtensionManifest.Engines? = nil,
        syntax: [LanguageExtensionManifest.Contributes.Syntax]
    ) -> LanguageExtensionManifest {
        LanguageExtensionManifest(
            schemaVersion: schemaVersion,
            id: id,
            name: name,
            languages: syntax.map(\.id),
            engines: engines,
            capabilities: ["syntax"],
            contributes: .init(syntax: syntax)
        )
    }

    private func queryOnlySyntax(
        id: String = "civet",
        extensions: [String] = ["civet"],
        grammarName: String = "html",
        highlights: String = "queries/highlights.scm",
        firstLinePatterns: [String]? = nil
    ) -> LanguageExtensionManifest.Contributes.Syntax {
        .init(
            id: id,
            displayName: "Civet",
            extensions: extensions,
            firstLinePatterns: firstLinePatterns,
            grammar: .init(kind: "builtin", name: grammarName),
            queries: .init(highlights: highlights)
        )
    }

    private func context(
        identifiers: Set<String> = ["html"],
        extensions: Set<String> = [],
        fileNames: Set<String> = [],
        allowsNativeGrammars: Bool = false,
        scope: LanguageExtensionPackScope = .global,
        hostVersion: String? = nil
    ) -> LanguageExtensionValidationContext {
        .init(
            known: .init(identifiers: identifiers, extensions: extensions, fileNames: fileNames),
            allowsNativeGrammars: allowsNativeGrammars,
            scope: scope,
            hostVersion: hostVersion
        )
    }

    private func nativeSyntax(
        id: String = "svelte",
        path: String = "grammars/libtree-sitter-svelte.dylib",
        symbol: String = "tree_sitter_svelte",
        sha256: String? = nil
    ) -> LanguageExtensionManifest.Contributes.Syntax {
        .init(
            id: id,
            displayName: "Svelte",
            extensions: ["svelte"],
            grammar: .init(kind: "native", path: path, symbol: symbol, sha256: sha256),
            queries: .init(highlights: "queries/highlights.scm")
        )
    }

    // MARK: Tests

    func testValidQueryOnlyPackPasses() throws {
        try write("(comment) @comment\n", to: "queries/highlights.scm")
        let result = LanguageExtensionValidator.validate(
            manifest: manifest(syntax: [queryOnlySyntax()]), root: directory, context: context()
        )
        XCTAssertTrue(result.isValid, "Unexpected errors: \(result.errors.map(\.description))")
    }

    func testQueryOnlyPackDoesNotRequireTopLevelLanguages() throws {
        try write("(comment) @comment\n", to: "queries/highlights.scm")
        let manifest = LanguageExtensionManifest(
            schemaVersion: 2,
            id: "com.example.syntax-only",
            name: "Syntax Only",
            capabilities: ["syntax"],
            contributes: .init(syntax: [queryOnlySyntax()])
        )
        let result = LanguageExtensionValidator.validate(manifest: manifest, root: directory, context: context())
        XCTAssertTrue(result.isValid, "Unexpected errors: \(result.errors.map(\.description))")
        XCTAssertFalse(result.warnings.contains { $0.message.contains("No `languages` declared") })
    }

    func testMissingHighlightsQueryIsAnError() throws {
        let result = LanguageExtensionValidator.validate(
            manifest: manifest(syntax: [queryOnlySyntax()]), root: directory, context: context()
        )
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.message.contains("Highlights query not found") })
    }

    func testUnsafePackIDIsAnError() throws {
        let result = LanguageExtensionValidator.validate(
            manifest: manifest(id: "../escape", name: "Escape", syntax: []),
            root: directory
        )
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.message.contains("`id` must contain only") })
    }

    func testOversizedQueryIsAnError() throws {
        let url = try write("", to: "queries/highlights.scm")
        try Data(repeating: 0x61, count: LanguageExtensionValidator.maximumQueryFileSize + 1)
            .write(to: url)

        let result = LanguageExtensionValidator.validate(
            manifest: manifest(syntax: [queryOnlySyntax()]), root: directory, context: context()
        )
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.message.contains("is too large") })
    }

    func testPathEscapeIsRejected() throws {
        // The file exists *outside* the pack root — containment must still reject it.
        try "(comment) @comment\n".write(
            to: directory.deletingLastPathComponent().appendingPathComponent("outside.scm"),
            atomically: true, encoding: .utf8
        )
        defer {
            try? FileManager.default.removeItem(
                at: directory.deletingLastPathComponent().appendingPathComponent("outside.scm")
            )
        }
        let result = LanguageExtensionValidator.validate(
            manifest: manifest(syntax: [queryOnlySyntax(highlights: "../outside.scm")]),
            root: directory,
            context: context()
        )
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.message.contains("escapes the pack root") })
    }

    func testUnknownBuiltInGrammarIsRejectedWhenCatalogIsKnown() throws {
        try write("(comment) @comment\n", to: "queries/highlights.scm")
        let result = LanguageExtensionValidator.validate(
            manifest: manifest(syntax: [queryOnlySyntax(grammarName: "not-a-grammar")]),
            root: directory,
            context: context(identifiers: ["html"])
        )
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.message.contains("Unknown built-in grammar") })
    }

    func testBuiltInGrammarCheckIsSkippedWithoutCatalogKnowledge() throws {
        try write("(comment) @comment\n", to: "queries/highlights.scm")
        // The CLI has no grammar knowledge, so it must not report an unknown grammar.
        let result = LanguageExtensionValidator.validate(
            manifest: manifest(syntax: [queryOnlySyntax(grammarName: "whatever")]),
            root: directory,
            context: context(identifiers: [])
        )
        XCTAssertTrue(result.isValid, "Unexpected errors: \(result.errors.map(\.description))")
    }

    func testCollidingWithBuiltInIdentifierIsAnError() throws {
        try write("(comment) @comment\n", to: "queries/highlights.scm")
        let result = LanguageExtensionValidator.validate(
            manifest: manifest(syntax: [queryOnlySyntax(id: "html")]),
            root: directory,
            context: context(identifiers: ["html"])
        )
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.message.contains("collides with a built-in language id") })
    }

    func testDuplicateSyntaxIDIsAnError() throws {
        try write("(comment) @comment\n", to: "queries/highlights.scm")
        try write("(comment) @comment\n", to: "queries/highlights2.scm")
        let syntax = [
            queryOnlySyntax(),
            queryOnlySyntax(extensions: ["civet2"], highlights: "queries/highlights2.scm")
        ]
        let result = LanguageExtensionValidator.validate(
            manifest: manifest(syntax: syntax), root: directory, context: context()
        )
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.message.contains("Duplicate syntax `id`") })
    }

    func testExtensionConflictWithBuiltInIsAnError() throws {
        try write("(comment) @comment\n", to: "queries/highlights.scm")
        let result = LanguageExtensionValidator.validate(
            manifest: manifest(syntax: [queryOnlySyntax()]),
            root: directory,
            context: context(identifiers: ["html"], extensions: ["civet"])
        )
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.message.contains("conflicts with a built-in language mapping") })
    }

    func testNativeGrammarIsRejectedUntilNativePhase() throws {
        try write("(comment) @comment\n", to: "queries/highlights.scm")
        let syntax = LanguageExtensionManifest.Contributes.Syntax(
            id: "svelte",
            grammar: .init(kind: "native", path: "grammars/libtree-sitter-svelte.dylib", symbol: "tree_sitter_svelte"),
            queries: .init(highlights: "queries/highlights.scm")
        )
        let result = LanguageExtensionValidator.validate(
            manifest: manifest(syntax: [syntax]), root: directory, context: context()
        )
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.message.contains("Native grammar packs are not supported") })
    }

    func testNativeGrammarPassesWhenAllowedGlobally() throws {
        try write("(comment) @comment\n", to: "queries/highlights.scm")
        try write("", to: "grammars/libtree-sitter-svelte.dylib")
        let result = LanguageExtensionValidator.validate(
            manifest: manifest(syntax: [nativeSyntax()]),
            root: directory,
            context: context(allowsNativeGrammars: true)
        )
        XCTAssertTrue(result.isValid, "Unexpected errors: \(result.errors.map(\.description))")
    }

    func testNativeGrammarIsRejectedInWorkspacePack() throws {
        try write("(comment) @comment\n", to: "queries/highlights.scm")
        try write("", to: "grammars/libtree-sitter-svelte.dylib")
        let result = LanguageExtensionValidator.validate(
            manifest: manifest(syntax: [nativeSyntax()]),
            root: directory,
            context: context(allowsNativeGrammars: true, scope: .workspace)
        )
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.message.contains("globally installed extensions") })
    }

    func testNativeGrammarRejectsNonDylibPath() throws {
        try write("(comment) @comment\n", to: "queries/highlights.scm")
        try write("", to: "grammars/libtree-sitter-svelte.so")
        let result = LanguageExtensionValidator.validate(
            manifest: manifest(syntax: [nativeSyntax(path: "grammars/libtree-sitter-svelte.so")]),
            root: directory,
            context: context(allowsNativeGrammars: true)
        )
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.message.contains("must be a `.dylib`") })
    }

    func testNativeGrammarRejectsInvalidSymbol() throws {
        try write("(comment) @comment\n", to: "queries/highlights.scm")
        try write("", to: "grammars/libtree-sitter-svelte.dylib")
        let result = LanguageExtensionValidator.validate(
            manifest: manifest(syntax: [nativeSyntax(symbol: "svelte_grammar")]),
            root: directory,
            context: context(allowsNativeGrammars: true)
        )
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.message.contains("exported `tree_sitter_*` symbol") })
    }

    func testNativeGrammarRejectsMalformedSHA256() throws {
        try write("(comment) @comment\n", to: "queries/highlights.scm")
        try write("", to: "grammars/libtree-sitter-svelte.dylib")
        let result = LanguageExtensionValidator.validate(
            manifest: manifest(syntax: [nativeSyntax(sha256: "not-a-hash")]),
            root: directory,
            context: context(allowsNativeGrammars: true)
        )
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.message.contains("64 lowercase hex") })
    }

    func testCommentBlockMustBeAPair() throws {
        try write("(comment) @comment\n", to: "queries/highlights.scm")
        let syntax = LanguageExtensionManifest.Contributes.Syntax(
            id: "civet",
            displayName: "Civet",
            extensions: ["civet"],
            grammar: .init(kind: "builtin", name: "html"),
            queries: .init(highlights: "queries/highlights.scm"),
            comments: .init(line: "", block: ["<!--"])
        )
        let result = LanguageExtensionValidator.validate(
            manifest: manifest(syntax: [syntax]), root: directory, context: context()
        )
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.message.contains("Comment `block` must be a pair") })
    }

    func testNativeGrammarRejectsMissingFile() throws {
        try write("(comment) @comment\n", to: "queries/highlights.scm")
        let result = LanguageExtensionValidator.validate(
            manifest: manifest(syntax: [nativeSyntax()]),
            root: directory,
            context: context(allowsNativeGrammars: true)
        )
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.message.contains("Native grammar not found") })
    }

    func testCompatibleEngineRequirementPasses() throws {
        let result = LanguageExtensionValidator.validate(
            manifest: manifest(engines: .init(codeedit: ">=0.18.0"), syntax: []),
            root: directory,
            context: context(hostVersion: "0.18.0")
        )
        XCTAssertTrue(result.isValid, "Unexpected errors: \(result.errors.map(\.description))")
    }

    func testIncompatibleEngineRequirementIsAnError() throws {
        let result = LanguageExtensionValidator.validate(
            manifest: manifest(engines: .init(codeedit: "^0.18.0"), syntax: []),
            root: directory,
            context: context(hostVersion: "0.17.9")
        )
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.message.contains("Requires CodeEdit ^0.18.0") })
    }

    func testInvalidEngineRequirementIsAWarning() throws {
        let result = LanguageExtensionValidator.validate(
            manifest: manifest(engines: .init(codeedit: "soon"), syntax: []),
            root: directory,
            context: context(hostVersion: "0.18.0")
        )
        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.warnings.contains { $0.message.contains("not a supported version range") })
    }

    func testUnsupportedSchemaVersionIsAnError() throws {
        let result = LanguageExtensionValidator.validate(
            manifest: manifest(schemaVersion: 3, syntax: []), root: directory, context: context()
        )
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.message.contains("Unsupported schemaVersion") })
    }

    func testInvalidFirstLinePatternIsAnError() throws {
        try write("(comment) @comment\n", to: "queries/highlights.scm")
        let result = LanguageExtensionValidator.validate(
            manifest: manifest(syntax: [queryOnlySyntax(firstLinePatterns: ["(unclosed"])]),
            root: directory,
            context: context()
        )
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.message.contains("Invalid first-line pattern") })
    }

    func testValidatePackAtMissingManifest() {
        let result = LanguageExtensionValidator.validate(packAt: directory)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.message.contains("No extension.json found") })
    }

    func testValidatePackAtReadsAndValidatesManifest() throws {
        try write("(comment) @comment\n", to: "queries/highlights.scm")
        let data = try JSONEncoder().encode(manifest(syntax: [queryOnlySyntax()]))
        try data.write(to: directory.appendingPathComponent("extension.json"))
        let result = LanguageExtensionValidator.validate(
            packAt: directory, context: context()
        )
        XCTAssertTrue(result.isValid, "Unexpected errors: \(result.errors.map(\.description))")
    }

    // MARK: Schema sync

    /// Guards against the published schema file and the canonical constant drifting apart.
    func testPublishedSchemaMatchesCanonicalConstant() throws {
        let repoRoot = try XCTUnwrap(Self.findPackageRoot(), "Could not locate the CodeEditLang package root.")
        let publishedURL = repoRoot.appendingPathComponent("Schema/language-extension.schema.json")
        let published = try JSONSerialization.jsonObject(
            with: Data(contentsOf: publishedURL)
        )
        let canonical = try JSONSerialization.jsonObject(
            with: Data(LanguageExtensionSchema.json.utf8)
        )
        XCTAssertEqual(
            NSDictionary(dictionary: published as? [String: Any] ?? [:]),
            NSDictionary(dictionary: canonical as? [String: Any] ?? [:])
        )
    }

    private static func findPackageRoot() -> URL? {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path),
               FileManager.default.fileExists(
                   atPath: url.appendingPathComponent("Schema/language-extension.schema.json").path
               ) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return nil
    }
}
