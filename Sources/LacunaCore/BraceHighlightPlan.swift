import Foundation

/// The phrases to mark in a focused editor, in geometry-query priority order.
/// Keeping the active and unfinished phrases first gives them a useful cue even
/// when an external app uses the entire accessibility-query time budget.
public struct BraceHighlightPlan: Equatable, Sendable {
    public enum Style: Equatable, Sendable { case opening, complete, active }
    public struct Item: Equatable, Sendable {
        public let range: NSRange
        public let style: Style
    }

    public let items: [Item]
    public let phraseCount: Int

    public init(text: String, selection: NSRange, activeRange: NSRange? = nil,
                showInactive: Bool = true, maximumCount: Int = 128) {
        let templates = BraceTemplate.all(in: text)
        var count = templates.count
        guard maximumCount > 0 else { items = []; phraseCount = count; return }
        var result: [Item] = []
        // The sequence owns its active range. Validate the expression locally
        // so braces in previously accepted wording cannot hide the next cue.
        if let activeRange, let range = Range(activeRange, in: text) {
            let expression = String(text[range])
            if BraceTemplate.all(in: expression).first?.range == NSRange(location: 0, length: expression.utf16.count) {
                result.append(Item(range: activeRange, style: .active))
                if !templates.contains(where: { $0.range == activeRange }) { count += 1 }
            }
        }
        if showInactive {
            if result.count < maximumCount,
               let opening = BraceTemplate.pendingOpening(in: text, selection: selection) {
                result.append(Item(range: opening, style: .opening))
            }
            for template in templates where result.count < maximumCount {
                if result.contains(where: { $0.range == template.range }) { continue }
                result.append(Item(range: template.range, style: .complete))
            }
        }
        items = result
        phraseCount = count
    }
}
