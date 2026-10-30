import Foundation

extension LLMBackend {
    public func complete(_ messages: [ChatMessage]) async throws -> String {
        try await complete(messages, temperature: 0.2)
    }

    public func stream(_ messages: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        stream(messages, temperature: 0.4)
    }
}

public enum ClaudeCodeError: LocalizedError {
    case notInstalled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            "Couldn't find the `claude` command. Install Claude Code and sign in, or pick another model in Settings."
        case .failed(let message):
            "Claude Code: \(message.prefix(400))"
        }
    }
}

/// Answers through the user's own Claude Code login by running `claude -p`
/// headless: no tools, no MCP servers, no hooks, no saved session.
public struct ClaudeCodeClient: LLMBackend {
    public var model: String

    public init(model: String) {
        self.model = model
    }

    static let searchPaths = [
        "~/.local/bin/claude",
        "~/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    ]

    public static func locate() -> String? {
        for path in searchPaths {
            let expanded = (path as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: expanded) { return expanded }
        }
        return nil
    }

    func arguments(system: String, streaming: Bool) -> [String] {
        var args = ["-p", "--model", model, "--system-prompt", system,
                    "--tools", "", "--no-session-persistence", "--setting-sources", "", "--strict-mcp-config"]
        args += streaming ? ["--output-format", "stream-json", "--verbose", "--include-partial-messages"]
                          : ["--output-format", "json"]
        return args
    }

    static func split(_ messages: [ChatMessage]) -> (system: String, prompt: String) {
        let system = messages.filter { $0.role == "system" }.map(\.content).joined(separator: "\n\n")
        let prompt = messages.filter { $0.role != "system" }.map(\.content).joined(separator: "\n\n")
        return (system.isEmpty ? "You are a helpful assistant." : system, prompt)
    }

    private func launch(_ messages: [ChatMessage], streaming: Bool) throws -> (Process, Pipe, Pipe) {
        guard let executable = Self.locate() else { throw ClaudeCodeError.notInstalled }
        let (system, prompt) = Self.split(messages)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments(system: system, streaming: streaming)
        // Run outside any project so no CLAUDE.md or project settings apply.
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\((executable as NSString).deletingLastPathComponent):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        process.environment = env

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        stdin.fileHandleForWriting.write(Data(prompt.utf8))
        try? stdin.fileHandleForWriting.close()
        return (process, stdout, stderr)
    }

    public func complete(_ messages: [ChatMessage], temperature: Double) async throws -> String {
        let (process, stdout, stderr) = try launch(messages, streaming: false)
        let errors = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }
        let output = await Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }.value
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        switch ClaudeStream.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case .result(let result): return result
        case .error(let message): throw ClaudeCodeError.failed(message)
        default:
            let err = String(decoding: await errors.value, as: UTF8.self)
            throw ClaudeCodeError.failed(err.isEmpty ? text : err)
        }
    }

    public func stream(_ messages: [ChatMessage], temperature: Double) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var process: Process?
                do {
                    let (p, stdout, stderr) = try launch(messages, streaming: true)
                    process = p
                    let errors = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }
                    var sawText = false
                    for try await line in stdout.fileHandleForReading.bytes.lines {
                        switch ClaudeStream.parse(line) {
                        case .delta(let text):
                            sawText = true
                            continuation.yield(text)
                        case .result(let text):
                            if !sawText { continuation.yield(text) }
                        case .error(let message):
                            throw ClaudeCodeError.failed(message)
                        case .ignore:
                            continue
                        }
                    }
                    p.waitUntilExit()
                    if p.terminationStatus != 0 && !sawText {
                        throw ClaudeCodeError.failed(String(decoding: await errors.value, as: UTF8.self))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                if Task.isCancelled { process?.terminate() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Parses one line of `claude -p` output (`json` or `stream-json` format).
public enum ClaudeStream {
    public enum Event: Equatable {
        case delta(String)
        case result(String)
        case error(String)
        case ignore
    }

    public static func parse(_ line: String) -> Event {
        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return .ignore
        }
        switch json["type"] as? String {
        case "stream_event":
            guard let event = json["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String
            else { return .ignore }
            return .delta(text)
        case "result":
            let text = json["result"] as? String ?? ""
            if json["is_error"] as? Bool == true {
                return .error(text.isEmpty ? (json["subtype"] as? String ?? "unknown error") : text)
            }
            return .result(text)
        default:
            return .ignore
        }
    }
}
