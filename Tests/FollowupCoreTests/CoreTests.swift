import Foundation
import Testing
@testable import FollowupCore

@Suite struct AnalysisParsing {
    @Test func parsesFencedJSONWithPreamble() throws {
        let raw = """
        Sure! Here's the map:
        ```json
        {"title": "Northwind bag order", "summary": "Maya wants print cost and a sample.",
         "branches": [{"label": "People", "items": ["Maya · Northwind buyer", "Leo"]}],
         "tasks": [{"text": "Ask Leo for print cost", "depends_on": []},
                   {"text": "Reply to Maya", "depends_on": [0]}]}
        ```
        """
        let a = try Analysis.parse(raw)
        #expect(a.title == "Northwind bag order")
        #expect(a.branches == [Branch(label: "People", items: ["Maya · Northwind buyer", "Leo"])])
        #expect(a.tasks == [ProposedTask(text: "Ask Leo for print cost"),
                            ProposedTask(text: "Reply to Maya", dependsOn: [0])])
    }

    @Test func stripsThinkBlocksThatContainBraces() throws {
        let raw = "<think>maybe {\"title\": \"wrong\"}</think>{\"title\": \"Right\", \"tasks\": []}"
        #expect(try Analysis.parse(raw).title == "Right")
    }

    @Test func acceptsDictionaryBranchesAndObjectItems() throws {
        let raw = """
        {"title": "T", "branches": {"People": [{"name": "Maya", "role": "buyer"}], "Facts": ["40 t", 175]},
         "tasks": ["Send sample"]}
        """
        let a = try Analysis.parse(raw)
        #expect(a.branches == [Branch(label: "Facts", items: ["40 t", "175"]),
                               Branch(label: "People", items: ["Maya · buyer"])])
        #expect(a.tasks == [ProposedTask(text: "Send sample")])
    }

    @Test func dropsForwardSelfAndBogusDependencies() throws {
        let raw = """
        {"tasks": [{"text": "A", "depends_on": [0, 1]}, {"text": "B", "depends_on": ["0", 5, -1, "x"]}]}
        """
        let a = try Analysis.parse(raw)
        #expect(a.tasks[0].dependsOn == [])
        #expect(a.tasks[1].dependsOn == [0])
    }

    @Test func throwsWhenNoJSON() {
        #expect(throws: AnalysisError.self) { try Analysis.parse("I can't help with that.") }
    }
}

@Suite struct ThinkFilterTests {
    @Test func hidesUnfinishedThinking() {
        #expect(ThinkFilter.visible("Hi <think>still going") == "Hi")
        #expect(ThinkFilter.visible("<think>x</think>Draft") == "Draft")
        #expect(ThinkFilter.visible("plain") == "plain")
    }
}

@Suite struct SSEParsing {
    @Test func parsesDeltaDoneAndNoise() {
        #expect(SSE.parse(#"data: {"choices":[{"delta":{"content":"Hel"}}]}"#) == .delta("Hel"))
        #expect(SSE.parse("data: [DONE]") == .done)
        #expect(SSE.parse(": keep-alive") == .ignore)
        #expect(SSE.parse(#"data: {"choices":[{"delta":{"role":"assistant"}}]}"#) == .ignore)
    }
}

@Suite struct WheelGeometry {
    @Test func picksSlicesClockwiseFromTop() {
        let pick = { (dx: Double, dy: Double) in RadialGeometry.slice(dx: dx, dy: dy, count: 6, innerRadius: 40) }
        #expect(pick(0, -100) == 0)   // up: Follow-up
        #expect(pick(87, -50) == 1)   // upper right: Research
        #expect(pick(87, 50) == 2)    // lower right: To-do
        #expect(pick(0, 100) == 3)    // down: Idea
        #expect(pick(-87, 50) == 4)   // lower left: Reference
        #expect(pick(-87, -50) == 5)  // upper left: Waiting on
        #expect(pick(10, 10) == nil)  // dead zone
    }
}

