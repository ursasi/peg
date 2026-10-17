import AppKit
import CoreGraphics

enum Permissions {
    static var hasScreenRecording: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks once. On the very first call macOS shows the system prompt and
    /// returns false; the app has to be relaunched after granting.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Called the moment the user asks for a screenshot but the permission is
    /// missing, so nothing prompts until the app is actually needed.
    static func ensure() -> Bool {
        if hasScreenRecording { return true }
        let granted = requestScreenRecording()
        if !granted {
            let alert = NSAlert()
            alert.messageText = "Peg 需要「屏幕录制」权限"
            alert.informativeText = """
            在「系统设置 → 隐私与安全性 → 屏幕录制」里勾选 Peg，然后重新打开 Peg。

            授权后必须重启一次，系统才会把画面交给它。
            """
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "稍后")
            alert.addButton(withTitle: "重启 Peg")
            NSApp.activate(ignoringOtherApps: true)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                openScreenRecordingSettings()
            case .alertThirdButtonReturn:
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                task.arguments = ["-n", Bundle.main.bundleURL.path]
                try? task.run()
                NSApp.terminate(nil)
            default:
                break
            }
        }
        return hasScreenRecording
    }
}
