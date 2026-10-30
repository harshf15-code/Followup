import Foundation

/// All captures and tasks, in one local SQLite file.
public final class Store {
    private let db: Database

    public static var defaultPath: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Followup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("followup.db").path
    }

    public init(path: String = Store.defaultPath) throws {
        db = try Database(path: path)
        try db.exec("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;")
        try migrate()
    }

    private func migrate() throws {
        let version = try db.query("PRAGMA user_version") { $0.int(0) }.first ?? 0
        if version < 1 {
            try db.exec("""
            CREATE TABLE captures (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                kind         TEXT NOT NULL,
                text         TEXT NOT NULL,
                source_app   TEXT NOT NULL DEFAULT '',
                window_title TEXT NOT NULL DEFAULT '',
                url          TEXT,
                created_at   REAL NOT NULL,
                title        TEXT NOT NULL DEFAULT '',
                summary      TEXT NOT NULL DEFAULT '',
                branches     TEXT NOT NULL DEFAULT '[]',
                status       TEXT NOT NULL DEFAULT 'pending',
                error        TEXT
            );
            CREATE INDEX idx_captures_created ON captures(created_at DESC);
            CREATE TABLE tasks (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                capture_id   INTEGER NOT NULL REFERENCES captures(id) ON DELETE CASCADE,
                position     INTEGER NOT NULL,
                text         TEXT NOT NULL,
                done         INTEGER NOT NULL DEFAULT 0,
                blocked_by   TEXT NOT NULL DEFAULT '[]',
                assist       TEXT,
                source       TEXT NOT NULL DEFAULT 'ai',
                created_at   REAL NOT NULL,
                completed_at REAL
            );
            CREATE INDEX idx_tasks_capture ON tasks(capture_id, position);
            PRAGMA user_version = 1;
            """)
        }
    }

    // MARK: Captures

    private static let captureColumns =
        "id, kind, text, source_app, window_title, url, created_at, title, summary, branches, status, error"

    private static func capture(_ r: Database.Row) -> Capture {
        Capture(
            id: r.int(0),
            kind: CaptureKind(rawValue: r.text(1)) ?? .todo,
            text: r.text(2),
            sourceApp: r.text(3),
            windowTitle: r.text(4),
            url: r.optionalText(5),
            createdAt: Date(timeIntervalSince1970: r.double(6)),
            title: r.text(7),
            summary: r.text(8),
            branches: (try? JSONDecoder().decode([Branch].self, from: Data(r.text(9).utf8))) ?? [],
            status: CaptureStatus(rawValue: r.text(10)) ?? .pending,
            error: r.optionalText(11)
        )
    }

    @discardableResult
    public func insertCapture(kind: CaptureKind, text: String, sourceApp: String, windowTitle: String,
                              url: String?, createdAt: Date = Date()) throws -> Int64 {
        try db.run(
            "INSERT INTO captures (kind, text, source_app, window_title, url, created_at) VALUES (?, ?, ?, ?, ?, ?)",
            [.text(kind.rawValue), .text(text), .text(sourceApp), .text(windowTitle),
             url.map(SQLValue.text) ?? .null, .double(createdAt.timeIntervalSince1970)]
        )
    }

    public func captures() throws -> [Capture] {
        try db.query("SELECT \(Self.captureColumns) FROM captures ORDER BY created_at DESC", [], Self.capture)
    }

    public func capture(id: Int64) throws -> Capture? {
        try db.query("SELECT \(Self.captureColumns) FROM captures WHERE id = ?", [.int(id)], Self.capture).first
    }

    public func setStatus(_ id: Int64, _ status: CaptureStatus, error: String? = nil) throws {
        try db.run("UPDATE captures SET status = ?, error = ? WHERE id = ?",
                   [.text(status.rawValue), error.map(SQLValue.text) ?? .null, .int(id)])
    }

    public func setKind(_ id: Int64, _ kind: CaptureKind) throws {
        try db.run("UPDATE captures SET kind = ? WHERE id = ?", [.text(kind.rawValue), .int(id)])
    }

    public func setTitle(_ id: Int64, _ title: String) throws {
        try db.run("UPDATE captures SET title = ? WHERE id = ?", [.text(title), .int(id)])
    }

    public func deleteCapture(_ id: Int64) throws {
        try db.run("DELETE FROM captures WHERE id = ?", [.int(id)])
    }

    /// Stores the mind map and replaces the model's unfinished tasks with the
    /// new ones. Finished tasks and tasks you added yourself are kept.
    public func applyAnalysis(_ analysis: Analysis, to captureId: Int64) throws {
        let branchesJSON = String(decoding: try JSONEncoder().encode(analysis.branches), as: UTF8.self)
        try db.transaction {
            try db.run(
                "UPDATE captures SET title = ?, summary = ?, branches = ?, status = 'ready', error = NULL WHERE id = ?",
                [.text(analysis.title), .text(analysis.summary), .text(branchesJSON), .int(captureId)]
            )
            try db.run("DELETE FROM tasks WHERE capture_id = ? AND source = 'ai' AND done = 0", [.int(captureId)])
            var position = try db.query("SELECT COALESCE(MAX(position), -1) FROM tasks WHERE capture_id = ?",
                                        [.int(captureId)]) { Int($0.int(0)) }.first ?? -1
            var newIDs: [Int64] = []
            let now = Date().timeIntervalSince1970
            for task in analysis.tasks {
                position += 1
                let blockers = task.dependsOn.filter { $0 < newIDs.count }.map { newIDs[$0] }
                let id = try db.run(
                    "INSERT INTO tasks (capture_id, position, text, blocked_by, source, created_at) VALUES (?, ?, ?, ?, 'ai', ?)",
                    [.int(captureId), .int(Int64(position)), .text(task.text), .text(Self.json(blockers)), .double(now)]
                )
                newIDs.append(id)
            }
        }
    }

    // MARK: Tasks

    private static let taskColumns =
        "id, capture_id, position, text, done, blocked_by, assist, source, created_at, completed_at"

    private static func task(_ r: Database.Row) -> TaskItem {
        TaskItem(
            id: r.int(0),
            captureId: r.int(1),
            position: Int(r.int(2)),
            text: r.text(3),
            done: r.int(4) != 0,
            blockedBy: (try? JSONDecoder().decode([Int64].self, from: Data(r.text(5).utf8))) ?? [],
            assist: r.optionalText(6),
            source: r.text(7),
            createdAt: Date(timeIntervalSince1970: r.double(8)),
            completedAt: r.optionalDouble(9).map(Date.init(timeIntervalSince1970:))
        )
    }

    public func tasks(captureId: Int64) throws -> [TaskItem] {
        try db.query("SELECT \(Self.taskColumns) FROM tasks WHERE capture_id = ? ORDER BY position",
                     [.int(captureId)], Self.task)
    }

    public func allTasks() throws -> [TaskItem] {
        try db.query("SELECT \(Self.taskColumns) FROM tasks ORDER BY capture_id, position", [], Self.task)
    }

    @discardableResult
    public func addTask(captureId: Int64, text: String) throws -> Int64 {
        let position = try db.query("SELECT COALESCE(MAX(position), -1) + 1 FROM tasks WHERE capture_id = ?",
                                    [.int(captureId)]) { $0.int(0) }.first ?? 0
        return try db.run(
            "INSERT INTO tasks (capture_id, position, text, source, created_at) VALUES (?, ?, ?, 'user', ?)",
            [.int(captureId), .int(position), .text(text), .double(Date().timeIntervalSince1970)]
        )
    }

    public func setTaskDone(_ id: Int64, _ done: Bool) throws {
        try db.run("UPDATE tasks SET done = ?, completed_at = ? WHERE id = ?",
                   [.int(done ? 1 : 0), done ? .double(Date().timeIntervalSince1970) : .null, .int(id)])
    }

    public func setTaskText(_ id: Int64, _ text: String) throws {
        try db.run("UPDATE tasks SET text = ? WHERE id = ?", [.text(text), .int(id)])
    }

    public func setAssist(_ id: Int64, _ text: String) throws {
        try db.run("UPDATE tasks SET assist = ? WHERE id = ?", [.text(text), .int(id)])
    }

    public func deleteTask(_ id: Int64) throws {
        try db.run("DELETE FROM tasks WHERE id = ?", [.int(id)])
    }

    private static func json(_ ids: [Int64]) -> String {
        "[" + ids.map(String.init).joined(separator: ",") + "]"
    }
}
