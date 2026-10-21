import Foundation
import XCTest
import CodeEditLang
import CodeEditLangPHP
import CodeEditSourceEditor

final class PHPHoverMapperTests: XCTestCase {
    func testMapsDocumentedFunctionToStructuredHover() throws {
        let symbol = makeSymbol(
            name: "charge",
            kind: .function,
            namespace: "App\\Payments",
            parameters: ["array<string, mixed> $options", "int $amount"],
            documentation: """
            Charges a card.

            Uses the configured provider.

            @param array<string, mixed> $options Provider overrides.
            @param int $amount Amount in cents.
            @return bool Whether the charge succeeded.
            @throws \\RuntimeException When the provider fails.
            @deprecated Use chargeAsync instead.
            @example
                $payment->charge(100);
            @see https://example.com/docs
            @since 1.2.0
            @author Jane Doe
            @custom keep: this
            """
        )
        let document = try XCTUnwrap(mappedDocument(for: symbol))

        XCTAssertEqual(document.header?.title, "charge")
        XCTAssertEqual(document.header?.subtitle, "App\\Payments")
        XCTAssertEqual(document.header?.systemImageName, "function")
        XCTAssertEqual(document.header?.tone, .callable)
        XCTAssertEqual(document.header?.badges.first?.text, "deprecated")

        XCTAssertEqual(document.signatures.first?.text, "function charge(array<string, mixed> $options, int $amount)")
        XCTAssertEqual(document.signatures.first?.language, "php")
        XCTAssertEqual(document.markdownBlocks, ["Charges a card.\n\nUses the configured provider."])

        let parameters = try XCTUnwrap(document.definitionList(named: "Parameters"))
        XCTAssertEqual(parameters.items.count, 2)
        XCTAssertEqual(parameters.items[0].term, "$options")
        XCTAssertEqual(parameters.items[0].type, "array<string, mixed>")
        XCTAssertEqual(parameters.items[0].description, "Provider overrides.")
        XCTAssertEqual(parameters.items[1].term, "$amount")
        XCTAssertEqual(parameters.items[1].type, "int")
        XCTAssertEqual(parameters.items[1].description, "Amount in cents.")

        let returns = try XCTUnwrap(document.definitionList(named: "Returns"))
        XCTAssertEqual(returns.items.first?.type, "bool")
        XCTAssertEqual(returns.items.first?.description, "Whether the charge succeeded.")
        XCTAssertEqual(returns.items.first?.tone, .accent)

        let throwsList = try XCTUnwrap(document.definitionList(named: "Throws"))
        XCTAssertEqual(throwsList.items.first?.type, "\\RuntimeException")
        XCTAssertEqual(throwsList.items.first?.tone, .warning)

        XCTAssertEqual(document.notices.first?.title, "Deprecated")
        XCTAssertEqual(document.notices.first?.message, "Use chargeAsync instead.")
        XCTAssertEqual(document.notices.first?.tone, .warning)

        XCTAssertEqual(document.codeBlocks.first?.language, "php")
        XCTAssertEqual(document.codeBlocks.first?.text, "    $payment->charge(100);")

        XCTAssertEqual(document.links.first?.title, "https://example.com/docs")
        XCTAssertEqual(document.links.first?.url?.absoluteString, "https://example.com/docs")

        XCTAssertEqual(document.metadata.first { $0.label == "Since" }?.value, "1.2.0")
        XCTAssertEqual(document.metadata.first { $0.label == "Author" }?.value, "Jane Doe")
        XCTAssertEqual(document.metadata.first { $0.label == "@custom" }?.value, "keep: this")
        XCTAssertTrue(document.plainText.contains("charge(array<string, mixed> $options"))
    }

    func testMapsParsedPHPMethod() throws {
        let source = """
        <?php
        namespace App;

        class Payment {
            /**
             * Charges a card.
             *
             * @param int $amount Amount in cents.
             * @return bool
             */
            public function charge(int $amount): bool {}
        }
        """
        let info = PHPFileParser.parse(source, fileURL: URL(fileURLWithPath: "/tmp/Payment.php"))
        let symbol = try XCTUnwrap(info.symbols.first { $0.name == "charge" })
        let document = try XCTUnwrap(mappedDocument(for: symbol))

        XCTAssertEqual(document.header?.title, "charge")
        XCTAssertEqual(document.header?.subtitle, "App\\Payment")
        XCTAssertEqual(document.signatures.first?.text, "method charge(int $amount)")
        XCTAssertEqual(document.markdownBlocks.first, "Charges a card.")
        XCTAssertEqual(document.definitionList(named: "Parameters")?.items.first?.type, "int")
        XCTAssertEqual(document.definitionList(named: "Returns")?.items.first?.type, "bool")
    }

