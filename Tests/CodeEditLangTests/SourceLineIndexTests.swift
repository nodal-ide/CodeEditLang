import Foundation
import XCTest
@testable import CodeEditLang

final class SourceLineIndexTests: XCTestCase {
    // MARK: - Line structure

    func testEmptyTextHasSingleEmptyLine() {
        let text = ""
        let index = SourceLineIndex(text)

        XCTAssertEqual(index.length, 0)
        XCTAssertEqual(index.lineCount, 1)
        XCTAssertEqual(index.lineContentRange(at: 0), NSRange(location: 0, length: 0))
        XCTAssertEqual(index.lineText(at: 0, in: text), "")
        XCTAssertEqual(index.position(atOffset: 0)?.line, 0)
        XCTAssertEqual(index.position(atOffset: 0)?.column, 0)
    }

    func testLineRangesExcludeTerminators() {
        let text = "abc\ndef\nghi"
        let index = SourceLineIndex(text)

        XCTAssertEqual(index.lineCount, 3)
        XCTAssertEqual(index.lineText(at: 0, in: text), "abc")
        XCTAssertEqual(index.lineText(at: 1, in: text), "def")
        XCTAssertEqual(index.lineText(at: 2, in: text), "ghi")
        XCTAssertEqual(index.lineContentRange(at: 1), NSRange(location: 4, length: 3))
    }

    func testTrailingNewlineProducesFinalEmptyLine() {
        let text = "abc\n"
        let index = SourceLineIndex(text)

        XCTAssertEqual(index.lineCount, 2)
        XCTAssertEqual(index.lineText(at: 0, in: text), "abc")
        XCTAssertEqual(index.lineText(at: 1, in: text), "")
        XCTAssertEqual(index.lineContentRange(at: 1), NSRange(location: 4, length: 0))
    }

    func testCRLFIsOneTerminator() {
        let text = "a\r\nb"
        let index = SourceLineIndex(text)

        XCTAssertEqual(index.lineCount, 2)
        XCTAssertEqual(index.lineText(at: 0, in: text), "a")
        XCTAssertEqual(index.lineText(at: 1, in: text), "b")
        // `b` starts after both the CR and the LF.
        XCTAssertEqual(index.offset(line: 1, column: 0), 3)
        XCTAssertEqual(index.position(atOffset: 3)?.line, 1)
        XCTAssertEqual(index.position(atOffset: 3)?.column, 0)
    }

    func testCarriageReturnOnlyIsALineBreak() {
        let text = "a\rb\rc"
        let index = SourceLineIndex(text)

        XCTAssertEqual(index.lineCount, 3)
        XCTAssertEqual(index.lineText(at: 0, in: text), "a")
        XCTAssertEqual(index.lineText(at: 1, in: text), "b")
        XCTAssertEqual(index.lineText(at: 2, in: text), "c")
    }

    // MARK: - UTF-16 offsets

    func testSurrogatePairsCountAsTwoUTF16Units() {
        let text = "🙂x"
        let index = SourceLineIndex(text)

        XCTAssertEqual(index.length, 3)
        XCTAssertEqual(index.lineText(at: 0, in: text), "🙂x")
        XCTAssertEqual(index.position(atOffset: 2)?.line, 0)
        XCTAssertEqual(index.position(atOffset: 2)?.column, 2)
        XCTAssertEqual(index.offset(line: 0, column: 2), 2)
    }

    func testOffsetClampsPastEndOfLineButNotPastTerminator() {
        let text = "ab\ncd"
        let index = SourceLineIndex(text)

        // Column past the end of line 0 clamps to the content end (2), not into the newline.
        XCTAssertEqual(index.offset(line: 0, column: 99), 2)
        XCTAssertEqual(index.offset(line: 1, column: 99), 5)
        // An offset that lands inside a terminator maps to end-of-line.
        XCTAssertEqual(index.position(atOffset: 2)?.line, 0)
        XCTAssertEqual(index.position(atOffset: 2)?.column, 2)
    }

