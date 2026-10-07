import AppKit
import ObjectiveC

/// Exercise the production panel through AppKit's normal display cycle before
/// using cacheDisplay for pixel assertions. A forced bitmap draw alone would not
/// catch a visible panel whose content was never scheduled for display.
@main
private enum HighlightPanelChecks {
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let highlight = BraceHighlight()
        guard let panel = app.windows.first(where: { $0 is PassivePanel }),
              let view = panel.contentView else { fatalError("Missing production highlight panel") }
        let originalKeyWindow = app.keyWindow
        let drawSelector = #selector(NSView.draw(_:))
        let drawMethod = class_getInstanceMethod(type(of: view), drawSelector)!
        let originalImplementation = method_getImplementation(drawMethod)
        typealias DrawImplementation = @convention(c) (AnyObject, Selector, NSRect) -> Void
        let originalDraw = unsafeBitCast(originalImplementation, to: DrawImplementation.self)
        var screenDraws = 0
        let observingDraw: @convention(block) (NSView, NSRect) -> Void = { object, dirty in
            if NSGraphicsContext.current?.isDrawingToScreen == true { screenDraws += 1 }
            originalDraw(object, drawSelector, dirty)
        }
        let observer = imp_implementationWithBlock(observingDraw)
        method_setImplementation(drawMethod, observer)

