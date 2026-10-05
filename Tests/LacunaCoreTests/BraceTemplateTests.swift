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
