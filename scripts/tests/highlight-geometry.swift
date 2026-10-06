import AppKit

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure(description: message) }
}

private final class EditorFixture {
    let window: NSWindow
    let scroll: NSScrollView
    let view: NSTextView
    let textKit2: Bool

    init(_ text: String, width: CGFloat = 650, height: CGFloat = 340, textKit2: Bool) {
        self.textKit2 = textKit2
        window = NSWindow(contentRect: NSRect(x: 160, y: 180, width: width, height: height),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        view = NSTextView(usingTextLayoutManager: textKit2)
        view.frame = scroll.bounds
        view.isRichText = false
        view.font = .systemFont(ofSize: 19)
        view.textContainerInset = NSSize(width: 26, height: 26)
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.widthTracksTextView = true
        scroll.documentView = view
        window.contentView = scroll
        view.string = text
        layout()
        // Attached, hidden windows provide real AppKit screen-coordinate geometry
        // without stealing focus, touching Accessibility, or showing test UI.
    }

    func layout() {
        window.contentView?.layoutSubtreeIfNeeded()
        if let manager = view.textLayoutManager, let range = manager.textContentManager?.documentRange {
            manager.ensureLayout(for: range)
        } else if let container = view.textContainer {
            view.layoutManager?.ensureLayout(for: container)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    var templateRange: NSRange {
        let source = view.string as NSString
        let opening = source.range(of: "{").location
        let closing = source.range(of: "}", options: .backwards)
        return NSRange(location: opening, length: NSMaxRange(closing) - opening)
    }

    var rectangles: [CGRect] { NativeTextGeometry.highlightBounds(for: templateRange, in: view) }

    func axRect(_ screenRect: CGRect) -> CGRect {
        let rect = screenRect.standardized
        return CGRect(x: rect.minX, y: (NSScreen.screens.first?.frame.height ?? 0) - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    var visibleRect: CGRect {
        axRect(window.convertToScreen(view.convert(view.visibleRect, to: nil)))
    }

    func glyphRect(at location: Int) -> CGRect {
        axRect(view.firstRect(forCharacterRange: NSRange(location: location, length: 1), actualRange: nil))
    }

    func assertValid(_ rectangles: [CGRect], _ label: String) throws {
        let visible = visibleRect.insetBy(dx: -0.5, dy: -0.5)
        for rect in rectangles {
            try expect(rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite,
                       "\(label): geometry must be finite")
            try expect(rect.width > 0 && rect.height > 0, "\(label): empty lines must not create zero-area overlays")
            try expect(visible.contains(rect), "\(label): overlay escapes the visible text viewport: \(rect)")
        }
        try expect((view.textLayoutManager != nil) == textKit2, "\(label): querying geometry changed TextKit mode")
        try expect(!window.isVisible && !window.isKeyWindow, "\(label): fixture must not show or focus its window")
    }

    func assertBothBracesCovered(_ rectangles: [CGRect], _ label: String) throws {
        for location in [templateRange.location, NSMaxRange(templateRange) - 1] {
            let glyph = glyphRect(at: location)
            try expect(glyph.width > 0 && glyph.height > 0, "\(label): test brace must be visible")
            try expect(rectangles.contains { $0.insetBy(dx: -0.5, dy: -0.5).contains(glyph) },
                       "\(label): missing brace at UTF-16 position \(location): \(glyph), highlights: \(rectangles)")
        }
    }
}

@main
private struct HighlightGeometryRegression {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        do {
            for textKit2 in [false, true] {
                try runCases(textKit2: textKit2)
                print("TextKit \(textKit2 ? 2 : 1): highlight geometry regression checks passed")
            }
            let detached = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            detached.string = "{hello}"
            try expect(NativeTextGeometry.highlightBounds(for: NSRange(location: 0, length: 7), in: detached).isEmpty,
                       "A detached view has no screen-space highlight")
            print("Native highlight regression checks passed without opening windows or changing preferences.")
        } catch {
            FileHandle.standardError.write(Data("Highlight geometry regression failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func runCases(textKit2: Bool) throws {
        let mode = "TextKit \(textKit2 ? 2 : 1)"

        // Exact Try Lacuna sample: the closing brace wraps to the next visual line.
        let sample = EditorFixture("Hi Alex,\n\nThanks for taking the time to share your feedback. {a warm one-sentence sign-off}", textKit2: textKit2)
        let sampleRects = sample.rectangles
        try expect(sampleRects.count == 2, "\(mode): default playground should highlight both wrapped lines")
        try sample.assertBothBracesCovered(sampleRects, "\(mode) soft wrap")
        try sample.assertValid(sampleRects, "\(mode) soft wrap")

        let hard = EditorFixture("Hello {first line\nsecond line\n\nlast line}", width: 500, textKit2: textKit2)
        let hardRects = hard.rectangles
        try expect(hardRects.count == 3, "\(mode): all nonempty hard lines, including the line after a blank line, need highlights")
        try hard.assertBothBracesCovered(hardRects, "\(mode) hard lines")
        try hard.assertValid(hardRects, "\(mode) hard lines")

        let longText = "{" + (1...12).map { "Line \($0) of the instruction" }.joined(separator: "\n") + "}"
        let tall = EditorFixture(longText, width: 500, height: 560, textKit2: textKit2)
        let tallRects = tall.rectangles
        try expect(tallRects.count == 12, "\(mode): a template taller than 180 points must retain every line")
        let union = tallRects.reduce(CGRect.null) { $0.union($1) }
        try expect(union.height > 180 && tallRects.allSatisfy { $0.height < 60 }, "\(mode): highlight each line separately")
        try tall.assertBothBracesCovered(tallRects, "\(mode) tall template")
        try tall.assertValid(tallRects, "\(mode) tall template")

        let unicode = EditorFixture("👩🏽‍💻 e\u{301} Hello {a warm greeting for 👨‍👩‍👧‍👦\nwith café and a kind sign-off}", width: 360, textKit2: textKit2)
        let unicodeRects = unicode.rectangles
        try expect(unicodeRects.count >= 2, "\(mode): Unicode fixture must wrap")
        try unicode.assertBothBracesCovered(unicodeRects, "\(mode) UTF-16")
        try unicode.assertValid(unicodeRects, "\(mode) UTF-16")

        let bidi = EditorFixture("Prefix {שלום world مرحبا hello suffix and then more ideas to keep it wrapping}", width: 320, textKit2: textKit2)
        try expect(bidi.rectangles.count >= 2, "\(mode): mixed direction fixture must wrap")
        // A single-character firstRect can expose unusually wide fallback-font
        // ink bounds for bidi text, so it is not a selection-geometry oracle here.
        try bidi.assertValid(bidi.rectangles, "\(mode) mixed direction")

        // Offscreen lines may have empty firstRect geometry. They must not prevent
        // later visible lines from being visited, and partial lines must be clipped.
        let clipped = EditorFixture(longText, width: 500, height: 90, textKit2: textKit2)
        clipped.view.scroll(NSPoint(x: 0, y: 61))
        clipped.scroll.reflectScrolledClipView(clipped.scroll.contentView)
        let clippedRects = clipped.rectangles
        try expect(!clippedRects.isEmpty && clippedRects.count < tallRects.count, "\(mode): only visible scrolled lines should be returned")
        try clipped.assertValid(clippedRects, "\(mode) clipped viewport")
        try expect(clippedRects.contains { $0.height < tallRects[0].height - 0.5 }, "\(mode): a partially visible line should be clipped")

        let offscreen = EditorFixture(String(repeating: "Earlier text\n", count: 12) + "{later instruction}", width: 500, height: 90, textKit2: textKit2)
        try expect(offscreen.rectangles.isEmpty, "\(mode): an offscreen template must not create an overlay")

        let resized = EditorFixture("Start {a warm one-sentence sign-off}", width: 700, textKit2: textKit2)
        try expect(resized.rectangles.count == 1, "\(mode): wide fixture should start on one line")
        resized.window.setContentSize(NSSize(width: 270, height: 340))
        resized.layout()
        let narrowRects = resized.rectangles
        try expect(narrowRects.count >= 2, "\(mode): resizing must recalculate soft wraps")
        try resized.assertBothBracesCovered(narrowRects, "\(mode) resize")
        try resized.assertValid(narrowRects, "\(mode) resize")

        for range in [NSRange(location: NSNotFound, length: 1), NSRange(location: -1, length: 1),
                      NSRange(location: 0, length: 0), NSRange(location: 0, length: Int.max),
                      NSRange(location: (sample.view.string as NSString).length + 1, length: 1)] {
            try expect(NativeTextGeometry.highlightBounds(for: range, in: sample.view).isEmpty,
                       "\(mode): invalid range \(range) must be rejected")
        }
    }
}
