import FollowupCore
import SwiftUI

enum SidebarItem: Hashable {
    case all
    case openTasks
    case kind(CaptureKind)
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var sidebar: SidebarItem? = .all
    @State private var selected: Int64?

    var body: some View {
        NavigationSplitView {
            List(selection: $sidebar) {
                Section {
                    Label("All captures", systemImage: "tray.full")
                        .badge(model.captures.count)
                        .tag(SidebarItem.all)
                    Label("Open tasks", systemImage: "checklist")
                        .badge(model.openTaskCount)
                        .tag(SidebarItem.openTasks)
                }
                Section("Types") {
                    ForEach(CaptureKind.allCases) { kind in
                        Label {
                            Text(kind.title)
                        } icon: {
                            Image(systemName: kind.symbol).foregroundStyle(Color(hex: kind.colorHex))
                        }
                        .badge(model.captures.filter { $0.kind == kind }.count)
                        .tag(SidebarItem.kind(kind))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } content: {
            Group {
                if sidebar == .openTasks {
                    OpenTasksList(selected: $selected)
                } else {
                    CaptureList(captures: filtered, selected: $selected)
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            if let id = selected, let capture = model.capture(id: id) {
                CaptureDetail(capture: capture)
                    .id(capture.id)
            } else {
                EmptyDetail()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { NotificationCenter.default.post(name: .openSettings, object: nil) } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
            }
        }
        .overlay(alignment: .bottom) {
            if let error = model.loadError {
                Text(error)
                    .font(.callout)
                    .padding(10)
                    .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.white)
                    .padding()
                    .onTapGesture { model.loadError = nil }
            }
        }
    }

    private var filtered: [Capture] {
        switch sidebar {
        case .kind(let kind): model.captures.filter { $0.kind == kind }
        default: model.captures
        }
    }
}

private struct EmptyDetail: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.cursor").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Select text anywhere and press ⌃F").font(.title3.weight(.medium))
            Text("Pick a slice on the wheel and your local model maps it out here.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Lists

struct CaptureList: View {
    @EnvironmentObject var model: AppModel
    let captures: [Capture]
    @Binding var selected: Int64?

    var body: some View {
        List(captures, selection: $selected) { capture in
            CaptureRow(capture: capture, openTasks: model.tasks(for: capture.id).filter { !$0.done }.count)
                .tag(capture.id)
                .contextMenu {
                    Button("Re-analyze") { model.analyze(capture.id) }
                    Button("Delete", role: .destructive) { model.delete(capture.id) }
                }
        }
        .overlay {
            if captures.isEmpty {
                Text("Nothing captured yet").foregroundStyle(.secondary)
            }
        }
    }
}

private struct CaptureRow: View {
    let capture: Capture
    let openTasks: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: capture.kind.symbol)
                .foregroundStyle(Color(hex: capture.kind.colorHex))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(capture.displayTitle).font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(capture.sourceApp)
                    Text("·")
                    Text(capture.createdAt, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            switch capture.status {
            case .processing, .pending: ProgressView().controlSize(.small)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .ready:
                if openTasks > 0 {
                    Text("\(openTasks)").font(.caption.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
        .padding(.vertical, 3)
    }
}

struct OpenTasksList: View {
    @EnvironmentObject var model: AppModel
    @Binding var selected: Int64?

    var body: some View {
        let groups = model.captures.compactMap { capture -> (Capture, [TaskItem])? in
            let open = model.tasks(for: capture.id).filter { !$0.done }
            return open.isEmpty ? nil : (capture, open)
        }
        List(selection: $selected) {
            ForEach(groups, id: \.0.id) { capture, tasks in
                Section {
                    ForEach(tasks) { task in
                        HStack {
                            Button { model.toggle(task) } label: { Image(systemName: "circle") }
                                .buttonStyle(.plain)
                            Text(task.text)
                            if !model.blockers(of: task).isEmpty {
                                Image(systemName: "hourglass").foregroundStyle(.red).help("Waiting on another task")
                            }
                        }
                        .tag(capture.id)
                    }
                } header: {
                    Label(capture.displayTitle, systemImage: capture.kind.symbol)
                }
            }
        }
        .overlay {
            if groups.isEmpty { Text("No open tasks 🎉").foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Detail

struct CaptureDetail: View {
    @EnvironmentObject var model: AppModel
    let capture: Capture
    @State private var assistTask: TaskItem?
    @State private var showSource = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                status
                if !capture.summary.isEmpty {
                    Text(capture.summary).font(.body).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    MindMapView(capture: capture, tasks: model.tasks(for: capture.id)) { assistTask = $0 }
                        .padding(.vertical, 8)
                }
                DisclosureGroup("Captured text", isExpanded: $showSource) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(capture.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        if let url = capture.url, let link = URL(string: url) {
                            Link(url, destination: link).font(.caption)
                        }
                    }
                    .padding(.top, 6)
                }
            }
            .padding(24)
        }
        .sheet(item: $assistTask) { task in
            AssistView(task: task).environmentObject(model)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Menu {
                    ForEach(CaptureKind.allCases) { kind in
                        Button { model.setKind(capture.id, kind) } label: { Label(kind.title, systemImage: kind.symbol) }
                    }
                } label: {
                    Label(capture.kind.title, systemImage: capture.kind.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color(hex: capture.kind.colorHex), in: Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
                .help("Change type (re-runs the model)")

                Text(capture.displayTitle).font(.title2.weight(.semibold)).textSelection(.enabled)
                HStack(spacing: 6) {
                    Text(capture.sourceApp)
                    if !capture.windowTitle.isEmpty { Text("· \(capture.windowTitle)").lineLimit(1) }
                    Text("·")
                    Text(capture.createdAt, format: .dateTime.day().month().hour().minute())
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.analyze(capture.id) } label: { Label("Re-analyze", systemImage: "arrow.clockwise") }
                .disabled(capture.status == .processing)
            Button(role: .destructive) { model.delete(capture.id) } label: { Image(systemName: "trash") }
                .help("Delete capture")
        }
    }

    @ViewBuilder
    private var status: some View {
        switch capture.status {
        case .pending, .processing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Your local model is mapping this out…").foregroundStyle(.secondary)
            }
        case .failed:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(capture.error ?? "Something went wrong.").textSelection(.enabled)
                Spacer()
                Button("Retry") { model.analyze(capture.id) }
                Button("Model settings…") { NotificationCenter.default.post(name: .openSettings, object: nil) }
            }
            .padding(10)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        case .ready:
            EmptyView()
        }
    }
}
