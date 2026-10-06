import XCTest
import CoreGraphics
@testable import LacunaCore

final class HighlightLineGeometryTests: XCTestCase {
    func testVisualLineRangesHighlightEveryWrappedLineWithoutAUnion() {
        let fixture = Layout("before {a warm one-sentence sign-off} after", columns: 16)
        let target = (fixture.text as NSString).range(of: "{a warm one-sentence sign-off}")
        let result = HighlightLineGeometry.rectangles(in: fixture.text, range: target,
            lineRange: fixture.visualLine, bounds: fixture.firstRowBounds)
        XCTAssertEqual(result, fixture.expected(target))
        XCTAssertEqual(result.count, 3)
        XCTAssertTrue(result.allSatisfy { $0.height == 18 })
    }

    func testParagraphLineRangesStillSplitSoftWrapping() {
        let fixture = Layout("{a warm one-sentence sign-off that spans several lines}", columns: 14)
        let target = NSRange(location: 0, length: (fixture.text as NSString).length)
        var queries = 0
        let result = HighlightLineGeometry.rectangles(in: fixture.text, range: target,
            lineRange: { _ in target }, bounds: { queries += 1; return fixture.unionBounds($0) })
        XCTAssertEqual(result, fixture.expected(target))
        XCTAssertLessThan(queries, 30, "Find wrap boundaries with binary search, not a query per character")
    }

    func testMissingLineAPIAndFirstRectOnlyProviderStillHighlightAllLines() {
        let fixture = Layout("{first second third fourth fifth}", columns: 12)
        let target = NSRange(location: 0, length: (fixture.text as NSString).length)
        let result = HighlightLineGeometry.rectangles(in: fixture.text, range: target,
            lineRange: { _ in nil }, bounds: fixture.firstRowBounds)
        XCTAssertEqual(result, fixture.expected(target))
    }

    func testHardBreaksAndBlankLinesNeverJoinUnrelatedRows() {
        let fixture = Layout("before {first\r\n\nsecond\u{2028}third} after", columns: 80)
        let target = (fixture.text as NSString).range(of: "{first\r\n\nsecond\u{2028}third}")
        var requests: [NSRange] = []
        let result = HighlightLineGeometry.rectangles(in: fixture.text, range: target,
            lineRange: { _ in nil }, bounds: { requests.append($0); return fixture.unionBounds($0) })
        XCTAssertEqual(result, fixture.expected(target))
        XCTAssertEqual(result.count, 3)
        for range in requests {
            let content = (fixture.text as NSString).substring(with: range)
            XCTAssertFalse(content.contains("\n") || content.contains("\r") || content.contains("\u{2028}"))
        }
    }

    func testEmojiAndCombiningMarksKeepWholeUTF16CharacterRanges() {
        let fixture = Layout("{a👨‍👩‍👧‍👦e\u{301}🙂b cdef}", columns: 5)
        let target = NSRange(location: 0, length: (fixture.text as NSString).length)
        var requests: [NSRange] = []
        let result = HighlightLineGeometry.rectangles(in: fixture.text, range: target,
            lineRange: { _ in nil }, bounds: { requests.append($0); return fixture.firstRowBounds($0) })
        XCTAssertEqual(result, fixture.expected(target))
        let boundaries = Set(fixture.glyphs.flatMap { [$0.range.location, NSMaxRange($0.range)] })
        XCTAssertTrue(requests.allSatisfy { boundaries.contains($0.location) && boundaries.contains(NSMaxRange($0)) })
    }

    func testBadMultilineRangeBoundsUseOnlyTheVerifiedRowEndpoints() {
        let fixture = Layout("{abcdefghijklmno}", columns: 6)
        let target = NSRange(location: 0, length: (fixture.text as NSString).length)
        let result = HighlightLineGeometry.rectangles(in: fixture.text, range: target,
            lineRange: fixture.visualLine, bounds: { range in
                range.length == 1 ? fixture.unionBounds(range) : fixture.unionBounds(target)
            })
        XCTAssertEqual(result, fixture.expected(target))
        XCTAssertTrue(result.allSatisfy { $0.height == 18 })
    }

