import XCTest
@testable import LacunaCore

final class ModelCatalogTests: XCTestCase {
    func testOpenAIListingUsesBearerAndNeedsNoSelectedModel() throws {
        let request = try ModelCatalogClient().makeRequest(configuration: LLMConfiguration(provider: .openAI, model: "", apiKey: " test-key "))
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "x-api-key"))
    }

    func testAnthropicListingUsesVersionedAuthAndEncodedCursor() throws {
        let request = try ModelCatalogClient().makeRequest(configuration: LLMConfiguration(provider: .anthropic, model: "", apiKey: "test-key"), afterID: "model+cursor/one")
        let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "api.anthropic.com")
        XCTAssertEqual(components.path, "/v1/models")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "limit", value: "1000"), URLQueryItem(name: "after_id", value: "model+cursor/one")])
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testCustomListingAllowsOptionalKeyAndUsesConfiguredBasePath() throws {
        let client = ModelCatalogClient()
        let local = try client.makeRequest(configuration: LLMConfiguration(provider: .custom))
        XCTAssertEqual(local.url?.absoluteString, "http://localhost:11434/v1/models")
        XCTAssertNil(local.value(forHTTPHeaderField: "Authorization"))
        let remote = try client.makeRequest(configuration: LLMConfiguration(provider: .custom, baseURL: "https://example.com/api/v2/", apiKey: "test-key"))
        XCTAssertEqual(remote.url?.absoluteString, "https://example.com/api/v2/models")
        XCTAssertEqual(remote.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
    }

    func testListingRejectsUnsafeEndpointsAndInvalidCredentials() {
        let client = ModelCatalogClient()
        for url in ["http://example.com/v1", "https://user:secret@example.com/v1", "https://example.com/v1?key=secret", "https://example.com/v1#secret", "file:///tmp/api", "not a URL"] {
            XCTAssertThrowsError(try client.makeRequest(configuration: LLMConfiguration(provider: .custom, baseURL: url))) {
                XCTAssertEqual($0 as? CompletionError, .invalidEndpoint)
            }
        }
        for provider in [LLMProvider.openAI, .anthropic] {
            XCTAssertThrowsError(try client.makeRequest(configuration: LLMConfiguration(provider: provider, baseURL: "https://example.com/v1", apiKey: "test-key"))) {
                XCTAssertEqual($0 as? CompletionError, .invalidEndpoint)
            }
            XCTAssertThrowsError(try client.makeRequest(configuration: LLMConfiguration(provider: provider))) {
                XCTAssertEqual($0 as? CompletionError, .missingAPIKey)
            }
            XCTAssertThrowsError(try client.makeRequest(configuration: LLMConfiguration(provider: provider, apiKey: "key\r\ninjected"))) {
                XCTAssertEqual($0 as? CompletionError, .unauthorized)
            }
        }
        XCTAssertNoThrow(try client.makeRequest(configuration: LLMConfiguration(provider: .custom, baseURL: "http://[::1]:1234/v1")))
    }

    func testOpenAICatalogFiltersUnrelatedAndRetiredModelsButKeepsNewIDs() throws {
        let data = try json([
            "data": [
                ["id": "gpt-4.1-mini"], ["id": "future-writer"], ["id": "gpt-future", "shutdown_date": "2099-01-01"],
                ["id": "gpt-expired", "shutdown_date": "2025-01-01"], ["id": "gpt-no-retirement", "shutdown_date": NSNull()],
                ["id": "gpt-unknown-retirement", "shutdown_date": "unknown"],
                ["id": "text-embedding-3-small"], ["id": "omni-moderation-latest"], ["id": "gpt-realtime"],
                ["id": "gpt-4o-audio-preview"], ["id": "gpt-4o-transcribe"], ["id": "gpt-image-1"], ["id": "dall-e-3"],
                ["id": "whisper-1"], ["id": "tts-1"], ["id": "sora-2"], ["id": "babbage-002"],
                ["id": "davinci-002"], ["id": "text-davinci-003"], ["id": "gpt-3.5-turbo-instruct"]
            ]
        ])
        let page = try ModelCatalogClient.parseResponse(data, provider: .openAI, now: Date(timeIntervalSince1970: 1_767_225_600))
        XCTAssertEqual(page.models.map(\.id), ["gpt-4.1-mini", "future-writer", "gpt-future", "gpt-no-retirement", "gpt-unknown-retirement"])
        XCTAssertTrue(page.models.allSatisfy { $0.displayName == $0.id })
        XCTAssertNil(page.nextCursor)
    }

    func testAnthropicPreservesDisplayNamesAndCustomModelsAreNotFiltered() throws {
        let anthropic = try ModelCatalogClient.parseResponse(json(["data": [["id": "claude-example", "display_name": "Claude Example"]], "has_more": false, "last_id": "claude-example"]), provider: .anthropic)
        XCTAssertEqual(anthropic.models, [AvailableModel(id: "claude-example", displayName: "Claude Example")])
        let custom = try ModelCatalogClient.parseResponse(json(["data": [["id": "custom-audio-capable"], ["id": "writer", "display_name": "  "]]]), provider: .custom)
        XCTAssertEqual(custom.models, [AvailableModel(id: "custom-audio-capable"), AvailableModel(id: "writer")])
    }

    func testRejectsMalformedCatalogsAndInconsistentPagination() throws {
        for body in ["not JSON", "{}", #"{"data":[{}]}"#, #"{"data":[{"id":7}]}"#, #"{"data":[{"id":""}]}"#, #"{"data":[{"id":" bad-id "}]}"#, #"{"data":[{"id":"bad\nid"}]}"#] {
            XCTAssertThrowsError(try ModelCatalogClient.parseResponse(Data(body.utf8), provider: .openAI)) {
                XCTAssertEqual($0 as? ModelCatalogError, .malformedResponse)
            }
        }
        for body in [#"{"data":[]}"#, #"{"data":[],"has_more":true,"last_id":"missing"}"#, #"{"data":[{"id":"one"}],"has_more":true}"#, #"{"data":[{"id":"one"}],"has_more":true,"last_id":"two"}"#] {
            XCTAssertThrowsError(try ModelCatalogClient.parseResponse(Data(body.utf8), provider: .anthropic)) {
                XCTAssertEqual($0 as? ModelCatalogError, .malformedResponse)
            }
        }
        XCTAssertThrowsError(try ModelCatalogClient.parseResponse(Data(repeating: 32, count: 2_000_001), provider: .openAI))
        XCTAssertTrue(try ModelCatalogClient.parseResponse(Data(#"{"data":[]}"#.utf8), provider: .custom).models.isEmpty)
    }

    func testOpenAISuccessSortsAndDeduplicatesCatalog() async throws {
        let client = mockClient { _ in
            (200, Data(#"{"data":[{"id":"writer-10"},{"id":"writer-2"},{"id":"writer-2"}]}"#.utf8))
        }
        let models = try await client.models(configuration: LLMConfiguration(provider: .openAI, apiKey: "test-key"))
        XCTAssertEqual(models.map(\.id), ["writer-2", "writer-10"])
    }

    func testAnthropicPaginationFollowsLastIDAndDeduplicatesAcrossPages() async throws {
        var requests: [URLRequest] = []
        let client = mockClient { request in
            requests.append(request)
            if requests.count == 1 {
                return (200, Data(#"{"data":[{"id":"claude-z","display_name":"Zebra"},{"id":"claude-a","display_name":"Alpha"}],"has_more":true,"last_id":"claude-a"}"#.utf8))
            }
            return (200, Data(#"{"data":[{"id":"claude-a","display_name":"Alpha"},{"id":"claude-b","display_name":"Beta"}],"has_more":false,"last_id":"claude-b"}"#.utf8))
        }
        let models = try await client.models(configuration: LLMConfiguration(provider: .anthropic, apiKey: "test-key"))
        XCTAssertEqual(models.map(\.id), ["claude-a", "claude-b", "claude-z"])
        XCTAssertEqual(requests.count, 2)
        let first = try XCTUnwrap(URLComponents(url: XCTUnwrap(requests.first?.url), resolvingAgainstBaseURL: false))
        let second = try XCTUnwrap(URLComponents(url: XCTUnwrap(requests.last?.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(first.queryItems, [URLQueryItem(name: "limit", value: "1000")])
        XCTAssertEqual(second.queryItems, [URLQueryItem(name: "limit", value: "1000"), URLQueryItem(name: "after_id", value: "claude-a")])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "x-api-key") == "test-key" })
    }

    func testRepeatedPaginationCursorFailsInsteadOfLooping() async throws {
        var count = 0
        let client = mockClient { _ in
            count += 1
            return (200, Data(#"{"data":[{"id":"same"}],"has_more":true,"last_id":"same"}"#.utf8))
        }
        do {
            _ = try await client.models(configuration: LLMConfiguration(provider: .anthropic, apiKey: "test-key"))
            XCTFail("Expected repeated cursor to fail")
        } catch {
            XCTAssertEqual(error as? ModelCatalogError, .malformedResponse)
        }
        XCTAssertEqual(count, 2)
    }

    func testHTTPFailuresDoNotEchoProviderBody() async throws {
        for (status, expected) in [(401, CompletionError.unauthorized), (403, .unauthorized), (429, .rateLimited), (500, .unavailable), (404, .rejectedRequest), (302, .redirected)] {
            let client = mockClient { _ in (status, Data(#"{"error":{"message":"secret-account-details"}}"#.utf8)) }
            do {
                _ = try await client.models(configuration: LLMConfiguration(provider: .openAI, apiKey: "test-key"))
                XCTFail("Expected HTTP \(status) to fail")
            } catch {
                XCTAssertEqual(error as? CompletionError, expected)
                XCTAssertFalse(error.localizedDescription.contains("secret-account-details"))
            }
        }
    }

    func testNetworkErrorsAreSanitizedAndCancellationIsPreserved() async throws {
        for (code, expected) in [(URLError.timedOut, CompletionError.timedOut), (.cannotConnectToHost, .network)] {
            let client = mockClient { _ in throw URLError(code, userInfo: [NSLocalizedDescriptionKey: "secret-account-details"]) }
            do {
                _ = try await client.models(configuration: LLMConfiguration(provider: .openAI, apiKey: "test-key"))
                XCTFail("Expected network failure")
            } catch {
                XCTAssertEqual(error as? CompletionError, expected)
                XCTAssertFalse(error.localizedDescription.contains("secret-account-details"))
            }
        }
        let cancelled = mockClient { _ in throw URLError(.cancelled) }
        do {
            _ = try await cancelled.models(configuration: LLMConfiguration(provider: .openAI, apiKey: "test-key"))
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testInFlightCancellationStopsModelRequest() async throws {
        let started = expectation(description: "Request started")
        let stopped = expectation(description: "Request stopped")
        HangingCatalogURLProtocol.onStart = { started.fulfill() }
        HangingCatalogURLProtocol.onStop = { stopped.fulfill() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingCatalogURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            HangingCatalogURLProtocol.onStart = nil
            HangingCatalogURLProtocol.onStop = nil
        }
        let client = ModelCatalogClient(session: session)
        let task = Task {
            try await client.models(configuration: LLMConfiguration(provider: .anthropic, apiKey: "test-key"))
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled request must not return a model list")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await fulfillment(of: [stopped], timeout: 3)
    }

    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func mockClient(handler: @escaping (URLRequest) throws -> (Int, Data)) -> ModelCatalogClient {
        CatalogURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogURLProtocol.self]
        return ModelCatalogClient(session: URLSession(configuration: configuration))
    }
}

private final class CatalogURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private final class HangingCatalogURLProtocol: URLProtocol {
    static var onStart: (() -> Void)?
    static var onStop: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.onStart?() }
    override func stopLoading() { Self.onStop?() }
}
