import XCTest
@testable import LacunaCore

final class AccessibleTextMarkersTests: XCTestCase {
    func testNavigatesComposedCharactersUsingExactUTF16Lengths() {
        let text = "prefix 😀 {x}"
        let source = text as NSString
        var navigator = AccessibleTextMarkers(text: text, start: 0, end: source.length)
        var steps = 0
        let opening = source.range(of: "{").location
        let result = navigator.marker(at: opening, move: { position, forward in
            steps += 1
            if forward { return NSMaxRange(source.rangeOfComposedCharacterSequence(at: position)) }
            return source.rangeOfComposedCharacterSequence(at: position - 1).location
        }, string: { start, end in source.substring(with: NSRange(location: start, length: end - start)) })
        XCTAssertEqual(result, opening)
        XCTAssertEqual(steps, 3, "Use the nearer end of the field rather than scan the whole value")
        XCTAssertEqual(navigator.marker(at: opening, move: { _, _ in XCTFail("Cached marker"); return nil },
                                        string: { _, _ in nil }), opening)
    }

    func testRejectsCanonicallyEquivalentButDifferentUTF16Text() {
        var navigator = AccessibleTextMarkers(text: "éab", start: 0, end: 3)
        XCTAssertNil(navigator.marker(at: 1, move: { _, _ in 1 }, string: { _, _ in "e\u{301}" }))
    }

    func testRejectsWrongFieldTextAndEmptySteps() {
        for returned in ["z", ""] {
            var navigator = AccessibleTextMarkers(text: "abcd", start: 0, end: 4)
            XCTAssertNil(navigator.marker(at: 1, move: { _, _ in 1 }, string: { _, _ in returned }))
        }
    }

    func testCannotSplitAnEmojiOrJumpPastRequestedOffset() {
        var navigator = AccessibleTextMarkers(text: "😀abcd", start: 0, end: 6)
        XCTAssertNil(navigator.marker(at: 1, move: { _, _ in 2 }, string: { _, _ in "😀" }))
    }

    func testStepBudgetIsSharedAcrossQueries() {
        let text = String(repeating: "a", count: 100)
        var navigator = AccessibleTextMarkers(text: text, start: 0, end: 100, maximumSteps: 3)
        var steps = 0
        let move: (Int, Bool) -> Int? = { position, forward in
            steps += 1
            return position + (forward ? 1 : -1)
        }
        XCTAssertEqual(navigator.marker(at: 2, move: move, string: { _, _ in "a" }), 2)
        XCTAssertNil(navigator.marker(at: 5, move: move, string: { _, _ in "a" }))
        XCTAssertNil(navigator.marker(at: 6, move: move, string: { _, _ in "a" }))
        XCTAssertEqual(steps, 3)
    }

    func testDeadlineAndInvalidOffsetsDoNotNavigate() {
        var navigator = AccessibleTextMarkers(text: "abcdef", start: 0, end: 6)
        for offset in [-1, 2, 7] {
            XCTAssertNil(navigator.marker(at: offset,
                move: { _, _ in XCTFail("No IPC after deadline or outside field"); return nil },
                string: { _, _ in nil }, shouldContinue: { false }))
        }
    }

    func testEmptyTextAndBoundaryRequestsNeedNoNavigation() {
        var navigator = AccessibleTextMarkers(text: "", start: 0, end: 0)
        XCTAssertEqual(navigator.marker(at: 0, move: { _, _ in XCTFail(); return nil },
                                        string: { _, _ in nil }), 0)
    }
}
