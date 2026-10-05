import Foundation

public struct AvailableModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName ?? id
    }
}

public enum ModelCatalogError: LocalizedError, Equatable {
    case malformedResponse

    public var errorDescription: String? {
        "The provider didn’t return a readable model list. Try refreshing or enter a model name manually."
    }
}

/// Fetches models available to the configured account without saving keys or responses.
public struct ModelCatalogClient {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    // Production always uses the session policy above; tests can supply URLProtocol.
    init(session: URLSession) { self.session = session }

    public func models(configuration: LLMConfiguration) async throws -> [AvailableModel] {
        var result: [String: AvailableModel] = [:]
        var afterID: String?
        var seenCursors = Set<String>()
        // Bound pagination in case a compatible service returns a broken cursor.
        for _ in 0..<20 {
            try Task.checkCancellation()
            let request = try makeRequest(configuration: configuration, afterID: afterID)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                switch error.code {
                case .cancelled: throw CancellationError()
                case .timedOut: throw CompletionError.timedOut
                default: throw CompletionError.network
                }
            } catch {
                throw CompletionError.network
            }
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw ModelCatalogError.malformedResponse }
            switch http.statusCode {
            case 200..<300: break
            case 300..<400: throw CompletionError.redirected
            case 401, 403: throw CompletionError.unauthorized
            case 429: throw CompletionError.rateLimited
            case 500..<600: throw CompletionError.unavailable
            default: throw CompletionError.rejectedRequest
            }
            // Raw response errors can contain private account details, so never surface them.
            let page = try Self.parseResponse(data, provider: configuration.provider)
            for model in page.models where result[model.id] == nil { result[model.id] = model }
            guard let next = page.nextCursor else {
                return result.values.sorted {
                    let comparison = $0.displayName.localizedStandardCompare($1.displayName)
                    return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
                }
            }
            guard seenCursors.insert(next).inserted else { throw ModelCatalogError.malformedResponse }
            afterID = next
        }
        throw ModelCatalogError.malformedResponse
    }

    func makeRequest(configuration: LLMConfiguration, afterID: String? = nil) throws -> URLRequest {
        let endpoint = try CompletionClient.endpoint(for: configuration, resource: "models")
        let key = configuration.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard configuration.provider == .custom || !key.isEmpty else { throw CompletionError.missingAPIKey }
        guard key.rangeOfCharacter(from: .newlines) == nil else { throw CompletionError.unauthorized }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        if configuration.provider == .anthropic {
            components.queryItems = [URLQueryItem(name: "limit", value: "1000")]
            if let afterID { components.queryItems?.append(URLQueryItem(name: "after_id", value: afterID)) }
        }
        guard let url = components.url else { throw CompletionError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if configuration.provider == .anthropic {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    struct Page {
        let models: [AvailableModel]
        let nextCursor: String?
    }

    static func parseResponse(_ data: Data, provider: LLMProvider, now: Date = Date()) throws -> Page {
        guard data.count <= 2_000_000,
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw ModelCatalogError.malformedResponse
        }
        var models: [AvailableModel] = []
        for model in payload.data {
            guard validIdentifier(model.id) else { throw ModelCatalogError.malformedResponse }
            if provider == .openAI {
                guard isTextModel(model.id), !hasShutDown(model.shutdownDate, now: now) else { continue }
            }
            let name = model.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            models.append(AvailableModel(id: model.id, displayName: name?.isEmpty == false ? name : nil))
        }
        var nextCursor: String?
        if provider == .anthropic {
            guard let hasMore = payload.hasMore else { throw ModelCatalogError.malformedResponse }
            if hasMore {
                guard !payload.data.isEmpty, let lastID = payload.lastID, validIdentifier(lastID),
                      payload.data.last?.id == lastID else { throw ModelCatalogError.malformedResponse }
                nextCursor = lastID
            }
        }
        return Page(models: models, nextCursor: nextCursor)
    }

    private static func validIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.utf16.count <= 512 && id == id.trimmingCharacters(in: .whitespacesAndNewlines)
            && id.rangeOfCharacter(from: .controlCharacters) == nil
    }

    // The OpenAI catalog has no capability flags. Exclude clearly unrelated model
    // families, while keeping unfamiliar IDs so new text models remain discoverable.
    // Listing alone does not guarantee support for Lacuna's structured Responses call.
    private static func isTextModel(_ id: String) -> Bool {
        let id = id.lowercased()
        let unrelated = ["embedding", "moderation", "realtime", "audio", "transcribe", "image", "dall-e", "whisper", "tts", "sora"]
        if unrelated.contains(where: { id.contains($0) }) { return false }
        if id.hasPrefix("babbage-") || id.hasPrefix("davinci-") || id.hasPrefix("text-") { return false }
        return !id.contains("-instruct")
    }

    private static func hasShutDown(_ value: String?, now: Date) -> Bool {
        guard let value else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard value.count == 10, let date = formatter.date(from: value) else { return false }
        return date <= now
    }

    private struct Payload: Decodable {
        let data: [Entry]
        let hasMore: Bool?
        let lastID: String?
        enum CodingKeys: String, CodingKey {
            case data
            case hasMore = "has_more"
            case lastID = "last_id"
        }
    }

    private struct Entry: Decodable {
        let id: String
        let displayName: String?
        let shutdownDate: String?
        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
            case shutdownDate = "shutdown_date"
        }
    }
}
