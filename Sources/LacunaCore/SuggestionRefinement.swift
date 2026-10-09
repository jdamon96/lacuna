import Foundation

/// The latest options and the complete, ordered feedback for one unchanged
/// placeholder. This travels in each stateless request, never a provider session.
public struct SuggestionRefinement: Equatable, Sendable {
    public static let maximumFeedbackRounds = 8
    public static let maximumFeedbackLength = 6_000

    public let previousSuggestions: [String]
    public let feedback: [String]

    public init(previousSuggestions: [String], feedback: [String]) throws {
        guard previousSuggestions.count == 3 else { throw CompletionError.invalidRefinementOptions }
        let options = previousSuggestions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard options.allSatisfy({ !$0.isEmpty && $0.utf16.count <= 12_000 }),
              Set(options.map { $0.precomposedStringWithCanonicalMapping.lowercased() }).count == 3 else {
            throw CompletionError.invalidRefinementOptions
        }
        guard !feedback.isEmpty else { throw CompletionError.emptyRefinementFeedback }
        guard feedback.count <= Self.maximumFeedbackRounds else { throw CompletionError.refinementRoundLimit }
        let cleaned = feedback.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var used = 0
        for entry in cleaned {
            guard !entry.isEmpty else { throw CompletionError.emptyRefinementFeedback }
            let length = entry.utf16.count
            guard length <= Self.maximumFeedbackLength - used else { throw CompletionError.refinementTooLong }
            used += length
        }
        self.previousSuggestions = options
        self.feedback = cleaned
    }
}
