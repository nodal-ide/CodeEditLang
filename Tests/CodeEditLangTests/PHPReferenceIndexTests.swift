import XCTest
@testable import CodeEditLangPHP

final class PHPReferenceIndexTests: XCTestCase {
    private let fileA = URL(fileURLWithPath: "/tmp/rf3/a.php")
    private let fileB = URL(fileURLWithPath: "/tmp/rf3/b.php")
    private let fileC = URL(fileURLWithPath: "/tmp/rf3/c.php")

    func testAddAndLookUp() {
        let index = PHPReferenceIndex()
        index.addPosting(name: "charge", fileURL: fileA)
        let (postings, isComplete) = index.lookUp("charge")
        XCTAssertEqual(postings.count, 1)
        XCTAssertEqual(postings.first?.fileURL, fileA.path(percentEncoded: false))
        XCTAssertTrue(isComplete)
    }

    func testLookUpNormalizesCaseAndLeadingBackslashes() {
        let index = PHPReferenceIndex()
        index.addPosting(name: "\\App\\Models\\User", fileURL: fileA)
        XCTAssertFalse(index.lookUp("app\\models\\user").0.isEmpty)
        XCTAssertFalse(index.lookUp("App\\Models\\User").0.isEmpty)
        XCTAssertTrue(index.lookUp("Other").0.isEmpty)
    }

    func testAddIsIdempotentPerFile() {
        let index = PHPReferenceIndex()
        index.addPosting(name: "get", fileURL: fileA)
        index.addPosting(name: "get", fileURL: fileA)
        XCTAssertEqual(index.lookUp("get").0.count, 1)
        XCTAssertEqual(index.postingCount, 1)
    }

    func testAddPostingsBatchDeduplicatesWithinBatch() {
        let index = PHPReferenceIndex()
        index.addPostings(names: ["Foo", "foo", "\\FOO", "Bar"], fileURL: fileA)
        XCTAssertEqual(index.lookUp("foo").0.count, 1)
        XCTAssertEqual(index.lookUp("bar").0.count, 1)
        XCTAssertEqual(index.postingCount, 2)
        XCTAssertEqual(index.names(inFile: fileA), ["foo", "bar"])
    }

    func testEmptyNamesAreIgnored() {
        let index = PHPReferenceIndex()
        index.addPostings(names: ["", "  "], fileURL: fileA)
        XCTAssertEqual(index.postingCount, 0)
        XCTAssertTrue(index.names(inFile: fileA).isEmpty)
    }

    func testRemoveFileEvictsOnlyThatFile() {
        let index = PHPReferenceIndex()
        index.addPostings(names: ["user", "save"], fileURL: fileA)
        index.addPostings(names: ["user"], fileURL: fileB)

        index.removeFile(fileA)

        let (postings, _) = index.lookUp("user")
        XCTAssertEqual(postings.count, 1)
        XCTAssertEqual(postings.first?.fileURL, fileB.path(percentEncoded: false))
        XCTAssertTrue(index.lookUp("save").0.isEmpty)
        XCTAssertTrue(index.names(inFile: fileA).isEmpty)
        XCTAssertEqual(index.names(inFile: fileB), ["user"])
    }

    func testRemoveUnknownFileIsNoOp() {
        let index = PHPReferenceIndex()
        index.addPostings(names: ["user"], fileURL: fileA)
        index.removeFile(fileC)
        XCTAssertEqual(index.lookUp("user").0.count, 1)
    }

    func testPostingsCapTruncatesAndMarksIncomplete() {
        let index = PHPReferenceIndex(maxPostings: 2)
        index.addPostings(names: ["get"], fileURL: fileA)
        index.addPostings(names: ["get"], fileURL: fileB)
        index.addPostings(names: ["get"], fileURL: fileC)

        let (postings, isComplete) = index.lookUp("get")
        XCTAssertEqual(postings.count, 2)
        XCTAssertFalse(isComplete)
        XCTAssertEqual(index.postingCount, 2)
        XCTAssertEqual(index.names(inFile: fileC), ["get"])
    }

    func testEvictionBelowCapRestoresCompletenessOnRebuild() {
        let index = PHPReferenceIndex(maxPostings: 1)
        index.addPostings(names: ["get"], fileURL: fileA)
        index.addPostings(names: ["get"], fileURL: fileB)
        XCTAssertFalse(index.lookUp("get").1)

        index.removeFile(fileA)
        index.removeFile(fileB)
        XCTAssertTrue(index.lookUp("get").0.isEmpty)

        index.addPostings(names: ["get"], fileURL: fileA)
        let (postings, isComplete) = index.lookUp("get")
        XCTAssertEqual(postings.count, 1)
        XCTAssertTrue(isComplete)
    }
}
