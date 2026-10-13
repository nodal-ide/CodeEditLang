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

    func testParsesClassMembers() {
        let source = """
        <?php
        namespace App;

        class Foo {
            private string $bar;
            public function baz(): void {}
        }
        """
        let url = URL(fileURLWithPath: "/p/Foo.php")
        let info = PHPFileParser.parse(source, fileURL: url)
        let members = info.symbols.filter { $0.container != nil }
        XCTAssertEqual(Set(members.map(\.name)), ["bar", "baz"])
        XCTAssertTrue(members.allSatisfy { $0.container == "App\\Foo" })
        let insideClass = (source as NSString).range(of: "private").location
        XCTAssertEqual(info.classContaining(offset: insideClass), "App\\Foo")
    }

    func testMemberCompletionForThis() {
        let source = """
        <?php
        namespace App;

        class Foo {
            private string $bar;
            public function baz(): void {}
            public function run(): void {
                $this->
            }
        }
        """
        let url = URL(fileURLWithPath: "/p/Foo.php")
        let info = PHPFileParser.parse(source, fileURL: url)
        let index = SymbolIndex()
        info.symbols.forEach { index.add($0) }

        let ns = source as NSString
        let marker = ns.range(of: "$this->")
        let offset = marker.location + marker.length
        let items = PHPCompletionEngine.items(source: source, cursorOffset: offset, fileURL: url, index: index)
        let labels = Set(items.map(\.label))
        XCTAssertTrue(labels.contains("bar"), "expected property member, got \(labels)")
        XCTAssertTrue(labels.contains("baz"), "expected method member, got \(labels)")
    }

    func testGeneralCompletionIncludesVariable() {
        let source = """
        <?php
        namespace App;

        function run(): void {
            $user = new User();
            $us
        }
        """
        let url = URL(fileURLWithPath: "/p/run.php")
        let info = PHPFileParser.parse(source, fileURL: url)
        let index = SymbolIndex()
        info.symbols.forEach { index.add($0) }

        let ns = source as NSString
        let marker = ns.range(of: "$us", options: .backwards)
        let offset = marker.location + marker.length
        let items = PHPCompletionEngine.items(source: source, cursorOffset: offset, fileURL: url, index: index)
        XCTAssertTrue(items.contains { $0.label == "user" })
    }

    func testParsesPromotedPropertiesTraitsAndConsts() {
        let source = """
        <?php
        namespace App;

        trait ViewHelper {
            protected function view(): void {}
        }

        final class Auth {
            use ViewHelper;

            private const string BACKUP_KEY = 'k';

            public function __construct(private readonly SessionInterface $session) {}
        }
        """
        let url = URL(fileURLWithPath: "/p/Auth.php")
        let info = PHPFileParser.parse(source, fileURL: url)

        let classMembers = info.symbols.filter { $0.container == "App\\Auth" }
        XCTAssertTrue(classMembers.contains { $0.name == "session" && $0.kind == .property })
        XCTAssertTrue(classMembers.contains { $0.name == "BACKUP_KEY" && $0.kind == .constant })
        XCTAssertEqual(info.classTraits["App\\Auth"], ["ViewHelper"])
    }

    func testMemberCompletionIncludesTraitAndPromotedMembers() {
        let source = """
        <?php
        namespace App;

        trait ViewHelper {
            protected function view(): void {}
        }

        final class Auth {
            use ViewHelper;
            private const string VERIFY_KEY = 'v';

            public function __construct(private readonly SessionInterface $session) {}

            public function run(): void {
                $this->
            }
        }
        """
        let url = URL(fileURLWithPath: "/p/Auth.php")
        let info = PHPFileParser.parse(source, fileURL: url)
        let index = SymbolIndex()
        info.symbols.forEach { index.add($0) }

        let ns = source as NSString
        let marker = ns.range(of: "$this->")
        let offset = marker.location + marker.length
        let items = PHPCompletionEngine.items(source: source, cursorOffset: offset, fileURL: url, index: index)
        let labels = Set(items.map(\.label))
        XCTAssertTrue(labels.contains("view"), "expected trait method, got \(labels)")
        XCTAssertTrue(labels.contains("session"), "expected promoted property, got \(labels)")
        XCTAssertTrue(labels.contains("VERIFY_KEY"), "expected class constant, got \(labels)")
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