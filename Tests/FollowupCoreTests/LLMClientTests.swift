import Foundation
import Testing
@testable import FollowupCore

/// Fakes an OpenAI-compatible server inside URLSession.shared.
final class MockServer: URLProtocol {
    nonisolated(unsafe) static var routes: [String: (Int, String)] = [:]
    nonisolated(unsafe) static var lastBody: [String: Any]?

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "mock.local" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            Self.lastBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        let (status, body) = Self.routes[request.url!.path] ?? (404, "not found")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct LLMClientTests {
    init() {
        URLProtocol.registerClass(MockServer.self)
        MockServer.routes = [
            "/v1/models": (200, #"{"data":[{"id":"qwen2.5:7b"},{"id":"llama3.2"}]}"#),
            "/v1/chat/completions": (200, #"{"choices":[{"message":{"role":"assistant","content":"{\"title\":\"Hi\"}"}}]}"#),
        ]
    }

    let client = LLMClient(settings: LLMSettings(baseURL: "http://mock.local/v1/"))

    @Test func listsModelsAndPicksFirstWhenUnset() async throws {
        #expect(try await client.models() == ["qwen2.5:7b", "llama3.2"])
        #expect(try await client.resolvedModel() == "qwen2.5:7b")
    }

    @Test func completesAndSendsChosenModel() async throws {
        var configured = client
        configured.settings.model = "llama3.2"
        let reply = try await configured.complete([.user("hello")])
        #expect(try Analysis.parse(reply).title == "Hi")
        #expect(MockServer.lastBody?["model"] as? String == "llama3.2")
        #expect(MockServer.lastBody?["stream"] as? Bool == false)
    }

    @Test func streamsDeltas() async throws {
        MockServer.routes["/v1/chat/completions"] = (200, """
        data: {"choices":[{"delta":{"role":"assistant"}}]}

        data: {"choices":[{"delta":{"content":"Hi "}}]}

        data: {"choices":[{"delta":{"content":"Maya"}}]}

        data: [DONE]

        """)
        var text = ""
        for try await chunk in client.stream([.user("draft")]) { text += chunk }
        #expect(text == "Hi Maya")
    }

    @Test func surfacesHTTPErrors() async {
        MockServer.routes["/v1/chat/completions"] = (404, #"{"error":"model 'nope' not found"}"#)
        var configured = client
        configured.settings.model = "nope"
        await #expect(throws: LLMError.self) { try await configured.complete([.user("x")]) }
    }
}
