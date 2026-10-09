import XCTest
@testable import LacunaCore

final class CompletionClientTests: XCTestCase {
    private let text = "Hello {a warm welcome} and thanks."
    private var template: BraceTemplate { BraceTemplate.find(in: text, selection: NSRange(location: 7, length: 0))! }

    func testRefinementCarriesCurrentOptionsAndOrderedFeedbackAcrossEveryProvider() throws {
        let refinement = try SuggestionRefinement(previousSuggestions: ["Warm welcome", "Happy to see you", "Please come in"],
            feedback: ["Make these more formal.", "Actually use a casual tone, but keep them short."])
        for provider in LLMProvider.allCases {
            let configuration = LLMConfiguration(provider: provider, model: "test-model", apiKey: "test-key")
            let client = CompletionClient()
            let original = try client.makeRequest(for: template, in: text, configuration: configuration)
            let request = try client.makeRequest(for: template, in: text, configuration: configuration, refinement: refinement)
            let base = try requestContents(original, provider: provider)
            let refined = try requestContents(request, provider: provider)
            XCTAssertEqual(request.url, original.url)
            XCTAssertEqual(request.allHTTPHeaderFields, original.allHTTPHeaderFields)
            XCTAssertEqual(refined.fields["instruction"] as? String, base.fields["instruction"] as? String)
            XCTAssertEqual(refined.fields["text_before"] as? String, base.fields["text_before"] as? String)
            XCTAssertEqual(refined.fields["text_after"] as? String, base.fields["text_after"] as? String)
            XCTAssertEqual(refined.fields["previous_suggestions"] as? [String], refinement.previousSuggestions)
            XCTAssertEqual(refined.fields["feedback"] as? [String], refinement.feedback)
            XCTAssertTrue(refined.system.hasPrefix(base.system), "Keep the existing replacement contract")
            XCTAssertTrue(refined.system.contains("latest relevant feedback wins"))
            XCTAssertTrue(refined.system.contains("exactly three distinct revised alternatives"))
            XCTAssertNil(refined.body["previous_response_id"])
            XCTAssertNil(refined.body["conversation"])
            XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("test-key"))
            switch provider {
            case .openAI:
                XCTAssertEqual(refined.body["store"] as? Bool, false)
                XCTAssertEqual(refined.body["text"] as? NSDictionary, base.body["text"] as? NSDictionary)
                XCTAssertEqual(refined.body["max_output_tokens"] as? Int, base.body["max_output_tokens"] as? Int)
            case .anthropic:
                XCTAssertEqual((refined.body["messages"] as? [[String: String]])?.count, 1)
                XCTAssertEqual(refined.body["max_tokens"] as? Int, base.body["max_tokens"] as? Int)
            case .custom:
                XCTAssertEqual((refined.body["messages"] as? [[String: String]])?.count, 2)
                XCTAssertEqual(refined.body["max_tokens"] as? Int, base.body["max_tokens"] as? Int)
            }
        }
    }

    func testNilRefinementPreservesInitialPromptAndProviderPayloads() throws {
        for provider in LLMProvider.allCases {
            let configuration = LLMConfiguration(provider: provider, model: "test-model", apiKey: "test-key")
            let client = CompletionClient()
            let implicit = try client.makeRequest(for: template, in: text, configuration: configuration)
            let explicit = try client.makeRequest(for: template, in: text, configuration: configuration, refinement: nil)
            let base = try requestContents(implicit, provider: provider)
            let nilRequest = try requestContents(explicit, provider: provider)
            XCTAssertEqual(base.body as NSDictionary, nilRequest.body as NSDictionary)
            XCTAssertEqual(base.fields as NSDictionary, [
                "instruction": "a warm welcome", "text_before": "Hello ", "text_after": " and thanks."
            ] as NSDictionary)
            XCTAssertFalse(base.system.contains("refinement"))
        }
    }

    func testRefinementKeepsOriginalTargetWhenOtherIdenticalPlaceholdersExist() throws {
        let text = "😀 Friend: {a greeting}\nClient: {a greeting}"
        let position = (text as NSString).range(of: "{a greeting}", options: .backwards).location
        let target = try XCTUnwrap(BraceTemplate.find(in: text, selection: NSRange(location: position + 2, length: 0)))
        let refinement = try SuggestionRefinement(previousSuggestions: ["Hi", "Hello", "Welcome"],
            feedback: ["Include \"thanks\".\nKeep {literal braces} if useful."])
        let request = try CompletionClient().makeRequest(for: target, in: text,
            configuration: LLMConfiguration(provider: .openAI, apiKey: "test-key"), refinement: refinement)
        let contents = try requestContents(request, provider: .openAI)
        XCTAssertEqual(contents.fields["text_before"] as? String, "😀 Friend: {a greeting}\nClient: ")
        XCTAssertEqual(contents.fields["text_after"] as? String, "")
        XCTAssertEqual(contents.fields["instruction"] as? String, "a greeting")
        XCTAssertEqual(contents.fields["feedback"] as? [String], refinement.feedback)
        XCTAssertThrowsError(try CompletionClient().makeRequest(for: target, in: "Changed field",
            configuration: LLMConfiguration(provider: .openAI, apiKey: "test-key"), refinement: refinement)) {
            XCTAssertEqual($0 as? CompletionError, .invalidTemplate)
        }
    }

    func testOpenAIRequestUsesStrictSchemaAndDisablesStorage() throws {
        let request = try CompletionClient().makeRequest(for: template, in: text, configuration: LLMConfiguration(provider: .openAI, apiKey: "test-key"))
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, false)
        let format = try XCTUnwrap((body["text"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format["strict"] as? Bool, true)
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        let suggestions = try XCTUnwrap((schema["properties"] as? [String: Any])?["suggestions"] as? [String: Any])
        XCTAssertEqual(suggestions["minItems"] as? Int, 3)
        XCTAssertEqual(suggestions["maxItems"] as? Int, 3)
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("test-key"))
        let prompt = try XCTUnwrap(body["input"] as? String)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(prompt.utf8)) as? [String: String])
        XCTAssertEqual(fields["instruction"], "a warm welcome")
        XCTAssertEqual(fields["text_before"], "Hello ")
        XCTAssertEqual(fields["text_after"], " and thanks.")
    }

    func testRequestDistinguishesIdenticalPlaceholdersAfterEmoji() throws {
        let text = "👩🏽‍💻 To my friend: {a sign-off}\nTo my client: {a sign-off}\nJack"
        let target = try XCTUnwrap(BraceTemplate.find(in: text, selection: NSRange(location: (text as NSString).range(of: "{a sign-off}", options: .backwards).location + 3, length: 0)))
        for provider in LLMProvider.allCases {
            let request = try CompletionClient().makeRequest(for: target, in: text, configuration: LLMConfiguration(provider: provider, model: "test-model", apiKey: "test-key"))
            let fields = try promptFields(in: request, provider: provider)
            XCTAssertEqual(fields["instruction"], "a sign-off")
            XCTAssertEqual(fields["text_before"], "👩🏽‍💻 To my friend: {a sign-off}\nTo my client: ")
            XCTAssertEqual(fields["text_after"], "\nJack")
        }
    }

    func testRequestContextSharesBoundAndPreservesComposedCharacters() throws {
        let repeated = String(repeating: "👨‍👩‍👧‍👦e\u{301}", count: 800)
        let text = repeated + "{a sign-off}" + repeated
        let target = try XCTUnwrap(BraceTemplate.find(in: text, selection: NSRange(location: repeated.utf16.count + 2, length: 0)))
        let request = try CompletionClient().makeRequest(for: target, in: text, configuration: LLMConfiguration(provider: .openAI, apiKey: "test-key"))
        let fields = try promptFields(in: request, provider: .openAI)
        let before = try XCTUnwrap(fields["text_before"])
        let after = try XCTUnwrap(fields["text_after"])
        XCTAssertLessThanOrEqual(before.utf16.count + target.range.length + after.utf16.count, 6_000)
        XCTAssertFalse(before.isEmpty)
        XCTAssertFalse(after.isEmpty)
        XCTAssertTrue(repeated.hasSuffix(before))
        XCTAssertTrue(repeated.hasPrefix(after))
        XCTAssertTrue(Set(before).isSubset(of: Set(repeated)))
        XCTAssertTrue(Set(after).isSubset(of: Set(repeated)))
    }

    func testAnthropicRequestUsesMessagesAndVersionedAuthentication() throws {
        let request = try CompletionClient().makeRequest(for: template, in: text, configuration: LLMConfiguration(provider: .anthropic, apiKey: "test-key"))
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertNotNil(body["system"])
        XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["role"], "user")
        XCTAssertEqual(body["model"] as? String, "claude-haiku-4-5")
    }

    func testCustomLocalProviderAllowsNoKeyAndUsesChatCompletions() throws {
        let request = try CompletionClient().makeRequest(for: template, in: text, configuration: LLMConfiguration(provider: .custom, model: "local-model"))
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertNil(body["response_format"])
        XCTAssertEqual((body["messages"] as? [[String: String]])?.count, 2)
    }

    func testRejectsUnsafeAndMalformedEndpoints() {
        for url in ["http://example.com/v1", "https://user:secret@example.com/v1", "https://example.com/v1?key=secret", "https://example.com/v1#secret", "file:///tmp/api", "not a URL"] {
            XCTAssertThrowsError(try CompletionClient.endpoint(for: LLMConfiguration(provider: .custom, baseURL: url, model: "x"))) {
                XCTAssertEqual($0 as? CompletionError, .invalidEndpoint)
            }
        }
        XCTAssertThrowsError(try CompletionClient.endpoint(for: LLMConfiguration(provider: .openAI, baseURL: "https://example.com/v1")))
        XCTAssertThrowsError(try CompletionClient.endpoint(for: LLMConfiguration(provider: .anthropic, baseURL: "https://example.com/v1")))
        XCTAssertNoThrow(try CompletionClient.endpoint(for: LLMConfiguration(provider: .custom, baseURL: "http://[::1]:1234/v1")))
    }

    func testRejectsMissingConfigurationAndStaleTemplate() {
        XCTAssertThrowsError(try CompletionClient().makeRequest(for: template, in: text, configuration: LLMConfiguration(provider: .openAI))) {
            XCTAssertEqual($0 as? CompletionError, .missingAPIKey)
        }
        XCTAssertThrowsError(try CompletionClient().makeRequest(for: template, in: "changed text", configuration: LLMConfiguration(provider: .openAI, apiKey: "test"))) {
            XCTAssertEqual($0 as? CompletionError, .invalidTemplate)
        }
        XCTAssertThrowsError(try CompletionClient().makeRequest(for: template, in: text, configuration: LLMConfiguration(provider: .custom))) {
            XCTAssertEqual($0 as? CompletionError, .missingModel)
        }
    }

    func testRejectsNewlinesInAuthenticationKeys() {
        for key in ["first\nsecond", "first\rsecond", "first\r\nsecond"] {
            XCTAssertThrowsError(try CompletionClient().makeRequest(for: template, in: text, configuration: LLMConfiguration(provider: .openAI, apiKey: key))) {
                XCTAssertEqual($0 as? CompletionError, .unauthorized)
            }
        }
    }

    func testResponseParsingAcrossProviders() throws {
        let json = #"{"suggestions":["Welcome!","Glad you’re here.","Make yourself at home."]}"#
        let expected = ["Welcome!", "Glad you’re here.", "Make yourself at home."]
        XCTAssertEqual(try CompletionClient.parseResponse(response(json, provider: .openAI), provider: .openAI), expected)
        XCTAssertEqual(try CompletionClient.parseResponse(response(json, provider: .anthropic), provider: .anthropic), expected)
        XCTAssertEqual(try CompletionClient.parseResponse(response("```json\n" + json + "\n```", provider: .custom), provider: .custom), expected)
    }

    func testRejectsMissingDuplicateEmptyOrTruncatedSuggestions() throws {
        for json in [#"{"suggestions":["one","two"]}"#, #"{"suggestions":["one","ONE","three"]}"#, #"{"suggestions":["one"," ","three"]}"#, #"{"suggestions":["one",2,"three"]}"#, "not JSON"] {
            XCTAssertThrowsError(try CompletionClient.parseResponse(response(json, provider: .custom), provider: .custom)) {
                XCTAssertEqual($0 as? CompletionError, .malformedResponse)
            }
        }
        let truncated = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "length", "message": ["content": #"{"suggestions":["a","b","c"]}"#]]]])
        XCTAssertThrowsError(try CompletionClient.parseResponse(truncated, provider: .custom))
    }

    func testProviderRefusalIsHandledWithoutEchoingIt() throws {
        let data = try JSONSerialization.data(withJSONObject: ["output": [["type": "message", "content": [["type": "refusal", "refusal": "sensitive user text"]]]]])
        XCTAssertThrowsError(try CompletionClient.parseResponse(data, provider: .openAI)) {
            XCTAssertEqual($0 as? CompletionError, .refused)
            XCTAssertFalse($0.localizedDescription.contains("sensitive"))
        }
    }

    func testHTTPFailuresAreSafeAndUseful() async throws {
        for (status, expected) in [(401, CompletionError.unauthorized), (403, .unauthorized), (429, .rateLimited), (500, .unavailable), (400, .rejectedRequest), (302, .redirected)] {
            let client = mockedClient(status: status, body: Data(#"{"error":{"message":"secret-api-key and private text"}}"#.utf8))
            do {
                _ = try await client.suggestions(for: template, in: text, configuration: LLMConfiguration(provider: .openAI, apiKey: "test-key"))
                XCTFail("Expected HTTP \(status) to fail")
            } catch {
                XCTAssertEqual(error as? CompletionError, expected)
                XCTAssertFalse(error.localizedDescription.contains("secret-api-key"))
            }
        }
    }

    func testSuccessfulURLSessionRequestAndNetworkError() async throws {
        let body = response(#"{"suggestions":["a","b","c"]}"#, provider: .openAI)
        let client = mockedClient(status: 200, body: body)
        let suggestions = try await client.suggestions(for: template, in: text, configuration: LLMConfiguration(provider: .openAI, apiKey: "test-key"))
        XCTAssertEqual(suggestions, ["a", "b", "c"])
        MockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do {
            _ = try await client.suggestions(for: template, in: text, configuration: LLMConfiguration(provider: .openAI, apiKey: "test-key"))
            XCTFail("Expected timeout")
        } catch {
            XCTAssertEqual(error as? CompletionError, .timedOut)
        }
    }

    func testInFlightCancellationStopsRequestAndPropagatesCancellation() async throws {
        let started = expectation(description: "Request started")
        let stopped = expectation(description: "Request stopped")
        HangingURLProtocol.onStart = { started.fulfill() }
        HangingURLProtocol.onStop = { stopped.fulfill() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            HangingURLProtocol.onStart = nil
            HangingURLProtocol.onStop = nil
        }
        let client = CompletionClient(session: session)
        let task = Task {
            try await client.suggestions(for: template, in: text, configuration: LLMConfiguration(provider: .openAI, apiKey: "test-key"))
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled request must not return suggestions")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        await fulfillment(of: [stopped], timeout: 3)
    }

    private func promptFields(in request: URLRequest, provider: LLMProvider) throws -> [String: String] {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let prompt: String
        if provider == .openAI {
            prompt = try XCTUnwrap(body["input"] as? String)
        } else {
            prompt = try XCTUnwrap((body["messages"] as? [[String: String]])?.last?["content"])
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(prompt.utf8)) as? [String: String])
    }

    private func requestContents(_ request: URLRequest, provider: LLMProvider) throws
        -> (body: [String: Any], fields: [String: Any], system: String) {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let prompt: String
        let system: String
        if provider == .openAI {
            prompt = try XCTUnwrap(body["input"] as? String)
            system = try XCTUnwrap(body["instructions"] as? String)
        } else {
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            prompt = try XCTUnwrap(messages.last?["content"])
            system = try XCTUnwrap(provider == .anthropic ? body["system"] as? String : messages.first?["content"])
        }
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(prompt.utf8)) as? [String: Any])
        return (body, fields, system)
    }

    private func response(_ json: String, provider: LLMProvider) -> Data {
        let object: [String: Any]
        switch provider {
        case .openAI: object = ["status": "completed", "output": [["type": "reasoning", "summary": []], ["type": "message", "content": [["type": "output_text", "text": json]]]]]
        case .anthropic: object = ["stop_reason": "end_turn", "content": [["type": "text", "text": json]]]
        case .custom: object = ["choices": [["finish_reason": "stop", "message": ["content": json]]]]
        }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func mockedClient(status: Int, body: Data) -> CompletionClient {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, body)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return CompletionClient(session: URLSession(configuration: configuration))
    }
}

private final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private final class HangingURLProtocol: URLProtocol {
    static var onStart: (() -> Void)?
    static var onStop: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.onStart?() }
    override func stopLoading() { Self.onStop?() }
}
