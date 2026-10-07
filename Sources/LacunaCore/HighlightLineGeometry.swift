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
        func measuredRowWithoutFirstGlyph(_ characters: ArraySlice<NSRange>) throws -> CGRect? {
            guard let first = characters.first, let last = characters.last else { return nil }
            let entire = NSUnionRange(first, last)
            guard let measured = try rectangle(entire) else { return nil }
            // Some editors expose range/caret bounds but not glyph bounds. A
            // caret or another glyph supplies a real row height; a line-range
            // hint alone cannot distinguish a soft-wrapped paragraph from a row.
            let probes = [NSRange(location: first.location, length: 0), last,
                          NSRange(location: NSMaxRange(last), length: 0)]
            for probe in probes {
                guard let anchor = try rectangle(probe),
                      probe.length > 0 || anchor.width <= 4,
                      sameRow(measured, anchor), measured.height <= anchor.height + 2,
                      measured.insetBy(dx: -1, dy: -1).contains(CGPoint(x: anchor.midX, y: anchor.midY)) else { continue }
                return measured
            }
            return nil
        }

        do {
            for characters in segments where !characters.isEmpty {
                var start = 0
                while start < characters.count, result.count < maximumRectangles {
                    guard let first = try rectangle(characters[start]) else {
                        if let measured = try measuredRowWithoutFirstGlyph(characters[start...]) {
                            result.append(measured)
                        }
                        break
                    }
                    let rowIndex = result.count
                    var candidate = characters.count - 1
                    // A single opening brace is already the complete target.
                    if candidate == start { result.append(first); break }
                    guard var last = try rectangle(characters[candidate]) else {
                        // Offscreen or unsupported endpoint queries need not hide
                        // a provider's valid first-row bounds for the whole range.
                        let remainder = NSRange(location: characters[start].location,
                                                length: NSMaxRange(characters[candidate]) - characters[start].location)
                        if let measured = try rectangle(remainder), measured != first, sameRow(first, measured),
                           measured.height <= first.height + 2,
                           measured.insetBy(dx: -1, dy: -1).contains(first) {
                            result.append(measured)
                        }
                        return result
                    }
                    // Some custom controls ignore the requested range and return
                    // their entire field for every glyph. Omit that geometry.
                    if first == last { return result }
                    // Distinct endpoint bounds establish that this provider is
                    // responding to the requested range, not returning its whole
                    // field for every glyph. Refinement can now preserve a glyph.
                    result.append(first)

                    if !sameRow(first, last) {
                        // Most templates fit one row. Do not spend time querying
                        // optional line APIs until endpoint geometry needs them.
                        try spendQuery()
                        let hint = lineRange(characters[start].location)
                        if let hint, hint.location >= 0, hint.length > 0,
                           hint.location <= characters[start].location,
                           hint.length <= source.length - hint.location {
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
                                guard let hintedLast = try rectangle(characters[candidate]) else { return result }
                                last = hintedLast
                            }
                        }
                    }
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
                    let endpoints = first.union(final)
                    // Endpoint geometry has already established a single row.
                    // Preserve it if the optional range-bounds request times out.
                    result[rowIndex] = endpoints
                    let measured = try rectangle(rowRange)
                    // Never use a rectangle spanning rows, even when an app's
                    // AX implementation returns the entire paragraph's bounds.
                    if let measured, sameRow(first, measured), sameRow(final, measured),
                       measured.height <= endpoints.height + 2,
                       measured.insetBy(dx: -1, dy: -1).contains(first),
                       measured.insetBy(dx: -1, dy: -1).contains(final) {
                        result[rowIndex] = measured
                    }
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
