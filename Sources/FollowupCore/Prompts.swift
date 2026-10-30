import Foundation

public enum Prompts {
    static func guidance(for kind: CaptureKind) -> String {
        switch kind {
        case .followUp:
            """
            This is a FOLLOW-UP: something the user owes someone or must chase.
            Branches: "People" (each person and their role), "Facts" (numbers, prices, quantities, dates), \
            "Open questions" (things still unknown or unconfirmed).
            Tasks: concrete next actions, naming who each one involves (e.g. "Ask Leo for the print cost").
            """
        case .research:
            """
            This is something to RESEARCH later.
            Branches: "Key questions", "What we already know", "Where to look" (sources, people, searches).
            Tasks: concrete research steps, smallest first.
            """
        case .todo:
            """
            This is a TO-DO.
            Branches: "Context" (why it matters, constraints), "Details" (anything needed to do it).
            Tasks: the steps to finish it.
            """
        case .idea:
            """
            This is an IDEA to develop.
            Branches: "Why it matters", "Open questions", "Risks".
            Tasks: cheap first experiments or checks.
            """
        case .reference:
            """
            This is REFERENCE material to keep.
            Branches: "Key points", plus any natural grouping such as "Numbers" or "Names".
            Tasks: only if the text clearly implies something to do; otherwise an empty list.
            """
        case .waiting:
            """
            The user is WAITING ON someone else.
            Branches: "Waiting on" (who and what), "Facts", "If it doesn't arrive" (fallbacks).
            Tasks: when and how to check in or chase.
            """
        }
    }

    public static func analyze(kind: CaptureKind, text: String, sourceApp: String, windowTitle: String,
                               url: String?, now: Date = Date()) -> [ChatMessage] {
        let system = """
        You turn a snippet the user captured from their screen into a small mind map and a list of next actions.

        \(guidance(for: kind))

        Rules:
        - Use only what the text says. Do not invent names, numbers or dates. If you estimate something, say "estimate".
        - Keep the user's own terms (product names, people, places).
        - Items are short phrases, not sentences. 2–6 items per branch.
        - 0–7 tasks. Each task starts with a verb. "depends_on" lists the 0-based indexes of EARLIER tasks \
        in your list that must be done first (e.g. a reply that needs an answer from someone else).

        Respond with ONLY a JSON object, no prose, in exactly this shape:
        {"title": "≤6 words", "summary": "one sentence", \
        "branches": [{"label": "People", "items": ["…"]}], \
        "tasks": [{"text": "…", "depends_on": []}]}
        """
        var context = "Captured from: \(sourceApp)"
        if !windowTitle.isEmpty { context += " — \(windowTitle)" }
        if let url, !url.isEmpty { context += "\nURL: \(url)" }
        context += "\nCaptured at: \(ISO8601DateFormatter().string(from: now))"
        return [.system(system), .user("\(context)\n\n---\n\(text)\n---")]
    }

    public static func assist(capture: Capture, tasks: [TaskItem], task: TaskItem, instruction: String?) -> [ChatMessage] {
        let system = """
        You help the user get one task done, using the context they captured.
        Produce the single most useful thing for this task:
        - If it means messaging or emailing someone, write the message ready to send (no subject line unless it's an email). \
        Match a direct, friendly business tone.
        - If it's research, give a short plan: what to look up, where, and what you already know (flag anything uncertain).
        - Otherwise, give short numbered steps.
        Use only facts from the context. Put anything you'd need to confirm in [brackets]. Be concise. No preamble.
        """
        var lines: [String] = []
        lines.append("Capture (\(capture.kind.title)): \(capture.displayTitle)")
        if !capture.summary.isEmpty { lines.append("Summary: \(capture.summary)") }
        for branch in capture.branches {
            lines.append("\(branch.label): " + branch.items.joined(separator: "; "))
        }
        let others = tasks.filter { $0.id != task.id }
        if !others.isEmpty {
            lines.append("Other tasks: " + others.map { ($0.done ? "[done] " : "") + $0.text }.joined(separator: "; "))
        }
        lines.append("\nOriginal text:\n---\n\(capture.text)\n---")
        lines.append("\nTASK: \(task.text)")
        if let instruction, !instruction.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("Extra instruction: \(instruction)")
        }
        return [.system(system), .user(lines.joined(separator: "\n"))]
    }
}
