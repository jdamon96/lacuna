import XCTest
@testable import LacunaCore

final class SuggestionCacheTests: XCTestCase {
    private let candidates = ["Welcome!", "Hello there.", "Glad you’re here."]
    private let text = "Hello {a greeting}, friend."
    private let configuration = LLMConfiguration(provider: .openAI, model: "test-model", apiKey: "test-key")

    func testReopeningSameTemplateWithDifferentCaretReturnsOriginalCandidates() throws {
        let first = try XCTUnwrap(BraceTemplate.find(in: text, selection: NSRange(location: 7, length: 0)))
        let reopened = try XCTUnwrap(BraceTemplate.find(in: text, selection: NSRange(location: 12, length: 0)))
        var cache = SuggestionCache()
        cache.store(candidates, for: SuggestionCacheKey(text: text, template: first, configuration: configuration))
        XCTAssertEqual(cache.suggestions(for: SuggestionCacheKey(text: text, template: reopened, configuration: configuration)), candidates)
        XCTAssertEqual(cache.count, 1)
    }

    func testContextTemplateProviderModelAndEndpointChangesMiss() throws {
        let template = try XCTUnwrap(BraceTemplate.find(in: text, selection: NSRange(location: 7, length: 0)))
        let original = SuggestionCacheKey(text: text, template: template, configuration: configuration)
        var cache = SuggestionCache()
        cache.store(candidates, for: original)
        let changedKeys = [
            SuggestionCacheKey(text: text + " More context.", template: template, configuration: configuration),
            SuggestionCacheKey(text: text, template: BraceTemplate(range: NSRange(location: template.range.location + 1, length: template.range.length), instruction: template.instruction), configuration: configuration),
            SuggestionCacheKey(text: text, template: BraceTemplate(range: NSRange(location: template.range.location, length: template.range.length + 1), instruction: template.instruction), configuration: configuration),
            SuggestionCacheKey(text: text, template: BraceTemplate(range: template.range, instruction: "a farewell"), configuration: configuration),
            SuggestionCacheKey(text: text, template: template, configuration: LLMConfiguration(provider: .anthropic, baseURL: configuration.baseURL, model: configuration.model)),
            SuggestionCacheKey(text: text, template: template, configuration: LLMConfiguration(provider: .openAI, model: "different-model")),
            SuggestionCacheKey(text: text, template: template, configuration: LLMConfiguration(provider: .openAI, baseURL: "https://api.openai.com/other", model: configuration.model))
        ]
        for key in changedKeys { XCTAssertNil(cache.suggestions(for: key)) }
        XCTAssertEqual(cache.suggestions(for: original), candidates)
    }

    func testExactUnicodeFieldEditsMissAndIdenticalInstructionsInDifferentLocationsStaySeparate() throws {
        let text = "{greeting} then {greeting} café"
        let first = try XCTUnwrap(BraceTemplate.find(in: text, selection: NSRange(location: 2, length: 0)))
        let second = try XCTUnwrap(BraceTemplate.find(in: text, selection: NSRange(location: 18, length: 0)))
        var cache = SuggestionCache()
        cache.store(candidates, for: SuggestionCacheKey(text: text, template: first, configuration: configuration))
        XCTAssertNil(cache.suggestions(for: SuggestionCacheKey(text: text, template: second, configuration: configuration)))
        // Swift String equality considers these equivalent, but the actual field has changed.
        let edited = "{greeting} then {greeting} cafe\u{301}"
        XCTAssertEqual(text, edited)
        XCTAssertNil(cache.suggestions(for: SuggestionCacheKey(text: edited, template: first, configuration: configuration)))
    }

    func testEditorScopeCanIsolateFieldsAndAPIKeysAreNotPartOfIdentity() throws {
        let template = try XCTUnwrap(BraceTemplate.find(in: text, selection: NSRange(location: 7, length: 0)))
        var cache = SuggestionCache()
        let scoped = SuggestionCacheKey(text: text, template: template, configuration: configuration, editorScope: "editor-a")
        cache.store(candidates, for: scoped)
        XCTAssertNil(cache.suggestions(for: SuggestionCacheKey(text: text, template: template, configuration: configuration, editorScope: "editor-b")))
        XCTAssertNil(cache.suggestions(for: SuggestionCacheKey(text: text, template: template, configuration: configuration)))
        var rotated = configuration
        rotated.apiKey = "a-new-key"
        XCTAssertEqual(scoped, SuggestionCacheKey(text: text, template: template, configuration: rotated, editorScope: "editor-a"))
    }

    func testReadsRefreshRecencyAndEvictionKeepsMostRecentlyUsedEntries() throws {
        var cache = SuggestionCache(capacity: 2)
        let first = try key("First {greeting}")
        let second = try key("Second {greeting}")
        let third = try key("Third {greeting}")
        cache.store(candidates, for: first)
        cache.store(candidates, for: second)
        XCTAssertEqual(cache.suggestions(for: first), candidates)
        cache.store(candidates, for: third)
        XCTAssertNil(cache.suggestions(for: second))
        XCTAssertEqual(cache.suggestions(for: first), candidates)
        XCTAssertEqual(cache.suggestions(for: third), candidates)
        XCTAssertEqual(cache.count, 2)
    }

    func testReplacingRemovingAndClearingEntries() throws {
        var cache = SuggestionCache(capacity: 2)
        let first = try key("First {greeting}")
        let second = try key("Second {greeting}")
        let third = try key("Third {greeting}")
        let replacement = ["A", "B", "C"]
        cache.store(candidates, for: first)
        cache.store(candidates, for: second)
        cache.store(replacement, for: first)
        XCTAssertEqual(cache.count, 2)
        cache.store(candidates, for: third)
        XCTAssertNil(cache.suggestions(for: second))
        XCTAssertEqual(cache.suggestions(for: first), replacement)
        cache.remove(for: first)
        XCTAssertNil(cache.suggestions(for: first))
        XCTAssertEqual(cache.count, 1)
        cache.clear()
        XCTAssertEqual(cache.count, 0)
        XCTAssertNil(cache.suggestions(for: third))
    }

    func testDefaultCapacityIsBoundedAndNonpositiveCapacityDisablesCaching() throws {
        var cache = SuggestionCache()
        for index in 0..<21 { cache.store(candidates, for: try key("\(index) {greeting}")) }
        XCTAssertEqual(cache.count, 20)
        XCTAssertNil(cache.suggestions(for: try key("0 {greeting}")))
        XCTAssertEqual(cache.suggestions(for: try key("20 {greeting}")), candidates)
        for capacity in [0, -1] {
            var disabled = SuggestionCache(capacity: capacity)
            let key = try key(text)
            disabled.store(candidates, for: key)
            XCTAssertNil(disabled.suggestions(for: key))
            XCTAssertEqual(disabled.count, 0)
        }
    }

    private func key(_ text: String) throws -> SuggestionCacheKey {
        let template = try XCTUnwrap(BraceTemplate.find(in: text, selection: NSRange(location: text.utf16.count, length: 0)))
        return SuggestionCacheKey(text: text, template: template, configuration: configuration)
    }
}
