import AppKit
import FollowupCore
import SwiftUI

private let wheelSize: CGFloat = 300
private let outerRadius: CGFloat = 125
private let innerRadius: CGFloat = 44
private let kinds = CaptureKind.allCases

final class WheelState: ObservableObject {
    @Published var hovered: Int?
    @Published var picked: CaptureKind?
    @Published var appeared = false
    let selection: CapturedSelection

    init(selection: CapturedSelection) {
        self.selection = selection
    }
}

/// A borderless panel that can take keystrokes (1–6, Return, Esc) without
/// activating the app, so the window you captured from keeps focus.
private final class WheelPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

/// Tracks the pointer even though our app isn't active, and reports clicks.
private final class TrackingView: NSView {
    var onMove: ((CGPoint) -> Void)?
    var onClick: ((CGPoint) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    private func centered(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x - bounds.midX, y: bounds.midY - p.y) // y-down, from center
    }

    override func mouseMoved(with event: NSEvent) { onMove?(centered(event)) }
    override func mouseDragged(with event: NSEvent) { onMove?(centered(event)) }
    override func mouseDown(with event: NSEvent) { onClick?(centered(event)) }
}

@MainActor
final class WheelController {
    private var panel: WheelPanel?
    private var state: WheelState?
    private var clickMonitor: Any?
    private var onPick: ((CaptureKind, CapturedSelection) -> Void)?

    func show(selection: CapturedSelection, at point: NSPoint, onPick: @escaping (CaptureKind, CapturedSelection) -> Void) {
        dismiss(animated: false)
        self.onPick = onPick

        let state = WheelState(selection: selection)
        self.state = state

        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        var origin = NSPoint(x: point.x - wheelSize / 2, y: point.y - wheelSize / 2)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - wheelSize)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - wheelSize)
        }

        let panel = WheelPanel(contentRect: NSRect(origin: origin, size: CGSize(width: wheelSize, height: wheelSize)),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.onKey = { [weak self] in self?.handleKey($0) ?? false }

        let container = NSView(frame: NSRect(x: 0, y: 0, width: wheelSize, height: wheelSize))
        let hosting = NSHostingView(rootView: WheelView(state: state))
        hosting.frame = container.bounds
        let tracker = TrackingView(frame: container.bounds)
        tracker.onMove = { [weak self] p in self?.hover(p) }
        tracker.onClick = { [weak self] p in
            self?.hover(p)
            if let index = self?.state?.hovered { self?.pick(kinds[index]) } else { self?.dismiss() }
        }
        container.addSubview(hosting)
        container.addSubview(tracker)
        panel.contentView = container

        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        withAnimation(.spring(response: 0.22, dampingFraction: 0.75)) { state.appeared = true }

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
    }

    private func hover(_ p: CGPoint) {
        guard let state, state.picked == nil else { return }
        let index = RadialGeometry.slice(dx: p.x, dy: p.y, count: kinds.count, innerRadius: innerRadius)
        if state.hovered != index { state.hovered = index }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: // Esc
            dismiss()
            return true
        case 36, 76: // Return, Enter
            if let index = state?.hovered { pick(kinds[index]) }
            return true
        default:
            if let char = event.charactersIgnoringModifiers?.first,
               let kind = kinds.first(where: { $0.shortcut == char }) {
                pick(kind)
                return true
            }
            return false
        }
    }

    private func pick(_ kind: CaptureKind) {
        guard let state, state.picked == nil else { return }
        state.hovered = kinds.firstIndex(of: kind)
        withAnimation(.easeOut(duration: 0.15)) { state.picked = kind }
        onPick?(kind, state.selection)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in self?.dismiss() }
    }

    func dismiss(animated: Bool = true) {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guard let panel else { return }
        self.panel = nil
        state = nil
        if animated {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 },
                                                 completionHandler: { panel.orderOut(nil) })
        } else {
            panel.orderOut(nil)
        }
    }
}

// MARK: - Drawing

private struct SliceShape: Shape {
    var startDegrees: Double
    var endDegrees: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.addArc(center: center, radius: outerRadius, startAngle: .degrees(startDegrees),
                    endAngle: .degrees(endDegrees), clockwise: false)
        path.addArc(center: center, radius: innerRadius, startAngle: .degrees(endDegrees),
                    endAngle: .degrees(startDegrees), clockwise: true)
        path.closeSubpath()
        return path
    }
}

struct WheelView: View {
    @ObservedObject var state: WheelState

    var body: some View {
        ZStack {
            ForEach(Array(kinds.enumerated()), id: \.offset) { index, kind in
                slice(index: index, kind: kind)
            }
            center
        }
        .frame(width: wheelSize, height: wheelSize)
        .scaleEffect(state.appeared ? 1 : 0.6)
        .opacity(state.appeared ? 1 : 0)
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }

    private func slice(index: Int, kind: CaptureKind) -> some View {
        let bounds = RadialGeometry.bounds(index: index, count: kinds.count)
        let isHot = state.hovered == index
        let isDimmed = state.picked != nil && state.picked != kind
        let angle = RadialGeometry.midAngle(index: index, count: kinds.count)
        let labelRadius = (outerRadius + innerRadius) / 2
        return ZStack {
            SliceShape(startDegrees: bounds.start, endDegrees: bounds.end)
                .fill(Color(hex: kind.colorHex).opacity(isHot ? 1 : 0.8))
                .overlay(SliceShape(startDegrees: bounds.start, endDegrees: bounds.end)
                    .stroke(.white, lineWidth: isHot ? 3 : 0))
            VStack(spacing: 3) {
                Image(systemName: kind.symbol).font(.system(size: 17, weight: .semibold))
                Text(kind.title).font(.system(size: 11, weight: .semibold))
                Text(String(kind.shortcut)).font(.system(size: 9, weight: .medium)).opacity(0.6)
            }
            .foregroundStyle(.white)
            .offset(x: cos(angle) * labelRadius, y: sin(angle) * labelRadius)
        }
        .scaleEffect(isHot ? 1.05 : 1)
        .opacity(isDimmed ? 0.25 : 1)
        .animation(.easeOut(duration: 0.1), value: isHot)
    }

    private var center: some View {
        ZStack {
            Circle().fill(Color(white: 0.08)).overlay(Circle().stroke(Color(white: 0.3)))
            if let picked = state.picked {
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color(hex: picked.colorHex))
                    .transition(.scale)
            } else {
                VStack(spacing: 2) {
                    Text("\(state.selection.text.count) chars").font(.system(size: 10, weight: .medium))
                    Text(state.selection.appName).font(.system(size: 9)).lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(Color(white: 0.75))
                .padding(.horizontal, 6)
            }
        }
        .frame(width: innerRadius * 2 - 6, height: innerRadius * 2 - 6)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
