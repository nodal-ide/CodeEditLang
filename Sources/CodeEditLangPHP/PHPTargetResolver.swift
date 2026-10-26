import Foundation
import CodeEditLang

/// Resolves the symbol under a cursor offset to a `ReferenceTarget` using cached parse results.
///
/// No reparse is performed — the target is resolved from `PHPFileSymbols` which is read from
/// the parse cache. Variables return `nil` (the query engine will report `.unsupported`).
enum PHPTargetResolver {

    /// Resolves the identifier at `cursorOffset` to a reference target.
    ///
    /// - Returns: `(target, aliases, namespace)` if a resolvable symbol is at the cursor,
    ///   or `nil` for variables / unknown identifiers.
    static func resolveTarget(
        at cursorOffset: Int,
        source: String,
        info: PHPFileSymbols,
        fileURL: URL
    ) -> (target: ReferenceTarget, aliases: [String: String], namespace: String?)? {
        let ns = source as NSString

        // Find the identifier token at or before the cursor.
        guard let (identifier, identifierRange) = identifier(at: cursorOffset, in: ns) else {
            return nil
        }

        // Skip `$this`, `$var`, etc. — variables are unsupported for find-references.
        if identifier.hasPrefix("$") {
            return nil
        }

        // Determine kind, FQN, and container.
        let (kind, fqn, container) = resolveKindAndFQN(
            identifier: identifier,
            info: info,
            cursorOffset: cursorOffset,
            source: source
        )

        if kind == .unknown {
            return nil
        }

        return (
            target: ReferenceTarget(
                identifier: identifier,
                kind: kind,
                fileURL: fileURL,
                range: identifierRange,
                fullyQualifiedName: fqn,
                container: container
            ),
            aliases: info.aliases,
            namespace: info.namespace
        )
    }

    private static func identifier(at offset: Int, in ns: NSString) -> (String, NSRange)? {
        func isIdentChar(_ c: unichar) -> Bool {
            if c == 0x5F || c == 0x5C { return true }
            if let s = UnicodeScalar(c) {
                return CharacterSet.alphanumerics.contains(s)
            }
            return false
        }

        // Cursor on an identifier.
        if offset < ns.length {
            let c = ns.character(at: offset)
            if isIdentChar(c) {
                var start = offset
                while start > 0 && isIdentChar(ns.character(at: start - 1)) { start -= 1 }
                var end = offset
                while end < ns.length && isIdentChar(ns.character(at: end)) { end += 1 }
                let range = NSRange(location: start, length: end - start)
                return (ns.substring(with: range), range)
            }
        }

        // Find identifier before cursor.
        var pos = min(offset, ns.length)
        while pos > 0 && !isIdentChar(ns.character(at: pos - 1)) { pos -= 1 }
        guard pos > 0, isIdentChar(ns.character(at: pos - 1)) else { return nil }
        var start = pos - 1
        while start > 0 && isIdentChar(ns.character(at: start - 1)) { start -= 1 }
        var end = pos
        while end < ns.length && isIdentChar(ns.character(at: end)) { end += 1 }
        let range = NSRange(location: start, length: end - start)
        return (ns.substring(with: range), range)
    }