    func testUnsupportedConstantGeometryIsOmitted() {
        let result = HighlightLineGeometry.rectangles(in: "{hello}", range: NSRange(location: 0, length: 7),
            lineRange: { _ in nil }, bounds: { _ in CGRect(x: 0, y: 0, width: 500, height: 400) })
        XCTAssertTrue(result.isEmpty)
    }

    func testLargeInputsRespectQueryAndRectangleBudgets() {
        let fixture = Layout("{" + String(repeating: "abc ", count: 5_000) + "}", columns: 40)
        let target = NSRange(location: 0, length: (fixture.text as NSString).length)
        var callbacks = 0
        let limited = HighlightLineGeometry.rectangles(in: fixture.text, range: target, maximumQueries: 8,
            lineRange: { _ in callbacks += 1; return nil },
            bounds: { callbacks += 1; return fixture.firstRowBounds($0) })
        XCTAssertLessThanOrEqual(callbacks, 8)
        XCTAssertTrue(limited.allSatisfy { $0.height == 18 })
        let three = HighlightLineGeometry.rectangles(in: fixture.text, range: target, maximumRectangles: 3,
            lineRange: fixture.visualLine, bounds: fixture.firstRowBounds)
        XCTAssertEqual(three.count, 3)
    }

    func testInvalidRangesAndExpiredTimeBudgetDoNotQueryTheApplication() {
        var calls = 0
        for range in [NSRange(location: NSNotFound, length: 1), NSRange(location: 0, length: 20),
                      NSRange(location: 2, length: 1), NSRange(location: 0, length: 0)] {
            let rectangles = HighlightLineGeometry.rectangles(in: "{🙂}", range: range,
                lineRange: { _ in calls += 1; return nil }, bounds: { _ in calls += 1; return nil })
            XCTAssertTrue(rectangles.isEmpty)
        }
        let expired = HighlightLineGeometry.rectangles(in: "{hello}", range: NSRange(location: 0, length: 7),
            lineRange: { _ in calls += 1; return nil }, bounds: { _ in calls += 1; return nil },
            shouldContinue: { false })
        XCTAssertTrue(expired.isEmpty)
        XCTAssertEqual(calls, 0)
    }

    private struct Layout {
        struct Glyph { let range: NSRange; let row: Int; let rectangle: CGRect }
        let text: String
        let glyphs: [Glyph]

        init(_ text: String, columns: Int) {
            self.text = text
            var glyphs: [Glyph] = []
            var offset = 0, row = 0, column = 0
            for character in text {
                let string = String(character)
                let length = string.utf16.count
                if string == "\n" || string == "\r" || string == "\r\n" || string == "\u{2028}" {
                    row += 1; column = 0
                } else {
                    if column == columns { row += 1; column = 0 }
                    glyphs.append(Glyph(range: NSRange(location: offset, length: length), row: row,
                        rectangle: CGRect(x: 100 + column * 9, y: 200 + row * 22, width: 9, height: 18)))
                    column += 1
                }
                offset += length
            }
            self.glyphs = glyphs
        }

        func selected(_ range: NSRange) -> [Glyph] {
            glyphs.filter { $0.range.location >= range.location && NSMaxRange($0.range) <= NSMaxRange(range) }
        }
        func visualLine(_ index: Int) -> NSRange? {
            guard let glyph = glyphs.first(where: { NSLocationInRange(index, $0.range) }) else { return nil }
            let row = glyphs.filter { $0.row == glyph.row }
            return NSUnionRange(row.first!.range, row.last!.range)
        }
        func unionBounds(_ range: NSRange) -> CGRect? {
            selected(range).map(\.rectangle).reduce(nil) { $0?.union($1) ?? $1 }
        }
        func firstRowBounds(_ range: NSRange) -> CGRect? {
            let values = selected(range)
            return values.filter { $0.row == values.first?.row }.map(\.rectangle).reduce(nil) { $0?.union($1) ?? $1 }
        }
        func expected(_ range: NSRange) -> [CGRect] {
            let values = selected(range)
            return Set(values.map(\.row)).sorted().map { row in
                values.filter { $0.row == row }.map(\.rectangle).reduce(CGRect.null) { $0.union($1) }
            }
        }
    }
}
