import Foundation
import SwiftTreeSitter
import CodeEditLanguages
import CodeEditLang

/// A class/interface/trait/enum scope found in a file.
public struct PHPScope: Sendable {
    public let fullyQualifiedName: String
    public let range: NSRange
}

/// The result of parsing a single PHP file.
public struct PHPFileSymbols {
    public var namespace: String?
    /// `use` alias -> fully-qualified class name, e.g. `"User"` -> `"App\\Models\\User"`.
    public var aliases: [String: String] = [:]
    public var symbols: [SymbolInfo] = []
    /// Distinct local variable names (without the leading `$`) found in the file.
    public var variables: [String] = []
    /// Class-like scopes, for resolving which class the cursor is inside.
    public var scopes: [PHPScope] = []
    /// Trait names used by each class-like FQN (`class FQN -> [TraitName]`).
    public var classTraits: [String: [String]] = [:]
    public var errorCount: Int = 0

    public static var empty: PHPFileSymbols { PHPFileSymbols() }

    /// The innermost class-like scope containing the given UTF-16 offset.
    public func classContaining(offset: Int) -> String? {
        scopes
            .filter { $0.range.location <= offset && offset <= $0.range.location + $0.range.length }
            .min { $0.range.length < $1.range.length }?
            .fullyQualifiedName
    }
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
    var scopes: [PHPScope] = []
    var classTraits: [String: [String]] = [:]
    var errorCount = 0

    private var currentClass: String?
    private var variableNames: Set<String> = []

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
            let hasBody = firstNamedChild(node, ofType: "compound_statement") != nil
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
            scanClassLike(node, type: type)

        case "function_definition":
            addNamedChildDeclaration(node, kind: .function)
            scanChildren(node)

        case "method_declaration":
            addNamedChildDeclaration(node, kind: .method, container: currentClass)
            if let nameNode = firstNamedChild(node, ofType: "name"), text(of: nameNode) == "__construct" {
                scanPromotedProperties(node)
            }
            scanChildren(node)

        case "use_declaration":
            scanTraitUse(node)
            scanChildren(node)

        case "property_declaration":
            scanPropertyDeclaration(node)
            scanChildren(node)

        case "const_declaration":
            scanConstDeclaration(node)
            scanChildren(node)

        case "variable_name":
            let name = text(of: node).replacingOccurrences(of: "$", with: "")
            if !name.isEmpty { variableNames.insert(name) }
            scanChildren(node)

