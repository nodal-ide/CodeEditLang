import Foundation
import XCTest
@testable import CodeEditLang

final class DeclarativeStubTests: XCTestCase {
    func testBuildsReferenceSheetWithNameRanges() {
        let entries: [LanguageSymbolPack.Entry] = [
            .init(
                name: "route",
                kind: .function,
                namespace: "Illuminate\\Support",
                signature: "function route(string $name): string",
                parameters: ["string $name"],
                documentation: "Generate a URL."
            ),
            .init(
                name: "Router",
                kind: .class,
                namespace: "Illuminate\\Routing"
            )
        ]

        let (text, ranges) = DeclarativeStub.build(entries: entries)

        XCTAssertEqual(ranges.count, entries.count)

        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: ranges[0]), "route")
        XCTAssertEqual(ns.substring(with: ranges[1]), "Router")

        // Each entry occupies its own line.
        XCTAssertEqual(text.split(separator: "\n").count, entries.count)
    }

    func testSymbolsUseStubURLAndRanges() {
        let pack = LanguageSymbolPack(
            language: "php",
            framework: .init(name: "laravel/framework"),
            symbols: [
                .init(name: "collect", kind: .function, namespace: "Illuminate\\Support"),
                .init(name: "Arr", kind: .class, namespace: "Illuminate\\Support")
            ]
        )
        let stubURL = URL(fileURLWithPath: "/tmp/CodeEdit/ExtensionStubs/pack.txt")

        let symbols = DeclarativeStub.symbols(from: pack, stubURL: stubURL)

        XCTAssertEqual(symbols.count, 2)
        XCTAssertTrue(symbols.allSatisfy { $0.fileURL == stubURL })
        XCTAssertEqual(symbols.map(\.name), ["collect", "Arr"])
        XCTAssertEqual(symbols[0].kind, .function)
    }

    func testDecodesPackFromJSON() throws {
        let json = """
        {
          "language": "php",
          "framework": { "name": "laravel/framework", "version": ">=11" },
          "symbols": [
            { "name": "route", "kind": "function", "namespace": "Illuminate\\\\Support",
              "parameters": ["string $name"], "documentation": "Generate a URL." }
          ]
        }
        """
        let pack = try JSONDecoder().decode(LanguageSymbolPack.self, from: Data(json.utf8))
        XCTAssertEqual(pack.language, "php")
        XCTAssertEqual(pack.symbols.count, 1)
        XCTAssertEqual(pack.symbols[0].name, "route")
        XCTAssertEqual(pack.symbols[0].parameters, ["string $name"])
    }
}
