import Foundation
import CodeEditLang

/// A lazily-loaded, in-memory symbol index built from the bundled phpstorm-stubs JSON.
///
/// The stubs describe PHP's built-in functions/classes (signatures + docs). They are a
/// *fallback*: the open file, its namespace, imports, and properties always take priority.
public enum PHPStubIndex {
    /// Sentinel file URL used for stub symbols (they have no real file on disk).
    public static let stubFileURL = URL(fileURLWithPath: "/__php_stub__")

    private static let lock = NSLock()
    private static var cached: SymbolIndex?

    public static func shared() -> SymbolIndex {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }

        let index = SymbolIndex(maxSymbols: 400_000)
        let url = Bundle.module.url(forResource: "phpstubs", withExtension: "json")
            ?? Bundle.module.url(forResource: "phpstubs", withExtension: "json", subdirectory: "Resources")
        if let url, let data = try? Data(contentsOf: url),
           let entries = try? JSONDecoder().decode([StubEntry].self, from: data) {
            for entry in entries {
                index.add(
                    SymbolInfo(
                        name: entry.name,
                        kind: SymbolKind(rawValue: entry.kind) ?? .function,
                        namespace: entry.namespace,
                        container: entry.container,
                        fileURL: stubFileURL,
                        nameRange: NSRange(location: 0, length: 0),
                        fullRange: NSRange(location: 0, length: 0),
                        parameters: entry.parameters,
                        documentation: entry.documentation
                    )
                )
            }
        }
        cached = index
        return index
    }

    public static func isStub(_ symbol: SymbolInfo) -> Bool {
        symbol.fileURL == stubFileURL
    }

    private struct StubEntry: Codable {
        let name: String
        let kind: String
        let namespace: String?
        let container: String?
        let parameters: [String]
        let documentation: String?
    }
}