    func testMapsUndocumentedPropertyWithoutDocumentationBlocks() throws {
        let symbol = makeSymbol(
            name: "count",
            kind: .property,
            namespace: "App",
            container: "App\\Counter",
            signature: "int"
        )
        let document = try XCTUnwrap(mappedDocument(for: symbol))

        XCTAssertEqual(document.header?.title, "$count")
        XCTAssertEqual(document.header?.subtitle, "App\\Counter")
        XCTAssertEqual(document.header?.tone, .value)
        XCTAssertEqual(document.header?.systemImageName, "square.on.square")
        XCTAssertEqual(document.signatures.first?.text, "int $count")
        XCTAssertTrue(document.markdownBlocks.isEmpty)
        XCTAssertTrue(document.definitionLists.isEmpty)
    }

    func testMapsClassWithNamespace() throws {
        let symbol = makeSymbol(name: "Counter", kind: .class, namespace: "App")
        let document = try XCTUnwrap(mappedDocument(for: symbol))

        XCTAssertEqual(document.header?.title, "Counter")
        XCTAssertEqual(document.header?.subtitle, "App")
        XCTAssertEqual(document.header?.tone, .type)
        XCTAssertEqual(document.header?.systemImageName, "cube")
        XCTAssertEqual(document.signatures.first?.text, "class App\\Counter")
    }

    func testAppendsUndocumentedSignatureParameters() throws {
        let symbol = makeSymbol(
            name: "greet",
            kind: .function,
            parameters: ["string $name", "int $age"],
            documentation: "@param string $name Name."
        )
        let document = try XCTUnwrap(mappedDocument(for: symbol))
        let parameters = try XCTUnwrap(document.definitionList(named: "Parameters"))

        XCTAssertEqual(parameters.items.count, 2)
        XCTAssertEqual(parameters.items[0].term, "$name")
        XCTAssertEqual(parameters.items[0].description, "Name.")
        XCTAssertEqual(parameters.items[1].term, "$age")
        XCTAssertEqual(parameters.items[1].type, "int")
        XCTAssertNil(parameters.items[1].description)
    }

    func testUsesPrefixedParamAndReturnTags() throws {
        let symbol = makeSymbol(
            name: "name",
            kind: .function,
            documentation: """
            @psalm-param string $name Name.
            @phpstan-return $this
            """
        )
        let document = try XCTUnwrap(mappedDocument(for: symbol))

        XCTAssertEqual(document.definitionList(named: "Parameters")?.items.first?.type, "string")
        XCTAssertEqual(document.definitionList(named: "Returns")?.items.first?.type, "$this")
    }

    func testInheritDocAddsNoticeAndRemovesInlineMarker() throws {
        let symbol = makeSymbol(
            name: "save",
            kind: .method,
            container: "App\\Model",
            documentation: """
            Saves {@inheritdoc}.

            @inheritdoc
            """
        )
        let document = try XCTUnwrap(mappedDocument(for: symbol))

        XCTAssertEqual(document.notices.first?.title, "Inherited documentation")
        XCTAssertEqual(document.notices.first?.tone, .info)
        XCTAssertEqual(document.markdownBlocks.first, "Saves.")
        XCTAssertFalse(document.metadata.contains { $0.label == "@inheritdoc" })
    }

    func testDeprecatedWithoutDescriptionUsesDefaultMessage() throws {
        let symbol = makeSymbol(
            name: "old",
            kind: .function,
            documentation: "@deprecated"
        )
        let document = try XCTUnwrap(mappedDocument(for: symbol))

        XCTAssertEqual(document.notices.first?.title, "Deprecated")
        XCTAssertEqual(document.notices.first?.message, "This symbol is deprecated.")
    }

    func testSplitsExampleDescriptionFromIndentedCode() throws {
        let symbol = makeSymbol(
            name: "charge",
            kind: .function,
            documentation: """
            @example Charge a card.
                $payment->charge(100);
            """
        )
        let document = try XCTUnwrap(mappedDocument(for: symbol))

        XCTAssertEqual(document.markdownBlocks.last, "Charge a card.")
        XCTAssertEqual(document.codeBlocks.first?.text, "    $payment->charge(100);")
    }