        // Keep test windows outside the user's displays; inspect only this
        // process's own window metadata, with no screen capture or AX access.
        let input = [CGRect(x: -10_000, y: -10_000, width: 140, height: 22),
                     CGRect(x: -10_080, y: -9_968, width: 95, height: 22)]
        func fragments(_ rects: [CGRect]) -> [CGRect] {
            let frames = rects.map { FloatingPanel.appKitRect($0).insetBy(dx: -2, dy: -2) }
            let bounds = frames.reduce(CGRect.null) { $0.union($1) }
            return frames.map { $0.offsetBy(dx: -bounds.minX, dy: -bounds.minY) }
        }
        func snapshot() -> NSBitmapImageRep {
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap
        }
        func alpha(_ bitmap: NSBitmapImageRep, at point: NSPoint) -> CGFloat {
            let x = min(bitmap.pixelsWide - 1, max(0, Int(point.x * CGFloat(bitmap.pixelsWide) / view.bounds.width)))
            let y = min(bitmap.pixelsHigh - 1, max(0, Int((view.bounds.height - point.y) * CGFloat(bitmap.pixelsHigh) / view.bounds.height)))
            return bitmap.colorAt(x: x, y: y)!.alphaComponent
        }
        func expectPassive() {
            precondition(panel.isVisible, "The highlight must be ordered on screen")
            precondition(!panel.canBecomeKey && !panel.canBecomeMain && !panel.isKeyWindow)
            precondition(panel.ignoresMouseEvents && !panel.hidesOnDeactivate)
            precondition(!panel.isOpaque && !panel.hasShadow && panel.level == .floating)
            precondition(app.keyWindow === originalKeyWindow, "Showing a highlight must preserve focus")
            precondition(panel.contentView === view && view.frame.size == panel.frame.size)
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], 0) as? [[String: Any]] ?? []
            precondition(windows.contains { info in
                (info[kCGWindowOwnerPID as String] as? Int) == Int(ProcessInfo.processInfo.processIdentifier)
                    && (info[kCGWindowNumber as String] as? Int) == panel.windowNumber
                    && (info[kCGWindowAlpha as String] as? Double) == 1
            }, "WindowServer must know about the visible nontransparent panel")
        }
        func expectContours(_ bitmap: NSBitmapImageRep, rects: [CGRect], active: Bool = false) {
            for rect in fragments(rects) {
                let fill = alpha(bitmap, at: CGPoint(x: rect.midX, y: rect.midY))
                let edge = alpha(bitmap, at: CGPoint(x: rect.midX, y: rect.minY + 0.5))
                precondition(active ? fill > 0.12 : (fill > 0.05 && fill < 0.12))
                precondition(edge > (active ? 0.7 : 0.35), "Each fragment needs a visible contour")
            }
        }

        var checks: [() -> Void] = []
        var priorDraws = 0
        func show(_ rects: [CGRect], style: BraceHighlight.Style = .complete) {
            priorDraws = screenDraws
            highlight.show(rects, style: style)
        }
        func expectAutomaticDraw() {
            precondition(screenDraws > priorDraws, "AppKit must draw the panel without a forced bitmap redraw")
            expectPassive()
        }
        checks.append { show(input) }
        checks.append {
            expectAutomaticDraw()
            precondition(panel.frame.size == CGSize(width: 224, height: 58))
            let bitmap = snapshot()
            expectContours(bitmap, rects: input)
            let rects = fragments(input)
            let gap = CGPoint(x: view.bounds.midX, y: (rects[0].minY + rects[1].maxY) / 2)
            precondition(alpha(bitmap, at: gap) == 0, "The interline gap must stay transparent")
            precondition(alpha(bitmap, at: CGPoint(x: 20, y: rects[0].midY)) == 0)
            precondition(alpha(bitmap, at: CGPoint(x: rects[1].maxX + 20, y: rects[1].midY)) == 0)
            show(input, style: .active)
        }
        checks.append {
            expectAutomaticDraw()
            expectContours(snapshot(), rects: input, active: true)
            let swapped = [CGRect(x: -10_080, y: -10_000, width: 95, height: 22),
                           CGRect(x: -10_000, y: -9_968, width: 140, height: 22)]
            show(swapped)
        }
        checks.append {
            expectAutomaticDraw()
            let bitmap = snapshot()
            precondition(alpha(bitmap, at: CGPoint(x: 180, y: 45)) == 0,
                         "Reusing the view must discard an old fragment at the same window size")
            show([input[1]], style: .opening)
        }
        checks.append {
            expectAutomaticDraw()
            precondition(panel.frame.size == CGSize(width: 97, height: 2))
            precondition(alpha(snapshot(), at: CGPoint(x: view.bounds.midX, y: 1)) > 0.75)
            show([input[0]])
        }
        checks.append {
            expectAutomaticDraw()
            precondition(panel.frame.size == CGSize(width: 144, height: 26))
            expectContours(snapshot(), rects: [input[0]])
            let manyLines = (0..<12).map { CGRect(x: -10_000, y: -10_000 + $0 * 24, width: 140, height: 20) }
            show(manyLines)
        }
        checks.append {
            expectAutomaticDraw()
            precondition(panel.frame.height > 180, "A tall union of normal text lines must still render")
            show([input[0], CGRect(x: 0, y: 0, width: 40, height: 200),
                  CGRect(x: CGFloat.nan, y: 0, width: 40, height: 20)])
        }
        checks.append {
            expectAutomaticDraw()
            precondition(panel.frame.size == CGSize(width: 144, height: 26), "Reject invalid fragments individually")
            highlight.hide()
            precondition(!panel.isVisible)
            show(input, style: .active)
        }
        checks.append {
            expectAutomaticDraw()
            expectContours(snapshot(), rects: input, active: true)
            highlight.show([])
            precondition(!panel.isVisible, "Empty geometry must clear a stale highlight")
            method_setImplementation(drawMethod, originalImplementation)
            imp_removeBlock(observer)
            print("Highlight panel checks passed: automatic display, complete/opening/active styles, passive focus, fragments, resize/reuse, tall highlights, invalid geometry, hide/reopen.")
            app.stop(nil)
            app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                          modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                          subtype: 0, data1: 0, data2: 0)!, atStart: false)
        }
        func next(_ index: Int) {
            guard checks.indices.contains(index) else { return }
            checks[index]()
            if index + 1 < checks.count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { next(index + 1) }
            }
        }
        DispatchQueue.main.async { next(0) }
        app.run()
    }
}
