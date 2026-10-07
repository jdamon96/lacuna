import AppKit
import SwiftUI
import ServiceManagement
import LacunaCore

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    let accessibility: AccessibilityBridge
    let saveShortcut: (Shortcut) -> Bool
    let openPlayground: () -> Void
    let recordingChanged: (Bool) -> Void
    @State private var provider: LLMProvider
    @State private var baseURL: String
    @State private var model: String
    @State private var key: String
    @State private var shortcut: Shortcut
    @State private var recording = false
    @State private var monitor: Any?
    @State private var status = ""
    @State private var testing = false
    @State private var hasAccess = false
    @State private var syncingLogin = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(preferences: Preferences, accessibility: AccessibilityBridge, saveShortcut: @escaping (Shortcut) -> Bool, recordingChanged: @escaping (Bool) -> Void, openPlayground: @escaping () -> Void) {
        self.preferences = preferences; self.accessibility = accessibility
        self.saveShortcut = saveShortcut; self.openPlayground = openPlayground; self.recordingChanged = recordingChanged
        _provider = State(initialValue: preferences.provider)
        _baseURL = State(initialValue: preferences.baseURL)
        _model = State(initialValue: preferences.model)
        _key = State(initialValue: preferences.key(for: preferences.provider, url: preferences.baseURL))
        _shortcut = State(initialValue: preferences.shortcut)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                Text("{ }").font(.system(size: 28, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white).frame(width: 52, height: 52)
                    .background(Color.indigo.gradient, in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Lacuna").font(.system(size: 29, weight: .semibold))
                    Text("Leave a gap. Find the words.").font(.system(size: 14)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Thanks for your time. {a warm, brief sign-off}")
                    .font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                HStack {
                    Text("\(shortcut.label) to fill  ·  1, 2, 3 to choose  ·  Esc to dismiss")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Try it", action: openPlayground).controlSize(.small)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            Form {
                Section {
                    Picker("Provider", selection: $provider) {
                        ForEach(LLMProvider.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    if provider == .custom { TextField("Base URL", text: $baseURL) }
                    SecureField("API key", text: $key)
                    ModelPicker(provider: provider, baseURL: baseURL, apiKey: key, model: $model)
                    Text("Your key stays in macOS Keychain. Requests go directly to your provider.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        Text("Fill template")
                        Spacer()
                        Button(recording ? "Press a shortcut…" : shortcut.label) { beginRecording() }
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .frame(minWidth: 110)
                    }
                    Toggle("Highlight braces", isOn: $preferences.highlights)
                    Toggle("Launch at login", isOn: $launchAtLogin)
                }
                Section {
                    HStack {
                        Image(systemName: hasAccess ? "checkmark.circle.fill" : "hand.raised")
                            .foregroundStyle(hasAccess ? Color.green : Color.orange)
                        Text(hasAccess ? "Accessibility is enabled" : "Enable Accessibility to work in other apps")
                        Spacer()
                        Button(hasAccess ? "Settings…" : "Enable…") { accessibility.requestPermission() }
                    }
                    Text("Only the focused editable field is inspected. Nearby text is sent when you press the shortcut. Password fields are excluded.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).disabled(testing)
            HStack {
                Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                Button(testing ? "Testing…" : "Test connection") { testConnection() }.disabled(testing || recording)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(recording || testing)
            }
        }
        .padding(24).frame(width: 610, height: 700)
        .onAppear { hasAccess = accessibility.isTrusted }
        .onReceive(timer) { _ in hasAccess = accessibility.isTrusted }
        .onChange(of: provider) { newProvider in
            let profile = preferences.profile(for: newProvider)
            baseURL = profile.0; model = profile.1
            key = preferences.key(for: newProvider, url: baseURL); status = ""
        }
        .onChange(of: baseURL) { url in
            // Switching a server must never carry an existing key to the new destination.
            key = preferences.key(for: provider, url: url); status = ""
        }
        .onChange(of: model) { _ in status = "" }
        .onChange(of: key) { _ in status = "" }
        .onChange(of: launchAtLogin) { enabled in
            if syncingLogin { syncingLogin = false; return }
            do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            catch {
                status = "Login item: \(error.localizedDescription)"
                let actual = SMAppService.mainApp.status == .enabled
                if launchAtLogin != actual { syncingLogin = true; launchAtLogin = actual }
            }
        }
        .onDisappear { stopRecording() }
    }

    private func beginRecording() {
        if recording { stopRecording(); return }
        recording = true; recordingChanged(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stopRecording(); return nil }
            if let value = Shortcut.from(event) { shortcut = value; stopRecording() }
            else { status = "Include Command, Control, or Option. Escape cancels." }
            return nil
        }
    }
    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        if recording { recording = false; recordingChanged(false) }
    }
    private func save() {
        guard saveShortcut(shortcut) else { status = "That shortcut is already in use. Choose another."; return }
        do {
            try preferences.save(provider: provider, baseURL: baseURL, model: model, apiKey: key, shortcut: shortcut)
            status = key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && provider != .custom
                ? "Saved. Add your API key to connect your model."
                : "Saved. You’re ready to fill a gap."
        } catch { _ = saveShortcut(preferences.shortcut); status = error.localizedDescription }
    }
    private func testConnection() {
        testing = true; status = "Checking your model with a short sample…"
        let configuration = LLMConfiguration(provider: provider, baseURL: baseURL, model: model, apiKey: key)
        Task { @MainActor in
            defer { testing = false }
            do {
                let sample = "Thanks for your help. {a friendly two-word sign-off}"
                guard let template = BraceTemplate.find(in: sample, selection: NSRange(location: (sample as NSString).length, length: 0)) else { return }
                _ = try await CompletionClient().suggestions(for: template, in: sample, configuration: configuration)
                status = "Connected. Your model returned three suggestions."
            } catch { status = error.localizedDescription }
        }
    }
}
