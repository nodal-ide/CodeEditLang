import XCTest
import CodeEditLanguages
import CodeEditSourceEditor
@testable import CodeEditLangPHP

final class LanguageProviderRoutingTests: XCTestCase {
    func testLSPRoutesOnlyForRootLanguageContext() {
        let root = LanguageID(rawValue: "php")
        let embedded = LanguageZoneContext(
            languageID: LanguageID(rawValue: "javascript"),
            parentLanguageID: root,
            sourceKey: "html-script",
            depth: 1
        )

        XCTAssertFalse(LanguageProviderAggregator.shouldRoute(
            providerPriority: .lsp,
            context: embedded,
            rootLanguageID: root
        ))
        XCTAssertTrue(LanguageProviderAggregator.shouldRoute(
            providerPriority: .lsp,
            context: LanguageZoneContext(languageID: root),
            rootLanguageID: root
        ))
        XCTAssertTrue(LanguageProviderAggregator.shouldRoute(
            providerPriority: .languageExtension,
            context: embedded,
            rootLanguageID: root
        ))
    }
}
