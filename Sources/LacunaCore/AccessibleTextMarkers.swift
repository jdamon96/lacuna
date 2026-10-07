import Foundation

/// Maps opaque accessibility markers to field-local UTF-16 offsets. Providers
/// disagree about integer marker indices, so navigation validates the text of
/// every step instead of treating document indices as offsets into a text field.
public struct AccessibleTextMarkers<Marker> {
    private let text: NSString
    private var markers: [Int: Marker]
    private var remainingSteps: Int

    public init(text: String, start: Marker, end: Marker, maximumSteps: Int = 24) {
        self.text = text as NSString
        markers = [0: start]
        markers[text.utf16.count] = end
        remainingSteps = maximumSteps
    }

    public mutating func marker(at offset: Int,
                                move: (Marker, Bool) -> Marker?,
                                string: (Marker, Marker) -> String?,
                                shouldContinue: () -> Bool = { true }) -> Marker? {
        guard offset >= 0, offset <= text.length else { return nil }
        if let known = markers[offset] { return known }
        guard let nearest = markers.keys.min(by: { abs($0 - offset) < abs($1 - offset) }),
              var current = markers[nearest] else { return nil }
        var position = nearest
        while position != offset, remainingSteps > 0, shouldContinue() {
            remainingSteps -= 1
            let forward = position < offset
            guard let next = move(current, forward),
                  let traversed = string(forward ? current : next, forward ? next : current),
                  !traversed.isEmpty else { return nil }
            let length = traversed.utf16.count
            let nextPosition = forward ? position + length : position - length
            guard nextPosition >= 0, nextPosition <= text.length,
                  forward ? nextPosition <= offset : nextPosition >= offset else { return nil }
            let actual = text.substring(with: NSRange(location: min(position, nextPosition), length: length))
            guard actual.utf16.elementsEqual(traversed.utf16) else { return nil }
            markers[nextPosition] = next
            current = next
            position = nextPosition
        }
        return position == offset ? current : nil
    }
}
