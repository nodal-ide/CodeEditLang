import Foundation

/// The symbol being searched for, captured at the cursor before any work leaves the main actor.
///
/// Providers receive this instead of an editor/controller reference so queries can run off the main
/// thread and be replayed in tests without an `NSTextView`.
public struct ReferenceTarget: Sendable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case type
        case function
        case method
        case property
        case constant
        case variable
        case unknown
    }

    /// The short name as written at the cursor, e.g. `charge`, `StripeClient`, `$amount`.
    public let identifier: String
    public let kind: Kind
    /// The file the query originated from. Always considered a candidate.
    public let fileURL: URL
    /// The identifier's UTF-16 range in `fileURL`.
    public let range: NSRange
    /// Namespace-qualified name when it could be resolved (`App\Services\Payment`).
    public let fullyQualifiedName: String?
    /// Owning type for members (`App\Services\Payment\StripeClient`).
    public let container: String?

    public init(
        identifier: String,
        kind: Kind = .unknown,
        fileURL: URL,
        range: NSRange,
        fullyQualifiedName: String? = nil,
        container: String? = nil
    ) {
        self.identifier = identifier
        self.kind = kind
        self.fileURL = fileURL
        self.range = range
        self.fullyQualifiedName = fullyQualifiedName
        self.container = container
    }

    /// Whether the target is a member of a type (method, property, constant).
    public var isMember: Bool { container != nil }
}
