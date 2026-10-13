import Foundation
import XCTest
@testable import CodeEditLang
@testable import CodeEditLangPHP

final class PHPCodeModelTests: XCTestCase {
    func testParsesNamespaceClassFunctionAndAliases() {
        let source = """
        <?php

        namespace App\\Services;

        use App\\Models\\User;
        use App\\Models\\Order as Invoice;

        class PaymentService {
            public function charge(User $user): void {}
        }

        function helper(): string {
            return 'ok';
        }
        """
        let url = URL(fileURLWithPath: "/project/src/Services/PaymentService.php")
        let parsed = PHPFileParser.parse(source, fileURL: url)

        XCTAssertEqual(parsed.namespace, "App\\Services")
        XCTAssertEqual(parsed.aliases["User"], "App\\Models\\User")
        XCTAssertEqual(parsed.aliases["Invoice"], "App\\Models\\Order")
        XCTAssertEqual(parsed.errorCount, 0)

        let classes = parsed.symbols.filter { $0.kind == .class }
        XCTAssertEqual(classes.count, 1)
        XCTAssertEqual(classes[0].name, "PaymentService")
        XCTAssertEqual(classes[0].namespace, "App\\Services")
        XCTAssertEqual(classes[0].fullyQualifiedName, "App\\Services\\PaymentService")
        XCTAssertEqual(classes[0].fileURL, url)

        let functions = parsed.symbols.filter { $0.kind == .function }
        XCTAssertEqual(functions.map(\.name), ["helper"])
    }

    func testResolverUsesAlias() {
        let symbols = [
            makeSymbol("User", namespace: "App\\Models", kind: .class),
            makeSymbol("Order", namespace: "App\\Models", kind: .class)
        ]
        let index = SymbolIndex()
        symbols.forEach { index.add($0) }

        let matches = PHPSymbolResolver.resolve(
            identifier: "Invoice",
            namespace: "App\\Services",
            aliases: ["Invoice": "App\\Models\\Order"],
            index: index
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].name, "Order")
        XCTAssertEqual(matches[0].fullyQualifiedName, "App\\Models\\Order")
    }

    func testResolverPrefersCurrentNamespace() {
        let index = SymbolIndex()
        index.add(makeSymbol("PaymentService", namespace: "App\\Services", kind: .class))
        index.add(makeSymbol("PaymentService", namespace: "Other\\Package", kind: .class))

        let matches = PHPSymbolResolver.resolve(
            identifier: "PaymentService",
            namespace: "App\\Services",
            aliases: [:],
            index: index
        )
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches[0].namespace, "App\\Services")
    }

    private func makeSymbol(
        _ name: String,
        namespace: String?,
        kind: SymbolKind
    ) -> SymbolInfo {
        SymbolInfo(
            name: name,
            kind: kind,
            namespace: namespace,
            fileURL: URL(fileURLWithPath: "/project/\(name).php"),
            nameRange: NSRange(location: 0, length: (name as NSString).length),
            fullRange: NSRange(location: 0, length: (name as NSString).length)
        )
    }
}