import AppKit
import ApplicationServices
import os

let captureLog = Logger(subsystem: "com.harshsharma.followup", category: "capture")

struct CapturedSelection {
    var text: String
    var appName: String
    var windowTitle: String
    var url: String?
}

/// Reads the selected text in whatever app is in front, the same way Goldfish
/// does: through the Accessibility API first, then a simulated ⌘C for apps
/// that don't expose their selection (many Chromium and Electron apps).
enum SelectionCapture {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    @MainActor
    static func capture() async -> CapturedSelection? {
        let front = NSWorkspace.shared.frontmostApplication
        var text = ""
        var windowTitle = ""
        var url: String?
        captureLog.info("capture: front=\(front?.bundleIdentifier ?? "nil", privacy: .public) trusted=\(AXIsProcessTrusted(), privacy: .public)")

        if let pid = front?.processIdentifier {
            let app = AXUIElementCreateApplication(pid)
            // Electron apps only build their accessibility tree when asked to.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)

            if let window = element(app, kAXFocusedWindowAttribute) {
                windowTitle = string(window, kAXTitleAttribute) ?? ""
                url = string(window, kAXDocumentAttribute)
            }
            let focused = element(app, kAXFocusedUIElementAttribute)
            if let focused {
                text = string(focused, kAXSelectedTextAttribute) ?? ""
                if url == nil { url = findURL(startingAt: focused) }
            }
            captureLog.info("capture: focusedElement=\(focused != nil, privacy: .public) axSelectedLength=\(text.count, privacy: .public)")
        }

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = await copyViaPasteboard() ?? ""
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return CapturedSelection(text: text, appName: front?.localizedName ?? "Unknown app",
                                 windowTitle: windowTitle, url: url)
    }

    // MARK: Accessibility helpers

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let v = value(element, attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        switch value(element, attribute) {
        case let s as String: s
        case let u as URL: u.absoluteString
        default: nil
        }
    }

    /// Browsers expose the page URL on the web area that contains the selection.
    private static func findURL(startingAt start: AXUIElement) -> String? {
        var current: AXUIElement? = start
        for _ in 0..<30 {
            guard let el = current else { return nil }
            if let url = string(el, "AXURL"), url.hasPrefix("http") { return url }
            current = element(el, kAXParentAttribute)
        }
        return nil
    }

    // MARK: ⌘C fallback

    @MainActor
    private static func copyViaPasteboard() async -> String? {
        let pasteboard = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pasteboard.pasteboardItems ?? []).map { item in
            var data: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { data[type] = item.data(forType: type) }
            return data
        }
        let before = pasteboard.changeCount

        postCommandC()
        captureLog.info("capture: posted cmd-C, changeCount before=\(before, privacy: .public)")
        var result: String?
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 25_000_000)
            if pasteboard.changeCount != before {
                result = pasteboard.string(forType: .string)
                break
            }
        }

        captureLog.info("capture: pasteboard changed=\(pasteboard.changeCount != before, privacy: .public) copiedLength=\(result?.count ?? -1, privacy: .public)")
        // Put the clipboard back the way it was.
        if pasteboard.changeCount != before {
            pasteboard.clearContents()
            let items = saved.map { data -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, value) in data { item.setData(value, forType: type) }
                return item
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
        return result
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .privateState)
        let keyC: CGKeyCode = 8
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyC, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
