import Foundation

/// The slices of the capture wheel, in clockwise order starting at the top.
public enum CaptureKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case followUp = "followup"
    case research
    case todo
    case idea
    case reference
    case waiting

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .followUp: "Follow-up"
        case .research: "Research"
        case .todo: "To-do"
        case .idea: "Idea"
        case .reference: "Reference"
        case .waiting: "Waiting on"
        }
    }

    public var symbol: String {
        switch self {
        case .followUp: "arrowshape.turn.up.left.fill"
        case .research: "magnifyingglass"
        case .todo: "checkmark.circle.fill"
        case .idea: "lightbulb.fill"
        case .reference: "pin.fill"
        case .waiting: "hourglass"
        }
    }

    public var colorHex: UInt32 {
        switch self {
        case .followUp: 0xF59E0B
        case .research: 0x3B82F6
        case .todo: 0x10B981
        case .idea: 0xA855F7
        case .reference: 0x64748B
        case .waiting: 0xEF4444
        }
    }

    /// Number key (1–6) that picks this slice on the wheel.
    public var shortcut: Character {
        Character(String(CaptureKind.allCases.firstIndex(of: self)! + 1))
    }
}

public enum CaptureStatus: String, Codable, Sendable {
    case pending, processing, ready, failed
}

public struct Branch: Codable, Equatable, Sendable {
    public var label: String
    public var items: [String]

    public init(label: String, items: [String]) {
        self.label = label
        self.items = items
    }
}

public struct Capture: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var kind: CaptureKind
    public var text: String
    public var sourceApp: String
    public var windowTitle: String
    public var url: String?
    public var createdAt: Date
    public var title: String
    public var summary: String
    public var branches: [Branch]
    public var status: CaptureStatus
    public var error: String?

    /// Title to show before (or if) the model names the capture.
    public var displayTitle: String {
        if !title.isEmpty { return title }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
    }
}

public struct TaskItem: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var captureId: Int64
    public var position: Int
    public var text: String
    public var done: Bool
    /// IDs of tasks that must be finished before this one.
    public var blockedBy: [Int64]
    /// Last thing the model produced to help with this task (draft, plan…).
    public var assist: String?
    /// "ai" when proposed by the model, "user" when added by hand.
    public var source: String
    public var createdAt: Date
    public var completedAt: Date?
}