    /// Determines the kind, FQN, and container for the identifier.
    private static func resolveKindAndFQN(
        identifier: String,
        info: PHPFileSymbols,
        cursorOffset: Int,
        source: String
    ) -> (kind: ReferenceTarget.Kind, fqn: String?, container: String?) {
        let lower = identifier.lowercased()

        // Member call on $this/self/static — look up the method in the enclosing class.
        if let container = info.classContaining(offset: cursorOffset) {
            // Is this a `$this->method()` or `ClassName::method()` pattern?
            if isMemberCallIdentifier(identifier, source: source as NSString, cursorOffset: cursorOffset, info: info) {
                return (
                    kind: .method,
                    fqn: "\(container)::\(identifier)",
                    container: container
                )
            }
        }

        // Exact symbol match in this file.
        for symbol in info.symbols where symbol.name == identifier {
            return (kind: symbolTargetKind(symbol), fqn: symbol.fullyQualifiedName, container: symbol.container)
        }

        // Class reference (from classReferences).
        for ref in info.classReferences where ref.name.lowercased() == lower {
            if let symbol = info.symbols.first(where: {
                $0.name.lowercased() == lower && ($0.kind == .class || $0.kind == .interface || $0.kind == .trait || $0.kind == .enum) && $0.container == nil
            }) {
                return (kind: .type, fqn: symbol.fullyQualifiedName, container: nil)
            }
            return (kind: .type, fqn: nil, container: nil)
        }

        // Function call.
        for call in info.functionCalls where call.name.lowercased() == lower {
            if let symbol = info.symbols.first(where: {
                $0.name.lowercased() == lower && $0.kind == .function && $0.container == nil
            }) {
                return (kind: .function, fqn: symbol.fullyQualifiedName, container: nil)
            }
            return (kind: .function, fqn: nil, container: nil)
        }

        // Global constant or function not in this file's parse — check by name pattern.
        if info.imports.filter({ $0.name.lowercased() == lower }).first != nil {
            return (kind: .unknown, fqn: nil, container: nil)
        }

        return (kind: .unknown, fqn: nil, container: nil)
    }

    /// Whether the identifier is part of a `$this->method()`, `self::method()`, or `static::method()` call.
    private static func isMemberCallIdentifier(
        _ identifier: String,
        source: NSString,
        cursorOffset: Int,
        info: PHPFileSymbols
    ) -> Bool {
        // Look backwards from the identifier for `->` or `::`.
        guard identifierRange(at: cursorOffset, in: source)?.location == cursorOffset else { return false }

        let identStart = cursorOffset - identifier.count
        guard identStart >= 0 else { return false }

        // Check for `->` before the identifier.
        if identStart >= 2 {
            let before = NSRange(location: identStart - 2, length: 2)
            if source.substring(with: before) == "->" {
                return true
            }
        }

        // Check for `::` before the identifier (static access).
        if identStart >= 2 {
            let before = NSRange(location: identStart - 2, length: 2)
            if source.substring(with: before) == "::" {
                // Is it self/static/parent or a class name?
                let beforeBefore = identStart - 2
                var classNameStart = beforeBefore
                while classNameStart > 0 && source.character(at: classNameStart - 1) != 0x20 && source.character(at: classNameStart - 1) != 0x0A {
                    classNameStart -= 1
                }
                let className = source.substring(with: NSRange(location: classNameStart, length: beforeBefore - classNameStart))
                if className == "self" || className == "static" || className == "parent" {
                    return true
                }
                // It's a ClassName::member access — still a method/property/constant reference.
                return true
            }
        }

        return false
    }

    private static func identifierRange(at offset: Int, in ns: NSString) -> NSRange? {
        // Find the identifier range that contains `offset`.
        func isIdentChar(_ c: unichar) -> Bool {
            if c == 0x5F || c == 0x5C { return true }
            if let s = UnicodeScalar(c) {
                return CharacterSet.alphanumerics.contains(s)
            }
            return false
        }

        var pos = offset
        guard pos < ns.length && isIdentChar(ns.character(at: pos)) else { return nil }
        var start = pos
        while start > 0 && isIdentChar(ns.character(at: start - 1)) { start -= 1 }
        var end = pos
        while end < ns.length && isIdentChar(ns.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func symbolTargetKind(_ symbol: SymbolInfo) -> ReferenceTarget.Kind {
        switch symbol.kind {
        case .class, .interface, .trait, .enum:
            return .type
        case .function:
            return .function
        case .method:
            return .method
        case .property:
            return .property
        case .constant:
            return .constant
        default:
            return .unknown
        }
    }
}
