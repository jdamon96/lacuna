import XCTest
@testable import LacunaCore

final class TemplateSequenceTests: XCTestCase {
    func testStartsWithEarliestTemplateIndependentOfCaret() throws {
        let text = "Hello {greeting}, then {a sign-off}."
        let caretAtEnd = NSRange(location: text.utf16.count, length: 0)
        XCTAssertEqual(BraceTemplate.find(in: text, selection: caretAtEnd)?.instruction, "a sign-off")
        let sequence = TemplateSequence(text: text)
        XCTAssertEqual(sequence.current(in: text)?.instruction, "greeting")
        XCTAssertEqual(sequence.totalCount, 2)
        XCTAssertEqual(sequence.completedCount, 0)
        XCTAssertFalse(sequence.isComplete)
    }

    func testAllPreservesParserRulesAndDuplicatesInTextOrder() {
        let text = #"\{escaped} { first } ${variable} {outer {inner}} {} {first} {{double}} {last} {unfinished"#
        let templates = BraceTemplate.all(in: text)
        XCTAssertEqual(templates.map(\.instruction), ["first", "first", "last"])
        XCTAssertEqual(templates.map { (text as NSString).substring(with: $0.range) }, ["{ first }", "{first}", "{last}"])
        XCTAssertEqual(templates.map(\.range.location), templates.map(\.range.location).sorted())
        XCTAssertEqual(TemplateSequence(text: text).totalCount, 3)
    }

    func testRebasesRangesInUTF16AndUsesEachAcceptedReplacementAsContext() throws {
        var text = "👩🏽‍💻 {first} e\u{301} {second} and {third}"
        var sequence = TemplateSequence(text: text)

        let first = try XCTUnwrap(sequence.current(in: text))
        let replacement = "Welcome, 👨‍👩‍👧‍👦!\n"
        text = (text as NSString).replacingCharacters(in: first.range, with: replacement)
        XCTAssertTrue(sequence.advance(afterReplacingWith: replacement, in: text))
        XCTAssertEqual(sequence.completedCount, 1)
        let second = try XCTUnwrap(sequence.current(in: text))
        XCTAssertEqual(second.range, (text as NSString).range(of: "{second}"))
        XCTAssertEqual(second.contextFragments(in: text).before, "👩🏽‍💻 Welcome, 👨‍👩‍👧‍👦!\n e\u{301} ")
        XCTAssertEqual(second.contextFragments(in: text).after, " and {third}")

        text = (text as NSString).replacingCharacters(in: second.range, with: "é")
        XCTAssertTrue(sequence.advance(afterReplacingWith: "é", in: text))
        let third = try XCTUnwrap(sequence.current(in: text))
        XCTAssertEqual(third.range, (text as NSString).range(of: "{third}"))
        XCTAssertEqual(third.contextFragments(in: text).before, "👩🏽‍💻 Welcome, 👨‍👩‍👧‍👦!\n e\u{301} é and ")

        text = (text as NSString).replacingCharacters(in: third.range, with: "Goodbye 👋")
        XCTAssertTrue(sequence.advance(afterReplacingWith: "Goodbye 👋", in: text))
        XCTAssertEqual(sequence.completedCount, 3)
        XCTAssertTrue(sequence.isComplete)
        XCTAssertNil(sequence.current)
        XCTAssertTrue(sequence.isValid(in: text))
        XCTAssertFalse(sequence.advance(afterReplacingWith: "again", in: text))
    }

    func testGeneratedBracesAreNeverQueuedOrUsedToReparseOriginals() throws {
        var text = "{same}{same} then {last}"
        var sequence = TemplateSequence(text: text)
        let replacements = ["{generated} {same} {", "\\", "${another}"]
        for (index, replacement) in replacements.enumerated() {
            let current = try XCTUnwrap(sequence.current(in: text))
            XCTAssertEqual(current.instruction, index < 2 ? "same" : "last")
            text = (text as NSString).replacingCharacters(in: current.range, with: replacement)
            XCTAssertTrue(sequence.advance(afterReplacingWith: replacement, in: text))
            XCTAssertEqual(sequence.completedCount, index + 1)
            XCTAssertEqual(sequence.totalCount, 3)
        }
        XCTAssertEqual(text, "{generated} {same} {\\ then ${another}")
        XCTAssertTrue(sequence.isComplete)
        XCTAssertNil(sequence.current(in: text))
    }

