import Foundation

/// Supplies source text for files a references query touches.
///
/// The app implements this to prefer an open document's live buffer over disk, so unsaved edits are
/// searched and the returned ranges line up with what the editor shows. Being `Sendable` is part of
/// the contract: candidate files are read and parsed off the main actor.
///
/// Implementations must be cheap to call repeatedly for the same URL within a query, or at least
/// idempotent; callers are expected to read each file once.
public protocol SourceTextProviding: Sendable {
    /// The file's text, or `nil` when it cannot be read.
    func text(for url: URL) -> String?
}

/// Reads files from disk as UTF-8, skipping files larger than `maxByteCount`.
///
/// Bulk reference scans create one of these rather than depending on the editor's document model.
public struct DiskSourceTextProvider: SourceTextProviding {
    /// Files larger than this are treated as unreadable rather than loaded into memory.
    public let maxByteCount: Int

    public init(maxByteCount: Int = 8 * 1024 * 1024) {
        self.maxByteCount = maxByteCount
    }

    public func text(for url: URL) -> String? {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maxByteCount {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
