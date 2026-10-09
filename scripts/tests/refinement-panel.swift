import AppKit

@main
private enum RefinementPanelChecks {
    static func main() {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let source = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let sourceText = NSTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        sourceText.string = "Source {phrase} stays unchanged"
        source.contentView = sourceText
        source.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        source.makeFirstResponder(sourceText)
        sourceText.setSelectedRange(NSRange(location: 8, length: 0))

        let popup = FloatingPanel()
        let options = (1...3).map { index in String(repeating: "Option \(index) has enough text to require keyboard scrolling. ", count: 18) }
        popup.show(instruction: "phrase", anchor: nil, options: options)
        let panel = app.windows.first { $0 is SuggestionPanel }!
        var submitted: [String] = []
        var cancellations = 0
        popup.state.submitFeedback = { submitted.append($0); popup.endRefinement() }
        popup.state.cancelRefinement = { cancellations += 1; popup.endRefinement() }

        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func feedbackField() -> NSTextField {
            guard let field = descendants(panel.contentView!).compactMap({ $0 as? NSTextField }).first(where: \.isEditable) else {
                fatalError("Expected the production native feedback field")
            }
            return field
        }
        func feedbackEditor() -> NSTextView {
            let field = feedbackField()
            guard let editor = field.currentEditor() as? NSTextView, panel.firstResponder === editor else {
                fatalError("The field editor must own key input, not just the panel")
            }
            return editor
        }
        func type(_ text: String, replacingAll: Bool = false) {
            let editor = feedbackEditor()
            if replacingAll { editor.selectAll(nil) }
            editor.insertText(text, replacementRange: editor.selectedRange())
        }
        func command(_ selector: Selector) { feedbackEditor().doCommand(by: selector) }
        func expectSource() {
            precondition(sourceText.string == "Source {phrase} stays unchanged")
            precondition(sourceText.selectedRange() == NSRange(location: 8, length: 0))
        }
        var scroll: SuggestionScrollView!
        var offset: CGFloat = 0
        var otherWindow: NSWindow?
        var checks: [() -> Void] = []
        checks.append {
            precondition(!panel.canBecomeKey && !panel.isKeyWindow && !panel.canBecomeMain)
            precondition(panel.styleMask.contains(.nonactivatingPanel))
            scroll = descendants(panel.contentView!).compactMap { $0 as? SuggestionScrollView }.first!
            scroll.navigate(direction: 1, jump: true)
            offset = scroll.contentView.bounds.minY
            precondition(popup.state.selected == 1 && offset > 0)
            popup.beginRefinement(feedback: "")
        }
        checks.append {
            precondition(popup.isRefinementKey && popup.state.isRefining && panel.canBecomeKey)
            precondition(panel.firstResponder === feedbackEditor())
            precondition(popup.state.options == options && popup.state.selected == 1)
            precondition(descendants(panel.contentView!).contains { $0 === scroll }, "Editing must retain the existing suggestion list")
            type("123 👩🏽‍💻 café 日本語")
            precondition(popup.state.feedback == "123 👩🏽‍💻 café 日本語", "Numbers and Unicode must enter the feedback field normally")
            let oldCaret = feedbackEditor().selectedRange().location
            command(#selector(NSResponder.moveLeft(_:)))
            precondition(feedbackEditor().selectedRange().location < oldCaret && popup.state.isRefining,
                         "Arrows must move the native text caret during refinement")
            command(#selector(NSResponder.moveRight(_:)))
            expectSource()
            command(#selector(NSResponder.insertNewline(_:)))
        }
        checks.append {
            precondition(submitted == ["123 👩🏽‍💻 café 日本語"])
            precondition(!popup.isRefinementKey && !popup.state.isRefining && !panel.canBecomeKey && panel.isVisible)
            precondition(source.isKeyWindow && source.firstResponder === sourceText,
                         "Submitting from the local editor must restore its original responder")
            precondition(popup.state.options == options && popup.state.selected == 1)
            precondition(abs(scroll.contentView.bounds.minY - offset) < 1, "Returning must preserve the reading position")
            expectSource()
            popup.beginRefinement(feedback: "   ")
        }
        checks.append {
            precondition(popup.isRefinementKey)
            command(#selector(NSResponder.insertNewline(_:)))
            precondition(submitted.count == 1 && popup.state.isRefining, "Blank feedback must not submit")
            type("Retry with a warmer tone", replacingAll: true)
            command(#selector(NSResponder.cancelOperation(_:)))
        }
        checks.append {
            precondition(cancellations == 1 && !popup.state.isRefining)
            precondition(popup.state.feedback == "Retry with a warmer tone", "Cancellation must retain the draft for reopening")
            precondition(popup.state.options == options && popup.state.selected == 1)
            popup.beginRefinement(feedback: popup.state.feedback)
        }
        checks.append {
            precondition(feedbackField().stringValue == "Retry with a warmer tone")
            let draft = popup.state.feedback
            // Full Keyboard Access can move focus from the field editor onto
            // the Refine control. Session ownership follows the key panel,
            // while initial entry still verifies actual native text focus.
            precondition(panel.makeFirstResponder(panel))
            precondition(popup.ownsRefinementFocus && !popup.isRefinementKey,
                         "Moving focus inside the key popup must retain the refinement session")
            precondition(popup.state.isRefining && popup.state.feedback == draft && popup.state.options == options)
            precondition(panel.makeFirstResponder(feedbackField()))
            precondition(popup.isRefinementKey, "The native editor must be focusable again within the same session")
            let editor = feedbackEditor()
            editor.selectAll(nil)
            editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0), replacementRange: editor.selectedRange())
            precondition(editor.hasMarkedText())
            let delegate = feedbackField().delegate!
            let handled = delegate.control?(feedbackField(), textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))) ?? false
            precondition(!handled && submitted.count == 1, "IME marked input must keep Return before refinement submission")
            let escaped = delegate.control?(feedbackField(), textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))) ?? false
            precondition(!escaped && cancellations == 1, "IME marked input must keep Escape before refinement cancellation")
            panel.cancelOperation(nil)
            precondition(cancellations == 1 && popup.state.isRefining,
                         "A cancel command reaching the panel must still preserve marked input")
            editor.unmarkText()
            popup.endRefinement()
            popup.state.loading = true
            popup.refresh()
            popup.beginRefinement(feedback: "Should not open while loading")
            precondition(!popup.state.isRefining && !panel.canBecomeKey)
            popup.state.loading = false
            popup.beginRefinement(feedback: "Keep the focus where the user puts it")
        }
        checks.append {
            precondition(popup.isRefinementKey)
            panel.makeFirstResponder(panel)
            precondition(popup.ownsRefinementFocus && !popup.isRefinementKey)
            panel.cancelOperation(nil)
            precondition(cancellations == 2 && !popup.state.isRefining && panel.isVisible,
                         "Escape outside the field editor must return to the existing suggestions")
            precondition(popup.state.options == options && popup.state.feedback == "Keep the focus where the user puts it")
            popup.beginRefinement(feedback: popup.state.feedback)
        }
        checks.append {
            precondition(popup.isRefinementKey)
            let other = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 100, height: 100),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            otherWindow = other
            other.makeKeyAndOrderFront(nil)
            popup.endRefinement()
            precondition(other.isKeyWindow, "Ending refinement after outside focus loss must not steal focus back")
            popup.beginRefinement(feedback: "Close me")
        }
        checks.append {
            precondition(popup.isRefinementKey)
            popup.hide()
            precondition(!panel.isVisible && !panel.canBecomeKey && !popup.state.isRefining)
            expectSource()
            otherWindow?.orderOut(nil); source.orderOut(nil)
            print("Refinement panel checks passed: real native field focus, numbers/Unicode/arrows, submit/cancel, blank rejection, IME command ownership, preserved options/selection/scroll/source, loading guard, passive restoration, outside-focus safety, hide cleanup.")
            app.stop(nil)
            app.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                          modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                          subtype: 0, data1: 0, data2: 0)!, atStart: false)
        }
        func next(_ index: Int) {
            checks[index]()
            if index + 1 < checks.count { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { next(index + 1) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { next(0) }
        app.run()
    }
}