    func testCompletionRequestsFollowOriginalPhrasesWithUpdatedExactContext() throws {
        for provider in LLMProvider.allCases {
            var text = "👩🏽‍💻 To Alex: {a greeting}\nFor Mei: {a sign-off}\nEnd: {a sign-off}"
            var sequence = TemplateSequence(text: text)
            let configuration = LLMConfiguration(provider: provider, model: "test-model", apiKey: "test-key")

            func requestContext() throws -> [String: String] {
                let template = try XCTUnwrap(sequence.current(in: text))
                let request = try CompletionClient().makeRequest(for: template, in: text, configuration: configuration)
                let data = try XCTUnwrap(request.httpBody)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let prompt = provider == .openAI
                    ? body["input"] as? String
                    : (body["messages"] as? [[String: String]])?.last?["content"]
                return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(prompt).utf8)) as? [String: String])
            }

            // The last phrase would be nearest an end-of-field caret, but this
            // pass must send only the earliest original phrase first.
            XCTAssertEqual(BraceTemplate.find(in: text, selection: NSRange(location: text.utf16.count, length: 0))?.instruction, "a sign-off")
            XCTAssertEqual(try requestContext(), [
                "instruction": "a greeting",
                "text_before": "👩🏽‍💻 To Alex: ",
                "text_after": "\nFor Mei: {a sign-off}\nEnd: {a sign-off}"
            ])

            let first = try XCTUnwrap(sequence.current(in: text))
            let greeting = "Hello {friend} 👋"
            text = (text as NSString).replacingCharacters(in: first.range, with: greeting)
            XCTAssertTrue(sequence.advance(afterReplacingWith: greeting, in: text))
            let secondContext = try requestContext()
            XCTAssertEqual(secondContext, [
                "instruction": "a sign-off",
                "text_before": "👩🏽‍💻 To Alex: Hello {friend} 👋\nFor Mei: ",
                "text_after": "\nEnd: {a sign-off}"
            ])
            // Regenerating the current phrase leaves its target and context intact.
            XCTAssertEqual(try requestContext(), secondContext)
            XCTAssertEqual(sequence.completedCount, 1)

            let second = try XCTUnwrap(sequence.current(in: text))
            let signOff = "Warmly, Jose\u{301}"
            text = (text as NSString).replacingCharacters(in: second.range, with: signOff)
            XCTAssertTrue(sequence.advance(afterReplacingWith: signOff, in: text))
            let finalContext = try requestContext()
            XCTAssertEqual(finalContext["instruction"], "a sign-off")
            XCTAssertEqual(finalContext["text_after"], "")
            let expectedBefore = "👩🏽‍💻 To Alex: Hello {friend} 👋\nFor Mei: Warmly, Jose\u{301}\nEnd: "
            XCTAssertTrue(try XCTUnwrap(finalContext["text_before"]).utf16.elementsEqual(expectedBefore.utf16))
            XCTAssertEqual(sequence.completedCount, 2)
            XCTAssertEqual(sequence.totalCount, 3)

            let final = try XCTUnwrap(sequence.current(in: text))
            text = (text as NSString).replacingCharacters(in: final.range, with: "Take care")
            XCTAssertTrue(sequence.advance(afterReplacingWith: "Take care", in: text))
            XCTAssertTrue(sequence.isComplete)
            XCTAssertNil(sequence.current(in: text))
            XCTAssertTrue(text.contains("{friend}"))
        }
    }

    func testOnlyExactReplacementAllowsAdvancement() throws {
        let original = "Before {first}, after {second}."
        let replacement = "accepted"
        let expected = "Before accepted, after {second}."
        for actual in [original, "Before accepted, after edited.", "Before accepted, after {second}.!", "Before acceptedaccepted, after {second}."] {
            var sequence = TemplateSequence(text: original)
            XCTAssertFalse(sequence.advance(afterReplacingWith: replacement, in: actual))
            XCTAssertEqual(sequence.completedCount, 0)
            XCTAssertFalse(sequence.isComplete)
            XCTAssertEqual(sequence.current?.instruction, "first")
            XCTAssertTrue(sequence.isValid(in: original))
            XCTAssertFalse(sequence.isValid(in: expected))
            XCTAssertEqual(sequence.totalCount, 2)
        }
    }

    func testExternalEditsInvalidateSnapshotAndPreventFollowingRequest() {
        let original = "{first} and {second}"
        let sequence = TemplateSequence(text: original)
        for edited in ["x" + original, "{first} and {changed}", "{second} and {first}", "", "{first} and {second}\n"] {
            XCTAssertFalse(sequence.isValid(in: edited))
            XCTAssertNil(sequence.current(in: edited))
        }
    }

    func testCanonicalEquivalentTextCannotSilentlyChangeUTF16Offsets() {
        let original = "café {first} {second}"
        let sequence = TemplateSequence(text: original)
        XCTAssertFalse(sequence.isValid(in: "cafe\u{301} {first} {second}"))
        var afterReplacement = sequence
        XCTAssertFalse(afterReplacement.advance(afterReplacingWith: "é", in: "café e\u{301} {second}"))
        XCTAssertEqual(afterReplacement.completedCount, 0)
        XCTAssertTrue(afterReplacement.isValid(in: original))
    }

    func testEmptySequenceAndShorterOrIdenticalReplacement() throws {
        for text in ["plain text", "{} ${variable} {outer {nested}}", "{unfinished"] {
            let empty = TemplateSequence(text: text)
            XCTAssertEqual(empty.totalCount, 0)
            XCTAssertTrue(empty.isComplete)
            XCTAssertNil(empty.current(in: text))
        }
        var text = "{first}{second}"
        var sequence = TemplateSequence(text: text)
        text = "{second}"
        XCTAssertTrue(sequence.advance(afterReplacingWith: "", in: text))
        XCTAssertEqual(sequence.current?.range.location, 0)
        XCTAssertTrue(sequence.advance(afterReplacingWith: "{second}", in: text))
        XCTAssertTrue(sequence.isComplete)
        XCTAssertNil(sequence.current)
    }
}
