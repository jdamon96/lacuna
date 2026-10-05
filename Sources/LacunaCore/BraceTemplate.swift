import Foundation

/// A complete, nonnested `{instruction}` and its UTF-16 range in the original text.
public struct BraceTemplate: Equatable, Sendable {
    public let range: NSRange
    public let instruction: String

    public init(range: NSRange, instruction: String) {
        self.range = range
        self.instruction = instruction
    }

    /// Finds the template containing the selection, or the nearest complete template.
    /// Ties prefer a template before the caret. Escaped, nested, empty, and `${…}`
    /// expressions are ignored. Ranges use the same UTF-16 coordinates as macOS AX.
    public static func find(in text: String, selection: NSRange) -> BraceTemplate? {
        let units = Array(text.utf16)
        guard selection.location != NSNotFound, selection.location >= 0,
              selection.length >= 0, selection.location <= units.count,
              selection.length <= units.count - selection.location else { return nil }
        let source = text as NSString
        var candidates: [BraceTemplate] = []
        var depth = 0
        var opening = 0
        var invalid = false
        var backslashes = 0

        for (index, unit) in units.enumerated() {
            let escaped = backslashes % 2 == 1
            backslashes = unit == 92 ? backslashes + 1 : 0
            guard !escaped else { continue }
            if unit == 123 {
                if depth == 0 {
                    opening = index
                    invalid = index > 0 && units[index - 1] == 36
                } else {
                    invalid = true
                }
                depth += 1
            } else if unit == 125, depth > 0 {
                depth -= 1
                guard depth == 0, !invalid else { continue }
                let instruction = source.substring(with: NSRange(location: opening + 1, length: index - opening - 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !instruction.isEmpty {
                    candidates.append(BraceTemplate(range: NSRange(location: opening, length: index - opening + 1), instruction: instruction))
                }
            }
        }

        func distance(_ template: BraceTemplate) -> Int {
            if NSMaxRange(template.range) < selection.location { return selection.location - NSMaxRange(template.range) }
            if template.range.location > NSMaxRange(selection) { return template.range.location - NSMaxRange(selection) }
            return 0
        }
        return candidates.min { lhs, rhs in
            let left = distance(lhs), right = distance(rhs)
            if left != right { return left < right }
            let leftContains = lhs.range.location <= selection.location && NSMaxRange(lhs.range) >= NSMaxRange(selection)
            let rightContains = rhs.range.location <= selection.location && NSMaxRange(rhs.range) >= NSMaxRange(selection)
            if leftContains != rightContains { return leftContains }
            return lhs.range.location < rhs.range.location
        }
    }

    /// The opening brace of an unfinished expression containing a collapsed caret.
    /// Scan beyond the caret too: a later closing or nested brace makes this
    /// expression complete or invalid, even while the caret is near its beginning.
    public static func pendingOpening(in text: String, selection: NSRange) -> NSRange? {
        let units = Array(text.utf16)
        guard selection.location != NSNotFound, selection.location >= 0,
              selection.length == 0, selection.location <= units.count,
              selection.location == units.count || !(0xDC00...0xDFFF).contains(units[selection.location]) else { return nil }
        var depth = 0
        var opening = 0
        var invalid = false
        var backslashes = 0

        for (index, unit) in units.enumerated() {
            let escaped = backslashes % 2 == 1
            backslashes = unit == 92 ? backslashes + 1 : 0
            guard !escaped else { continue }
            if unit == 123 {
                if depth == 0 {
                    opening = index
                    invalid = index > 0 && units[index - 1] == 36
                } else {
                    invalid = true
                }
                depth += 1
            } else if unit == 125, depth > 0 {
                depth -= 1
            }
        }

        guard depth == 1, !invalid, selection.location > opening else { return nil }
        return NSRange(location: opening, length: 1)
    }

    /// Nearby text, limited in UTF-16 units without splitting composed characters.
    /// Always preserves the complete template, even when it exceeds `limit`.
    public func context(in text: String, limit: Int = 6_000) -> String {
        guard let bounds = contextRange(in: text, limit: limit) else { return "" }
        return (text as NSString).substring(with: bounds)
    }

    /// Keeps the selected placeholder unambiguous even when its instruction occurs
    /// more than once. Both sides and the template share the same context budget.
    func contextFragments(in text: String, limit: Int = 6_000) -> (before: String, after: String) {
        guard let bounds = contextRange(in: text, limit: limit) else { return ("", "") }
        let source = text as NSString
        let before = source.substring(with: NSRange(location: bounds.location, length: range.location - bounds.location))
        let after = source.substring(with: NSRange(location: NSMaxRange(range), length: NSMaxRange(bounds) - NSMaxRange(range)))
        return (before, after)
    }

    private func contextRange(in text: String, limit: Int) -> NSRange? {
        let source = text as NSString
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.location <= source.length, range.length <= source.length - range.location,
              Range(range, in: text) != nil else { return nil }
        let budget = min(source.length, max(range.length, max(0, limit)))
        let spare = budget - range.length
        var start = max(0, range.location - spare / 2)
        let end = min(source.length, start + budget)
        start = max(0, end - budget)
        var safeEnd = end
        if start > 0, start < source.length {
            let cluster = source.rangeOfComposedCharacterSequence(at: start)
            if cluster.location < start { start = NSMaxRange(cluster) }
        }
        if end > 0, end < source.length {
            let cluster = source.rangeOfComposedCharacterSequence(at: end)
            if cluster.location < end { safeEnd = cluster.location }
        }
        guard start <= range.location, safeEnd >= NSMaxRange(range) else { return nil }
        return NSRange(location: start, length: safeEnd - start)
    }
}