    func testFencedExampleStaysMarkdown() throws {
        let symbol = makeSymbol(
            name: "charge",
            kind: .function,
            documentation: """
            @example
            ```php
            echo "charged";
            ```
            """
        )
        let document = try XCTUnwrap(mappedDocument(for: symbol))

        XCTAssertEqual(document.markdownBlocks.count, 1)
        XCTAssertTrue(document.markdownBlocks[0].contains("```php"))
        XCTAssertTrue(document.codeBlocks.isEmpty)
    }

    func testMapsVarTagForProperty() throws {
        let symbol = makeSymbol(
            name: "items",
            kind: .property,
            container: "App\\Bag",
            documentation: "@var array<int, string> Stored items."
        )
        let document = try XCTUnwrap(mappedDocument(for: symbol))
        let typeList = try XCTUnwrap(document.definitionList(named: "Type"))

        XCTAssertEqual(typeList.items.first?.type, "array<int, string>")
        XCTAssertEqual(typeList.items.first?.description, "Stored items.")
        XCTAssertEqual(typeList.items.first?.tone, .type)
    }

    func testConvertsInlineDocumentationLinks() throws {
        let symbol = makeSymbol(
            name: "charge",
            kind: .function,
            documentation: "See {@link https://example.com Docs} for details."
        )
        let document = try XCTUnwrap(mappedDocument(for: symbol))

        XCTAssertEqual(document.markdownBlocks.first, "See [Docs](https://example.com) for details.")
    }

    func testKeepsUnsafeInlineLinksLiteral() throws {
        let symbol = makeSymbol(
            name: "charge",
            kind: .function,
            documentation: "See {@link javascript:alert(1) Unsafe}."
        )
        let document = try XCTUnwrap(mappedDocument(for: symbol))

        XCTAssertEqual(document.markdownBlocks.first, "See {@link javascript:alert(1) Unsafe}.")
    }

    private func makeSymbol(
        name: String,
        kind: SymbolKind,
        namespace: String? = nil,
        container: String? = nil,
        signature: String? = nil,
        parameters: [String] = [],
        documentation: String? = nil,
        visibility: String? = nil
    ) -> SymbolInfo {
        SymbolInfo(
            name: name,
            kind: kind,
            namespace: namespace,
            container: container,
            fileURL: URL(fileURLWithPath: "/tmp/HoverFixture.php"),
            nameRange: NSRange(location: 0, length: name.utf16.count),
            fullRange: NSRange(location: 0, length: 1),
            signature: signature,
            parameters: parameters,
            documentation: documentation,
            visibility: visibility
        )
    }

    private func mappedDocument(
        for symbol: SymbolInfo,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> HoverDocument? {
        guard case .document(let document) = PHPHoverMapper.content(for: symbol) else {
            XCTFail("Expected structured hover content", file: file, line: line)
            return nil
        }
        return document
    }
}

private extension HoverDocument {
    var markdownBlocks: [String] {
        blocks.compactMap { block in
            guard case .markdown(let text) = block else { return nil }
            return text
        }
    }

    var signatures: [HoverCode] {
        blocks.compactMap { block in
            guard case .signature(let code) = block else { return nil }
            return code
        }
    }

    var codeBlocks: [HoverCode] {
        blocks.compactMap { block in
            guard case .code(let code) = block else { return nil }
            return code
        }
    }

    var definitionLists: [HoverDefinitionList] {
        blocks.compactMap { block in
            guard case .definitionList(let list) = block else { return nil }
            return list
        }
    }

    var notices: [HoverNotice] {
        blocks.compactMap { block in
            guard case .notice(let notice) = block else { return nil }
            return notice
        }
    }

    var links: [HoverLink] {
        blocks.flatMap { block -> [HoverLink] in
            guard case .links(let links) = block else { return [] }
            return links
        }
    }

    var metadata: [HoverMetadataItem] {
        blocks.flatMap { block -> [HoverMetadataItem] in
            guard case .metadata(let items) = block else { return [] }
            return items
        }
    }

    func definitionList(named title: String) -> HoverDefinitionList? {
        definitionLists.first { $0.title == title }
    }
}
