import Foundation
import XCTest
@testable import CodeEditLang
@testable import CodeEditLangPHP

final class ReferenceAggregationTests: XCTestCase {
    // MARK: - Doubles

    private final class StubProvider: ReferenceProviding {
        let supportsReferences: Bool
        let outcome: ReferenceQueryOutcome
        private(set) var callCount = 0

        init(supports: Bool = true, outcome: ReferenceQueryOutcome) {
            self.supportsReferences = supports
            self.outcome = outcome
        }

        func references(for query: ReferenceQuery) async -> ReferenceQueryOutcome {
            callCount += 1
            return outcome
        }
    }

    private func makeQuery(maxResults: Int = ReferenceQuery.defaultMaxResults) -> ReferenceQuery {
        ReferenceQuery(
            target: ReferenceTarget(
                identifier: "charge",
                kind: .method,
                fileURL: URL(fileURLWithPath: "/project/a.php"),
                range: NSRange(location: 10, length: 6)
            ),
            languageID: "php",
            source: "<?php charge();",
            workspaceRoot: URL(fileURLWithPath: "/project"),
            maxResults: maxResults
        )
    }

    private func makeReference(at location: Int = 6) -> EditorReference {
        EditorReference(
            fileURL: URL(fileURLWithPath: "/project/a.php"),
            range: NSRange(location: location, length: 6),
            line: 1,
            column: location + 1,
            preview: "charge();"
        )
    }

    // MARK: - Merge policy

    func testFirstAnsweredProviderWins() async {
        let first = StubProvider(outcome: .results([makeReference()], isComplete: true))
        let second = StubProvider(outcome: .results([makeReference(at: 20)], isComplete: true))

        let outcome = await LanguageProviderAggregator.mergeReferences(
            query: makeQuery(),
            providers: [first, second]
        )

        XCTAssertEqual(outcome, .results([makeReference()], isComplete: true))
        XCTAssertEqual(first.callCount, 1)
        XCTAssertEqual(second.callCount, 0, "a lower-priority provider must not be consulted")
    }

    func testEmptyAuthoritativeResultStopsTheSearch() async {
        let first = StubProvider(outcome: .results([], isComplete: true))
        let second = StubProvider(outcome: .results([makeReference()], isComplete: true))

        let outcome = await LanguageProviderAggregator.mergeReferences(
            query: makeQuery(),
            providers: [first, second]
        )

        XCTAssertEqual(outcome, .results([], isComplete: true))
        XCTAssertEqual(second.callCount, 0, "an authoritative empty result must not fall through")
    }

    func testProvidersWithoutCapabilityAreSkipped() async {
        let incapable = StubProvider(
            supports: false,
            outcome: .results([makeReference()], isComplete: true)
        )
        let capable = StubProvider(outcome: .results([makeReference(at: 20)], isComplete: true))

        let outcome = await LanguageProviderAggregator.mergeReferences(
            query: makeQuery(),
            providers: [incapable, capable]
        )

        XCTAssertEqual(outcome, .results([makeReference(at: 20)], isComplete: true))
        XCTAssertEqual(incapable.callCount, 0)
        XCTAssertEqual(capable.callCount, 1)
    }

    func testUnsupportedProvidersFallThrough() async {
        let declining = StubProvider(outcome: .unsupported(reason: "Not a symbol"))
        let answering = StubProvider(outcome: .results([makeReference()], isComplete: true))

        let outcome = await LanguageProviderAggregator.mergeReferences(
            query: makeQuery(),
            providers: [declining, answering]
        )

        XCTAssertEqual(outcome, .results([makeReference()], isComplete: true))
        XCTAssertEqual(declining.callCount, 1)
        XCTAssertEqual(answering.callCount, 1)
    }

    func testFailureFallsThroughToNextProvider() async {
        let failing = StubProvider(outcome: .failed(.timedOut))
        let answering = StubProvider(outcome: .results([makeReference()], isComplete: true))

        let outcome = await LanguageProviderAggregator.mergeReferences(
            query: makeQuery(),
            providers: [failing, answering]
        )

        XCTAssertEqual(outcome, .results([makeReference()], isComplete: true))
        XCTAssertEqual(failing.callCount, 1)
        XCTAssertEqual(answering.callCount, 1)
    }

    func testAllFailuresSurfaceTheLastFailure() async {
        let transport = StubProvider(outcome: .failed(.transport("socket closed")))
        let timeout = StubProvider(outcome: .failed(.timedOut))

        let outcome = await LanguageProviderAggregator.mergeReferences(
            query: makeQuery(),
            providers: [transport, timeout]
        )

        XCTAssertEqual(outcome, .failed(.timedOut))
        XCTAssertEqual(transport.callCount, 1)
        XCTAssertEqual(timeout.callCount, 1)
    }

