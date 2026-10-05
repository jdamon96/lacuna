import AppKit
import ApplicationServices
import LacunaCore

/// Accessibility ranges are UTF-16 offsets. Frames are global screen coordinates
/// with the origin at the top-left of the main display, not AppKit coordinates.
struct FocusedTextSnapshot {
    let element: AXUIElement
    let pid: pid_t
    let text: String
    let selection: NSRange
    let fieldFrame: CGRect?
}

enum AccessibilityBridgeError: LocalizedError {
    case permissionRequired
    case noEditableText
    case secureText
    case unavailableText
    case unsupportedSelection
    case changedText
    case invalidRange
    case clipboardUnavailable
    case replacementUnavailable
    case replacementUnconfirmed

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "Allow Lacuna in System Settings → Privacy & Security → Accessibility, then try again."
        case .noEditableText:
            return "Place your cursor in an editable text field, then try again."
        case .secureText:
            return "Lacuna does not read or change password fields."
        case .unavailableText:
            return "This app does not expose its text to macOS Accessibility. Try a standard text field in another app."
        case .unsupportedSelection:
            return "This text field does not support accessible text selection. Try another text field."
        case .changedText:
            return "The text, cursor, or focused field changed. Return to the braces and reopen Lacuna."
        case .invalidRange:
            return "The template is no longer at its original position. Run Lacuna again."
        case .clipboardUnavailable:
            return "Lacuna could not preserve the current clipboard, so it left the text unchanged."
        case .replacementUnavailable:
            return "This app did not allow Lacuna to replace the template."
        case .replacementUnconfirmed:
            return "Lacuna could not confirm the replacement. Check the text before trying again."
        }
    }
}

final class AccessibilityBridge {
    private let system = AXUIElementCreateSystemWide()
    private var replacing = false
    private var pastePreferredProcesses = Set<pid_t>()

    var isTrusted: Bool { AXIsProcessTrusted() }

    init() {
        // An unresponsive app should not hold up the menu bar indefinitely.
        AXUIElementSetMessagingTimeout(system, 0.3)
    }

    func requestPermission() {
        if !isTrusted {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        }
        // The system may suppress a prompt that was dismissed previously. The
        // same action remains useful for both Enable and Settings buttons.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func capture() throws -> FocusedTextSnapshot {
        guard isTrusted else { throw AccessibilityBridgeError.permissionRequired }
        let element = try focusedElement()
        AXUIElementSetMessagingTimeout(element, 0.3)
        try requireEditable(element)

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid != ProcessInfo.processInfo.processIdentifier else {
            throw AccessibilityBridgeError.noEditableText
        }
        guard let text = text(of: element) else {
            throw AccessibilityBridgeError.unavailableText
        }
        guard let selection = selection(of: element), valid(selection, in: text),
              isSettable(kAXSelectedTextRangeAttribute, on: element) else {
            throw AccessibilityBridgeError.unsupportedSelection
        }
        return FocusedTextSnapshot(
            element: element, pid: pid, text: text,
            selection: selection, fieldFrame: frame(of: element)
        )
    }

