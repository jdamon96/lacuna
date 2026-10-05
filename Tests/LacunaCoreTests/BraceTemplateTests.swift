import XCTest
@testable import LacunaCore

final class BraceTemplateTests: XCTestCase {
    func testFindsInstructionAndUTF16Range() throws {
        let text = "👩🏽‍💻 Hello { write a friendly greeting 👋 }!"
        let range = (text as NSString).range(of: "{ write a friendly greeting 👋 }")
        let result = try XCTUnwrap(BraceTemplate.find(in: text, selection: NSRange(location: range.location + 4, length: 0)))
        XCTAssertEqual(result.range, range)
        XCTAssertEqual(result.instruction, "write a friendly greeting 👋")
        XCTAssertEqual((text as NSString).replacingCharacters(in: result.range, with: "Welcome"), "👩🏽‍💻 Hello Welcome!")
    }

    func testChoosesEnclosingThenNearestWithPreviousTiePreference() {
        let text = "{first}    {second}"
        XCTAssertEqual(BraceTemplate.find(in: text, selection: NSRange(location: 4, length: 0))?.instruction, "first")
        XCTAssertEqual(BraceTemplate.find(in: text, selection: NSRange(location: 9, length: 0))?.instruction, "first")
        XCTAssertEqual(BraceTemplate.find(in: text, selection: NSRange(location: 10, length: 0))?.instruction, "second")
        XCTAssertEqual(BraceTemplate.find(in: text, selection: NSRange(location: 11, length: 8))?.instruction, "second")
    }

    func testSkipsEscapedNestedEmptyDollarAndIncompleteExpressions() {
        for text in ["\\{escaped}", "{outer {inner}}", "{{double}}", "{}", "{ \n }", "${variable}", "{unfinished", "closing}"] {
            XCTAssertNil(BraceTemplate.find(in: text, selection: NSRange(location: text.utf16.count, length: 0)), text)
        }
        let text = "\\\\{allowed} {nested {skip}} ${skip} {final}"
        XCTAssertEqual(BraceTemplate.find(in: text, selection: NSRange(location: 0, length: 0))?.instruction, "allowed")
        XCTAssertEqual(BraceTemplate.find(in: text, selection: NSRange(location: text.utf16.count, length: 0))?.instruction, "final")
    }

