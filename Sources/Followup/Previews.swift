import AppKit
import FollowupCore
import SwiftUI

/// `Followup --render-previews <dir>` writes PNGs of the wheel and a sample
/// mind map, using a throwaway database. Handy for checking visuals.
@MainActor
enum Previews {
    static func render(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("followup-preview-\(UUID().uuidString).db").path
        let store = try Store(path: dbPath)
        let text = """
        Northwind Coffee just got a lot bigger. Maya replied this morning: they roast about 40 tonnes a year \
        and want pricing for 2,000 compostable bags a month with their logo printed. She's also asking for a sample.
        """
        let id = try store.insertCapture(kind: .followUp, text: text, sourceApp: "Mail", windowTitle: "Northwind",
                                         url: nil)
        try store.applyAnalysis(Analysis(
            title: "Northwind Coffee bag order",
            summary: "Maya at Northwind wants pricing for 2,000 printed compostable bags a month, plus a sample.",
            branches: [
                Branch(label: "People", items: ["Maya · Northwind buyer", "Leo · print setup"]),
                Branch(label: "Facts", items: ["~40 t roasted / year", "2,000 bags / month",
                                               "Logo print needed", "≈24k bags / year (estimate)"]),
                Branch(label: "Open questions", items: ["Target price", "Bag size", "Start date?"]),
            ],
            tasks: [ProposedTask(text: "Ask Leo for print setup cost and lead time"),
                    ProposedTask(text: "Send Maya a sample bag"),
                    ProposedTask(text: "Reply to Maya with pricing and questions", dependsOn: [0])]
        ), to: id)

        let model = AppModel(storePath: dbPath)
        guard let capture = model.capture(id: id) else { return }

        let wheelState = WheelState(selection: CapturedSelection(text: text, appName: "Mail", windowTitle: "", url: nil))
        wheelState.appeared = true
        wheelState.hovered = 0
        try save(WheelView(state: wheelState).padding(30).background(Color(white: 0.12)),
                 to: dir.appendingPathComponent("wheel.png"))

        let map = MindMapView(capture: capture, tasks: model.tasks(for: id)) { _ in }
            .environmentObject(model)
            .padding(30)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        try save(map, to: dir.appendingPathComponent("mindmap.png"))
    }

    static func save(_ view: some View, to url: URL) throws {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark).environment(\.snapshot, true))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}

/// `Followup --try <text-file> [kind] [out-dir]` runs a capture through the
/// real pipeline with the configured model, prints the mind map, renders it,
/// and drafts help for the first task that's waiting on another one.
@MainActor
enum TryRun {
    static func run(file: String, kind: CaptureKind, outDir: URL) async throws {
        let text = try String(contentsOfFile: file, encoding: .utf8)
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("followup-try-\(UUID().uuidString).db").path
        let store = try Store(path: dbPath)
        // Create the model before inserting, so it doesn't start its own analysis.
        let model = AppModel(storePath: dbPath)
        let id = try store.insertCapture(kind: kind, text: text, sourceApp: "Grok", windowTitle: "", url: nil)
        print("Model: \(model.settings.modelLabel)\n")

        var started = Date()
        let messages = Prompts.analyze(kind: kind, text: text, sourceApp: "Grok", windowTitle: "", url: nil)
        let raw = try await model.backend.complete(messages)
        let analysis = try Analysis.parse(raw)
        try store.applyAnalysis(analysis, to: id)
        model.reload()
        print(String(format: "== Mind map (%.1fs)", Date().timeIntervalSince(started)))
        print("Title: \(analysis.title)\nSummary: \(analysis.summary)")
        for branch in analysis.branches {
            print("\n[\(branch.label)]")
            branch.items.forEach { print("  • \($0)") }
        }
        let tasks = model.tasks(for: id)
        print("\n[Tasks]")
        for task in tasks {
            let after = model.blockers(of: task).map(\.text)
            print("  ☐ \(task.text)" + (after.isEmpty ? "" : "   ⏳ after: \(after.joined(separator: ", "))"))
        }

        if let capture = model.capture(id: id) {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let map = MindMapView(capture: capture, tasks: tasks) { _ in }
                .environmentObject(model)
                .padding(30)
                .background(Color(nsColor: .windowBackgroundColor))
            try Previews.save(map, to: outDir.appendingPathComponent("try-mindmap.png"))
        }

        guard let target = tasks.first(where: { !$0.blockedBy.isEmpty }) ?? tasks.last,
              let stream = model.assistStream(for: target, instruction: nil) else { return }
        started = Date()
        print("\n== ✨ Help with: \(target.text)\n")
        var draft = ""
        for try await chunk in stream { draft += chunk }
        print(ThinkFilter.visible(draft))
        print(String(format: "\n(%.1fs)", Date().timeIntervalSince(started)))
    }
}
