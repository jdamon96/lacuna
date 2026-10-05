import Foundation

/// Identifies one generation request independently of the current caret position.
/// API keys are deliberately not retained. Callers can clear the cache when account
/// credentials change and supply an editor scope to isolate otherwise identical fields.
public struct SuggestionCacheKey: Hashable, Sendable {
    private let fieldText: Data
    private let templateLocation: Int
    private let templateLength: Int
    private let instruction: Data
    private let provider: String
    private let model: String
    private let baseURL: String
    private let editorScope: String?

    public init(text: String, template: BraceTemplate, configuration: LLMConfiguration, editorScope: String? = nil) {
        // Byte equality keeps even canonically equivalent edits distinct, since
        // editor selections and insertion checks use exact UTF-16 coordinates.
        fieldText = Data(text.utf8)
        templateLocation = template.range.location
        templateLength = template.range.length
        instruction = Data(template.instruction.utf8)
        provider = configuration.provider.rawValue
        model = configuration.model
        baseURL = configuration.baseURL
        self.editorScope = editorScope
    }
}

/// A bounded, session-only cache. Reads refresh recency; no content is persisted.
public struct SuggestionCache: Sendable {
    private struct Entry: Sendable {
        let key: SuggestionCacheKey
        let suggestions: [String]
    }

    private let capacity: Int
    private var entries: [Entry] = []

    public init(capacity: Int = 20) {
        self.capacity = max(0, capacity)
    }

    public var count: Int { entries.count }

    public mutating func suggestions(for key: SuggestionCacheKey) -> [String]? {
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.suggestions
    }

    public mutating func store(_ suggestions: [String], for key: SuggestionCacheKey) {
        guard capacity > 0 else { return }
        remove(for: key)
        entries.append(Entry(key: key, suggestions: suggestions))
        if entries.count > capacity { entries.removeFirst() }
    }

    public mutating func remove(for key: SuggestionCacheKey) {
        entries.removeAll { $0.key == key }
    }

    public mutating func clear() {
        entries.removeAll(keepingCapacity: false)
    }
}
