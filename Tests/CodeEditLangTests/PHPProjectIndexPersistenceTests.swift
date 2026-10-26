import XCTest
@testable import CodeEditLangPHP

final class PHPProjectIndexPersistenceTests: XCTestCase {
    private var root: URL!
    private var fileA: URL!
    private var fileB: URL!

    private let sourceA = """
    <?php
    namespace App;
    class UserService {
        public function save() {
            return Validator::check();
        }
    }
    """

    private let sourceB = """
    <?php
    namespace App;
    use App\\UserService;
    class Controller {
        public function index() {
            $svc = new UserService();
            return $svc->save();
        }
    }
    """

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rf3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Create files through path-based URLs, but capture enumerator URLs
        // so test assertions use the same URL representation the indexer sees.
        let tempA = root.appending(path: "UserService.php")
        let tempB = root.appending(path: "Controller.php")
        try sourceA.write(to: tempA, atomically: true, encoding: .utf8)
        try sourceB.write(to: tempB, atomically: true, encoding: .utf8)
        let allFiles = phpFilesViaEnumerator()
        fileA = allFiles.first { $0.lastPathComponent == "UserService.php" }
        fileB = allFiles.first { $0.lastPathComponent == "Controller.php" }
    }

    private func phpFilesViaEnumerator() -> [URL] {
        var files: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return files }
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "php" { files.append(url) }
        }
        return files
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testColdBuildPopulatesBothIndexesAndPersistsNames() async throws {
        let indexer = PHPProjectIndexer()
        await indexer.buildIndex(at: root)

        XCTAssertFalse(indexer.symbolIndex.symbols(inFile: fileA).isEmpty)
        XCTAssertFalse(indexer.referenceIndex.lookUp("userservice").0.isEmpty)
        XCTAssertFalse(indexer.referenceIndex.lookUp("validator").0.isEmpty)

        let cache = try XCTUnwrap(PHPProjectCache.load(for: root))
        XCTAssertEqual(cache.version, PHPProjectCache.version)
        XCTAssertEqual(cache.files.count, 2)
        let namesA = try XCTUnwrap(cache.files.first { $0.path.hasSuffix("UserService.php") })
        XCTAssertTrue(namesA.referenceNames.contains("UserService"))
        XCTAssertTrue(namesA.referenceNames.contains("save"))
    }

    func testWarmBuildHydratesPostingsFromCacheWithoutReparsing() async throws {
        let first = PHPProjectIndexer()
        await first.buildIndex(at: root)

        // Set a distinctive mtime so we can verify it persists through the warm build.
        let sentinel = Date(timeIntervalSinceReferenceDate: -1_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: sentinel],
            ofItemAtPath: fileA.path
        )

        let warm = PHPProjectIndexer()
        await warm.buildIndex(at: root)

        XCTAssertFalse(
            warm.referenceIndex.lookUp("userservice").0.isEmpty,
            "postings must be rehydrated from the persisted cache for unchanged files"
        )
        let warmCache = try XCTUnwrap(PHPProjectCache.load(for: root))
        let entry = try XCTUnwrap(warmCache.files.first { $0.path.hasSuffix("UserService.php") })
        XCTAssertEqual(entry.modified, sentinel, "stale mtime must survive a hydration-only build")
    }

    func testRefreshReplacesStalePostings() async throws {
        let indexer = PHPProjectIndexer()
        await indexer.buildIndex(at: root)
        XCTAssertFalse(indexer.referenceIndex.lookUp("validator").0.isEmpty)

        let edited = sourceA.replacingOccurrences(of: "Validator::check()", with: "'ok'")
        try edited.write(to: fileA, atomically: true, encoding: .utf8)
        indexer.refreshFile(at: fileA)

        XCTAssertTrue(
            indexer.referenceIndex.lookUp("validator").0.isEmpty,
            "names dropped by an edit must be evicted on refresh"
        )
        XCTAssertFalse(indexer.referenceIndex.lookUp("userservice").0.isEmpty)
    }

    func testReplaceFromParseResultRebuildsPostings() async throws {
        let indexer = PHPProjectIndexer()
        await indexer.buildIndex(at: root)

        let edited = sourceA.replacingOccurrences(of: "Validator::check()", with: "'ok'")
        let info = await PHPParseCache.shared.infoAsync(for: fileA, source: edited)
        indexer.replace(file: fileA, with: info)

        XCTAssertTrue(indexer.referenceIndex.lookUp("validator").0.isEmpty)
        XCTAssertFalse(indexer.referenceIndex.lookUp("userservice").0.isEmpty)
    }

    func testDeletedFilesAreEvictedOnNextBuild() async throws {
        let indexer = PHPProjectIndexer()
        await indexer.buildIndex(at: root)
        XCTAssertFalse(indexer.referenceIndex.lookUp("controller").0.isEmpty)

        try FileManager.default.removeItem(at: fileB)
        await indexer.buildIndex(at: root)

        XCTAssertTrue(indexer.symbolIndex.symbols(inFile: fileB).isEmpty)
        XCTAssertTrue(indexer.referenceIndex.lookUp("controller").0.isEmpty)
        XCTAssertTrue(indexer.referenceIndex.names(inFile: fileB).isEmpty)

        let cache = try XCTUnwrap(PHPProjectCache.load(for: root))
            XCTAssertEqual(cache.files.count, 1)
    }

    func testChangedFileIsReparsedAndCacheUpdated() async throws {
        let first = PHPProjectIndexer()
        await first.buildIndex(at: root)

        let edited = sourceB.replacingOccurrences(of: "save()", with: "delete()")
        try edited.write(to: fileB, atomically: true, encoding: .utf8)

        let second = PHPProjectIndexer()
        await second.buildIndex(at: root)

        XCTAssertFalse(second.referenceIndex.lookUp("delete").0.isEmpty)
        let cache = try XCTUnwrap(PHPProjectCache.load(for: root))
        let entryB = try XCTUnwrap(cache.files.first { $0.path.hasSuffix("Controller.php") })
        XCTAssertTrue(entryB.referenceNames.contains("delete"))
    }

    func testIgnoredDirectoriesAreNotIndexed() async throws {
        let vendor = root.appendingPathComponent("vendor", isDirectory: true)
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        try "<?php class Ghost {}".write(
            to: vendor.appending(path: "Ghost.php"),
            atomically: true,
            encoding: .utf8
        )

        let indexer = PHPProjectIndexer()
        await indexer.buildIndex(at: root)

        XCTAssertTrue(indexer.referenceIndex.lookUp("ghost").0.isEmpty)
        let cache = try XCTUnwrap(PHPProjectCache.load(for: root))
        XCTAssertFalse(cache.files.contains { $0.path.contains("vendor") })
    }
}