    func testOutOfBoundsLookupsReturnNil() {
        let index = SourceLineIndex("abc")

        XCTAssertNil(index.lineStart(at: -1))
        XCTAssertNil(index.lineStart(at: 1))
        XCTAssertNil(index.lineContentRange(at: 5))
        XCTAssertNil(index.lineIndex(atOffset: -1))
        XCTAssertNil(index.lineIndex(atOffset: 4))
        XCTAssertNil(index.position(atOffset: -1))
        XCTAssertNil(index.offset(line: 1, column: 0))
        XCTAssertNil(index.lineText(at: 3, in: "abc"))
    }

    func testLastCharacterOffsetIsValid() {
        let index = SourceLineIndex("abc")

        XCTAssertEqual(index.lineIndex(atOffset: 3), 0)
        XCTAssertEqual(index.position(atOffset: 3)?.column, 3)
    }

    // MARK: - Range clamping and references

    func testClampedRangeTruncatesAtDocumentEnd() {
        let index = SourceLineIndex("abcdef")

        XCTAssertEqual(index.clampedRange(NSRange(location: 4, length: 10)), NSRange(location: 4, length: 2))
        XCTAssertEqual(index.clampedRange(NSRange(location: 0, length: 0)), NSRange(location: 0, length: 0))
    }

    func testClampedRangeRejectsUnusableRanges() {
        let index = SourceLineIndex("abcdef")

        XCTAssertNil(index.clampedRange(NSRange(location: NSNotFound, length: 1)))
        XCTAssertNil(index.clampedRange(NSRange(location: -1, length: 1)))
        XCTAssertNil(index.clampedRange(NSRange(location: 7, length: 1)))
    }

    func testReferenceMapsOneBasedLineAndColumn() {
        let text = "<?php\n$total = charge();"
        let index = SourceLineIndex(text)
        let url = URL(fileURLWithPath: "/project/a.php")
        let range = (text as NSString).range(of: "charge")

        let reference = index.reference(for: range, in: text, fileURL: url, kind: .read)

        XCTAssertEqual(reference?.line, 2)
        XCTAssertEqual(reference?.column, 10)
        XCTAssertEqual(reference?.range, range)
        XCTAssertEqual(reference?.preview, "$total = charge();")
        XCTAssertEqual(reference?.kind, .read)
        XCTAssertEqual(reference?.id, "/project/a.php#\(range.location):\(range.length)")
    }

    func testReferenceForRangeOutsideDocumentIsNil() {
        let text = "abc"
        let index = SourceLineIndex(text)

        XCTAssertNil(index.reference(
            for: NSRange(location: 10, length: 1),
            in: text,
            fileURL: URL(fileURLWithPath: "/a.php")
        ))
    }

    func testReferencePreviewTrimsIndentationAndCapsLength() {
        let longLine = String(repeating: "a", count: 260)
        let text = "    \(longLine)\n"
        let index = SourceLineIndex(text)

        let reference = index.reference(
            for: NSRange(location: 4, length: 1),
            in: text,
            fileURL: URL(fileURLWithPath: "/a.php")
        )

        XCTAssertEqual(reference?.preview.count, SourceLineIndex.maxPreviewLength + 1)
        XCTAssertEqual(reference?.preview.hasSuffix("…"), true)
        XCTAssertEqual(reference?.preview.hasPrefix("    "), false)
    }

    func testMultiLineRangeUsesStartPosition() {
        let text = "one\ntwo\nthree"
        let index = SourceLineIndex(text)
        let range = NSRange(location: 0, length: 9)

        let reference = index.reference(for: range, in: text, fileURL: URL(fileURLWithPath: "/a.php"))

        XCTAssertEqual(reference?.line, 1)
        XCTAssertEqual(reference?.column, 1)
        XCTAssertEqual(reference?.range, range)
        XCTAssertEqual(reference?.preview, "one")
    }

    func testPreviewCollapsesLeadingWhitespaceOnly() {
        XCTAssertEqual(SourceLineIndex.preview(from: "\t  foo()  "), "foo()")
        XCTAssertEqual(SourceLineIndex.preview(from: ""), "")
    }
}
