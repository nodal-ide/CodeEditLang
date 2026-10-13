import Foundation
import SwiftTreeSitter
import CodeEditLanguages
import CodeEditLang

/// The result of parsing a single PHP file.
public struct PHPFileSymbols {
    public var namespace: String?
    /// `use` alias -> fully-qualified class name, e.g. `"User"` -> `"App\\Models\\User"`.
    public var aliases: [String: String] = [:]
    public var symbols: [SymbolInfo] = []
    public var errorCount: Int = 0

    public static var empty: PHPFileSymbols { PHPFileSymbols() }
}

/// Parses PHP source with the bundled tree-sitter PHP grammar and extracts a lightweight
/// symbol table. Keeps only small records (no source retention).
public enum PHPFileParser {
    /// The `TreeSitterLanguage` id this parser serves.
    public static let languageID = CodeLanguage.php.id

    public static func parse(_ source: String, fileURL: URL) -> PHPFileSymbols {
        guard let language = CodeLanguage.php.language else { return .empty }
        do {
            let parser = Parser()
            try parser.setLanguage(language)
            guard let tree = parser.parse(source) else { return .empty }
            var scanner = PHPScanner(source: source as NSString, fileURL: fileURL)
            if let root = tree.rootNode {
                scanner.scan(root)
            }
            return scanner.finish()
        } catch {
            return .empty
        }
    }
}

/// Depth-first walker over the PHP tree.
private struct PHPScanner {
    let source: NSString
    let fileURL: URL

    var namespace: String?
    var aliases: [String: String] = [:]
    var symbols: [SymbolInfo] = []
    var errorCount = 0

    init(source: NSString, fileURL: URL) {
        self.source = source
        self.fileURL = fileURL
    }

    mutating func scan(_ node: Node) {
        let type = node.nodeType ?? ""

        switch type {
        case "ERROR", "MISSING":
            errorCount += 1

        case "namespace_definition":
            let hasBody = firstNamedChild(node, ofType: "compound_statement", orWithField: "body") != nil
            if let nameNode = firstNamedChild(node, matching: { $0 == "namespace_name" }) {
                namespace = normalized(name: text(of: nameNode))
            } else if !hasBody {
                namespace = nil
            }
            scanChildren(node)
            if hasBody {
                namespace = nil
            }

        case "namespace_use_declaration":
            scanUseDeclaration(node)

        case "class_declaration", "interface_declaration", "trait_declaration", "enum_declaration":
            addDeclaration(node, kind: Self.kind(for: type))
            scanChildren(node)

        case "function_definition":
            addNamedChildDeclaration(node, kind: .function)
            scanChildren(node)

        case "const_declaration":
            addNamedChildDeclaration(node, kind: .constant)
            scanChildren(node)

        default:
            scanChildren(node)
        }
    }

    // MARK: - Use declarations

    private mutating func scanUseDeclaration(_ node: Node) {
        for index in 0..<node.namedChildCount {
            guard let clause = node.namedChild(at: index) else { continue }
            if clause.nodeType == "namespace_use_clause" {
                registerAlias(from: clause)
            } else {
                // Prefer a shallow scan for group clauses (`use A\B\{C, D as E};`),
                // otherwise leave the prefix unhandled for v1.
                scan(clause)
            }
        }
    }

    private mutating func registerAlias(from clause: Node) {
        var qualified: String?
        for index in 0..<clause.namedChildCount {
            guard let child = clause.namedChild(at: index) else { continue }
            let type = child.nodeType ?? ""
            if type == "qualified_name" || type == "relative_name" || type == "name" {
                qualified = normalized(name: text(of: child))
                break
            }
        }
        guard var fqName = qualified, !fqName.isEmpty else { return }

        var alias: String?
        // Direct `name` sibling that isn't the qualified name itself.
        for index in 0..<clause.namedChildCount {
            guard let child = clause.namedChild(at: index), child.nodeType == "name" else { continue }
            let candidate = text(of: child)
            if candidate != fqName {
                alias = candidate
                break
            }
        }
        // Older grammar revisions wrap the alias in an `as`/`as_clause` node.
        if alias == nil {
            for index in 0..<clause.namedChildCount {
                guard let child = clause.namedChild(at: index) else { continue }
                if (child.nodeType ?? "").contains("as") {
                    if let nameNode = firstNamedChild(child, ofType: "name") {
                        alias = text(of: nameNode)
                    } else {
                        alias = text(of: child)
                    }
                    break
                }
            }
        }

        if let alias {
            aliases[alias] = fqName
        } else if let lastComponent = fqName.split(separator: "\\").last {
            aliases[String(lastComponent)] = fqName
        }
    }

    // MARK: - Declarations

    private mutating func addDeclaration(_ node: Node, kind: SymbolKind) {
        guard let nameNode = firstNamedChild(node, ofType: "name") else { return }
        add(name: text(of: nameNode), kind: kind, node: node)
    }

    private mutating func addNamedChildDeclaration(_ node: Node, kind: SymbolKind) {
        guard let nameNode = firstNamedChild(node, ofType: "name") else { return }
        add(name: text(of: nameNode), kind: kind, node: node)
    }

    private mutating func add(name: String, kind: SymbolKind, node: Node) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        symbols.append(
            SymbolInfo(
                name: trimmed,
                kind: kind,
                namespace: namespace,
                fileURL: fileURL,
                nameRange: node.range,
                fullRange: node.range
            )
        )
    }

    mutating func finish() -> PHPFileSymbols {
        PHPFileSymbols(
            namespace: namespace,
            aliases: aliases,
            symbols: symbols,
            errorCount: errorCount
        )
    }

    // MARK: - Helpers

    private mutating func scanChildren(_ node: Node) {
        for index in 0..<node.namedChildCount {
            guard let child = node.namedChild(at: index) else { continue }
            scan(child)
        }
    }

    private func text(of node: Node) -> String {
        source.substring(with: node.range)
    }

    private func normalized(name: String) -> String {
        var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix("\\") {
            trimmed.removeFirst()
        }
        return trimmed
    }

    private func firstNamedChild(_ node: Node, ofType type: String) -> Node? {
        for index in 0..<node.namedChildCount {
            guard let child = node.namedChild(at: index), child.nodeType == type else { continue }
            return child
        }
        return nil
    }

    private func firstNamedChild(
        _ node: Node,
        matching predicate: (String) -> Bool
    ) -> Node? {
        for index in 0..<node.namedChildCount {
            guard let child = node.namedChild(at: index), predicate(child.nodeType ?? "") else { continue }
            return child
        }
        return nil
    }

    private func firstNamedChild(
        _ node: Node,
        ofType type: String,
        orWithField _: String
    ) -> Node? {
        firstNamedChild(node, ofType: type)
    }
}

private extension PHPScanner {
    static func kind(for type: String) -> SymbolKind {
        switch type {
        case "class_declaration": return .class
        case "interface_declaration": return .interface
        case "trait_declaration": return .trait
        case "enum_declaration": return .enum
        default: return .class
        }
    }
}