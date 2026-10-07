import Foundation

/// A single pass over the complete templates present when the user starts filling.
/// Accepted text is context for later requests; any braces it contains are never
/// added to this pass. All positions and equality checks use exact UTF-16 units.
public struct TemplateSequence: Sendable {
    public let totalCount: Int
    public private(set) var completedCount = 0

    private var expectedText: String
    private var templates: [BraceTemplate]

    public init(text: String) {
        expectedText = text
        templates = BraceTemplate.all(in: text)
        totalCount = templates.count
    }

    /// The next original template, with its range rebased after accepted replacements.
    /// Validate a fresh editor snapshot with `current(in:)` before using its range.
    public var current: BraceTemplate? {
        guard completedCount < totalCount else { return nil }
        return templates[completedCount]
    }

    public var isComplete: Bool { completedCount == totalCount }

    public func isValid(in text: String) -> Bool {
        text.utf16.elementsEqual(expectedText.utf16)
    }

    /// Returns nil if the editor changed outside this sequence.
    public func current(in text: String) -> BraceTemplate? {
        isValid(in: text) ? current : nil
    }

    /// Advance only after the editor confirms exactly the requested replacement.
    /// A mismatch leaves the sequence unchanged and returns false. The caller
    /// should cancel the pass rather than continue using a changed editor.
    @discardableResult
    public mutating func advance(afterReplacingWith replacement: String, in updatedText: String) -> Bool {
        guard let current else { return false }
        let expected = (expectedText as NSString).replacingCharacters(in: current.range, with: replacement)
        guard updatedText.utf16.elementsEqual(expected.utf16) else { return false }

        let shift = replacement.utf16.count - current.range.length
        completedCount += 1
        for index in completedCount..<totalCount {
            let template = templates[index]
            templates[index] = BraceTemplate(
                range: NSRange(location: template.range.location + shift, length: template.range.length),
                instruction: template.instruction
            )
        }
        expectedText = updatedText
        return true
    }
}