    func testCancellationStopsImmediately() async {
        let cancelled = StubProvider(outcome: .failed(.cancelled))
        let second = StubProvider(outcome: .results([makeReference()], isComplete: true))

        let outcome = await LanguageProviderAggregator.mergeReferences(
            query: makeQuery(),
            providers: [cancelled, second]
        )

        XCTAssertEqual(outcome, .failed(.cancelled))
        XCTAssertEqual(second.callCount, 0)
    }

    func testFirstDeclineReasonIsReported() async {
        let first = StubProvider(outcome: .unsupported(reason: "Variables aren't supported yet."))
        let second = StubProvider(outcome: .unsupported(reason: ""))

        let outcome = await LanguageProviderAggregator.mergeReferences(
            query: makeQuery(),
            providers: [first, second]
        )

        XCTAssertEqual(outcome, .unsupported(reason: "Variables aren't supported yet."))
    }

    func testNoCapableProviderReportsUnavailable() async {
        let incapable = StubProvider(supports: false, outcome: .results([], isComplete: true))

        let outcome = await LanguageProviderAggregator.mergeReferences(
            query: makeQuery(),
            providers: [incapable]
        )

        guard case .unsupported(let reason) = outcome else {
            return XCTFail("expected unsupported, got \(outcome)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(incapable.callCount, 0)
    }

    func testResultsAreCappedAndCompletenessCleared() async {
        let references = [makeReference(at: 0), makeReference(at: 10), makeReference(at: 20)]
        let provider = StubProvider(outcome: .results(references, isComplete: true))

        let outcome = await LanguageProviderAggregator.mergeReferences(
            query: makeQuery(maxResults: 2),
            providers: [provider]
        )

        XCTAssertEqual(outcome, .results([makeReference(at: 0), makeReference(at: 10)], isComplete: false))
        XCTAssertEqual(outcome.references?.count, 2)
        XCTAssertFalse(outcome.isComplete)
    }

    func testCompletenessIsPreservedUnderTheCap() async {
        let provider = StubProvider(outcome: .results([makeReference()], isComplete: true))

        let outcome = await LanguageProviderAggregator.mergeReferences(
            query: makeQuery(maxResults: 10),
            providers: [provider]
        )

        XCTAssertTrue(outcome.isComplete)
        XCTAssertTrue(outcome.isAnswered)
    }

    func testPartialProviderResultStaysPartial() async {
        let provider = StubProvider(outcome: .results([makeReference()], isComplete: false))

        let outcome = await LanguageProviderAggregator.mergeReferences(
            query: makeQuery(),
            providers: [provider]
        )

        XCTAssertEqual(outcome.references?.count, 1)
        XCTAssertFalse(outcome.isComplete)
    }

    // MARK: - Model helpers

    func testOutcomeHelpersDistinguishStates() {
        XCTAssertEqual(ReferenceQueryOutcome.results([], isComplete: true).references, [])
        XCTAssertNil(ReferenceQueryOutcome.unsupported(reason: "x").references)
        XCTAssertNil(ReferenceQueryOutcome.failed(.timedOut).references)
        XCTAssertFalse(ReferenceQueryOutcome.failed(.timedOut).isAnswered)
        XCTAssertFalse(ReferenceQueryOutcome.unsupported(reason: "x").isComplete)
    }

    func testErrorMessagesAreNonEmpty() {
        let errors: [ReferenceQueryError] = [
            .transport("socket closed"),
            .transport(""),
            .timedOut,
            .cancelled,
            .notReady(""),
        ]
        for error in errors {
            XCTAssertFalse(error.message.isEmpty, "\(error) must have a user-facing message")
        }
    }

    func testTargetMemberDetection() {
        let member = ReferenceTarget(
            identifier: "charge",
            kind: .method,
            fileURL: URL(fileURLWithPath: "/project/a.php"),
            range: NSRange(location: 0, length: 6),
            fullyQualifiedName: "App\\StripeClient::charge",
            container: "App\\StripeClient"
        )
        XCTAssertTrue(member.isMember)

        let freeFunction = ReferenceTarget(
            identifier: "charge",
            kind: .function,
            fileURL: URL(fileURLWithPath: "/project/a.php"),
            range: NSRange(location: 0, length: 6)
        )
        XCTAssertFalse(freeFunction.isMember)
    }
}
