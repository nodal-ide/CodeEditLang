import SwiftUI
import XCTest
import CodeEditSourceEditor
@testable import CodeEditLangPHP

final class CompletionMergeTests: XCTestCase {
    private struct Entry: CodeSuggestionEntry {
        let label: String
        var detail: String?

        var documentation: String? { nil }
        var pathComponents: [String]? { nil }
        var targetPosition: CursorPosition? { nil }
        var sourcePreview: String? { nil }
        var image: Image { Image(systemName: "square") }
        var imageColor: Color { .clear }
        var deprecated: Bool { false }
    }

    private func group(
        tier: Int,
        order: Int,
        owner: String,
        labels: [String],
        incomplete: Bool = false
    ) -> CompletionMerge.Group {
        CompletionMerge.Group(
            tier: tier,
            order: order,
            ownerID: owner,
            items: labels.map { Entry(label: $0) },
            isIncomplete: incomplete
        )
    }

    func testAutomaticPolicyRanksBuiltInFirst() {
        let policy = CompletionMergePolicy()
        XCTAssertEqual(policy.tier(for: .internalLanguage), 0)
        XCTAssertEqual(policy.tier(for: .lsp), 1)
        XCTAssertEqual(policy.tier(for: .languageExtension), 2)
    }

    func testLanguageServerFirstPolicy() {
        let policy = CompletionMergePolicy(preference: .languageServerFirst)
        XCTAssertEqual(policy.tier(for: .lsp), 0)
        XCTAssertEqual(policy.tier(for: .internalLanguage), 1)
        XCTAssertEqual(policy.tier(for: .languageExtension), 2)
    }

    func testExtensionFirstPolicy() {
        let policy = CompletionMergePolicy(preference: .extensionFirst)
        XCTAssertEqual(policy.tier(for: .languageExtension), 0)
        XCTAssertEqual(policy.tier(for: .internalLanguage), 1)
        XCTAssertEqual(policy.tier(for: .lsp), 2)
    }

    func testMergeOrdersByTierAndKeepsProviderOrder() {
        let groups = [
            group(tier: 2, order: 2, owner: "extension", labels: ["Container"]),
            group(tier: 0, order: 0, owner: "native", labels: ["strlen", "str_replace"]),
            group(tier: 1, order: 1, owner: "lsp", labels: ["str_contains"])
        ]
        let merged = CompletionMerge.merge(groups: groups)
        XCTAssertEqual(merged?.items.map(\.label), ["strlen", "str_replace", "str_contains", "Container"])
        XCTAssertEqual((merged?.items.first as? AttributedCompletionEntry)?.ownerID, "native")
        XCTAssertEqual((merged?.items.last as? AttributedCompletionEntry)?.ownerID, "extension")
    }

    func testDuplicateLabelsKeepPrimaryItem() {
        let groups = [
            group(tier: 0, order: 0, owner: "native", labels: ["strlen"]),
            group(tier: 1, order: 1, owner: "lsp", labels: ["strlen", "array_map"])
        ]
        let merged = CompletionMerge.merge(groups: groups)
        XCTAssertEqual(merged?.items.map(\.label), ["strlen", "array_map"])
        XCTAssertEqual((merged?.items.first as? AttributedCompletionEntry)?.ownerID, "native")
        XCTAssertEqual((merged?.items.last as? AttributedCompletionEntry)?.ownerID, "lsp")
    }

    func testAppendedItemsAreLimited() {
        let groups = [
            group(tier: 0, order: 0, owner: "native", labels: ["a", "b", "c"]),
            group(tier: 1, order: 1, owner: "lsp", labels: (0..<20).map { "item\($0)" })
        ]
        let merged = CompletionMerge.merge(groups: groups, appendedLimit: 4)
        XCTAssertEqual(merged?.items.count, 7)
    }

    func testTotalLimitClampsMergedItems() {
        let groups = [
            group(tier: 0, order: 0, owner: "native", labels: ["a", "b", "c", "d"]),
            group(tier: 1, order: 1, owner: "lsp", labels: ["e", "f"])
        ]
        let merged = CompletionMerge.merge(groups: groups, totalLimit: 5)
        XCTAssertEqual(merged?.items.count, 5)
    }

    func testIncompleteFlagComesFromPrimary() {
        let groups = [
            group(tier: 1, order: 1, owner: "lsp", labels: ["a"], incomplete: true),
            group(tier: 0, order: 0, owner: "native", labels: ["b"], incomplete: false)
        ]
        XCTAssertEqual(CompletionMerge.merge(groups: groups)?.isIncomplete, false)
    }

    func testEmptyGroupsReturnNil() {
        XCTAssertNil(CompletionMerge.merge(groups: [
            group(tier: 0, order: 0, owner: "native", labels: [])
        ]))
    }

    func testLowerTierWinsRegardlessOfGroupOrder() {
        let groups = [
            group(tier: 2, order: 0, owner: "extension", labels: ["x"]),
            group(tier: 0, order: 1, owner: "native", labels: ["y"])
        ]
        XCTAssertEqual(CompletionMerge.merge(groups: groups)?.items.first?.label, "y")
    }
}
