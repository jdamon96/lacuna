import XCTest
@testable import LacunaCore

final class SuggestionNavigationTests: XCTestCase {
    func testDownReadsEveryPartOfAnOversizedOptionBeforeSelectingNext() {
        let rows = [0.0...1200.0, 1206.0...1260.0, 1266.0...1320.0]
        var selected = 0
        var offset = 0.0
        var visibleEnd = 330.0
        for _ in 0..<20 {
            let next = SuggestionNavigation.move(selected: selected, offset: offset, viewportHeight: 330, rows: rows, direction: 1)
            if next.selected != selected {
                XCTAssertEqual(visibleEnd, rows[0].upperBound)
                XCTAssertEqual(next.selected, 1)
                XCTAssertGreaterThanOrEqual(next.offset + 330, rows[1].upperBound)
                selected = next.selected
                break
            }
            XCTAssertGreaterThan(next.offset, offset)
            XCTAssertLessThan(next.offset, visibleEnd, "Each scroll overlaps the previous viewport; no text is skipped")
            offset = next.offset
            visibleEnd = offset + 330
        }
        XCTAssertEqual(selected, 1, "Navigation must eventually leave a fully read option")
    }

    func testUpReversesScrollingAndReadsToTheBeginning() {
        let rows = [0.0...1200.0, 1206.0...1260.0]
        var offset = 870.0
        for _ in 0..<4 {
            let next = SuggestionNavigation.move(selected: 0, offset: offset, viewportHeight: 330, rows: rows, direction: -1)
            XCTAssertEqual(next.selected, 0)
            XCTAssertLessThan(next.offset, offset)
            XCTAssertGreaterThan(next.offset + 330, offset)
            offset = next.offset
        }
        XCTAssertEqual(offset, 0)
        let wrapped = SuggestionNavigation.move(selected: 0, offset: offset, viewportHeight: 330, rows: rows, direction: -1)
        XCTAssertEqual(wrapped.selected, 1)
        XCTAssertEqual(wrapped.offset, 930)
    }

    func testShortOptionsMoveSelectionAndRevealTheFullRow() {
        let rows = [0.0...130.0, 136.0...266.0, 272.0...402.0]
        let second = SuggestionNavigation.move(selected: 0, offset: 0, viewportHeight: 330, rows: rows, direction: 1)
        XCTAssertEqual(second.selected, 1)
        XCTAssertEqual(second.offset, 0)
        let third = SuggestionNavigation.move(selected: 1, offset: 0, viewportHeight: 330, rows: rows, direction: 1)
        XCTAssertEqual(third.selected, 2)
        XCTAssertEqual(third.offset, 72)
        let first = SuggestionNavigation.move(selected: 2, offset: third.offset, viewportHeight: 330, rows: rows, direction: 1)
        XCTAssertEqual(first.selected, 0)
        XCTAssertEqual(first.offset, 0)
    }

    func testTabSkipsUnreadTextAndOpensNextLongOptionAtItsBeginning() {
        let rows = [0.0...1200.0, 1206.0...2406.0, 2412.0...2460.0]
        let next = SuggestionNavigation.move(selected: 0, offset: 247.5, viewportHeight: 330, rows: rows, direction: 1, jump: true)
        XCTAssertEqual(next.selected, 1)
        XCTAssertEqual(next.offset, 1206)
        let back = SuggestionNavigation.move(selected: 1, offset: next.offset, viewportHeight: 330, rows: rows, direction: -1)
        XCTAssertEqual(back.selected, 0)
        XCTAssertEqual(back.offset, 870, "Up enters the previous long option at its end")
    }

    func testManualScrollIsRespectedAndTinyViewportStillOverlaps() {
        let rows = [0.0...500.0, 506.0...1006.0]
        let up = SuggestionNavigation.move(selected: 0, offset: 111, viewportHeight: 10, rows: rows, direction: -1)
        XCTAssertEqual(up.selected, 0)
        XCTAssertEqual(up.offset, 103.5)
        let down = SuggestionNavigation.move(selected: 1, offset: 600, viewportHeight: 100, rows: rows, direction: 1)
        XCTAssertEqual(down.selected, 1)
        XCTAssertEqual(down.offset, 675)
    }

    func testMissingLayoutDoesNotLoseSelection() {
        XCTAssertEqual(SuggestionNavigation.move(selected: 0, offset: 0, viewportHeight: 330, rows: [], direction: 1).selected, 0)
        XCTAssertEqual(SuggestionNavigation.move(selected: 0, offset: 0, viewportHeight: 0, rows: [0.0...100.0], direction: 1).offset, 0)
    }
}