    func testEscapedClosingBraceRemainsInsideInstruction() {
        let text = #"{write a \} symbol}"#
        XCTAssertEqual(BraceTemplate.find(in: text, selection: NSRange(location: 3, length: 0))?.instruction, #"write a \} symbol"#)
    }

    func testInvalidSelectionsDoNotOverflowOrSelect() {
        let text = "{hello}"
        for selection in [NSRange(location: NSNotFound, length: 0), NSRange(location: 0, length: Int.max), NSRange(location: 8, length: 0), NSRange(location: -1, length: 0)] {
            XCTAssertNil(BraceTemplate.find(in: text, selection: selection))
        }
    }

    func testPendingOpeningTracksTypingClosingAndBackspacing() {
        let opening = NSRange(location: 6, length: 1)
        for text in ["Hello {", "Hello {write a welcome", "Hello {write a welcome}", "Hello {write a welcome", "Hello {", "Hello "] {
            let result = BraceTemplate.pendingOpening(in: text, selection: NSRange(location: text.utf16.count, length: 0))
            XCTAssertEqual(result, text.contains("{") && !text.contains("}") ? opening : nil, text)
        }
        XCTAssertEqual(BraceTemplate.pendingOpening(in: "{", selection: NSRange(location: 1, length: 0)), NSRange(location: 0, length: 1))
        XCTAssertEqual(BraceTemplate.pendingOpening(in: "{ \n", selection: NSRange(location: 3, length: 0)), NSRange(location: 0, length: 1))
    }

    func testPendingOpeningHonorsCaretBoundariesAndCollapsedSelection() {
        let text = "A {instruction"
        for location in [0, 1, 2] {
            XCTAssertNil(BraceTemplate.pendingOpening(in: text, selection: NSRange(location: location, length: 0)))
        }
        for location in [3, 7, text.utf16.count] {
            XCTAssertEqual(BraceTemplate.pendingOpening(in: text, selection: NSRange(location: location, length: 0)), NSRange(location: 2, length: 1))
        }
        for selection in [NSRange(location: 2, length: 1), NSRange(location: 3, length: 4), NSRange(location: NSNotFound, length: 0), NSRange(location: 0, length: Int.max), NSRange(location: Int.max - 1, length: 0), NSRange(location: -1, length: 0), NSRange(location: 3, length: -1)] {
            XCTAssertNil(BraceTemplate.pendingOpening(in: text, selection: selection))
        }
        // A complete expression is never pending, including when editing before its closing brace.
        for location in [1, 4, 6, 7] {
            XCTAssertNil(BraceTemplate.pendingOpening(in: "{hello}", selection: NSRange(location: location, length: 0)))
        }
    }

    func testPendingOpeningIgnoresEscapedDollarAndNestedExpressions() {
        for text in [#"\{"#, #"\{escaped"#, "${", "${variable", "{{", "{{double}", "{outer {inner", "{outer {inner}", "{outer {inner} more", "closing}"] {
            XCTAssertNil(BraceTemplate.pendingOpening(in: text, selection: NSRange(location: text.utf16.count, length: 0)), text)
        }
        // Syntax after the caret must not briefly activate an invalid expression.
        for text in ["{{double", "{outer {inner", "{outer {inner}", "{outer {inner} more"] {
            XCTAssertNil(BraceTemplate.pendingOpening(in: text, selection: NSRange(location: 1, length: 0)), text)
        }
        let evenBackslashes = #"\\{allowed"#
        XCTAssertEqual(BraceTemplate.pendingOpening(in: evenBackslashes, selection: NSRange(location: evenBackslashes.utf16.count, length: 0)), NSRange(location: 2, length: 1))
        for text in [#"{write a \} symbol"#, #"{write a \{ symbol"#] {
            XCTAssertEqual(BraceTemplate.pendingOpening(in: text, selection: NSRange(location: text.utf16.count, length: 0)), NSRange(location: 0, length: 1))
        }
    }

    func testPendingOpeningFindsNewExpressionAfterCompletedOrInvalidOnes() {
        for prefix in ["{finished} then ", "{outer {inner}} then ", "${variable} then ", #"\{escaped} then "#] {
            let text = prefix + "{new instruction"
            XCTAssertEqual(BraceTemplate.pendingOpening(in: text, selection: NSRange(location: text.utf16.count, length: 0)), NSRange(location: prefix.utf16.count, length: 1))
            XCTAssertNil(BraceTemplate.pendingOpening(in: text, selection: NSRange(location: 1, length: 0)))
        }
        let text = "{finished} {new"
        let caret = NSRange(location: text.utf16.count, length: 0)
        XCTAssertEqual(BraceTemplate.find(in: text, selection: caret)?.instruction, "finished")
        XCTAssertEqual(BraceTemplate.pendingOpening(in: text, selection: caret), NSRange(location: 11, length: 1))
    }

    func testPendingOpeningUsesUTF16CoordinatesAndRejectsSplitSurrogates() {
        let prefix = "👩🏽‍💻 e\u{301} "
        let text = prefix + "{write 👋"
        let expected = NSRange(location: prefix.utf16.count, length: 1)
        XCTAssertEqual(BraceTemplate.pendingOpening(in: text, selection: NSRange(location: text.utf16.count, length: 0)), expected)
        XCTAssertEqual(BraceTemplate.pendingOpening(in: text, selection: NSRange(location: prefix.utf16.count + 1, length: 0)), expected)
        XCTAssertNil(BraceTemplate.pendingOpening(in: text, selection: NSRange(location: text.utf16.count - 1, length: 0)))
        XCTAssertNil(BraceTemplate.pendingOpening(in: text, selection: NSRange(location: text.utf16.count + 1, length: 0)))
    }

    func testContextIsBoundedAndKeepsComposedCharacters() throws {
        let prefix = String(repeating: "👨‍👩‍👧‍👦e\u{301}", count: 100)
        let text = prefix + "{write something}" + prefix
        let result = try XCTUnwrap(BraceTemplate.find(in: text, selection: NSRange(location: prefix.utf16.count, length: 0)))
        for limit in [20, 40, 60, 100, 999] {
            let context = result.context(in: text, limit: limit)
            XCTAssertLessThanOrEqual(context.utf16.count, limit)
            XCTAssertTrue(context.contains("{write something}"))
            XCTAssertFalse(context.contains("�"))
            XCTAssertFalse(context.hasPrefix("\u{301}"))
            XCTAssertFalse(context.hasPrefix("\u{200D}"))
            XCTAssertFalse(context.hasSuffix("\u{200D}"))
        }
    }

    func testContextUsesAvailableSpaceAtBeginningAndEnd() throws {
        for text in ["{x}" + String(repeating: "a", count: 100), String(repeating: "a", count: 100) + "{x}"] {
            let template = try XCTUnwrap(BraceTemplate.find(in: text, selection: NSRange(location: 0, length: 0)))
            XCTAssertEqual(template.context(in: text, limit: 20).utf16.count, 20)
            XCTAssertEqual(template.context(in: text, limit: 0), "{x}")
        }
    }
}
