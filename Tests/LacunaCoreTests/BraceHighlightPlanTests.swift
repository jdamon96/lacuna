import XCTest
@testable import LacunaCore

final class BraceHighlightPlanTests: XCTestCase {
    func testEveryCompletePhraseIsMarkedRegardlessOfCaretPosition() {
        let text = "👋 {a greeting}\nFor Mei: {a sign-off}\nEnd: {a sign-off}"
        let expected = BraceTemplate.all(in: text).map(\.range)
        for caret in [0, text.utf16.count] {
            let plan = BraceHighlightPlan(text: text, selection: NSRange(location: caret, length: 0))
            XCTAssertEqual(plan.items.map(\.range), expected)
            XCTAssertEqual(plan.items.map(\.style), [.complete, .complete, .complete])
        }
    }

    func testOpeningCueDoesNotReplaceExistingCompleteHighlights() {
        let text = "{a greeting}, {a sign-off}\n{"
        let plan = BraceHighlightPlan(text: text, selection: NSRange(location: text.utf16.count, length: 0))
        XCTAssertEqual(plan.items.map(\.style), [.opening, .complete, .complete])
        XCTAssertEqual(plan.items.first?.range, NSRange(location: text.utf16.count - 1, length: 1))
        XCTAssertEqual(plan.items.dropFirst().map(\.range), BraceTemplate.all(in: text).map(\.range))
    }

    func testCompletePhrasesRemainVisibleWithoutAccessibleSelection() {
        let text = "{first} / {second} / {"
        let plan = BraceHighlightPlan(text: text, selection: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(plan.items.map(\.range), BraceTemplate.all(in: text).map(\.range))
        XCTAssertEqual(plan.items.map(\.style), [.complete, .complete])
        XCTAssertEqual(plan.phraseCount, 2)
    }

    func testCurrentPhraseGetsPriorityWithoutHidingOtherPhrases() {
        let text = "{first} / {second} / {third}"
        let templates = BraceTemplate.all(in: text)
        let plan = BraceHighlightPlan(text: text, selection: NSRange(location: 0, length: 0), activeRange: templates[1].range)
        XCTAssertEqual(plan.items.map(\.range), [templates[1].range, templates[0].range, templates[2].range])
        XCTAssertEqual(plan.items.map(\.style), [.active, .complete, .complete])
    }

    func testActiveCueSurvivesUnbalancedBracesInPreviouslyAcceptedWording() {
        let text = "Accepted {literal then {next instruction}"
        let range = (text as NSString).range(of: "{next instruction}")
        let plan = BraceHighlightPlan(text: text, selection: NSRange(location: text.utf16.count, length: 0), activeRange: range)
        XCTAssertEqual(plan.items.map(\.range), [range])
        XCTAssertEqual(plan.items.map(\.style), [.active])
        XCTAssertEqual(plan.phraseCount, 1)
    }

    func testDisabledBackgroundHighlightsRetainOnlyTheActiveCue() {
        let text = "{first} / {second}"
        let active = BraceTemplate.all(in: text)[1].range
        let plan = BraceHighlightPlan(text: text, selection: NSRange(location: 0, length: 0), activeRange: active, showInactive: false)
        XCTAssertEqual(plan.items.map(\.range), [active])
        XCTAssertEqual(plan.items.map(\.style), [.active])
        XCTAssertTrue(BraceHighlightPlan(text: text, selection: NSRange(location: 0, length: 0), showInactive: false).items.isEmpty)
    }

    func testBoundsGeometryWorkAndPreservesPriorityForLargeInputs() {
        let text = (0..<200).map { "{phrase \($0)}" }.joined(separator: " ") + " {"
        let active = BraceTemplate.all(in: text)[150].range
        let plan = BraceHighlightPlan(text: text, selection: NSRange(location: text.utf16.count, length: 0), activeRange: active, maximumCount: 4)
        XCTAssertEqual(plan.items.count, 4)
        XCTAssertEqual(plan.items[0].range, active)
        XCTAssertEqual(plan.items.map(\.style), [.active, .opening, .complete, .complete])
        XCTAssertTrue(BraceHighlightPlan(text: text, selection: NSRange(location: 0, length: 0), maximumCount: 0).items.isEmpty)
    }

    func testInvalidAndEscapedExpressionsAreNotMarked() {
        let text = #"\{escaped} ${variable} {nested {inner}} {} {real}"#
        let invalid = (text as NSString).range(of: "{nested {inner}}")
        let plan = BraceHighlightPlan(text: text, selection: NSRange(location: 0, length: 0), activeRange: invalid)
        XCTAssertEqual(plan.items.map(\.range), [(text as NSString).range(of: "{real}")])
        XCTAssertEqual(plan.items.map(\.style), [.complete])
    }
}
