import Foundation

/// Tracks one insertion attempt. Seeing an intermediate edit must never permit
/// another insertion, even if the editor later reports the original text again.
public struct ReplacementReadback {
    public enum Outcome: Equatable {
        case confirmed
        case unchanged
        case unconfirmed
    }

    private let original: String
    private let expected: String
    private var originalObservations = 0
    private var unsafeToRetry = false
    public private(set) var confirmed = false
    public private(set) var focusLost = false

    public init(original: String, expected: String) {
        self.original = original
        self.expected = Self.normalizedLineEndings(expected)
    }

    public mutating func observe(text: String?, targetIsFocused: Bool, selectionMatches: Bool) {
        guard targetIsFocused else {
            focusLost = true
            unsafeToRetry = true
            return
        }
        guard let text else {
            unsafeToRetry = true
            return
        }
        if Self.normalizedLineEndings(text).utf16.elementsEqual(expected.utf16) {
            confirmed = true
            return
        }
        if text.utf16.elementsEqual(original.utf16) && selectionMatches {
            originalObservations += 1
        } else {
            unsafeToRetry = true
        }
    }

    /// Only use `unchanged` after a bounded observation window has elapsed.
    /// Missing reads, focus loss, selection movement, or any observed mutation
    /// rule out an automatic fallback for the rest of this attempt.
    public var outcome: Outcome {
        if confirmed { return .confirmed }
        if !unsafeToRetry && originalObservations >= 2 { return .unchanged }
        return .unconfirmed
    }

    private static func normalizedLineEndings(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
