import SwiftUI
import LacunaCore

/// The catalog belongs to the current provider, endpoint and credential. It never
/// changes the saved model just because a provider returns a different catalog.
struct ModelPicker: View {
    let provider: LLMProvider
    let baseURL: String
    let apiKey: String
    @Binding var model: String
    @State private var models: [AvailableModel] = []
    @State private var loading = false
    @State private var message = ""
    @State private var manualEntry = false
    @State private var refresh = 0
    @State private var loadedIdentity: CatalogIdentity?

    private var identity: CatalogIdentity {
        CatalogIdentity(provider: provider, baseURL: baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
                        apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private var requestIdentity: CatalogRequest { CatalogRequest(identity: identity, refresh: refresh) }
    private var canLoad: Bool { provider == .custom || !identity.apiKey.isEmpty }

    var body: some View {
        HStack {
            if manualEntry {
                TextField("Model ID", text: $model)
                    .accessibilityLabel("Custom model ID")
            } else {
                Picker("Model", selection: $model) {
                    if model.isEmpty { Text("Choose a model").tag("") }
                    // A saved alias may not be present in the list of dated model IDs.
                    if !model.isEmpty && !models.contains(where: { $0.id == model }) {
                        Text("\(model) (current)").tag(model)
                    }
                    ForEach(models) { item in
                        Text(label(for: item)).tag(item.id)
                    }
                }.accessibilityHint("Models available from your provider")
            }
            Button { refresh += 1 } label: {
                if loading { ProgressView().controlSize(.small).frame(width: 16, height: 16) }
                else { Image(systemName: "arrow.clockwise").frame(width: 16, height: 16) }
            }
            .buttonStyle(.borderless)
            .disabled(loading || !canLoad)
            .accessibilityLabel("Refresh models")
            .help("Refresh models from your provider")
        }
        HStack(alignment: .top) {
            Text(message).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(manualEntry ? "Choose from list" : "Enter model ID…") { manualEntry.toggle() }
                .buttonStyle(.link).font(.caption)
        }
        .task(id: requestIdentity) { await loadModels() }
    }

    private func label(for item: AvailableModel) -> String {
        let duplicates = models.filter { $0.displayName == item.displayName }.count > 1
        return duplicates && item.displayName != item.id ? "\(item.displayName) (\(item.id))" : item.displayName
    }

    @MainActor private func loadModels() async {
        let requested = identity
        if loadedIdentity != requested {
            models = []
            loadedIdentity = requested
        }
        guard canLoad else {
            loading = false
            message = "Add your API key to load available models."
            return
        }
        loading = true
        message = "Loading models…"
        do {
            // Avoid a request for each keystroke while entering a key or endpoint.
            try await Task.sleep(nanoseconds: 500_000_000)
            let result = try await ModelCatalogClient().models(configuration: LLMConfiguration(
                provider: requested.provider, baseURL: requested.baseURL, apiKey: requested.apiKey))
            try Task.checkCancellation()
            guard requested == identity else { return }
            models = result
            message = result.isEmpty
                ? "No models were listed. You can still enter a model ID."
                : "\(result.count) models available from your provider."
            loading = false
        } catch is CancellationError {
            // A new task owns the UI when the provider, key or endpoint changes.
        } catch {
            guard !Task.isCancelled, requested == identity else { return }
            loading = false
            message = error.localizedDescription
        }
    }
}

private struct CatalogIdentity: Equatable {
    let provider: LLMProvider
    let baseURL: String
    let apiKey: String
}
private struct CatalogRequest: Equatable {
    let identity: CatalogIdentity
    let refresh: Int
}
