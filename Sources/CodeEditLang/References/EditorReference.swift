import Foundation

/// A single occurrence of a symbol, ready for display and navigation.
///
/// Produced by every references provider (native engine, language server, extension) so the app can
/// group, filter, and render rows without knowing where they came from. All offsets are UTF-16
/// (`NSString`/`NSRange`) and are validated against the source text before they leave
/// ``SourceLineIndex/reference(for:in:fileURL:kind:container:isHeuristic:)``.
public struct EditorReference: Sendable, Hashable, Identifiable {
    /// What the occurrence does to the symbol.
    public enum Kind: String, Sendable, Codable, Hashable {
        /// The symbol's own declaration.
        case declaration
        /// A write (assignment, mutation, definition use).
        case write
        /// A read (call, access, type reference).
        case read
        /// A match by name only, without a resolvable receiver type.
        case text
    }

    /// Stable identity: file path + UTF-16 location/length. Two queries that find the same
    /// occurrence produce the same id, so list diffing and emphasis updates are cheap.
    public let id: String
    public let fileURL: URL
    /// The occurrence range, validated and clamped to the document.
    public let range: NSRange
    /// 1-based display line.
    public let line: Int
    /// 1-based display column (UTF-16 offset within the line).
    public let column: Int
    /// Trimmed source line for the row preview (capped at 200 characters).
    public let preview: String
    public let kind: Kind
    /// Enclosing type/function name, for display when it isn't the target.
    public let container: String?
    /// `true` when the match is a name-only approximation (e.g. an instance member accessed
    /// through a receiver whose type is unknown).
    public let isHeuristic: Bool

    public init(
        fileURL: URL,
        range: NSRange,
        line: Int,
        column: Int,
        preview: String,
        kind: Kind = .read,
        container: String? = nil,
        isHeuristic: Bool = false
    ) {
        self.id = "\(fileURL.path(percentEncoded: false))#\(range.location):\(range.length)"
        self.fileURL = fileURL
        self.range = range
        self.line = line
        self.column = column
        self.preview = preview
        self.kind = kind
        self.container = container
        self.isHeuristic = isHeuristic
    }
}

extension EditorReference: Comparable {
    public static func < (lhs: EditorReference, rhs: EditorReference) -> Bool {
        if lhs.fileURL != rhs.fileURL {
            return lhs.fileURL.path(percentEncoded: false) < rhs.fileURL.path(percentEncoded: false)
        }
        if lhs.range.location != rhs.range.location {
            return lhs.range.location < rhs.range.location
        }
        return lhs.range.length < rhs.range.length
    }
}
