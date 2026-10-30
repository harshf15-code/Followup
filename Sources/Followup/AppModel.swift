import AppKit
import FollowupCore
import ServiceManagement

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var captures: [Capture] = []
    @Published private(set) var tasks: [Int64: [TaskItem]] = [:]
    @Published var loadError: String?
    @Published var settings: LLMSettings {
        didSet { saveSettings() }
    }

    private let store: Store?
    private static let settingsKey = "llmSettings"

    init(storePath: String = Store.defaultPath) {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let saved = try? JSONDecoder().decode(LLMSettings.self, from: data) {
            settings = saved
        } else {
            settings = LLMSettings()
        }
        do {
            store = try Store(path: storePath)
        } catch {
            store = nil
            loadError = error.localizedDescription
        }
        reload()
        // Anything interrupted by a quit or crash gets another go.
        for capture in captures where capture.status == .pending || capture.status == .processing {
            analyze(capture.id)
        }
    }

    /// The model server, used for listing models in Settings.
    var client: LLMClient { LLMClient(settings: settings) }

    /// Whatever answers prompts: Claude Code or a model server.
    var backend: any LLMBackend { settings.makeBackend() }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
    }

    func reload() {
        guard let store else { return }
        do {
            captures = try store.captures()
            tasks = Dictionary(grouping: try store.allTasks(), by: \.captureId)
        } catch {
            loadError = error.localizedDescription
        }
    }

    func capture(id: Int64) -> Capture? { captures.first { $0.id == id } }

    func tasks(for captureId: Int64) -> [TaskItem] { tasks[captureId] ?? [] }

    var openTaskCount: Int { tasks.values.joined().filter { !$0.done }.count }

    private func perform(_ body: (Store) throws -> Void) {
        guard let store else { return }
        do {
            try body(store)
        } catch {
            loadError = error.localizedDescription
        }
        reload()
    }

    // MARK: Captures

    func add(kind: CaptureKind, selection: CapturedSelection) {
        var newID: Int64?
        perform { newID = try $0.insertCapture(kind: kind, text: selection.text, sourceApp: selection.appName,
                                               windowTitle: selection.windowTitle, url: selection.url) }
        if let newID { analyze(newID) }
    }

    func analyze(_ id: Int64) {
        guard let capture = capture(id: id) else { return }
        perform { try $0.setStatus(id, .processing) }
        let messages = Prompts.analyze(kind: capture.kind, text: capture.text, sourceApp: capture.sourceApp,
                                       windowTitle: capture.windowTitle, url: capture.url, now: capture.createdAt)
        let backend = backend
        Task {
            do {
                let raw = try await backend.complete(messages)
                let analysis = try Analysis.parse(raw)
                perform { try $0.applyAnalysis(analysis, to: id) }
            } catch {
                perform { try $0.setStatus(id, .failed, error: error.localizedDescription) }
            }
        }
    }

    func setKind(_ id: Int64, _ kind: CaptureKind) {
        perform { try $0.setKind(id, kind) }
        analyze(id)
    }

    func setTitle(_ id: Int64, _ title: String) {
        perform { try $0.setTitle(id, title) }
    }

    func delete(_ id: Int64) {
        perform { try $0.deleteCapture(id) }
    }

    // MARK: Tasks

    func toggle(_ task: TaskItem) {
        perform { try $0.setTaskDone(task.id, !task.done) }
    }

    func addTask(to captureId: Int64, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        perform { try $0.addTask(captureId: captureId, text: trimmed) }
    }

    func deleteTask(_ task: TaskItem) {
        perform { try $0.deleteTask(task.id) }
    }

    func saveAssist(_ task: TaskItem, _ text: String) {
        perform { try $0.setAssist(task.id, text) }
    }

    /// Unfinished tasks this one is waiting on.
    func blockers(of task: TaskItem) -> [TaskItem] {
        tasks(for: task.captureId).filter { task.blockedBy.contains($0.id) && !$0.done }
    }

    func assistStream(for task: TaskItem, instruction: String?) -> AsyncThrowingStream<String, Error>? {
        guard let capture = capture(id: task.captureId) else { return nil }
        let messages = Prompts.assist(capture: capture, tasks: tasks(for: capture.id), task: task,
                                      instruction: instruction)
        return backend.stream(messages)
    }

    // MARK: Launch at login

    var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loadError = "Couldn't change launch at login: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    /// Turns launch-at-login on the first time the app runs, like Goldfish does.
    func seedLaunchAtLogin() {
        let key = "launchAtLoginSeeded"
        guard !UserDefaults.standard.bool(forKey: key), Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        UserDefaults.standard.set(true, forKey: key)
        setLaunchAtLogin(true)
    }
}
