import Foundation

/// A UTF-16 line index for a piece of source text.
///
/// Built once per file and reused for every range in that file, which is what keeps reference
/// mapping linear instead of O(occurrences × file length). Line content ranges exclude their line
/// terminator, so `lineText(at:in:)` never returns a stray `\n`, `\r`, or `\r\n`.
///
/// All offsets are UTF-16 code units, matching `NSRange`, `NSString`, and LSP positions.
///
/// The index stores offsets only; callers must pass the same string it was built from to the
/// methods that need text. `Tests/CodeEditLangTests/SourceLineIndexTests.swift` pins that contract.
public struct SourceLineIndex: Sendable, Equatable {
    /// Total UTF-16 length of the indexed text.
    public let length: Int

    /// Offset of the first character of each line, ascending.
    private let lineStarts: [Int]
    /// Offset just past the last content character of each line (excluding the terminator).
    private let lineEnds: [Int]

    /// Longest preview returned by ``reference(for:in:fileURL:kind:container:isHeuristic:)``.
    public static let maxPreviewLength = 200

    public init(_ text: String) {
        self.init(nsString: text as NSString)
    }

    public init(nsString: NSString) {
        var starts: [Int] = [0]
        var ends: [Int] = []
        starts.reserveCapacity(max(1, nsString.length / 32))
        ends.reserveCapacity(starts.capacity)

        var index = 0
        while index < nsString.length {
            let character = nsString.character(at: index)
            if character == 0x0A { // \n
                ends.append(index)
                starts.append(index + 1)
            } else if character == 0x0D { // \r or \r\n
                ends.append(index)
                if index + 1 < nsString.length, nsString.character(at: index + 1) == 0x0A {
                    index += 1
                }
                starts.append(index + 1)
            }
            index += 1
        }
        ends.append(nsString.length)

        self.length = nsString.length
        self.lineStarts = starts
        self.lineEnds = ends
    }

    /// Number of lines. A trailing terminator produces a final empty line, like most editors.
    public var lineCount: Int { lineStarts.count }

    // MARK: - Line lookups

    /// Start offset of a 0-based line, or `nil` when the line is out of range.
    public func lineStart(at line: Int) -> Int? {
        guard line >= 0, line < lineStarts.count else { return nil }
        return lineStarts[line]
    }

    /// Content range of a 0-based line, excluding its terminator.
    public func lineContentRange(at line: Int) -> NSRange? {
        guard line >= 0, line < lineStarts.count else { return nil }
        let start = lineStarts[line]
        return NSRange(location: start, length: max(0, lineEnds[line] - start))
    }

    /// The 0-based line containing a UTF-16 offset, or `nil` when the offset is out of bounds.
    public func lineIndex(atOffset offset: Int) -> Int? {
        guard offset >= 0, offset <= length else { return nil }
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    /// 0-based line/column for a UTF-16 offset. Columns are clamped to the line's content length so
    /// an offset pointing at a line terminator maps to end-of-line rather than a phantom column.
    public func position(atOffset offset: Int) -> (line: Int, column: Int)? {
        guard let line = lineIndex(atOffset: offset) else { return nil }
        let column = min(max(0, offset - lineStarts[line]), max(0, lineEnds[line] - lineStarts[line]))
        return (line, column)
    }

    /// UTF-16 offset for a 0-based line/column. Columns past the end of the line clamp to its content
    /// length (an LSP position at end-of-line is valid). Returns `nil` for an invalid line.
    public func offset(line: Int, column: Int) -> Int? {
        guard line >= 0, line < lineStarts.count else { return nil }
        let start = lineStarts[line]
        let lineLength = max(0, lineEnds[line] - start)
        return start + min(max(0, column), lineLength)
    }

    /// The text of a 0-based line, without its terminator. `text` must be the string this index was
    /// built from.
    public func lineText(at line: Int, in text: String) -> String? {
        guard let range = lineContentRange(at: line) else { return nil }
        return (text as NSString).substring(with: range)
    }

    // MARK: - Range mapping

    /// Validates a range against the indexed text, clamping a long range to the end of the document.
    ///
    /// Returns `nil` for `.notFound`, negative locations, or locations past the end. Clamping rather
    /// than dropping keeps a stale-by-a-few-characters provider result displayable; a range that
    /// starts outside the document is unusable and is rejected.
    public func clampedRange(_ range: NSRange) -> NSRange? {
        guard range.location != NSNotFound, range.location >= 0, range.location <= length else {
            return nil
        }
        let upperBound = min(NSMaxRange(range), length)
        return NSRange(location: range.location, length: max(0, upperBound - range.location))
    }

    /// Builds a display-ready reference for a provider-reported range, or `nil` when the range cannot
    /// be mapped into this document.
    ///
    /// This is the single mapping path shared by the native engine and language servers: it clamps the
    /// range, computes 1-based line/column, and produces the bounded preview, so both producers render
    /// identically and no provider re-implements line math.
    public func reference(
        for range: NSRange,
        in text: String,
        fileURL: URL,
        kind: EditorReference.Kind = .read,
        container: String? = nil,
        isHeuristic: Bool = false
    ) -> EditorReference? {
        guard let clamped = clampedRange(range),
              let position = position(atOffset: clamped.location),
              let lineText = lineText(at: position.line, in: text) else {
            return nil
        }
        return EditorReference(
            fileURL: fileURL,
            range: clamped,
            line: position.line + 1,
            column: position.column + 1,
            preview: Self.preview(from: lineText),
            kind: kind,
            container: container,
            isHeuristic: isHeuristic
        )
    }

    /// Trims indentation and caps a preview line for list display.
    static func preview(from lineText: String) -> String {
        let trimmed = lineText.trimmingCharacters(in: .whitespaces)
        guard trimmed.count > maxPreviewLength else { return trimmed }
        return String(trimmed.prefix(maxPreviewLength)) + "…"
    }
}
