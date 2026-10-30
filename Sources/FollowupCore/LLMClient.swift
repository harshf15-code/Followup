import Foundation

public struct ChatMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ content: String) -> ChatMessage { ChatMessage(role: "system", content: content) }
    public static func user(_ content: String) -> ChatMessage { ChatMessage(role: "user", content: content) }
}

/// Anything that can answer a chat: a model server or the Claude Code CLI.
public protocol LLMBackend: Sendable {
    func complete(_ messages: [ChatMessage], temperature: Double) async throws -> String
    func stream(_ messages: [ChatMessage], temperature: Double) -> AsyncThrowingStream<String, Error>
}

public enum LLMProvider: String, Codable, CaseIterable, Sendable {
    /// Runs `claude -p` with the user's own Claude Code login.
    case claudeCode
    /// Ollama, LM Studio, llama.cpp, or any OpenAI-compatible API.
    case openAICompatible
}

public struct LLMSettings: Codable, Equatable, Sendable {
    public var provider: LLMProvider
    /// Claude model alias passed to `claude --model` (haiku, sonnet, opus).
    public var claudeModel: String
    /// Any OpenAI-compatible server: Ollama (http://localhost:11434/v1),
    /// LM Studio (http://localhost:1234/v1), llama.cpp server, or a cloud API.
    public var baseURL: String
    /// Empty means "use the first model the server lists".
    public var model: String
    public var apiKey: String

    public init(provider: LLMProvider = .claudeCode, claudeModel: String = "sonnet",
                baseURL: String = "http://localhost:11434/v1", model: String = "", apiKey: String = "") {
        self.provider = provider
        self.claudeModel = claudeModel
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LLMSettings()
        provider = try c.decodeIfPresent(LLMProvider.self, forKey: .provider) ?? defaults.provider
        claudeModel = try c.decodeIfPresent(String.self, forKey: .claudeModel) ?? defaults.claudeModel
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? defaults.baseURL
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? defaults.model
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? defaults.apiKey
    }

    public func makeBackend() -> any LLMBackend {
        switch provider {
        case .claudeCode: ClaudeCodeClient(model: claudeModel)
        case .openAICompatible: LLMClient(settings: self)
        }
    }

    /// Human-readable name of the model that will answer.
    public var modelLabel: String {
        switch provider {
        case .claudeCode: "Claude \(claudeModel) (Claude Code login)"
        case .openAICompatible: model.isEmpty ? "first model at \(baseURL)" : model
        }
    }
}

public enum LLMError: LocalizedError {
    case badURL(String)
    case unreachable(String, underlying: String)
    case http(Int, String)
    case noModels(String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .badURL(let url):
            "“\(url)” isn't a valid server address."
        case .unreachable(let url, let underlying):
            "Can't reach the model server at \(url). Is Ollama or LM Studio running? (\(underlying))"
        case .http(let code, let body):
            "The model server returned HTTP \(code): \(body.prefix(300))"
        case .noModels(let url):
            "The server at \(url) has no models. Pull one first, e.g. `ollama pull qwen2.5:7b`."
        case .emptyResponse:
            "The model returned an empty response."
        }
    }
}

/// Client for the OpenAI-compatible `/models` and `/chat/completions` endpoints.
public struct LLMClient: LLMBackend {
    public var settings: LLMSettings

    public init(settings: LLMSettings) {
        self.settings = settings
    }

    private func url(_ path: String) throws -> URL {
        var base = settings.baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path), url.scheme != nil else { throw LLMError.badURL(settings.baseURL) }
        return url
    }

    private func request(_ path: String, body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: try url(path))
        request.timeoutInterval = 600
        if !settings.apiKey.isEmpty {
            request.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LLMError.unreachable(settings.baseURL, underlying: error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LLMError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return data
    }

    public func models() async throws -> [String] {
        let data = try await send(try request("/models"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let list = json?["data"] as? [[String: Any]] ?? []
        return list.compactMap { $0["id"] as? String }
    }

    public func resolvedModel() async throws -> String {
        if !settings.model.isEmpty { return settings.model }
        guard let first = try await models().first else { throw LLMError.noModels(settings.baseURL) }
        return first
    }

    private func body(_ messages: [ChatMessage], model: String, temperature: Double, stream: Bool) -> [String: Any] {
        [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": temperature,
            "stream": stream,
        ]
    }

    public func complete(_ messages: [ChatMessage], temperature: Double = 0.2) async throws -> String {
        let model = try await resolvedModel()
        let data = try await send(try request("/chat/completions",
                                               body: body(messages, model: model, temperature: temperature, stream: false)))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let message = ((json?["choices"] as? [[String: Any]])?.first?["message"]) as? [String: Any]
        guard let content = message?["content"] as? String, !content.isEmpty else { throw LLMError.emptyResponse }
        return content
    }

    /// Streams the reply token by token. Each element is the next text chunk.
    public func stream(_ messages: [ChatMessage], temperature: Double = 0.4) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let model = try await resolvedModel()
                    let request = try request("/chat/completions",
                                              body: body(messages, model: model, temperature: temperature, stream: true))
                    let bytes: URLSession.AsyncBytes
                    let response: URLResponse
                    do {
                        (bytes, response) = try await URLSession.shared.bytes(for: request)
                    } catch {
                        throw LLMError.unreachable(settings.baseURL, underlying: error.localizedDescription)
                    }
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw LLMError.http(http.statusCode, body)
                    }
                    for try await line in bytes.lines {
                        switch SSE.parse(line) {
                        case .delta(let text): continuation.yield(text)
                        case .done: continuation.finish(); return
                        case .ignore: continue
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Parses one line of an OpenAI-style server-sent event stream.
public enum SSE {
    public enum Event: Equatable {
        case delta(String)
        case done
        case ignore
    }

    public static func parse(_ line: String) -> Event {
        guard line.hasPrefix("data:") else { return .ignore }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let delta = choice["delta"] as? [String: Any],
              let content = delta["content"] as? String, !content.isEmpty
        else { return .ignore }
        return .delta(content)
    }
}