@Suite struct StoreTests {
    func makeStore() throws -> Store {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("followup-test-\(UUID().uuidString).db").path
        return try Store(path: path)
    }

    @Test func appliesAnalysisAndMapsDependenciesToTaskIDs() throws {
        let store = try makeStore()
        let id = try store.insertCapture(kind: .followUp, text: "Northwind…", sourceApp: "Grok",
                                         windowTitle: "Chat", url: "https://grok.com")
        let analysis = Analysis(title: "Northwind", summary: "s",
                                branches: [Branch(label: "People", items: ["Maya"])],
                                tasks: [ProposedTask(text: "Ask Leo"), ProposedTask(text: "Send sample"),
                                        ProposedTask(text: "Reply to Maya", dependsOn: [0])])
        try store.applyAnalysis(analysis, to: id)

        let capture = try #require(try store.capture(id: id))
        #expect(capture.status == .ready)
        #expect(capture.branches == analysis.branches)
        let tasks = try store.tasks(captureId: id)
        #expect(tasks.map(\.text) == ["Ask Leo", "Send sample", "Reply to Maya"])
        #expect(tasks[2].blockedBy == [tasks[0].id])
    }

    @Test func reanalysisKeepsFinishedAndUserTasks() throws {
        let store = try makeStore()
        let id = try store.insertCapture(kind: .todo, text: "x", sourceApp: "a", windowTitle: "", url: nil)
        try store.applyAnalysis(Analysis(title: "", summary: "", branches: [],
                                         tasks: [ProposedTask(text: "old done"), ProposedTask(text: "old open")]), to: id)
        let first = try store.tasks(captureId: id)
        try store.setTaskDone(first[0].id, true)
        try store.addTask(captureId: id, text: "mine")

        try store.applyAnalysis(Analysis(title: "", summary: "", branches: [],
                                         tasks: [ProposedTask(text: "new")]), to: id)
        #expect(try store.tasks(captureId: id).map(\.text) == ["old done", "mine", "new"])
    }

    @Test func deletingCaptureRemovesItsTasks() throws {
        let store = try makeStore()
        let id = try store.insertCapture(kind: .idea, text: "x", sourceApp: "a", windowTitle: "", url: nil)
        try store.addTask(captureId: id, text: "t")
        try store.deleteCapture(id)
        #expect(try store.allTasks().isEmpty)
        #expect(try store.captures().isEmpty)
    }
}

@Suite struct ClaudeCodeParsing {
    @Test func parsesStreamDeltasAndResults() {
        let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}}"#
        #expect(ClaudeStream.parse(delta) == .delta("Hello"))
        #expect(ClaudeStream.parse(#"{"type":"result","subtype":"success","is_error":false,"result":"ready"}"#) == .result("ready"))
        #expect(ClaudeStream.parse(#"{"type":"result","is_error":true,"result":"Not logged in"}"#) == .error("Not logged in"))
        #expect(ClaudeStream.parse(#"{"type":"system","subtype":"init"}"#) == .ignore)
        #expect(ClaudeStream.parse("not json") == .ignore)
    }

    @Test func splitsSystemFromPromptAndDisablesTools() {
        let (system, prompt) = ClaudeCodeClient.split([.system("rules"), .user("text")])
        #expect(system == "rules" && prompt == "text")
        let args = ClaudeCodeClient(model: "haiku").arguments(system: "rules", streaming: false)
        #expect(args.contains("--tools") && args.contains("--strict-mcp-config") && args.contains("--no-session-persistence"))
    }

    @Test func oldSettingsDecodeWithClaudeDefaults() throws {
        let old = #"{"baseURL":"http://localhost:1234/v1","model":"m","apiKey":""}"#
        let settings = try JSONDecoder().decode(LLMSettings.self, from: Data(old.utf8))
        #expect(settings.baseURL == "http://localhost:1234/v1")
        #expect(settings.provider == .claudeCode && settings.claudeModel == "sonnet")
    }
}
