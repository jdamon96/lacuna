import XCTest
@testable import LacunaCore

final class ReplacementReadbackTests: XCTestCase {
    func testContinuouslyUnchangedTextAllowsOneFallback() {
        var readback = ReplacementReadback(original: "Hi {sign-off}", expected: "Hi Thanks")
        readback.observe(text: "Hi {sign-off}", targetIsFocused: true, selectionMatches: true)
        XCTAssertEqual(readback.outcome, .unconfirmed)
        readback.observe(text: "Hi {sign-off}", targetIsFocused: true, selectionMatches: true)
        XCTAssertEqual(readback.outcome, .unchanged)
    }

    func testIntermediateEditCanStillReachExpectedResult() {
        var readback = ReplacementReadback(original: "Hi {sign-off}", expected: "Hi Thanks")
        readback.observe(text: "Hi ", targetIsFocused: true, selectionMatches: false)
        XCTAssertEqual(readback.outcome, .unconfirmed)
        readback.observe(text: "Hi Thanks", targetIsFocused: true, selectionMatches: false)
        XCTAssertEqual(readback.outcome, .confirmed)
    }

    func testMutationThenReversionNeverAllowsDuplicateInsertion() {
        var readback = ReplacementReadback(original: "Hi {sign-off}", expected: "Hi Thanks")
        readback.observe(text: "Hi ", targetIsFocused: true, selectionMatches: false)
        for _ in 0..<4 {
            readback.observe(text: "Hi {sign-off}", targetIsFocused: true, selectionMatches: true)
        }
        XCTAssertEqual(readback.outcome, .unconfirmed)
    }

    func testUnavailableReadPreventsAutomaticRetry() {
        var readback = ReplacementReadback(original: "{gap}", expected: "Filled")
        readback.observe(text: nil, targetIsFocused: true, selectionMatches: true)
        for _ in 0..<4 { readback.observe(text: "{gap}", targetIsFocused: true, selectionMatches: true) }
        XCTAssertEqual(readback.outcome, .unconfirmed)
    }

    func testFocusOrSelectionMovementPreventsAutomaticRetry() {
        for (focused, selected) in [(false, true), (true, false)] {
            var readback = ReplacementReadback(original: "{gap}", expected: "Filled")
            readback.observe(text: "{gap}", targetIsFocused: focused, selectionMatches: selected)
            for _ in 0..<4 { readback.observe(text: "{gap}", targetIsFocused: true, selectionMatches: true) }
            XCTAssertEqual(readback.outcome, .unconfirmed)
        }
    }

    func testEditorLineEndingNormalizationDoesNotReportFalseFailure() {
        var readback = ReplacementReadback(original: "Before\r\n{gap}\r\nAfter", expected: "Before\r\nA\nB\r\nAfter")
        readback.observe(text: "Before\nA\nB\nAfter", targetIsFocused: true, selectionMatches: false)
        XCTAssertEqual(readback.outcome, .confirmed)
    }

    func testWhitespaceOrSurroundingEditsAreNotAcceptedAsSuccess() {
        for changed in ["Before Filled After ", "Before Filled Changed", "BeforeFilled After"] {
            var readback = ReplacementReadback(original: "Before {gap} After", expected: "Before Filled After")
            readback.observe(text: changed, targetIsFocused: true, selectionMatches: false)
            XCTAssertEqual(readback.outcome, .unconfirmed)
        }
    }

    func testCanonicallyEquivalentTextWithDifferentUTF16OffsetsCannotRetry() {
        var readback = ReplacementReadback(original: "Café {gap}", expected: "Café Filled")
        for _ in 0..<4 { readback.observe(text: "Cafe\u{301} {gap}", targetIsFocused: true, selectionMatches: true) }
        XCTAssertEqual(readback.outcome, .unconfirmed)
        readback.observe(text: "Cafe\u{301} Filled", targetIsFocused: true, selectionMatches: false)
        XCTAssertEqual(readback.outcome, .unconfirmed)
    }
}
