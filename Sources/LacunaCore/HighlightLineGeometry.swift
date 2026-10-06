import Foundation
import CoreGraphics

/// Splits an accessible text range into visual rows without querying every glyph.
/// AX providers may report a paragraph for a line, or only the first row's bounds
/// for a multiline range. Endpoint geometry checks both cases before drawing.
public enum HighlightLineGeometry {
    public static func rectangles(in text: String, range: NSRange,
                                  maximumQueries: Int = 64, maximumRectangles: Int = 16,
                                  lineRange: (Int) -> NSRange?,
                                  bounds: (NSRange) -> CGRect?,
                                  shouldContinue: () -> Bool = { true }) -> [CGRect] {
        let source = text as NSString
        guard range.location >= 0, range.length > 0, range.location <= source.length,
              range.length <= source.length - range.location,
              maximumQueries > 0, maximumRectangles > 0 else { return [] }

        // Keep composed characters intact, including emoji and CRLF. Limit local
        // work as well as IPC for unusually large templates. Hard line breaks are
        // excluded: some AX implementations locate their bounds on the next row.
        var segments: [[NSRange]] = [[]]
        var cursor = range.location
        var characterCount = 0
        while cursor < NSMaxRange(range), characterCount < 4_096 {
            let character = source.rangeOfComposedCharacterSequence(at: cursor)
            guard character.location == cursor, NSMaxRange(character) <= NSMaxRange(range) else { return [] }
            let first = source.character(at: cursor)
            if [0x0A, 0x0D, 0x85, 0x2028, 0x2029].contains(first) {
                if !segments[segments.count - 1].isEmpty { segments.append([]) }
            } else {
                segments[segments.count - 1].append(character)
            }
            cursor = NSMaxRange(character)
            characterCount += 1
        }

        var result: [CGRect] = []
        var queries = 0
        var queriedBounds = Set<NSRange>()
        var cachedBounds: [NSRange: CGRect] = [:]
        func spendQuery() throws {
            guard queries < maximumQueries, shouldContinue() else { throw QueryLimit.reached }
            queries += 1
        }
        func rectangle(_ range: NSRange) throws -> CGRect? {
            if queriedBounds.contains(range) { return cachedBounds[range] }
            try spendQuery()
            queriedBounds.insert(range)
            if let value = bounds(range), usable(value) { cachedBounds[range] = value }
            return cachedBounds[range]
        }

        do {
            for characters in segments where !characters.isEmpty {
                var start = 0
                while start < characters.count, result.count < maximumRectangles {
                    guard let first = try rectangle(characters[start]) else { return result }
                    try spendQuery()
                    let hint = lineRange(characters[start].location)
                    var candidate = characters.count - 1
                    if let hint, hint.location >= 0, hint.length > 0,
                       hint.location <= characters[start].location,
                       hint.length <= source.length - hint.location {
                        // A hint is useful only if it contains the first complete
                        // character. Binary search avoids trusting a broken range.
                        let hintEnd = NSMaxRange(hint)
                        if hintEnd >= NSMaxRange(characters[start]) {
                            var lower = start
                            var upper = characters.count
                            while lower + 1 < upper {
                                let middle = lower + (upper - lower) / 2
                                if NSMaxRange(characters[middle]) <= hintEnd { lower = middle }
                                else { upper = middle }
                            }
                            candidate = lower
                        }
                    }

                    guard let last = try rectangle(characters[candidate]) else { return result }
                    // Some custom controls ignore the requested range and return
                    // their entire field for every glyph. Omit that geometry.
                    if candidate > start, first == last { return result }
                    var end = candidate
                    if !sameRow(first, last) {
                        // A paragraph hint or unsupported line API: find the last
                        // character on this visual row in O(log n) AX requests.
                        var lower = start
                        var upper = candidate
                        while lower + 1 < upper {
                            let middle = lower + (upper - lower) / 2
                            guard let probe = try rectangle(characters[middle]) else { return result }
                            if sameRow(first, probe) { lower = middle }
                            else { upper = middle }
                        }
                        end = lower
                    }
                    guard let final = try rectangle(characters[end]) else { return result }
                    let rowRange = NSRange(location: characters[start].location,
                                           length: NSMaxRange(characters[end]) - characters[start].location)
                    let measured = try rectangle(rowRange)
                    // Never use a rectangle spanning rows, even when an app's
                    // AX implementation returns the entire paragraph's bounds.
                    let endpoints = first.union(final)
                    let row: CGRect
                    if let measured, sameRow(first, measured), sameRow(final, measured),
                       measured.height <= endpoints.height + 2,
                       measured.insetBy(dx: -1, dy: -1).contains(first),
                       measured.insetBy(dx: -1, dy: -1).contains(final) {
                        row = measured
                    } else {
                        row = endpoints
                    }
                    result.append(row)
                    start = end + 1
                }
                if result.count >= maximumRectangles { break }
            }
        } catch {
            // A partial highlight is preferable to blocking typing or drawing a
            // guessed union across unrelated text when the budget is exhausted.
        }
        return result
    }

    private enum QueryLimit: Error { case reached }

    private static func usable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width >= 0 && rect.height > 0
    }

    private static func sameRow(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.midY - rhs.midY) <= max(1, min(lhs.height, rhs.height) * 0.45)
    }
}
