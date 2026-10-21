import Foundation
import XCTest
@testable import CodeEditLangPHP

final class PHPDocParserTests: XCTestCase {
    func testParsesSummaryAndMultilineDescription() throws {
        let block = try XCTUnwrap(PHPDocParser.parse("""
        Charges a card.

        Uses the configured provider and returns whether the charge succeeded.
        The call is idempotent.
        """))

        XCTAssertEqual(block.summary, "Charges a card.")
        XCTAssertEqual(
            block.description,
            "Uses the configured provider and returns whether the charge succeeded. "
                + "The call is idempotent."
        )
        XCTAssertTrue(block.tags.isEmpty)
    }

    func testParsesParametersReturnsThrowsAndMetadata() throws {
        let block = try XCTUnwrap(PHPDocParser.parse("""
        Charges a card.

        @param array<string, mixed> $options Provider overrides.
        @param int $amount
            Amount in cents.
        @return bool
        @throws \\RuntimeException When the provider fails.
        @since 1.2.0
        """))

        XCTAssertEqual(block.parameters.count, 2)
        XCTAssertEqual(block.parameters[0].type, "array<string, mixed>")
        XCTAssertEqual(block.parameters[0].variable, "$options")
        XCTAssertEqual(block.parameters[0].description, "Provider overrides.")
        XCTAssertEqual(block.parameters[1].type, "int")
        XCTAssertEqual(block.parameters[1].variable, "$amount")
        XCTAssertEqual(block.parameters[1].description, "Amount in cents.")

        XCTAssertEqual(block.returnTag?.type, "bool")
        XCTAssertEqual(block.throwsTags.first?.type, "\\RuntimeException")
        XCTAssertEqual(block.throwsTags.first?.description, "When the provider fails.")
        XCTAssertEqual(block.tags(named: "since").first?.content, "1.2.0")
    }

    func testParsesUntypedParameter() throws {
        let block = try XCTUnwrap(PHPDocParser.parse("@param $value Raw value."))
        let parameter = try XCTUnwrap(block.parameters.first)

        XCTAssertNil(parameter.type)
        XCTAssertEqual(parameter.variable, "$value")
        XCTAssertEqual(parameter.description, "Raw value.")
    }

    func testNormalizesByReferenceAndVariadicParameters() throws {
        let block = try XCTUnwrap(PHPDocParser.parse("""
        @param string &$reference Reference.
        @param int ...$values Values.
        @param array &...$items Items.
        """))

        XCTAssertEqual(block.parameters.map(\.variable), ["$reference", "$values", "$items"])
        XCTAssertEqual(block.parameters.map(\.type), ["string", "int", "array"])
    }

    func testParsesCallableTypeWithReturnType() throws {
        let block = try XCTUnwrap(PHPDocParser.parse("@param callable(int): void $callback Callback."))
        let parameter = try XCTUnwrap(block.parameters.first)

        XCTAssertEqual(parameter.type, "callable(int): void")
        XCTAssertEqual(parameter.variable, "$callback")
        XCTAssertEqual(parameter.description, "Callback.")
    }

    func testPrefixedTagsAreExposedAsParametersAndReturnValues() throws {
        let block = try XCTUnwrap(PHPDocParser.parse("""
        @psalm-param string $name Name.
        @phpstan-return $this
        """))

        XCTAssertEqual(block.parameters.first?.variable, "$name")
        XCTAssertEqual(block.returnTag?.type, "$this")
    }

    func testAnnotationsInExamplesRemainExampleContent() throws {
        let block = try XCTUnwrap(PHPDocParser.parse("""
        @example
            #[Entity]
            @ORM\\Column(type="string")
            public string $name;
        """))

        let example = try XCTUnwrap(block.tags(named: "example").first)
        XCTAssertTrue(example.content.contains("@ORM\\Column(type=\"string\")"))
        XCTAssertTrue(example.content.contains("#[Entity]"))
    }

    func testPreservesMultilineExampleContent() throws {
        let block = try XCTUnwrap(PHPDocParser.parse("""
        @example
            $payment->charge(100);
            $payment->charge(200);
        """))

        let example = try XCTUnwrap(block.tags(named: "example").first)
        XCTAssertEqual(example.content, """
            $payment->charge(100);
            $payment->charge(200);
        """)
    }

    func testParsesRawCommentMarkers() throws {
        let block = try XCTUnwrap(PHPDocParser.parse("""
        /**
         * Summary.
         *
         * @param string $name Name.
         */
        """))

        XCTAssertEqual(block.summary, "Summary.")
        XCTAssertEqual(block.parameters.first?.type, "string")
        XCTAssertEqual(block.parameters.first?.variable, "$name")
    }

    func testRawFallbackIsRetained() throws {
        let source = "Summary.\n\n@custom keep: this"
        let block = try XCTUnwrap(PHPDocParser.parse(source))

        XCTAssertEqual(block.raw, source)
        XCTAssertEqual(block.tags(named: "custom").first?.content, "keep: this")
    }

    func testEmptyDocumentationReturnsNil() {
        XCTAssertNil(PHPDocParser.parse(""))
        XCTAssertNil(PHPDocParser.parse(" \n\n "))
    }

    func testFileParserPreservesDocblockIndentation() throws {
        let source = """
        <?php
        class Foo {
            /**
             * Summary.
             *
             * @example
             *     $value = 1;
             */
            public function example(): void {}
        }
        """
        let info = PHPFileParser.parse(source, fileURL: URL(fileURLWithPath: "/p/Foo.php"))
        let method = try XCTUnwrap(info.symbols.first { $0.name == "example" })

        XCTAssertEqual(method.documentation?.contains("\n    $value = 1;"), true)
    }
}
