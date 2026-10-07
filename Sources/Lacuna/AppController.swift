import AppKit
import ApplicationServices
import Carbon
import SwiftUI
import LacunaCore

private struct CapturedInput {
    let text: String
    let selection: NSRange
    let anchor: CGRect?
    let external: FocusedTextSnapshot?
    let local: NSTextView?
}

final class AppController: NSObject, NSApplicationDelegate {
    private let preferences = Preferences()
    private let accessibility = AccessibilityBridge()
    private let shortcut = GlobalShortcut()
    private let keyboard = ChoiceKeyboard()
    private let panel = FloatingPanel()
    private let highlight = BraceHighlight()
    private let compatibilityReport = CompatibilityReportWindow()
    private let updater = AppUpdater()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var playgroundWindow: NSWindow?
    private var playgroundText: NSTextView?
    private var timer: Timer?
    private var request: Task<Void, Never>?
    private var insertion: Task<Void, Never>?
    private var suggestions = SuggestionCache()
    private var requestID = UUID()
    private var input: CapturedInput?
    private var template: BraceTemplate?
    private var sequence: TemplateSequence?
    private var localMonitor: Any?
    private var triggerMonitor: Any?
    private var lastInvocation: TimeInterval = 0
    private var mouseMonitor: Any?
    private var playgroundObservers: [NSObjectProtocol] = []
    private var dismissWork: DispatchWorkItem?
    private var shortcutWorks = true
    private var isRecordingShortcut = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        updater.willShowUI = { [weak self] in self?.dismiss(); self?.highlight.hide() }
        updater.start()
        setupMainMenu()
        setupMenu()
        shortcut.onPress = { [weak self] in self?.invokeShortcut() }
        // Directly delivered app events do not always go through Carbon's global hotkeys.
        triggerMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.preferences.enabled, !self.isRecordingShortcut, self.isShortcut(event) else { return event }
            if !event.isARepeat { self.invokeShortcut() }
            return nil
        }
        preferences.onSave = { [weak self] in
            // A saved profile can include a different API account.
            self?.suggestions.clear()
            self?.refreshMenu()
        }
        if preferences.enabled { shortcutWorks = shortcut.register(preferences.shortcut) }
        panel.state.choose = { [weak self] in self?.accept($0) }
        panel.state.dismiss = { [weak self] in self?.dismiss() }
        panel.state.copySelected = { [weak self] in self?.copySelected() }
        panel.state.regenerate = { [weak self] in self?.beginSuggestions(refresh: true) }
        keyboard.onKey = { [weak self] code, flags in
            guard let self, !self.isShortcut(code, flags: flags) else { return false }
            return self.handleKey(code, modified: !flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty,
                                  commandOnly: flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]) == .maskCommand)
        }
        // Keep the overlay following text during window drags/live resize too.
        let trackingTimer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }
        trackingTimer.tolerance = 0.025
        RunLoop.main.add(trackingTimer, forMode: .common)
        timer = trackingTimer
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] _ in
            self?.dismiss(); self?.highlight.hide()
        }
        if !UserDefaults.standard.bool(forKey: "hasOpened") || !shortcutWorks {
            showSettings()
            UserDefaults.standard.set(true, forKey: "hasOpened")
        }
        if CommandLine.arguments.contains("--settings") { showSettings() }
        if CommandLine.arguments.contains("--playground") { showPlayground() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        dismiss(); timer?.invalidate()
        if let triggerMonitor { NSEvent.removeMonitor(triggerMonitor) }
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        playgroundObservers.forEach(NotificationCenter.default.removeObserver)
    }

    private func setupMainMenu() {
        // AppKit text controls resolve Command-A/C/V/Z through the responder-chain menu.
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Lacuna", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(updater.makeMenuItem())
        appMenu.addItem(updater.makeAutomaticChecksMenuItem())
        appMenu.addItem(.separator())
        let fill = appMenu.addItem(withTitle: "Fill template", action: #selector(trigger), keyEquivalent: "")
        fill.target = self
        appMenu.addItem(.separator())
        let inspect = appMenu.addItem(withTitle: "Inspect text field…", action: #selector(inspectTextField), keyEquivalent: "")
        inspect.target = self
        appMenu.addItem(withTitle: "Quit Lacuna", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "{ }"
        statusItem.button?.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        statusItem.button?.setAccessibilityLabel("Lacuna")
        refreshMenu()
    }
    private func refreshMenu() {
        let menu = NSMenu()
        let title = NSMenuItem(title: "Lacuna · \(preferences.shortcut.label)", action: nil, keyEquivalent: "")
        title.isEnabled = false; menu.addItem(title)
        menu.addItem(.separator())
        let enabled = NSMenuItem(title: "Enable Lacuna", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self; enabled.state = preferences.enabled ? .on : .off; menu.addItem(enabled)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self; menu.addItem(settings)
        let playground = NSMenuItem(title: "Try Lacuna…", action: #selector(showPlayground), keyEquivalent: "")
        playground.target = self; menu.addItem(playground)
        let inspect = NSMenuItem(title: "Inspect text field…", action: #selector(inspectTextField), keyEquivalent: "")
        inspect.target = self; menu.addItem(inspect)
        menu.addItem(updater.makeMenuItem())
        menu.addItem(updater.makeAutomaticChecksMenuItem())
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Lacuna", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit); statusItem.menu = menu
        statusItem.button?.appearsDisabled = !preferences.enabled
        statusItem.button?.toolTip = preferences.enabled ? "Lacuna · \(preferences.shortcut.label)" : "Lacuna is paused"
    }
    @objc private func toggleEnabled() {
        preferences.enabled.toggle(); dismiss(); highlight.hide()
        if preferences.enabled { shortcutWorks = shortcut.register(preferences.shortcut) } else { shortcut.unregister() }
        refreshMenu()
    }

    @objc private func inspectTextField() {
        let report = TextFieldCompatibilityReport.capture(using: accessibility)
        dismiss(); highlight.hide()
        compatibilityReport.show(report)
    }

    @objc func showSettings() {
        dismiss(); highlight.hide()
        if settingsWindow == nil {
            let view = SettingsView(preferences: preferences, accessibility: accessibility, saveShortcut: { [weak self] candidate in
                guard let self else { return false }
                let worked = self.shortcut.register(candidate)
                if !worked { _ = self.shortcut.register(self.preferences.shortcut) }
                if !self.preferences.enabled { self.shortcut.unregister() }
                self.shortcutWorks = worked
                return worked
            }, recordingChanged: { [weak self] recording in
                guard let self else { return }
                self.isRecordingShortcut = recording
                if recording { self.shortcut.unregister() }
                else if self.preferences.enabled { self.shortcutWorks = self.shortcut.register(self.preferences.shortcut) }
            }, openPlayground: { [weak self] in self?.showPlayground() })
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 610, height: 700), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Lacuna"; window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: view); window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showPlayground() {
        dismiss()
        if playgroundWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 650, height: 340), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Try Lacuna · \(preferences.shortcut.label) to fill"; window.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: window.contentView!.bounds)
            scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
            let text = NSTextView(frame: scroll.bounds)
            text.isRichText = false; text.allowsUndo = true; text.font = .systemFont(ofSize: 19)
            text.textContainerInset = NSSize(width: 26, height: 26)
            text.autoresizingMask = [.width]; text.isVerticallyResizable = true
            text.textContainer?.widthTracksTextView = true
            text.string = "Hi Alex,\n\nThanks for taking the time to share your feedback. {a warm one-sentence sign-off}"
            text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
            scroll.documentView = text; window.contentView = scroll; window.center()
            playgroundText = text; playgroundWindow = window
            // Native editor events can refresh in the same display cycle;
            // external applications continue using the bounded AX poll.
            scroll.contentView.postsBoundsChangedNotifications = true
            let observations: [(Notification.Name, AnyObject)] = [
                (NSWindow.didMoveNotification, window),
                (NSWindow.didResizeNotification, window),
                (NSWindow.didChangeScreenNotification, window),
                (NSText.didChangeNotification, text),
                (NSTextView.didChangeSelectionNotification, text),
                (NSView.boundsDidChangeNotification, scroll.contentView)
            ]
            playgroundObservers = observations.map { name, object in
                NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    self?.poll()
                }
            }
        }
        playgroundWindow?.title = "Try Lacuna · \(preferences.shortcut.label) to fill"
        NSApp.activate(ignoringOtherApps: true); playgroundWindow?.makeKeyAndOrderFront(nil)
        playgroundWindow?.makeFirstResponder(playgroundText)
    }

    private func capture(forHighlighting: Bool = false) throws -> CapturedInput {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let view = playgroundText, playgroundWindow?.isKeyWindow == true, playgroundWindow?.firstResponder === view {
            let rect = view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil)
            let height = NSScreen.screens.first?.frame.height ?? 0
            let ax = CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
            return CapturedInput(text: view.string, selection: view.selectedRange(), anchor: ax, external: nil, local: view)
        }
        let snapshot = try forHighlighting ? accessibility.captureForHighlighting() : accessibility.capture()
        return CapturedInput(text: snapshot.text, selection: snapshot.selection, anchor: snapshot.fieldFrame, external: snapshot, local: nil)
    }
    private func matches(_ original: CapturedInput) -> Bool {
        matchingInput(original) != nil
    }
    private func matchingInput(_ original: CapturedInput) -> CapturedInput? {
        guard let current = try? capture(), current.text.utf16.elementsEqual(original.text.utf16),
              current.selection == original.selection, sameEditor(current, original) else { return nil }
        return current
    }
    private func sameEditor(_ current: CapturedInput, _ original: CapturedInput) -> Bool {
        if let a = original.external, let b = current.external { return a.pid == b.pid && CFEqual(a.element, b.element) }
        return original.local != nil && current.local === original.local
    }
    private func bounds(_ range: NSRange, in input: CapturedInput) -> CGRect? {
        if let external = input.external { return accessibility.bounds(for: range, in: external) }
        if let local = input.local {
            let rect = local.firstRect(forCharacterRange: range, actualRange: nil)
            let height = NSScreen.screens.first?.frame.height ?? 0
            return CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
        }
        return nil
    }

    @discardableResult
    private func showHighlights(in input: CapturedInput, active: NSRange? = nil) -> [CGRect] {
        let plan = BraceHighlightPlan(text: input.text, selection: input.selection,
                                     activeRange: active, showInactive: preferences.highlights)
        let geometry: [[CGRect]]
        if let external = input.external {
            geometry = accessibility.highlightBounds(for: plan.items.map(\.range), in: external)
        } else if let local = input.local {
            let deadline = ProcessInfo.processInfo.systemUptime + 0.08
            geometry = plan.items.map { item in
                guard ProcessInfo.processInfo.systemUptime < deadline else { return [] }
                return NativeTextGeometry.highlightBounds(for: item.range, in: local)
            }
        } else { geometry = plan.items.map { _ in [] } }
        let regions = zip(plan.items, geometry).map { item, rects in
            let style: BraceHighlight.Style
            switch item.style {
            case .opening: style = .opening
            case .complete: style = .complete
            case .active: style = .active
            }
            return BraceHighlight.Region(rects: rects, style: style)
        }
        var fieldIndicator: BraceHighlight.FieldIndicator?
        let omittedPhrases = preferences.highlights && plan.phraseCount > plan.items.filter { $0.style != .opening }.count
        if !plan.items.isEmpty, geometry.contains(where: \.isEmpty) || omittedPhrases {
            var field = input.external?.fieldFrame
            if let local = input.local, let window = local.window {
                let screen = window.convertToScreen(local.convert(local.visibleRect, to: nil))
                field = FloatingPanel.appKitRect(screen)
            }
            if let field {
                let title = plan.phraseCount > 0
                    ? "Lacuna · \(plan.phraseCount) \(plan.phraseCount == 1 ? "phrase" : "phrases")"
                    : "Lacuna · Instruction started"
                fieldIndicator = BraceHighlight.FieldIndicator(frame: field, title: title)
            }
        }
        highlight.show(regions: regions, fieldIndicator: fieldIndicator)
        return zip(plan.items, geometry).first(where: { $0.0.style == .active })?.1 ?? []
    }

    private func isShortcut(_ event: NSEvent) -> Bool {
        guard let candidate = Shortcut.from(event) else { return false }
        return candidate.keyCode == preferences.shortcut.keyCode && candidate.modifiers == preferences.shortcut.modifiers
    }
    private func isShortcut(_ code: UInt16, flags: CGEventFlags) -> Bool {
        var modifiers: UInt32 = 0
        if flags.contains(.maskCommand) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.maskControl) { modifiers |= UInt32(controlKey) }
        if flags.contains(.maskAlternate) { modifiers |= UInt32(optionKey) }
        if flags.contains(.maskShift) { modifiers |= UInt32(shiftKey) }
        return UInt32(code) == preferences.shortcut.keyCode && modifiers == preferences.shortcut.modifiers
    }
    private func invokeShortcut() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastInvocation > 0.15 else { return }
        lastInvocation = now
        // Finish the activating event before installing a temporary chooser monitor.
        DispatchQueue.main.async { [weak self] in self?.trigger() }
    }

    @objc private func trigger() {
        guard preferences.enabled, !isRecordingShortcut, insertion == nil else { return }
        if request != nil || !panel.state.options.isEmpty { dismiss(); return }
        beginSuggestions()
    }
    private func beginSuggestions(refresh: Bool = false) {
        guard preferences.enabled, !isRecordingShortcut, insertion == nil else { return }
        let previousInput = input
        let previousSequence = sequence
        dismiss(); highlight.hide()
        do {
            let input = try capture()
            let sequence: TemplateSequence
            if refresh {
                guard let previousInput, let previousSequence,
                      sameEditor(input, previousInput), previousSequence.isValid(in: input.text) else {
                    throw AccessibilityBridgeError.changedText
                }
                sequence = previousSequence
            } else {
                sequence = TemplateSequence(text: input.text)
            }
            guard sequence.current != nil else {
                if let opening = BraceTemplate.pendingOpening(in: input.text, selection: input.selection) {
                    showMessage("Close the instruction with } to get suggestions.", anchor: bounds(opening, in: input) ?? input.anchor)
                } else {
                    showMessage("Type an instruction in {braces}, then press the shortcut to fill it.", anchor: input.anchor)
                }
                return
            }
            presentSuggestions(in: input, sequence: sequence, refresh: refresh)
        } catch { showMessage(error.localizedDescription, anchor: nil) }
    }

    private func presentSuggestions(in input: CapturedInput, sequence: TemplateSequence, refresh: Bool = false) {
        guard let template = sequence.current(in: input.text) else { dismiss(); return }
        self.input = input; self.template = template; self.sequence = sequence
        let rects = showHighlights(in: input, active: template.range)
        // Anchor below all visible fragments, so the chooser doesn't cover a
        // continuation line of the phrase being filled.
        let anchor = rects.isEmpty ? bounds(template.range, in: input) ?? input.anchor
            : rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        let number = sequence.completedCount + 1
        let count = sequence.totalCount
        let configuration = preferences.configuration
        let cacheKey = SuggestionCacheKey(text: input.text, template: template, configuration: configuration)
        if !refresh, let cached = suggestions.suggestions(for: cacheKey) {
            panel.show(instruction: template.instruction, anchor: anchor, options: cached, phraseNumber: number, phraseCount: count)
            startKeyboard(local: input.local != nil)
            return
        }
        panel.show(instruction: template.instruction, anchor: anchor, loading: true, phraseNumber: number, phraseCount: count)
        startKeyboard(local: input.local != nil)
        let id = UUID(); requestID = id
        request = Task { @MainActor [weak self] in
            do {
                let suggestions = try await CompletionClient().suggestions(for: template, in: input.text, configuration: configuration)
                guard let self, !Task.isCancelled, self.requestID == id else { return }
                self.request = nil
                self.suggestions.store(suggestions, for: cacheKey)
                guard let current = self.matchingInput(input) else { self.dismiss(); return }
                let currentRects = self.showHighlights(in: current, active: template.range)
                let currentAnchor = currentRects.isEmpty ? self.bounds(template.range, in: current) ?? current.anchor
                    : currentRects.dropFirst().reduce(currentRects[0]) { $0.union($1) }
                self.panel.show(instruction: template.instruction, anchor: currentAnchor, options: suggestions, phraseNumber: number, phraseCount: count)
            } catch {
                guard let self, !Task.isCancelled, self.requestID == id else { return }
                self.dismiss()
                self.showMessage(error.localizedDescription, anchor: anchor)
            }
        }
    }
    private func poll() {
        guard preferences.enabled else { highlight.hide(); return }
        // Insertion deliberately changes the selected range before changing the text.
        guard insertion == nil else { return }
        if let input {
            if let current = matchingInput(input), let template {
                let rects = showHighlights(in: current, active: template.range)
                let anchor = rects.isEmpty ? current.anchor : rects.dropFirst().reduce(rects[0]) { $0.union($1) }
                panel.reanchor(anchor)
            } else { dismiss() }
            return
        }
        guard !panel.isVisible, preferences.highlights, let candidate = try? capture(forHighlighting: true) else { highlight.hide(); return }
        showHighlights(in: candidate)
    }

    private func startKeyboard(local: Bool) {
        stopKeyboard()
        if local {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if self?.isShortcut(event) == true { return event }
                let modified = !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                let commandOnly = event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
                return self?.handleKey(event.keyCode, modified: modified, commandOnly: commandOnly) == true ? nil : event
            }
        } else if !keyboard.start() {
            // Mouse buttons remain functional when macOS has not enabled key interception yet.
            panel.state.message = "Keyboard access is unavailable. Reopen Lacuna after enabling Accessibility."
        }
    }
    private func stopKeyboard() { keyboard.stop(); if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil }
    private func handleKey(_ code: UInt16, modified: Bool, commandOnly: Bool) -> Bool {
        if code == 53 { DispatchQueue.main.async { [weak self] in self?.dismiss() }; return true }
        if commandOnly, !panel.state.options.isEmpty {
            if code == 8 { copySelected(); return true }
            if code == 15 {
                DispatchQueue.main.async { [weak self] in self?.beginSuggestions(refresh: true) }
                return true
            }
        }
        guard !modified else { dismiss(); return false }
        if panel.state.loading, panel.state.options.isEmpty,
           [18, 19, 20, 83, 84, 85, 36, 76, 48, 125, 126].contains(code) {
            // A repeated choice key between phrases must not type into the
            // editor (or submit its form) while the next options are loading.
            return true
        }
        let options = panel.state.options
        if !options.isEmpty {
            let numbers: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 83: 0, 84: 1, 85: 2]
            if let index = numbers[code], index < options.count {
                DispatchQueue.main.async { [weak self] in self?.accept(index) }; return true
            }
            if code == 125 || code == 126 || code == 48 {
                let delta = code == 126 ? -1 : 1
                panel.state.navigate?(delta, code == 48)
                return true
            }
            if code == 36 || code == 76 {
                let selected = panel.state.selected
                DispatchQueue.main.async { [weak self] in self?.accept(selected) }; return true
            }
        }
        dismiss(); return false
    }
    private func accept(_ index: Int) {
        guard insertion == nil, panel.state.canInsert,
              let input, let template, panel.state.options.indices.contains(index) else { return }
        let replacement = panel.state.options[index]
        // Stop intercepting before posting any insertion events.
        stopKeyboard(); highlight.hide(); request?.cancel(); request = nil
        panel.state.selected = index
        panel.setInserting(true)
        let id = UUID(); requestID = id
        insertion = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                guard self.matches(input) else { throw AccessibilityBridgeError.changedText }
                if let external = input.external {
                    try await self.accessibility.replace(range: template.range, with: replacement, in: external)
                } else if let view = input.local {
                    // insertText performs the delegate check and undo registration
                    // itself. Calling shouldChangeText first registers the edit twice.
                    view.insertText(replacement, replacementRange: template.range)
                    let expected = (input.text as NSString).replacingCharacters(in: template.range, with: replacement)
                    guard view.string.utf16.elementsEqual(expected.utf16) else {
                        throw view.string.utf16.elementsEqual(input.text.utf16)
                            ? AccessibilityBridgeError.replacementUnavailable
                            : AccessibilityBridgeError.replacementUnconfirmed
                    }
                }
                self.insertion = nil
                guard self.requestID == id else { return }
                // Re-read the same editor after insertion. Later requests see the
                // accepted wording, and only the original queued phrases advance.
                let current = try? self.capture()
                var next = self.sequence
                let canContinue = current.map { current in
                    self.sameEditor(current, input)
                        && next?.advance(afterReplacingWith: replacement, in: current.text) == true
                } ?? false
                self.dismiss()
                if canContinue, let current, let next, next.current != nil {
                    self.presentSuggestions(in: current, sequence: next)
                }
            } catch {
                self.insertion = nil
                guard self.requestID == id else { return }
                // A failed attempt may have selected the braces. Rebind only when
                // the same editor still contains exactly the original text.
                let current = try? self.capture()
                // An unconfirmed write can still be pending in the target app.
                // Keep its candidates copyable, without offering an immediate retry.
                let uncertain = (error as? AccessibilityBridgeError) == .replacementUnconfirmed
                let retryInput = uncertain ? nil : current.flatMap { self.sameEditor($0, input) && $0.text.utf16.elementsEqual(input.text.utf16) ? $0 : nil }
                self.input = retryInput
                let recovery = retryInput == nil
                    ? "Your options are kept below. Copy a suggestion, or return to the braces and reopen Lacuna."
                    : "Your options are kept below. Try again, or copy a suggestion."
                self.panel.showInsertionError(error.localizedDescription + "\n" + recovery, canInsert: retryInput != nil)
                self.startKeyboard(local: retryInput?.local != nil || NSApp.isActive)
            }
        }
    }
    private func copySelected() {
        guard insertion == nil, panel.state.options.indices.contains(panel.state.selected) else { return }
        let value = panel.state.options[panel.state.selected]
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
    private func showMessage(_ text: String, anchor: CGRect?) {
        panel.show(instruction: "", anchor: anchor, message: text)
        startKeyboard(local: NSApp.isActive)
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissWork?.cancel(); dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }
    private func dismiss() {
        requestID = UUID(); request?.cancel(); request = nil
        // Keep the task reference until it finishes any already-posted paste and
        // clipboard restoration. No new insertion may overlap that cleanup.
        insertion?.cancel()
        input = nil; template = nil; sequence = nil
        dismissWork?.cancel(); dismissWork = nil
        stopKeyboard(); panel.hide(); panel.state.options = []; highlight.hide()
    }
}
