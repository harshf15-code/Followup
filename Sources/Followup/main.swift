import AppKit
import FollowupCore

MainActor.assumeIsolated {
    let arguments = CommandLine.arguments
    if let flag = arguments.firstIndex(of: "--render-previews"), arguments.count > flag + 1 {
        do {
            try Previews.render(to: URL(fileURLWithPath: arguments[flag + 1]))
            exit(0)
        } catch {
            print("Preview render failed: \(error)")
            exit(1)
        }
    }

    if let flag = arguments.firstIndex(of: "--try"), arguments.count > flag + 1 {
        let kind = arguments.count > flag + 2 ? CaptureKind(rawValue: arguments[flag + 2]) ?? .followUp : .followUp
        let out = URL(fileURLWithPath: arguments.count > flag + 3 ? arguments[flag + 3] : NSTemporaryDirectory())
        Task {
            do {
                try await TryRun.run(file: arguments[flag + 1], kind: kind, outDir: out)
                exit(0)
            } catch {
                print("Failed: \(error.localizedDescription)")
                exit(1)
            }
        }
        RunLoop.main.run()
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
    app.run()
}
