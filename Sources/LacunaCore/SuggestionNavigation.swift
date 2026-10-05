import Foundation

/// Keyboard navigation in a list whose options can be taller than its viewport.
public enum SuggestionNavigation {
    public struct Position: Equatable {
        public let selected: Int
        public let offset: Double
    }

    /// Arrow keys read the current option before moving on. Tab skips directly to
    /// the next option. Offsets and row bounds use a top-left document origin.
    public static func move(selected: Int, offset: Double, viewportHeight: Double,
                            rows: [ClosedRange<Double>], direction: Int,
                            jump: Bool = false) -> Position {
        guard rows.indices.contains(selected), viewportHeight > 0 else {
            return Position(selected: selected, offset: offset)
        }
        let maximumOffset = max(0, (rows.last?.upperBound ?? 0) - viewportHeight)
        let offset = min(maximumOffset, max(0, offset))
        let current = rows[selected]
        let step = viewportHeight * 0.75 // Keep overlapping text visible while reading.
        let forward = direction >= 0

        if !jump {
            if forward, current.upperBound > offset + viewportHeight + 0.5 {
                return Position(selected: selected, offset: min(maximumOffset, min(offset + step, current.upperBound - viewportHeight)))
            }
            if !forward, current.lowerBound < offset - 0.5 {
                return Position(selected: selected, offset: max(0, max(offset - step, current.lowerBound)))
            }
        }

        let next = (selected + (forward ? 1 : -1) + rows.count) % rows.count
        let row = rows[next]
        var destination = offset
        if row.upperBound - row.lowerBound > viewportHeight {
            destination = forward ? row.lowerBound : row.upperBound - viewportHeight
        } else if row.lowerBound < offset {
            destination = row.lowerBound
        } else if row.upperBound > offset + viewportHeight {
            destination = row.upperBound - viewportHeight
        }
        return Position(selected: next, offset: min(maximumOffset, max(0, destination)))
    }
}
