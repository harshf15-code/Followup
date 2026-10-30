import Foundation

/// What the local model returns for a capture: a mind map plus next actions.
public struct Analysis: Equatable, Sendable {
    public var title: String
    public var summary: String
    public var branches: [Branch]
    public var tasks: [ProposedTask]

    public init(title: String, summary: String, branches: [Branch], tasks: [ProposedTask]) {
        self.title = title
        self.summary = summary
        self.branches = branches
        self.tasks = tasks
    }
}

public struct ProposedTask: Equatable, Sendable {
    public var text: String
    /// Indexes of earlier tasks in the same analysis that must happen first.
    public var dependsOn: [Int]

    public init(text: String, dependsOn: [Int] = []) {
        self.text = text
        self.dependsOn = dependsOn
    }
}

public enum AnalysisError: LocalizedError {
    case noJSON(String)

    public var errorDescription: String? {
        switch self {
        case .noJSON(let raw):
            "The model didn't return a mind map. It said: \(raw.prefix(200))"
        }
    }
}

extension Analysis {
    static let maxTasks = 10

    /// Parses model output leniently: small local models wrap JSON in prose or
    /// code fences, emit branches as a dictionary, or use objects for items.
    public static func parse(_ raw: String) throws -> Analysis {
        guard let json = extractJSONObject(raw),
              let data = json.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw AnalysisError.noJSON(ThinkFilter.visible(raw)) }

        let title = string(dict["title"]) ?? ""
        let summary = string(dict["summary"]) ?? ""

        var branches: [Branch] = []
        if let array = dict["branches"] as? [Any] {
            for element in array {
                guard let b = element as? [String: Any] else { continue }
                let label = string(b["label"] ?? b["name"] ?? b["title"]) ?? ""
                let items = list(b["items"] ?? b["children"] ?? b["points"])
                if !label.isEmpty, !items.isEmpty { branches.append(Branch(label: label, items: items)) }
            }
        } else if let map = dict["branches"] as? [String: Any] {
            for key in map.keys.sorted() {
                let items = list(map[key])
                if !items.isEmpty { branches.append(Branch(label: key, items: items)) }
            }
        }

        var tasks: [ProposedTask] = []
        for element in (dict["tasks"] as? [Any]) ?? [] {
            guard tasks.count < maxTasks else { break }
            let index = tasks.count
            if let text = element as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { tasks.append(ProposedTask(text: trimmed)) }
            } else if let t = element as? [String: Any],
                      let text = string(t["text"] ?? t["task"] ?? t["title"]), !text.isEmpty {
                let rawDeps = (t["depends_on"] ?? t["dependsOn"] ?? t["blocked_by"]) as? [Any] ?? []
                // Only earlier tasks may block a task, which rules out cycles.
                let deps = rawDeps.compactMap(int).filter { $0 >= 0 && $0 < index }
                tasks.append(ProposedTask(text: text, dependsOn: Array(Set(deps)).sorted()))
            }
        }

        return Analysis(title: title, summary: summary, branches: branches, tasks: tasks)
    }

    /// Returns the outermost `{…}` span after removing reasoning blocks.
    static func extractJSONObject(_ raw: String) -> String? {
        let text = ThinkFilter.visible(raw)
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"), start < end
        else { return nil }
        return String(text[start...end])
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: s.trimmingCharacters(in: .whitespacesAndNewlines)
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }

    private static func int(_ value: Any) -> Int? {
        switch value {
        case let n as NSNumber: n.intValue
        case let s as String: Int(s.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    private static func list(_ value: Any?) -> [String] {
        guard let value else { return [] }
        if let s = string(value) { return s.isEmpty ? [] : [s] }
        if let array = value as? [Any] { return array.flatMap { list($0) } }
        if let object = value as? [String: Any] {
            // e.g. {"name": "Maya", "role": "Northwind buyer"} -> "Maya · Northwind buyer"
            let preferred = ["name", "text", "title", "role", "detail", "note"]
            let keys = preferred.filter { object[$0] != nil }
                + object.keys.filter { !preferred.contains($0) }.sorted()
            let joined = keys.compactMap { string(object[$0]) }.filter { !$0.isEmpty }.joined(separator: " · ")
            return joined.isEmpty ? [] : [joined]
        }
        return []
    }
}

/// Removes `<think>…</think>` reasoning that some local models emit inline.
public enum ThinkFilter {
    public static func visible(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "<think>") {
            result += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "</think>") else {
                // Still thinking (stream not finished): hide the tail.
                return result.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            rest = rest[close.upperBound...]
        }
        result += rest
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
