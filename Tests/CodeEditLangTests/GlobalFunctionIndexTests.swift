import Foundation
import XCTest
@testable import CodeEditLang
@testable import CodeEditLangPHP

final class GlobalFunctionIndexTests: XCTestCase {
    func testParserIndexesGlobalFunction() {
        let source = """
        <?php
        function helper_one() { return 1; }
        class Foo { public function bar() {} }
        """
        let info = PHPFileParser.parse(source, fileURL: URL(fileURLWithPath: "/proj/a.php"))
        XCTAssertTrue(
            info.symbols.contains { $0.name == "helper_one" && $0.kind == .function && $0.container == nil },
            "global function should be parsed with no container"
        )
    }

    func testCompletionIncludesIndexedGlobalFunction() {
        let index = SymbolIndex()
        let info = PHPFileParser.parse(
            "<?php\nfunction helper_one() {}",
            fileURL: URL(fileURLWithPath: "/proj/helpers.php")
        )
        index.add(info.symbols)

        let source = "<?php\nhel"
        let items = PHPCompletionEngine.items(
            source: source,
            cursorOffset: (source as NSString).length,
            fileURL: URL(fileURLWithPath: "/proj/app/a.php"),
            index: index,
            stubIndex: nil
        )
        XCTAssertTrue(items.contains { $0.label == "helper_one" }, "indexed global function should complete")
    }

    func testCompletionIncludesGlobalFunctionWhenFileIsNamespaced() {
        let index = SymbolIndex()
        index.add(
            PHPFileParser.parse(
                "<?php\nfunction helper_one() {}",
                fileURL: URL(fileURLWithPath: "/proj/helpers.php")
            ).symbols
        )

        let source = "<?php\nnamespace App;\nhel"
        let items = PHPCompletionEngine.items(
            source: source,
            cursorOffset: (source as NSString).length,
            fileURL: URL(fileURLWithPath: "/proj/app/a.php"),
            index: index,
            stubIndex: nil
        )
        XCTAssertTrue(items.contains { $0.label == "helper_one" }, "global function should complete in namespaced file")
    }

    func testCompletionIncludesBuiltinFunctionFromStubs() {
        let stubIndex = SymbolIndex()
        stubIndex.add(
            PHPFileParser.parse(
                "<?php\nfunction array_map(callable $cb, array $arr): array {}",
                fileURL: URL(fileURLWithPath: "/stubs/array.php")
            ).symbols
        )

        let source = "<?php\narray_ma"
        let items = PHPCompletionEngine.items(
            source: source,
            cursorOffset: (source as NSString).length,
            fileURL: URL(fileURLWithPath: "/proj/a.php"),
            index: SymbolIndex(),
            stubIndex: stubIndex
        )
        XCTAssertTrue(items.contains { $0.label == "array_map" }, "builtin function should complete from stubs")
    }
}
