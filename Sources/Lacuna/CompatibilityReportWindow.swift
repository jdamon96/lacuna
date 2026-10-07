import AppKit
import ApplicationServices
import LacunaCore

/// An explicit, local diagnostic. It reports capabilities and counts, never the
/// field's value, instruction text, document title, URL, or accessibility IDs.
enum TextFieldCompatibilityReport {
    static func capture(using bridge: AccessibilityBridge) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        var lines = ["Lacuna text field compatibility", "Lacuna: \(version) (\(build))",
                     "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "Accessibility access: \(bridge.isTrusted ? "allowed" : "not allowed")"]
        guard bridge.isTrusted else { return lines.joined(separator: "\n") }

        // Let the production capture path activate accessibility support first.
        let captured = Result { try bridge.captureForHighlighting() }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var raw: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &raw)
        guard result == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            lines.append("Focused field: unavailable (AX error \(result.rawValue))")
            return lines.joined(separator: "\n")
        }
        let element = unsafeBitCast(raw, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.05)
        defer { AXUIElementSetMessagingTimeout(element, 0.3) }
        func attribute(_ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        func capability(_ name: String) -> String {
            var writable = DarwinBoolean(false)
            let status = AXUIElementIsAttributeSettable(element, name as CFString, &writable)
            return status == .success ? (writable.boolValue ? "yes" : "no") : "unavailable"
        }
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success,
           let app = NSRunningApplication(processIdentifier: pid) {
            lines.append("App: \(app.localizedName ?? "unknown") (\(app.bundleIdentifier ?? "unknown"))")
            if let url = app.bundleURL, let bundle = Bundle(url: url),
               let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                lines.append("App version: \(appVersion)")
            }
        }
        let role = attribute(kAXRoleAttribute) as? String
        let subrole = attribute(kAXSubroleAttribute) as? String
        lines.append("Role: \(role ?? "unavailable")")
        lines.append("Subrole: \(subrole ?? "unavailable")")
        guard role != kAXSecureTextFieldSubrole, subrole != kAXSecureTextFieldSubrole else {
            lines.append("Password field: excluded")
            return lines.joined(separator: "\n")
        }
        if let editable = attribute(kAXIsEditableAttribute) as? Bool {
            lines.append("Explicitly editable: \(editable ? "yes" : "no")")
        } else { lines.append("Explicitly editable: not advertised") }
        lines.append("Value writable: \(capability(kAXValueAttribute))")
        lines.append("Selection writable: \(capability(kAXSelectedTextRangeAttribute))")
        lines.append("Selected text writable: \(capability(kAXSelectedTextAttribute))")
        var parameters: CFArray?
        if AXUIElementCopyParameterizedAttributeNames(element, &parameters) == .success,
           let names = parameters as? [String] {
            for name in [kAXBoundsForRangeParameterizedAttribute, "AXTextMarkerRangeForUIElement",
                         "AXBoundsForTextMarkerRange", "AXStringForTextMarkerRange"] {
                lines.append("\(name): \(names.contains(name) ? "advertised" : "not advertised")")
            }
        }
        switch captured {
        case .failure(let error):
            lines.append("Editable text capture: \(error.localizedDescription)")
        case .success(let snapshot):
            lines.append("Editable text capture: available")
            lines.append("Caret/selection readable: \(snapshot.selection.location != NSNotFound ? "yes" : "no")")
            let templates = BraceTemplate.all(in: snapshot.text)
            let opening = BraceTemplate.pendingOpening(in: snapshot.text, selection: snapshot.selection)
            lines.append("Completed phrases: \(templates.count)")
            lines.append("Pending opening brace: \(opening != nil ? "yes" : "no")")
            if let range = templates.first?.range ?? opening {
                let rectangles = bridge.highlightBounds(for: range, in: snapshot)
                lines.append("Precise highlight fragments for first phrase: \(rectangles.count)")
            }
            let field = snapshot.fieldFrame
            lines.append("Field bounds available: \(field != nil && field!.width > 0 && field!.height > 0 ? "yes" : "no")")
        }
        lines.append("This report does not include your text.")
        return lines.joined(separator: "\n")
    }
}

final class CompatibilityReportWindow {
    private var window: NSWindow?
    private var report = ""

    func show(_ report: String) {
        self.report = report
        window?.close()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 580, height: 470),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Text field compatibility"
        window.isReleasedWhenClosed = false
        let content = NSView()
        window.contentView = content
        let help = NSTextField(wrappingLabelWithString: "To check another input, focus it and choose Inspect text field… from Lacuna’s menu. This report includes capabilities, not your text.")
        help.textColor = .secondaryLabelColor
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 540, height: 340))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isRichText = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = report
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        let copy = NSButton(title: "Copy report", target: self, action: #selector(copyReport))
        copy.bezelStyle = .rounded
        for view in [help, scroll, copy] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            help.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            help.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            help.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: help.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: help.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: help.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: copy.topAnchor, constant: -14),
            copy.trailingAnchor.constraint(equalTo: help.trailingAnchor),
            copy.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
        window.minSize = NSSize(width: 440, height: 320)
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}
