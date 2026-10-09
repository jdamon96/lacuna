import XCTest
@testable import LacunaCore

final class SuggestionRefinementTests: XCTestCase {
    private let options = ["First option", "Second option", "Third option"]

    func testNormalizesFeedbackAndOptionsWithoutReorderingHistory() throws {
        let result = try SuggestionRefinement(previousSuggestions: ["  First option\n", "Second option", "Third option "],
            feedback: ["  Make it formal.\n", "Actually, use a friendly tone.  "])
        XCTAssertEqual(result.previousSuggestions, options)
        XCTAssertEqual(result.feedback, ["Make it formal.", "Actually, use a friendly tone."])
    }

    func testRejectsMissingOrBlankFeedbackWithoutEchoingPrivateText() {
        for feedback in [[], [" \n\t"], ["private phrase", "   "]] {
            XCTAssertThrowsError(try SuggestionRefinement(previousSuggestions: options, feedback: feedback)) {
                XCTAssertEqual($0 as? CompletionError, .emptyRefinementFeedback)
                XCTAssertFalse($0.localizedDescription.contains("private phrase"))
            }
        }
    }

    func testEightRoundsAreAllowedAndNinthIsRejectedWithoutDroppingHistory() throws {
        let feedback = (1...8).map { "Round \($0)" }
        XCTAssertEqual(try SuggestionRefinement(previousSuggestions: options, feedback: feedback).feedback, feedback)
        XCTAssertThrowsError(try SuggestionRefinement(previousSuggestions: options, feedback: feedback + ["Round 9"])) {
            XCTAssertEqual($0 as? CompletionError, .refinementRoundLimit)
            XCTAssertTrue($0.localizedDescription.contains("8"))
        }
    }

    func testFeedbackLimitCountsTotalUTF16AcrossTrimmedRounds() throws {
        let first = String(repeating: "😀", count: 1_500)
        let second = String(repeating: "x", count: 3_000)
        let boundary = try SuggestionRefinement(previousSuggestions: options, feedback: ["  " + first + "\n", second])
        XCTAssertEqual(boundary.feedback.reduce(0) { $0 + $1.utf16.count }, 6_000)
        XCTAssertThrowsError(try SuggestionRefinement(previousSuggestions: options, feedback: [first, second + "x"])) {
            XCTAssertEqual($0 as? CompletionError, .refinementTooLong)
        }
        XCTAssertThrowsError(try SuggestionRefinement(previousSuggestions: options,
            feedback: [String(repeating: "😀", count: 3_001)])) {
            XCTAssertEqual($0 as? CompletionError, .refinementTooLong)
        }
    }

    func testPreviousOptionsMustMatchTheThreeOptionResponseContract() {
        let invalid = [
            [], ["one", "two"], ["one", "two", "three", "four"],
            ["one", "ONE", "three"], ["é", "e\u{301}", "three"],
            ["one", " \n", "three"],
            [String(repeating: "x", count: 12_001), "two", "three"]
        ]
        for previous in invalid {
            XCTAssertThrowsError(try SuggestionRefinement(previousSuggestions: previous, feedback: ["Shorter"])) {
                XCTAssertEqual($0 as? CompletionError, .invalidRefinementOptions)
            }
        }
    }

    func testFeedbackCanReferToOptionNumbersQuotesAndLineBreaksLiterally() throws {
        let feedback = "Use option 2’s tone.\nInclude \"thanks\" and {an example}."
        let result = try SuggestionRefinement(previousSuggestions: options, feedback: [feedback])
        XCTAssertEqual(result.feedback, [feedback])
    }
}
