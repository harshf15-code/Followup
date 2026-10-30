import AppKit
import FollowupCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var models: [String] = []
    @State private var testResult: String?
    @State private var testing = false
    @State private var trusted = SelectionCapture.isTrusted

    private let presets: [(String, String)] = [
        ("Ollama", "http://localhost:11434/v1"),
        ("LM Studio", "http://localhost:1234/v1"),
        ("llama.cpp", "http://localhost:8080/v1"),
    ]

    var body: some View {
        Form {
            Section("AI") {
                Picker("Answer with", selection: $model.settings.provider) {
                    Text("Claude (your Claude Code login)").tag(LLMProvider.claudeCode)
                    Text("Local / OpenAI-compatible server").tag(LLMProvider.openAICompatible)
                }
                if model.settings.provider == .claudeCode {
                    Picker("Claude model", selection: $model.settings.claudeModel) {
                        Text("Haiku (fastest)").tag("haiku")
                        Text("Sonnet (balanced)").tag("sonnet")
                        Text("Opus (best)").tag("opus")
                    }
                    if ClaudeCodeClient.locate() == nil {
                        Label("Claude Code isn't installed or isn't on a standard path.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Captured text is sent to Claude under your account; nothing else from your Mac is.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    HStack {
                        TextField("Server URL", text: $model.settings.baseURL)
                        Menu("Presets") {
                            ForEach(presets, id: \.0) { name, url in
                                Button(name) {
                                    model.settings.baseURL = url
                                    refreshModels()
                                }
                            }
                        }
                        .fixedSize()
                    }
                    HStack {
                        Picker("Model", selection: $model.settings.model) {
                            Text("First available").tag("")
                            ForEach(modelChoices, id: \.self) { Text($0).tag($0) }
                        }
                        Button { refreshModels() } label: { Image(systemName: "arrow.clockwise") }
                            .help("Reload the server's model list")
                    }
                    SecureField("API key (only for cloud servers)", text: $model.settings.apiKey)
                }
                HStack {
                    Button("Test connection", action: test).disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let testResult {
                        Text(testResult).font(.callout).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                    }
                }
            }

            Section("Capture") {
                LabeledContent("Shortcut", value: "⌃F  (select text, then press)")
                LabeledContent("Accessibility access") {
                    if trusted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant…") {
                            SelectionCapture.requestAccess()
                            NSWorkspace.shared.open(URL(string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }
                Toggle("Open at login", isOn: Binding(get: { model.launchesAtLogin },
                                                      set: { model.setLaunchAtLogin($0) }))
            }

            Section("Data") {
                LabeledContent("Database") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Store.defaultPath)])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onAppear(perform: refreshModels)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            trusted = SelectionCapture.isTrusted
        }
    }

    private var modelChoices: [String] {
        var list = models
        if !model.settings.model.isEmpty && !list.contains(model.settings.model) { list.insert(model.settings.model, at: 0) }
        return list
    }

    private func refreshModels() {
        guard model.settings.provider == .openAICompatible else { return }
        let client = model.client
        Task {
            models = (try? await client.models()) ?? []
        }
    }

    private func test() {
        testing = true
        testResult = nil
        let backend = model.backend
        let label = model.settings.modelLabel
        Task {
            do {
                let started = Date()
                let reply = try await backend.complete([.user("Reply with just the word: ready")], temperature: 0)
                testResult = "✓ \(label) answered “\(ThinkFilter.visible(reply).prefix(40))” in "
                    + String(format: "%.1fs", Date().timeIntervalSince(started))
            } catch {
                testResult = error.localizedDescription
            }
            testing = false
        }
    }
}
