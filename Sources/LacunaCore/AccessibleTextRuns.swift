import Foundation

/// Maps ordered static-text descendants into their focused editor's UTF-16
/// value. Only whitespace may occur between runs; never search ahead for a
/// matching phrase. Callers must require `isComplete` before using any mapping.
public struct AccessibleTextRuns {
    private static let maximumUTF16Length = 128 * 1_024
    private let units: [UInt16]
    private var offset = 0
    private var failed = false

    public init(text: String) {
        // Do not count or copy an unbounded editor value before applying the cap.
        let captured = Array(text.utf16.prefix(Self.maximumUTF16Length + 1))
        failed = captured.count > Self.maximumUTF16Length
        units = failed ? [] : captured
    }

    public mutating func append(_ text: String) -> NSRange? {
        guard !failed else { return nil }
        let remaining = units.count - offset
        let next = Array(text.utf16.prefix(remaining + 1))
        guard next.count <= remaining else { failed = true; return nil }
        guard !next.isEmpty else { return NSRange(location: offset, length: 0) }

        // KMP avoids comparing a long whitespace prefix again at every possible
        // starting offset. Each run takes linear work in the bounded input.
        var prefixes = Array(repeating: 0, count: next.count)
        var matched = 0
        for index in 1..<next.count {
            while matched > 0, next[index] != next[matched] {
                matched = prefixes[matched - 1]
            }
            if next[index] == next[matched] { matched += 1 }
            prefixes[index] = matched
        }

        var latestStart = units.count - next.count
        var index = offset
        matched = 0
        while index < latestStart + next.count {
            // A candidate may skip whitespace, but never the first nonwhitespace
            // unit. Stop after the last possible match beginning at that unit.
            if index < latestStart, !Self.isWhitespace(units[index]) { latestStart = index }
            while matched > 0, units[index] != next[matched] {
                matched = prefixes[matched - 1]
            }
            if units[index] == next[matched] { matched += 1 }
            if matched == next.count {
                let start = index + 1 - next.count
                offset = index + 1
                return NSRange(location: start, length: next.count)
            }
            index += 1
        }
        failed = true
        return nil
    }

    public var isComplete: Bool {
        !failed && units[offset...].allSatisfy(Self.isWhitespace)
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        guard let scalar = UnicodeScalar(UInt32(unit)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
}
