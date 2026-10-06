import AppKit

enum NativeTextGeometry {
    /// Visible line fragments in AX's global, top-left screen coordinates.
    static func highlightBounds(for range: NSRange, in view: NSTextView) -> [CGRect] {
        let length = (view.string as NSString).length
        guard let window = view.window,
              range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location <= length, range.length <= length - range.location else { return [] }
        let visible = window.convertToScreen(view.convert(view.visibleRect, to: nil))
        guard !visible.isEmpty else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var cursor = range.location
        let end = NSMaxRange(range)
        var fragments: [CGRect] = []
        // firstRect returns only the first visual line, including for soft wraps.
        // Its actualRange lets us advance without splitting UTF-16 characters or
        // switching a TextKit 2 view into legacy layout-manager compatibility.
        for _ in 0..<512 {
            guard cursor < end else { break }
            var actual = NSRange(location: NSNotFound, length: 0)
            let rect = view.firstRect(forCharacterRange: NSRange(location: cursor, length: end - cursor),
                                      actualRange: &actual).standardized
            guard actual.location != NSNotFound, actual.location >= 0, actual.length > 0,
                  actual.location <= cursor, actual.location <= length,
                  actual.length <= length - actual.location,
                  NSMaxRange(actual) > cursor else { break }
            cursor = min(end, NSMaxRange(actual))
            guard rect.origin.x.isFinite, rect.origin.y.isFinite,
                  rect.width.isFinite, rect.height.isFinite else { continue }
            let clipped = rect.intersection(visible)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { continue }
            fragments.append(CGRect(x: clipped.minX, y: primaryHeight - clipped.maxY,
                                    width: clipped.width, height: clipped.height))
        }
        return fragments
    }
}
