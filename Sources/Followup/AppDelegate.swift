import AppKit
import Carbon
import SwiftUI

extension Notification.Name {
    static let openSettings = Notification.Name("FollowupOpenSettings")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel()
    private let wheel = WheelController()
    private var statusItem: NSStatusItem!
    private var hotKey: HotKey?
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        hotKey = HotKey(keyCode: kVK_ANSI_F, modifiers: controlKey) { [weak self] in
            Task { @MainActor in await self?.captureSelection() }
        }
        NotificationCenter.default.addObserver(forName: .openSettings, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.openSettings() }
        }
        model.seedLaunchAtLogin()
        if !SelectionCapture.isTrusted {
            SelectionCapture.requestAccess()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMain()
        return true
    }

    // MARK: Capture

    private func captureSelection() async {
        guard SelectionCapture.isTrusted else {
            SelectionCapture.requestAccess()
            return
        }
        let mouse = NSEvent.mouseLocation
        guard let selection = await SelectionCapture.capture() else {
            NSSound.beep()
            return
        }
        wheel.show(selection: selection, at: mouse) { [weak self] kind, selection in
            self?.model.add(kind: kind, selection: selection)
        }
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Keeps the spot you ⌘-drag the icon to, across relaunches and reinstalls.
        statusItem.autosaveName = "FollowupStatusItem"
        statusItem.button?.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Followup")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let open = model.openTaskCount
        let header = NSMenuItem(title: open == 0 ? "No open tasks" : "\(open) open task\(open == 1 ? "" : "s")",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(item("Open Followup", #selector(openMainAction), key: "o"))
        menu.addItem(item("Capture selection   ⌃F", #selector(captureAction)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettingsAction), key: ","))
        let login = item("Open at Login", #selector(toggleLoginAction))
        login.state = model.launchesAtLogin ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Quit Followup", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target ?? self
        return item
    }

    @objc private func openMainAction() { openMain() }
    @objc private func openSettingsAction() { openSettings() }
    @objc private func toggleLoginAction() { model.setLaunchAtLogin(!model.launchesAtLogin) }
    @objc private func captureAction() {
        // From the menu, give focus back to the previous app before reading its selection.
        NSApp.hide(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Task { await self.captureSelection() } }
    }

    // MARK: Windows

    private func openMain() {
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Followup"
            window.contentViewController = NSHostingController(rootView: MainView().environmentObject(model))
            window.setFrameAutosaveName("FollowupMain")
            window.isReleasedWhenClosed = false
            if !window.setFrameUsingName("FollowupMain") { window.center() }
            mainWindow = window
        }
        model.reload()
        show(mainWindow!)
    }

    private func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Followup Settings"
            window.contentViewController = NSHostingController(rootView: SettingsView().environmentObject(model))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        show(settingsWindow!)
    }

    private func show(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
