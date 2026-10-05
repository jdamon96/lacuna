import AppKit
import ApplicationServices
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
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var playgroundWindow: NSWindow?
    private var playgroundText: NSTextView?
    private var timer: Timer?
    private var request: Task<Void, Never>?
    private var requestID = UUID()
    private var input: CapturedInput?
    private var template: BraceTemplate?
    private var localMonitor: Any?
    private var triggerMonitor: Any?
    private var lastInvocation: TimeInterval = 0
    private var mouseMonitor: Any?
    private var dismissWork: DispatchWorkItem?
    private var shortcutWorks = true
    private var isRecordingShortcut = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupMainMenu()
        setupMenu()
        shortcut.onPress = { [weak self] in self?.invokeShortcut() }
        // Directly delivered app events do not always go through Carbon's global hotkeys.
        triggerMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.preferences.enabled, !self.isRecordingShortcut, self.isShortcut(event) else { return event }
            if !event.isARepeat { self.invokeShortcut() }
            return nil
        }
        preferences.onSave = { [weak self] in self?.refreshMenu() }
        if preferences.enabled { shortcutWorks = shortcut.register(preferences.shortcut) }
        panel.state.choose = { [weak self] in self?.accept($0) }
        panel.state.dismiss = { [weak self] in self?.dismiss() }
        keyboard.onKey = { [weak self] code, flags in self?.handleKey(code, modified: !flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty) ?? false }
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in self?.poll() }
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
    func applicationWillTerminate(_ notification: Notification) { dismiss(); timer?.invalidate(); if let triggerMonitor { NSEvent.removeMonitor(triggerMonitor) }; if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) } }

    private func setupMainMenu() {
        // AppKit text controls resolve Command-A/C/V/Z through the responder-chain menu.
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Lacuna", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        let fill = appMenu.addItem(withTitle: "Fill template", action: #selector(trigger), keyEquivalent: "")
        fill.target = self
        appMenu.addItem(.separator())
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
        }
        playgroundWindow?.title = "Try Lacuna · \(preferences.shortcut.label) to fill"
        NSApp.activate(ignoringOtherApps: true); playgroundWindow?.makeKeyAndOrderFront(nil)
        playgroundWindow?.makeFirstResponder(playgroundText)
    }

    private func capture() throws -> CapturedInput {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let view = playgroundText, playgroundWindow?.isKeyWindow == true, playgroundWindow?.firstResponder === view {
            let rect = view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil)
            let height = NSScreen.screens.first?.frame.height ?? 0
            let ax = CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
            return CapturedInput(text: view.string, selection: view.selectedRange(), anchor: ax, external: nil, local: view)
        }
        let snapshot = try accessibility.capture()
        return CapturedInput(text: snapshot.text, selection: snapshot.selection, anchor: snapshot.fieldFrame, external: snapshot, local: nil)
    }
    private func matches(_ original: CapturedInput) -> Bool {
        guard let current = try? capture(), current.text == original.text, current.selection == original.selection else { return false }
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

    private func isShortcut(_ event: NSEvent) -> Bool {
        guard let candidate = Shortcut.from(event) else { return false }
        return candidate.keyCode == preferences.shortcut.keyCode && candidate.modifiers == preferences.shortcut.modifiers
    }
    private func invokeShortcut() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastInvocation > 0.15 else { return }
        lastInvocation = now
        // Finish the activating event before installing a temporary chooser monitor.
        DispatchQueue.main.async { [weak self] in self?.trigger() }
    }

    @objc private func trigger() {
        guard preferences.enabled, !isRecordingShortcut else { return }
        if request != nil || !panel.state.options.isEmpty { dismiss(); return }
        dismiss(); highlight.hide()
        do {
            let input = try capture()
            guard let template = BraceTemplate.find(in: input.text, selection: input.selection) else {
                showMessage("Type an instruction in {braces}, then place your cursor nearby.", anchor: input.anchor)
                return
            }
            self.input = input; self.template = template
            let anchor = bounds(template.range, in: input) ?? bounds(input.selection, in: input) ?? input.anchor
            panel.show(instruction: template.instruction, anchor: anchor, loading: true)
            startKeyboard(local: input.local != nil)
            let id = UUID(); requestID = id
            let configuration = preferences.configuration
            request = Task { @MainActor [weak self] in
                do {
                    let suggestions = try await CompletionClient().suggestions(for: template, in: input.text, configuration: configuration)
                    guard let self, !Task.isCancelled, self.requestID == id else { return }
                    self.request = nil
                    guard self.matches(input) else { self.dismiss(); return }
                    self.panel.show(instruction: template.instruction, anchor: anchor, options: suggestions)
                } catch {
                    guard let self, !Task.isCancelled, self.requestID == id else { return }
                    self.request = nil; self.input = nil; self.template = nil
                    self.showMessage(error.localizedDescription, anchor: anchor)
                }
            }
        } catch { showMessage(error.localizedDescription, anchor: nil) }
    }
    private func poll() {
        guard preferences.enabled else { highlight.hide(); return }
        if let input {
            if !matches(input) { dismiss() }
            return
        }
        guard !panel.isVisible, preferences.highlights, let candidate = try? capture(),
              let template = BraceTemplate.find(in: candidate.text, selection: candidate.selection),
              let rect = bounds(template.range, in: candidate) else { highlight.hide(); return }
        highlight.show(rect)
    }

    private func startKeyboard(local: Bool) {
        stopKeyboard()
        if local {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if self?.isShortcut(event) == true { return event }
                let modified = !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                return self?.handleKey(event.keyCode, modified: modified) == true ? nil : event
            }
        } else if !keyboard.start() {
            // Mouse buttons remain functional when macOS has not enabled key interception yet.
            panel.state.message = "Keyboard access is unavailable. Reopen Lacuna after enabling Accessibility."
        }
    }
    private func stopKeyboard() { keyboard.stop(); if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil }
    private func handleKey(_ code: UInt16, modified: Bool) -> Bool {
        if code == 53 { DispatchQueue.main.async { [weak self] in self?.dismiss() }; return true }
        guard !modified else { dismiss(); return false }
        let options = panel.state.options
        if !options.isEmpty {
            let numbers: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 83: 0, 84: 1, 85: 2]
            if let index = numbers[code], index < options.count {
                DispatchQueue.main.async { [weak self] in self?.accept(index) }; return true
            }
            if code == 125 || code == 126 || code == 48 {
                let delta = code == 126 ? -1 : 1
                panel.state.selected = (panel.state.selected + delta + options.count) % options.count
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
        guard let input, let template, panel.state.options.indices.contains(index) else { return }
        let replacement = panel.state.options[index]
        // Stop intercepting before posting any insertion events.
        stopKeyboard(); panel.hide(); highlight.hide(); request?.cancel(); request = nil
        do {
            guard matches(input) else { throw AccessibilityBridgeError.changedText }
            if let external = input.external { try accessibility.replace(range: template.range, with: replacement, in: external) }
            else if let view = input.local {
                guard view.shouldChangeText(in: template.range, replacementString: replacement) else { throw AccessibilityBridgeError.replacementUnavailable }
                view.insertText(replacement, replacementRange: template.range)
            }
            dismiss()
        } catch { dismiss(); showMessage(error.localizedDescription, anchor: input.anchor) }
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
        input = nil; template = nil
        dismissWork?.cancel(); dismissWork = nil
        stopKeyboard(); panel.hide(); panel.state.options = []; highlight.hide()
    }
}
