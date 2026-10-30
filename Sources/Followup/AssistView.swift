import AppKit
import FollowupCore
import SwiftUI

/// "Help me do this": the local model drafts the message, plan or steps for
/// one task, streaming as it writes.
struct AssistView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let task: TaskItem

    @State private var output = ""
    @State private var instruction = ""
    @State private var running = false
    @State private var error: String?
    @State private var generation: Task<Void, Never>?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text(task.text).font(.headline)
                Spacer()
            }

            ScrollView {
                Text(output.isEmpty ? (running ? "Thinking…" : "") : output)
                    .textSelection(.enabled)
                    .foregroundStyle(output.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 220)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))

            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }

            HStack {
                TextField("Tweak it: “shorter”, “more formal”, “mention the 900 mm line”…", text: $instruction)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(generate)
                Button(output.isEmpty ? "Generate" : "Regenerate", action: generate)
                    .disabled(running)
            }

            HStack {
                if running {
                    ProgressView().controlSize(.small)
                    Button("Stop") { generation?.cancel() }
                }
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                    copied = true
                }
                .disabled(output.isEmpty)
                Button("Mark done") {
                    model.toggle(task)
                    dismiss()
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear {
            if let saved = task.assist, !saved.isEmpty { output = saved } else { generate() }
        }
        .onDisappear { generation?.cancel() }
    }

    private func generate() {
        guard !running, let stream = model.assistStream(for: task, instruction: instruction) else { return }
        running = true
        error = nil
        copied = false
        output = ""
        generation = Task {
            var raw = ""
            do {
                for try await chunk in stream {
                    raw += chunk
                    output = ThinkFilter.visible(raw)
                }
                if !output.isEmpty { model.saveAssist(task, output) }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            running = false
        }
    }
}
