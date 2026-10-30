import Foundation
import XCTest
@testable import CodeEditLang

final class ThemeDocumentTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ce-theme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testValidDocumentWithoutInterfacePasses() throws {
        let document = makeDocument()
        let result = ThemeDocumentValidator.validate(document: document)
        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testUppercaseHexIsAccepted() {
        let document = makeDocument(color: "#292A30")
        XCTAssertTrue(ThemeDocumentValidator.validate(document: document).isValid)
    }

    func testInvalidHexIsReportedWithItsPath() {
        let document = makeDocument(color: "#29A30")
        let result = ThemeDocumentValidator.validate(document: document)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.location == "editor.text.color" })
    }

    func testInvalidInterfaceColorIsReported() {
        var document = makeDocument()
        document.interface = ThemeDocument.InterfaceColors(accent: "rgb(1, 2, 3)")
        let result = ThemeDocumentValidator.validate(document: document)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.location == "interface.accent" })
    }

    func testInvalidVersionIsOnlyAWarning() {
        var document = makeDocument()
        document.version = "one"
        let result = ThemeDocumentValidator.validate(document: document)
        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.warnings.first?.location, "version")
    }

    func testDecodeWithoutInterfaceAndReencodeRoundTrips() throws {
        var document = makeDocument()
        document.interface = ThemeDocument.InterfaceColors(
            accent: "#4C8DFF",
            sidebarBackground: "#0E1527",
            materials: .solid
        )
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(ThemeDocument.self, from: data)
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(decoded.interface?.materials, .solid)
        XCTAssertNil(decoded.interface?.windowBackground)
    }

    func testFileValidationRejectsOversizedAndUndecodableFiles() throws {
        let oversized = directory.appendingPathComponent("oversized.cetheme")
        try Data(repeating: 0, count: ThemeDocumentValidator.maximumFileSize + 1).write(to: oversized)
        XCTAssertFalse(ThemeDocumentValidator.validate(fileAt: oversized).isValid)

        let broken = directory.appendingPathComponent("broken.cetheme")
        try Data("{".utf8).write(to: broken)
        let result = ThemeDocumentValidator.validate(fileAt: broken)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors[0].message.contains("is invalid"))
    }

    func testPackWithThemesIsNotReportedAsEmpty() throws {
        let pack = try makePack(themes: [("midnight", "themes/midnight.cetheme")])
        let result = LanguageExtensionValidator.validate(packAt: pack)
        XCTAssertTrue(result.isValid)
        XCTAssertFalse(result.warnings.contains { $0.message.contains("contributes nothing") })
    }

    func testDuplicateThemeIDsAreRejected() throws {
        let pack = try makePack(themes: [
            ("midnight", "themes/midnight.cetheme"),
            ("midnight", "themes/midnight-two.cetheme")
        ])
        let result = LanguageExtensionValidator.validate(packAt: pack)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.message.contains("Duplicate theme") })
    }

    func testMissingThemeFileIsRejected() throws {
        let pack = try makePack(themes: [("ghost", "themes/missing.cetheme")], writeFiles: false)
        let result = LanguageExtensionValidator.validate(packAt: pack)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { $0.message.contains("Theme file not found") })
    }

    func testWorkspacePackThemesWarnAboutScope() throws {
        let pack = try makePack(themes: [("midnight", "themes/midnight.cetheme")])
        let result = LanguageExtensionValidator.validate(
            packAt: pack,
            context: .init(scope: .workspace)
        )
        XCTAssertTrue(result.warnings.contains { $0.message.contains("Workspace-scoped") })
    }

    func testContributionWithoutCapabilityWarns() throws {
        let pack = try makePack(themes: [("midnight", "themes/midnight.cetheme")], capabilities: [])
        let result = LanguageExtensionValidator.validate(packAt: pack)
        XCTAssertTrue(result.warnings.contains { $0.message.contains("capabilities") })
    }

    private func makeDocument(color: String = "#FFFFFF") -> ThemeDocument {
        func attributes(_ value: String) -> ThemeDocument.Attributes {
            ThemeDocument.Attributes(color: value)
        }
        let editor = ThemeDocument.EditorColors(
            text: attributes(color),
            insertionPoint: attributes(color),
            invisibles: attributes(color),
            background: attributes(color),
            lineHighlight: attributes(color),
            selection: attributes(color),
            keywords: attributes(color),
            commands: attributes(color),
            types: attributes(color),
            attributes: attributes(color),
            variables: attributes(color),
            values: attributes(color),
            numbers: attributes(color),
            strings: attributes(color),
            characters: attributes(color),
            comments: attributes(color)
        )
        let terminal = ThemeDocument.TerminalColors(
            text: attributes(color),
            boldText: attributes(color),
            cursor: attributes(color),
            background: attributes(color),
            selection: attributes(color),
            black: attributes(color),
            red: attributes(color),
            green: attributes(color),
            yellow: attributes(color),
            blue: attributes(color),
            magenta: attributes(color),
            cyan: attributes(color),
            white: attributes(color),
            brightBlack: attributes(color),
            brightRed: attributes(color),
            brightGreen: attributes(color),
            brightYellow: attributes(color),
            brightBlue: attributes(color),
            brightMagenta: attributes(color),
            brightCyan: attributes(color),
            brightWhite: attributes(color)
        )
        return ThemeDocument(
            name: "test",
            displayName: "Test",
            appearance: .dark,
            editor: editor,
            terminal: terminal
        )
    }

    private func makePack(
        themes: [(String, String)],
        capabilities: [String]? = ["themes"],
        writeFiles: Bool = true
    ) throws -> URL {
        let pack = directory.appendingPathComponent("pack", isDirectory: true)
        let themesDirectory = pack.appendingPathComponent("themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
        let document = makeDocument()
        let data = try JSONEncoder().encode(document)
        if writeFiles {
            for (_, path) in themes where path.hasPrefix("themes/") {
                try data.write(to: pack.appendingPathComponent(path))
            }
        }
        let manifest = LanguageExtensionManifest(
            id: "com.example.themes",
            name: "Example Themes",
            version: "1.0.0",
            type: "theme",
            capabilities: capabilities,
            contributes: .init(themes: themes.map { .init(id: $0.0, path: $0.1) })
        )
        try JSONEncoder().encode(manifest).write(to: pack.appendingPathComponent("extension.json"))
        return pack
    }
}
