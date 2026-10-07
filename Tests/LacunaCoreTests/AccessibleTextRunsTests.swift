import XCTest
import CoreGraphics
@testable import LacunaCore

final class AccessibleTextRunsTests: XCTestCase {
    func testRichEditorWithUnsupportedParentBoundsUsesMappedStaticTextRuns() {
        let text = "Before {warm sign-off} after"
        let target = (text as NSString).range(of: "{warm sign-off}")
        let unsupportedParent = HighlightLineGeometry.rectangles(in: text, range: target,
            lineRange: { _ in nil }, bounds: { _ in nil })
        XCTAssertTrue(unsupportedParent.isEmpty)

        var mapping = AccessibleTextRuns(text: text)
        let children = ["Before ", "{warm ", "sign-off}", " after"]
        let runs = children.map { (text: $0, range: mapping.append($0)!) }
        XCTAssertTrue(mapping.isComplete)
        let rectangles = runs.flatMap { run -> [CGRect] in
            let overlap = NSIntersectionRange(target, run.range)
            guard overlap.length > 0 else { return [] }
            let local = NSRange(location: overlap.location - run.range.location, length: overlap.length)
            return HighlightLineGeometry.rectangles(in: run.text, range: local,
                lineRange: { _ in nil }, bounds: { range in
                    CGRect(x: 100 + (run.range.location + range.location) * 9, y: 200,
                           width: range.length * 9, height: 18)
                })
        }
        XCTAssertEqual(rectangles.count, 2)
        XCTAssertEqual(rectangles.reduce(CGRect.null) { $0.union($1) },
                       CGRect(x: 100 + target.location * 9, y: 200, width: target.length * 9, height: 18))
    }

    func testContenteditableSpansMapAcrossWhitespaceAndParagraphBreaks() {
        var mapping = AccessibleTextRuns(text: "Hello {a warm\n sign-off}\n")
        XCTAssertEqual(mapping.append("Hello "), NSRange(location: 0, length: 6))
        XCTAssertEqual(mapping.append("{a warm"), NSRange(location: 6, length: 7))
        XCTAssertEqual(mapping.append("sign-off}"), NSRange(location: 15, length: 9))
        XCTAssertTrue(mapping.isComplete)
    }

    func testDuplicateTextMustAccountForEveryOccurrence() {
        var mapping = AccessibleTextRuns(text: "{hello} {hello}")
        XCTAssertEqual(mapping.append("{hello}"), NSRange(location: 0, length: 7))
        XCTAssertFalse(mapping.isComplete, "One descendant cannot stand in for two identical phrases")
        XCTAssertEqual(mapping.append("{hello}"), NSRange(location: 8, length: 7))
        XCTAssertTrue(mapping.isComplete)
    }

    func testMissingOrReorderedNonwhitespaceTextIsRejectedWithoutSearching() {
        var missing = AccessibleTextRuns(text: "first {hello}")
        XCTAssertNil(missing.append("{hello}"))
        XCTAssertFalse(missing.isComplete)
        XCTAssertNil(missing.append("first {hello}"), "A failed mapping cannot resume at a later match")
        var reordered = AccessibleTextRuns(text: "one two")
        XCTAssertNil(reordered.append("two"))
    }

    func testUTF16OffsetsPreserveEmojiAndExactUnicodeRepresentation() {
        var mapping = AccessibleTextRuns(text: "🙂 {e\u{301}}")
        XCTAssertEqual(mapping.append("🙂"), NSRange(location: 0, length: 2))
        XCTAssertEqual(mapping.append("{e\u{301}}"), NSRange(location: 3, length: 4))
        XCTAssertTrue(mapping.isComplete)
        var normalized = AccessibleTextRuns(text: "{e\u{301}}")
        XCTAssertNil(normalized.append("{é}"), "Canonically equivalent strings can have different AX offsets")
    }

    func testEmptyRunsDoNotConsumeWhitespaceOrCompleteMissingText() {
        var mapping = AccessibleTextRuns(text: "  {hello}")
        XCTAssertEqual(mapping.append(""), NSRange(location: 0, length: 0))
        XCTAssertFalse(mapping.isComplete)
        XCTAssertEqual(mapping.append("{hello}"), NSRange(location: 2, length: 7))
        XCTAssertTrue(mapping.isComplete)
    }

    func testLongWhitespacePrefixesMatchWithoutRepeatedFullComparisons() {
        let parentPrefix = String(repeating: " ", count: 40_000)
        let childPrefix = String(repeating: " ", count: 20_000)
        var matching = AccessibleTextRuns(text: parentPrefix + "x")
        XCTAssertEqual(matching.append(childPrefix + "x"), NSRange(location: 20_000, length: 20_001))
        XCTAssertTrue(matching.isComplete)

        var mismatched = AccessibleTextRuns(text: parentPrefix + "x")
        XCTAssertNil(mismatched.append(childPrefix + "y"))
        XCTAssertFalse(mismatched.isComplete)
    }

    func testWhitespaceSearchCannotSkipAnEarlierNonwhitespaceUnit() {
        var mapping = AccessibleTextRuns(text: " \twrong \t{hello}")
        XCTAssertNil(mapping.append(" \t{hello}"))
        XCTAssertFalse(mapping.isComplete)

        var whitespaceOnly = AccessibleTextRuns(text: " \t \t{hello}")
        XCTAssertEqual(whitespaceOnly.append("\t "), NSRange(location: 1, length: 2))
        XCTAssertEqual(whitespaceOnly.append("{hello}"), NSRange(location: 4, length: 7))
        XCTAssertTrue(whitespaceOnly.isComplete)
    }

    func testOversizedParentIsRejectedWithoutAcceptingItsTruncatedPrefix() {
        let limit = 128 * 1_024
        var oversized = AccessibleTextRuns(text: "{hello}" + String(repeating: " ", count: limit))
        XCTAssertNil(oversized.append("{hello}"))
        XCTAssertFalse(oversized.isComplete)

        let atLimit = String(repeating: " ", count: limit - 7) + "{hello}"
        var allowed = AccessibleTextRuns(text: atLimit)
        XCTAssertEqual(allowed.append("{hello}"), NSRange(location: limit - 7, length: 7))
        XCTAssertTrue(allowed.isComplete)
    }

    func testDescendantLongerThanRemainingParentIsRejected() {
        var mapping = AccessibleTextRuns(text: "prefix {hello}")
        XCTAssertEqual(mapping.append("prefix "), NSRange(location: 0, length: 7))
        XCTAssertNil(mapping.append("{hello}" + String(repeating: " ", count: 128 * 1_024)))
        XCTAssertFalse(mapping.isComplete)
        XCTAssertNil(mapping.append("{hello}"), "An oversized descendant cannot resume matching")
    }
}