        default:
            scanChildren(node)
        }
    }

    // MARK: - Classes & members

    private mutating func scanClassLike(_ node: Node, type: String) {
        guard let nameNode = firstNamedChild(node, ofType: "name") else {
            scanChildren(node)
            return
        }
        let name = text(of: nameNode).trimmingCharacters(in: .whitespacesAndNewlines)
        let fqn: String
        if let namespace, !namespace.isEmpty {
            fqn = "\(namespace)\\\(name)"
        } else {
            fqn = name
        }

        symbols.append(
            SymbolInfo(
                name: name,
                kind: Self.kind(for: type),
                namespace: namespace,
                fileURL: fileURL,
                nameRange: nameNode.range,
                fullRange: node.range,
                documentation: documentation(before: node.range.location)
            )
        )
        scopes.append(PHPScope(fullyQualifiedName: fqn, range: node.range))

        let saved = currentClass
        currentClass = fqn
        scanChildren(node)
        currentClass = saved
    }

    private mutating func scanPropertyDeclaration(_ node: Node) {
        guard let container = currentClass else { return }
        let type = typeText(of: node)
        // A property declaration contains one or more `property_element`s, each with a `variable_name`.
        for index in 0..<node.namedChildCount {
            guard let element = node.namedChild(at: index), element.nodeType == "property_element" else { continue }
            guard let nameNode = firstNamedChild(element, ofType: "variable_name") else { continue }
            let name = text(of: nameNode).replacingOccurrences(of: "$", with: "")
            guard !name.isEmpty else { continue }
            symbols.append(
                SymbolInfo(
                    name: name,
                    kind: .property,
                    namespace: namespace,
                    container: container,
                    fileURL: fileURL,
                    nameRange: nameNode.range,
                    fullRange: element.range,
                    signature: type
                )
            )
        }
    }

    /// Constructor-promoted properties (`__construct(private Foo $foo)`) become real properties.
    private mutating func scanPromotedProperties(_ method: Node) {
        guard let container = currentClass,
              let parameters = firstNamedChild(method, ofType: "formal_parameters") else { return }
        for index in 0..<parameters.namedChildCount {
            guard let parameter = parameters.namedChild(at: index),
                  parameter.nodeType == "property_promotion_parameter" else { continue }
            guard let nameNode = firstNamedChild(parameter, ofType: "variable_name") else { continue }
            let name = text(of: nameNode).replacingOccurrences(of: "$", with: "")
            guard !name.isEmpty else { continue }
            let type = typeText(of: parameter)
            symbols.append(
                SymbolInfo(
                    name: name,
                    kind: .property,
                    namespace: namespace,
                    container: container,
                    fileURL: fileURL,
                    nameRange: nameNode.range,
                    fullRange: parameter.range,
                    signature: type
                )
            )
        }
    }

    /// Trait `use` declarations inside a class body.
    private mutating func scanTraitUse(_ node: Node) {
        guard let container = currentClass else { return }
        for index in 0..<node.namedChildCount {
            guard let child = node.namedChild(at: index) else { continue }
            let type = child.nodeType ?? ""
            if type == "name" || type == "qualified_name" || type == "relative_name" {
                let name = normalized(name: text(of: child))
                if !name.isEmpty {
                    classTraits[container, default: []].append(name)
                }
            }
        }
    }

    private mutating func scanConstDeclaration(_ node: Node) {
        let container = currentClass
        for index in 0..<node.namedChildCount {
            guard let element = node.namedChild(at: index) else { continue }
            let type = element.nodeType ?? ""
            let nameNode: Node?
            if type == "const_element" {
                nameNode = firstNamedChild(element, ofType: "name")
            } else if type == "name" {
                nameNode = element
            } else {
                nameNode = nil
            }
            guard let nameNode else { continue }
            let name = text(of: nameNode)
            guard !name.isEmpty else { continue }
            symbols.append(
                SymbolInfo(
                    name: name,
                    kind: .constant,
                    namespace: namespace,
                    container: container,
                    fileURL: fileURL,
                    nameRange: nameNode.range,
                    fullRange: element.range
                )
            )
        }
    }

    // MARK: - Use declarations

    private mutating func scanUseDeclaration(_ node: Node) {
        for index in 0..<node.namedChildCount {
            guard let clause = node.namedChild(at: index) else { continue }
            if clause.nodeType == "namespace_use_clause" {
                registerAlias(from: clause)
            } else {
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
        guard let fqName = qualified, !fqName.isEmpty else { return }

        var alias: String?
        for index in 0..<clause.namedChildCount {
            guard let child = clause.namedChild(at: index), child.nodeType == "name" else { continue }
            let candidate = text(of: child)
            if candidate != fqName {
                alias = candidate
                break
            }
        }
        if alias == nil {
            for index in 0..<clause.namedChildCount {
                guard let child = clause.namedChild(at: index) else { continue }
                if (child.nodeType ?? "").contains("as") {
                    alias = firstNamedChild(child, ofType: "name").map { text(of: $0) } ?? text(of: child)
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

    private mutating func addNamedChildDeclaration(
        _ node: Node,
        kind: SymbolKind,
        container: String? = nil
    ) {
        guard let nameNode = firstNamedChild(node, ofType: "name") else { return }
        let name = text(of: nameNode).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        symbols.append(
            SymbolInfo(
                name: name,
                kind: kind,
                namespace: namespace,
                container: container,
                fileURL: fileURL,
                nameRange: nameNode.range,
                fullRange: node.range,
                documentation: documentation(before: node.range.location)
            )
        )
    }

    mutating func finish() -> PHPFileSymbols {
        PHPFileSymbols(
            namespace: namespace,
            aliases: aliases,
            symbols: symbols,
            variables: variableNames.sorted(),
            scopes: scopes,
            classTraits: classTraits,
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

    /// Extracts a `/** ... */` docblock immediately preceding `location`, if any.
    private func documentation(before location: Int) -> String? {
        let safe = min(max(location, 0), source.length)
        let prefix = (source.substring(to: safe) as NSString)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix.hasSuffix("*/"), let startRange = prefix.range(of: "/**", options: .backwards) else {
            return nil
        }
        var body = String(prefix[startRange.lowerBound...])
        body = body.replacingOccurrences(of: "/**", with: "")
        if body.hasSuffix("*/") { body.removeLast(2) }
        let cleaned = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var text = line.trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("*") { text.removeFirst() }
                return text.trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private func firstNamedChild(_ node: Node, ofType type: String) -> Node? {
        for index in 0..<node.namedChildCount {
            guard let child = node.namedChild(at: index), child.nodeType == type else { continue }
            return child
        }
        return nil
    }

    /// Extracts the declared type text from a parameter or property declaration.
    ///
    /// Tree-sitter PHP names the type node differently across grammar revisions
    /// (`type`, `named_type`, `primitive_type`, `optional_type`, `union_type`, ...),
    /// so match any direct child whose node type contains "type".
    private func typeText(of node: Node) -> String? {
        if let direct = firstNamedChild(node, ofType: "type") {
            return text(of: direct)
        }
        for index in 0..<node.namedChildCount {
            guard let child = node.namedChild(at: index) else { continue }
            let type = child.nodeType ?? ""
            if type == "variable_name" || type.contains("attribute") { continue }
            if type.contains("type") { return text(of: child) }
        }
        return nil
    }

    private func firstNamedChild(_ node: Node, matching predicate: (String) -> Bool) -> Node? {
        for index in 0..<node.namedChildCount {
            guard let child = node.namedChild(at: index), predicate(child.nodeType ?? "") else { continue }
            return child
        }
        return nil
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