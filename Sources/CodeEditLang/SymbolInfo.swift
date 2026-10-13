import Foundation

/// A symbol (class, function, method, ...) indexed for a native language.
///
/// Ranges are UTF-16 offsets into the document, matching `NSString`/`NSRange`
/// so the values can be handed directly to the editor (`CursorPosition`).
public struct SymbolInfo: Sendable {
    /// Short name, e.g. `User` or `handle`.
    public let name: String
    public let kind: SymbolKind
    /// Fully-qualified namespace path, e.g. `App\Services\Payment`. `nil` for global scope.
    public let namespace: String?
    /// Owning type for members (methods/properties/constants), e.g. `App\Services\Payment`.
    public let container: String?
    /// The namespace-qualified identifier, e.g. `App\Services\Payment\StripeClient`
    /// or `App\Services\Payment::charge` for members.
    public let fullyQualifiedName: String
    public let fileURL: URL
    /// Byte/UTF-16 range of the declaration identifier within the file.
    public let nameRange: NSRange
    /// Range of the whole declaration (class body/function body) when known.
    public let fullRange: NSRange
    public let signature: String?
    public let documentation: String?
    public let visibility: String?

    public init(
        name: String,
        kind: SymbolKind,
        namespace: String?,
        container: String? = nil,
        fileURL: URL,
        nameRange: NSRange,
        fullRange: NSRange,
        signature: String? = nil,
        documentation: String? = nil,
        visibility: String? = nil
    ) {
        self.name = name
        self.kind = kind
        self.namespace = namespace
        self.container = container
        self.fileURL = fileURL
        self.nameRange = nameRange
        self.fullRange = fullRange
        self.signature = signature
        self.documentation = documentation
        self.visibility = visibility

        if let container, !container.isEmpty {
            self.fullyQualifiedName = "\(container)::\(name)"
        } else if let namespace, !namespace.isEmpty {
            self.fullyQualifiedName = "\(namespace)\\\(name)"
        } else {
            self.fullyQualifiedName = name
        }
    }
}