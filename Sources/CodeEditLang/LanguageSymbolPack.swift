import Foundation

/// A data-only "language pack": a set of symbols (with signatures and documentation) for a
/// framework or library, shipped by a declarative extension.
///
/// Packs are loaded into a workspace `SymbolIndex`, so any language engine backed by that index
/// (currently the native PHP engine) surfaces them in completion, hover and go-to-definition.
/// No code is required from the pack author.
public struct LanguageSymbolPack: Codable, Sendable {
    /// Language these symbols belong to, e.g. `"php"`.
    public var language: String
    /// Optional framework the pack targets (used for activation/display).
    public var framework: Framework?
    /// The symbols.
    public var symbols: [Entry]

    public init(language: String, framework: Framework? = nil, symbols: [Entry]) {
        self.language = language
        self.framework = framework
        self.symbols = symbols
    }

    public struct Framework: Codable, Sendable {
        public var name: String
        public var version: String?

        public init(name: String, version: String? = nil) {
            self.name = name
            self.version = version
        }
    }

    /// One symbol entry.
    public struct Entry: Codable, Sendable {
        public var name: String
        public var kind: SymbolKind
        public var namespace: String?
        public var container: String?
        public var signature: String?
        public var parameters: [String]?
        public var documentation: String?
        /// Text inserted on completion (falls back to `name`).
        public var insertText: String?

        public init(
            name: String,
            kind: SymbolKind,
            namespace: String? = nil,
            container: String? = nil,
            signature: String? = nil,
            parameters: [String]? = nil,
            documentation: String? = nil,
            insertText: String? = nil
        ) {
            self.name = name
            self.kind = kind
            self.namespace = namespace
            self.container = container
            self.signature = signature
            self.parameters = parameters
            self.documentation = documentation
            self.insertText = insertText
        }
    }
}

/// Builds a plain-text "reference sheet" for a symbol pack and the UTF-16 range of each entry's
/// name within it.
///
/// Declarative packs rarely ship real source stubs for every symbol. Rather than open a
/// non-existent file on go-to-definition, the host writes this generated sheet once and points
/// each symbol's `fileURL` at it — jumping lands on the symbol's line.
public enum DeclarativeStub {
    /// Returns the reference-sheet text and, for each entry (same order), the range of its name.
    public static func build(entries: [LanguageSymbolPack.Entry]) -> (text: String, nameRanges: [NSRange]) {
        var text = ""
        var ranges: [NSRange] = []
        var offset = 0

        for entry in entries {
            let fqn = entry.container.map { "\($0)::\(entry.name)" }
                ?? entry.namespace.map { "\($0)\\\(entry.name)" }
                ?? entry.name
            let line = entry.signature ?? "\(entry.kind.rawValue) \(fqn)"
            let nsLine = (line + "\n") as NSString

            let nameRange = nsLine.range(of: entry.name)
            if nameRange.location == NSNotFound {
                ranges.append(NSRange(location: offset, length: nsLine.length - 1))
            } else {
                ranges.append(NSRange(location: offset + nameRange.location, length: nameRange.length))
            }

            text += nsLine as String
            offset += nsLine.length
        }

        return (text, ranges)
    }

    /// Builds `SymbolInfo`s for a pack, using the generated reference sheet at `stubURL` as the
    /// declaration location.
    public static func symbols(from pack: LanguageSymbolPack, stubURL: URL) -> [SymbolInfo] {
        let (_, nameRanges) = build(entries: pack.symbols)

        return zip(pack.symbols, nameRanges).map { entry, nameRange in
            SymbolInfo(
                name: entry.name,
                kind: entry.kind,
                namespace: entry.namespace,
                container: entry.container,
                fileURL: stubURL,
                nameRange: nameRange,
                fullRange: nameRange,
                signature: entry.signature,
                parameters: entry.parameters ?? [],
                documentation: entry.documentation
            )
        }
    }
}