    /// The returned rectangle uses AX global, top-left screen coordinates.
    func bounds(for range: NSRange, in snapshot: FocusedTextSnapshot) -> CGRect? {
        guard valid(range, in: snapshot.text), let parameter = axRange(range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            snapshot.element, kAXBoundsForRangeParameterizedAttribute as CFString,
            parameter, &result
        ) == .success, let value = axValue(result, type: .cgRect) else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value, .cgRect, &rect), rect.isUsableAXFrame else { return nil }
        return rect
    }

    /// Only the requested UTF-16 range is replaced. Never sets the whole field's
    /// value, which can destroy rich text, editor state, or unrelated user edits.
    @MainActor func replace(range: NSRange, with replacement: String, in snapshot: FocusedTextSnapshot) async throws {
        guard !replacing else { throw AccessibilityBridgeError.replacementUnavailable }
        replacing = true
        defer { replacing = false }
        try Task.checkCancellation()
        guard valid(range, in: snapshot.text) else { throw AccessibilityBridgeError.invalidRange }
        try validate(snapshot, expectedSelection: snapshot.selection)
        let expected = (snapshot.text as NSString).replacingCharacters(in: range, with: replacement)
        if sameText(expected, snapshot.text) { return }

        try Task.checkCancellation()
        guard let rangeValue = axRange(range),
              AXUIElementSetAttributeValue(
                snapshot.element, kAXSelectedTextRangeAttribute as CFString, rangeValue
              ) == .success else { throw AccessibilityBridgeError.unsupportedSelection }

        var insertionAttempted = false
        do {
            // Setting a range can fail silently in a custom editor. Read it back
            // before either direct replacement or sending a paste event.
            try await waitForSelection(range, in: snapshot)
            if !shouldPasteFirst(in: snapshot), isSettable(kAXSelectedTextAttribute, on: snapshot.element) {
                try Task.checkCancellation()
                try validate(snapshot, expectedSelection: range)
                try Task.checkCancellation()
                insertionAttempted = true
                _ = AXUIElementSetAttributeValue(
                    snapshot.element, kAXSelectedTextAttribute as CFString, replacement as CFString
                )
                // Success can mean an ignored AX setter; an error can accompany
                // a completed edit. The text, not the return code, decides.
                switch await waitForReplacement(expected, range: range, in: snapshot, timeout: 1.2) {
                case .confirmed:
                    return
                case .unchanged:
                    // A browser/custom editor may advertise a writable setter
                    // but ignore it. Avoid that route in this process next time.
                    pastePreferredProcesses.insert(snapshot.pid)
                case .unconfirmed:
                    throw AccessibilityBridgeError.replacementUnconfirmed
                }
            }
            // Dismissing the chooser while an AX attempt was being verified
            // must not cause a later paste. Once paste is posted, however,
            // bounded verification and clipboard cleanup always finish.
            try Task.checkCancellation()
            try validate(snapshot, expectedSelection: range)
            insertionAttempted = true
            try await paste(replacement, expected: expected, range: range, in: snapshot)
        } catch {
            // After any insertion command, its outcome may be delayed. Moving
            // the caret then could redirect that command into unrelated text.
            if !insertionAttempted {
                restoreSelectionIfUnchanged(snapshot, temporaryRange: range)
            }
            throw error
        }
    }

    private func focusedElement() throws -> AXUIElement {
        guard let value = attribute(kAXFocusedUIElementAttribute, on: system),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw AccessibilityBridgeError.noEditableText
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func requireEditable(_ element: AXUIElement) throws {
        let role = attribute(kAXRoleAttribute, on: element) as? String
        let subrole = attribute(kAXSubroleAttribute, on: element) as? String
        // Check before reading AXValue, including when revalidating an edit.
        guard subrole != kAXSecureTextFieldSubrole,
              role != kAXSecureTextFieldSubrole else { throw AccessibilityBridgeError.secureText }
        guard (attribute(kAXEnabledAttribute, on: element) as? Bool) != false else {
            throw AccessibilityBridgeError.noEditableText
        }
        let explicitlyEditable = attribute(kAXIsEditableAttribute, on: element) as? Bool
        let textRole = role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole
        guard explicitlyEditable != false,
              textRole || explicitlyEditable == true,
              explicitlyEditable == true || isSettable(kAXValueAttribute, on: element)
                || isSettable(kAXSelectedTextAttribute, on: element) else {
            throw AccessibilityBridgeError.noEditableText
        }
    }

    private func validate(_ snapshot: FocusedTextSnapshot, expectedSelection: NSRange) throws {
        guard isTrusted else { throw AccessibilityBridgeError.permissionRequired }
        let focused = try focusedElement()
        guard CFEqual(focused, snapshot.element) else { throw AccessibilityBridgeError.changedText }
        try requireEditable(focused)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid,
              let current = text(of: focused), sameText(current, snapshot.text),
              selection(of: focused) == expectedSelection else {
            throw AccessibilityBridgeError.changedText
        }
    }

    @MainActor private func paste(_ replacement: String, expected: String, range: NSRange,
                                  in snapshot: FocusedTextSnapshot) async throws {
        try Task.checkCancellation()
        let pasteboard = NSPasteboard.general
        let originalChangeCount = pasteboard.changeCount
        let savedItems = try copyPasteboardItems(pasteboard)
        guard pasteboard.changeCount == originalChangeCount else {
            throw AccessibilityBridgeError.clipboardUnavailable
        }
        try validate(snapshot, expectedSelection: range)
        guard let source = CGEventSource(stateID: .privateState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            throw AccessibilityBridgeError.replacementUnavailable
        }

        try Task.checkCancellation()
        pasteboard.clearContents()
        let didWrite = pasteboard.setString(replacement, forType: .string)
        let lacunaChangeCount = pasteboard.changeCount
        let restore = {
            // Never overwrite a copy made by the user or another app after us.
            guard pasteboard.changeCount == lacunaChangeCount else { return }
            pasteboard.clearContents()
            if !savedItems.isEmpty { _ = pasteboard.writeObjects(savedItems) }
        }
        // This scope outlives cancellation and verification. Do not restore on
        // a fixed timer: a slow editor may not have consumed the paste yet.
        defer { restore() }
        guard didWrite else {
            throw AccessibilityBridgeError.clipboardUnavailable
        }
        try Task.checkCancellation()
        try validate(snapshot, expectedSelection: range)
        try Task.checkCancellation()

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        // Target the captured process so a last-moment app switch cannot paste
        // the suggestion into some unrelated application.
        keyDown.postToPid(snapshot.pid)
        keyUp.postToPid(snapshot.pid)

        // Exactly one paste is posted. In particular, never retry a slow paste
        // or switch insertion methods after a partial/mismatched edit.
        let result = await waitForReplacement(expected, range: range, in: snapshot, timeout: 3.0)
        guard result == .confirmed else {
            throw AccessibilityBridgeError.replacementUnconfirmed
        }
    }

    private func copyPasteboardItems(_ pasteboard: NSPasteboard) throws -> [NSPasteboardItem] {
        try (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type), copy.setData(data, forType: type) else {
                    throw AccessibilityBridgeError.clipboardUnavailable
                }
            }
            return copy
        }
    }

    @MainActor private func waitForSelection(_ range: NSRange, in snapshot: FocusedTextSnapshot) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        repeat {
            try Task.checkCancellation()
            let focused = try focusedElement()
            guard CFEqual(focused, snapshot.element),
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else {
                throw AccessibilityBridgeError.changedText
            }
            try requireEditable(focused)
            guard let current = text(of: focused), sameText(current, snapshot.text),
                  let selected = selection(of: focused) else { throw AccessibilityBridgeError.changedText }
            if selected == range { return }
            guard selected == snapshot.selection else { throw AccessibilityBridgeError.changedText }
            if ProcessInfo.processInfo.systemUptime >= deadline { break }
            await pauseForReadback()
        } while true
        throw AccessibilityBridgeError.unsupportedSelection
    }

    @MainActor private func waitForReplacement(_ expected: String, range: NSRange,
                                               in snapshot: FocusedTextSnapshot,
                                               timeout: TimeInterval) async -> ReplacementReadback.Outcome {
        var readback = ReplacementReadback(original: snapshot.text, expected: expected)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        repeat {
            // Refresh the object from the focused field rather than repeatedly
            // reading only the object captured before the network request.
            if isTrusted, let focused = try? focusedElement(), CFEqual(focused, snapshot.element),
               NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid,
               (try? requireEditable(focused)) != nil {
                readback.observe(text: text(of: focused), targetIsFocused: true,
                                 selectionMatches: selection(of: focused) == range)
            } else {
                readback.observe(text: nil, targetIsFocused: false, selectionMatches: false)
                // Do not end early after posting a paste: that would restore
                // the previous clipboard before the queued event is consumed.
            }
            if readback.confirmed { return .confirmed }
            if ProcessInfo.processInfo.systemUptime >= deadline { return readback.outcome }
            // Intermediate values are normal in web editors. Keep observing,
            // but the readback helper permanently rules out another insertion.
            await pauseForReadback()
        } while true
    }

    @MainActor private func pauseForReadback() async {
        // A cancelled task still has to finish observing an already-posted edit
        // and restoring its clipboard. Task.sleep would throw immediately and
        // turn that cleanup into a busy loop after cancellation.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
        }
    }

    private func shouldPasteFirst(in snapshot: FocusedTextSnapshot) -> Bool {
        if pastePreferredProcesses.contains(snapshot.pid) { return true }
        if let app = NSRunningApplication(processIdentifier: snapshot.pid) {
            let identifier = app.bundleIdentifier?.lowercased() ?? ""
            let browsers = ["com.apple.safari", "com.google.chrome", "com.microsoft.edgemac",
                            "org.mozilla.firefox", "org.chromium.chromium", "com.brave.browser",
                            "company.thebrowser.browser", "com.vivaldi.vivaldi", "com.operasoftware.opera"]
            if browsers.contains(where: { identifier == $0 || identifier.hasPrefix($0 + ".") }) { return true }
            if let framework = app.bundleURL?.appendingPathComponent("Contents/Frameworks/Electron Framework.framework"),
               FileManager.default.fileExists(atPath: framework.path) { return true }
        }
        // Embedded web editors can exist inside otherwise native applications.
        // Inspect only ancestor roles, never text from another field.
        var ancestor = snapshot.element
        for _ in 0..<12 {
            if attribute(kAXRoleAttribute, on: ancestor) as? String == "AXWebArea" { return true }
            guard let parent = attribute(kAXParentAttribute, on: ancestor),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            let next = unsafeBitCast(parent, to: AXUIElement.self)
            if CFEqual(ancestor, next) { break }
            ancestor = next
        }
        return false
    }

    private func restoreSelectionIfUnchanged(_ snapshot: FocusedTextSnapshot, temporaryRange: NSRange) {
        guard let focused = try? focusedElement(), CFEqual(focused, snapshot.element),
              let current = text(of: focused), sameText(current, snapshot.text),
              selection(of: focused) == temporaryRange,
              let originalRange = axRange(snapshot.selection) else { return }
        _ = AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, originalRange)
    }

    private func sameText(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf16.elementsEqual(rhs.utf16)
    }

    private func attribute(_ name: String, on element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func text(of element: AXUIElement) -> String? {
        attribute(kAXValueAttribute, on: element) as? String
    }

    private func selection(of element: AXUIElement) -> NSRange? {
        guard let value = axValue(attribute(kAXSelectedTextRangeAttribute, on: element), type: .cfRange) else {
            return nil
        }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let position = axValue(attribute(kAXPositionAttribute, on: element), type: .cgPoint),
              let size = axValue(attribute(kAXSizeAttribute, on: element), type: .cgSize) else { return nil }
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(size, .cgSize, &dimensions) else {
            return nil
        }
        let rect = CGRect(origin: point, size: dimensions)
        return rect.isUsableAXFrame ? rect : nil
    }

    private func isSettable(_ name: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success
            && settable.boolValue
    }

    private func axValue(_ value: CFTypeRef?, type: AXValueType) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let result = unsafeBitCast(value, to: AXValue.self)
        return AXValueGetType(result) == type ? result : nil
    }

    private func axRange(_ range: NSRange) -> AXValue? {
        var value = CFRange(location: range.location, length: range.length)
        return AXValueCreate(.cfRange, &value)
    }

    private func valid(_ range: NSRange, in text: String) -> Bool {
        let length = (text as NSString).length
        return range.location >= 0 && range.length >= 0 && range.location <= length
            && range.length <= length - range.location
    }
}

private extension CGRect {
    var isUsableAXFrame: Bool {
        origin.x.isFinite && origin.y.isFinite && width.isFinite && height.isFinite
            && width >= 0 && height > 0
    }
}
