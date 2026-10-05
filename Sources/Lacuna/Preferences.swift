import AppKit
import Carbon
import Combine
import LacunaCore
import Security

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var label: String
    static let initial = Shortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘K")

    static func from(_ event: NSEvent) -> Shortcut? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option),
              let key = event.charactersIgnoringModifiers, !key.isEmpty,
              ![36, 48, 51, 53, 117].contains(Int(event.keyCode)) else { return nil }
        var modifiers: UInt32 = 0
        var label = ""
        if flags.contains(.control) { modifiers |= UInt32(controlKey); label += "⌃" }
        if flags.contains(.option) { modifiers |= UInt32(optionKey); label += "⌥" }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey); label += "⇧" }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey); label += "⌘" }
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers, label: label + key.uppercased())
    }
}

final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled") } }
    @Published var highlights: Bool { didSet { defaults.set(highlights, forKey: "highlights") } }
    @Published var shortcut: Shortcut
    @Published var provider: LLMProvider
    @Published var baseURL: String
    @Published var model: String
    var onSave: (() -> Void)?

    init() {
        defaults.register(defaults: ["enabled": true, "highlights": true])
        enabled = defaults.bool(forKey: "enabled")
        highlights = defaults.bool(forKey: "highlights")
        shortcut = defaults.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .initial
        let provider = LLMProvider(rawValue: defaults.string(forKey: "provider") ?? "") ?? .openAI
        self.provider = provider
        baseURL = defaults.string(forKey: "\(provider.rawValue).baseURL") ?? provider.defaultBaseURL
        model = defaults.string(forKey: "\(provider.rawValue).model") ?? provider.defaultModel
    }

    func profile(for provider: LLMProvider) -> (String, String) {
        (defaults.string(forKey: "\(provider.rawValue).baseURL") ?? provider.defaultBaseURL,
         defaults.string(forKey: "\(provider.rawValue).model") ?? provider.defaultModel)
    }

    func save(provider: LLMProvider, baseURL: String, model: String, apiKey: String, shortcut: Shortcut) throws {
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw SettingsError.message("Enter a model name.") }
        // Keys are scoped to the provider AND endpoint, preventing accidental reuse at another server.
        try Keychain.save(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), account: keyAccount(provider, url))
        self.provider = provider; self.baseURL = url; self.model = model; self.shortcut = shortcut
        defaults.set(provider.rawValue, forKey: "provider")
        defaults.set(url, forKey: "\(provider.rawValue).baseURL")
        defaults.set(model, forKey: "\(provider.rawValue).model")
        defaults.set(try JSONEncoder().encode(shortcut), forKey: "shortcut")
        onSave?()
    }

    func key(for provider: LLMProvider, url: String) -> String {
        Keychain.read(account: keyAccount(provider, url))
    }
    var configuration: LLMConfiguration {
        LLMConfiguration(provider: provider, baseURL: baseURL, model: model, apiKey: key(for: provider, url: baseURL))
    }
    private func keyAccount(_ provider: LLMProvider, _ url: String) -> String { "\(provider.rawValue)|\(url.trimmingCharacters(in: .whitespacesAndNewlines))" }
}

enum SettingsError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum Keychain {
    static let service = "com.jdamon.lacuna.api-keys"
    static func read(account: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SettingsError.message("Couldn’t remove the API key from Keychain (\(status)).") }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SettingsError.message("Couldn’t save the API key in Keychain (\(status)).") }
    }
}
