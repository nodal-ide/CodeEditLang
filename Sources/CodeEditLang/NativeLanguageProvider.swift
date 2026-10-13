import Foundation

/// The entry point a native language implementation exposes to the app.
///
/// This is intentionally small: the heavy work (index, parsing, resolution) lives in
/// each language implementation, and the app queries it through the concrete service it
/// registers (completion/hover/definition adapters that implement the editor's delegate
/// protocols). Add capabilities here as the per-language providers grow.
public protocol NativeLanguageProvider: AnyObject {
    /// The `TreeSitterLanguage` id this provider serves, e.g. "php".
    var languageID: String { get }
}

/// Maps language ids to their native providers.
public final class NativeLanguageRegistry: @unchecked Sendable {
    private static let lock = NSLock()
    private static var providers: [String: any NativeLanguageProvider] = [:]

    public init() {}

    public static func register(_ provider: any NativeLanguageProvider) {
        lock.lock()
        defer { lock.unlock() }
        providers[provider.languageID] = provider
    }

    public static func provider(for languageID: String) -> (any NativeLanguageProvider)? {
        lock.lock()
        defer { lock.unlock() }
        return providers[languageID]
    }

    public static func isRegistered(_ languageID: String) -> Bool {
        provider(for: languageID) != nil
    }
}