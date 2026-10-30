import FollowupCore
import SwiftUI

private struct NodeAnchors: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The capture in the middle, branches on the left, open questions and tasks
/// on the right, joined by curved connectors.
struct MindMapView: View {
    @EnvironmentObject var model: AppModel
    let capture: Capture
    let tasks: [TaskItem]
    let onAssist: (TaskItem) -> Void

    private var leftBranches: [(Int, Branch)] {
        let all = Array(capture.branches.enumerated())
        return Array(all.prefix((all.count + 1) / 2))
    }

    private var rightBranches: [(Int, Branch)] {
        let all = Array(capture.branches.enumerated())
        return Array(all.dropFirst((all.count + 1) / 2))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 56) {
            VStack(alignment: .trailing, spacing: 22) {
                ForEach(leftBranches, id: \.0) { index, branch in
                    BranchCard(branch: branch).anchorPreference(key: NodeAnchors.self, value: .bounds) { ["L\(index)": $0] }
                }
            }
            centerNode.anchorPreference(key: NodeAnchors.self, value: .bounds) { ["center": $0] }
            VStack(alignment: .leading, spacing: 22) {
                ForEach(rightBranches, id: \.0) { index, branch in
                    BranchCard(branch: branch).anchorPreference(key: NodeAnchors.self, value: .bounds) { ["R\(index)": $0] }
                }
                TasksCard(captureId: capture.id, tasks: tasks, onAssist: onAssist)
                    .anchorPreference(key: NodeAnchors.self, value: .bounds) { ["Rtasks": $0] }
            }
        }
        .padding(.horizontal, 4)
        .backgroundPreferenceValue(NodeAnchors.self) { anchors in
            GeometryReader { proxy in
                if let centerAnchor = anchors["center"] {
                    let center = proxy[centerAnchor]
                    ForEach(anchors.keys.filter { $0 != "center" }.sorted(), id: \.self) { key in
                        let node = proxy[anchors[key]!]
                        Connector(from: key.hasPrefix("L") ? CGPoint(x: center.minX, y: center.midY)
                                                           : CGPoint(x: center.maxX, y: center.midY),
                                  to: key.hasPrefix("L") ? CGPoint(x: node.maxX, y: node.midY)
                                                         : CGPoint(x: node.minX, y: node.midY))
                            .stroke(Color.secondary.opacity(0.35), lineWidth: 2)
                    }
                }
            }
        }
    }

    private var centerNode: some View {
        VStack(spacing: 4) {
            Text(capture.displayTitle)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Label(capture.kind.title, systemImage: capture.kind.symbol)
                .font(.caption)
                .opacity(0.85)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .frame(maxWidth: 220)
        .background(Color(hex: capture.kind.colorHex), in: Capsule())
        .shadow(color: Color(hex: capture.kind.colorHex).opacity(0.35), radius: 10, y: 4)
    }
}

private struct Connector: Shape {
    let from: CGPoint
    let to: CGPoint

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        let midX = (from.x + to.x) / 2
        path.addCurve(to: to, control1: CGPoint(x: midX, y: from.y), control2: CGPoint(x: midX, y: to.y))
        return path
    }
}

private struct BranchCard: View {
    let branch: Branch

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(branch.label.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(1)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(branch.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.tertiary)
                        Text(item).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(.callout)
            .padding(10)
            .frame(width: 240, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
        }
    }
}

/// True while rendering to an image, where AppKit-backed controls draw as placeholders.
private struct SnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var snapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

private struct TasksCard: View {
    @EnvironmentObject var model: AppModel
    let captureId: Int64
    let tasks: [TaskItem]
    let onAssist: (TaskItem) -> Void
    @State private var newTask = ""
    @Environment(\.snapshot) private var snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TASKS")
                .font(.caption2.weight(.bold))
                .tracking(1)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(tasks) { task in
                    TaskRow(task: task, blockers: model.blockers(of: task), onAssist: { onAssist(task) })
                }
                HStack(spacing: 6) {
                    Image(systemName: "plus").foregroundStyle(.tertiary)
                    if snapshot {
                        Text("Add a task").foregroundStyle(.tertiary)
                    } else {
                        TextField("Add a task", text: $newTask)
                            .textFieldStyle(.plain)
                            .onSubmit {
                                model.addTask(to: captureId, text: newTask)
                                newTask = ""
                            }
                    }
                }
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .frame(width: 320, alignment: .leading)
        }
    }
}

private struct TaskRow: View {
    @EnvironmentObject var model: AppModel
    let task: TaskItem
    let blockers: [TaskItem]
    let onAssist: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { model.toggle(task) } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.done ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.text)
                    .strikethrough(task.done)
                    .foregroundStyle(task.done ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !blockers.isEmpty && !task.done {
                    Label("after: " + blockers.map(\.text).joined(separator: ", "), systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                if task.assist != nil && !task.done {
                    Label("Draft ready", systemImage: "doc.text").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if !task.done {
                Button(action: onAssist) {
                    Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain) // .borderless can't be drawn by ImageRenderer
                .help("Help me do this")
            }
        }
        .font(.callout)
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(blockers.isEmpty || task.done ? Color.green.opacity(0.5) : Color.red.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1, dash: blockers.isEmpty || task.done ? [] : [4, 3]))
        )
        .contextMenu {
            Button("Delete task", role: .destructive) { model.deleteTask(task) }
        }
    }
}
