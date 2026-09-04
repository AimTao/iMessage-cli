import Foundation
import AppKit

enum Sender {
    /// 通过 AppleScript 调用 Messages.app 发送消息
    static func send(to handle: String, text: String) throws {
        // 检查 Messages 是否在运行
        guard isMessagesRunning() else {
            throw IMSGError.messagesNotRunning
        }

        let escapedText = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Messages"
            set targetService to 1st account whose service type = iMessage
            set targetBuddy to buddy "\(handle)" of targetService
            send "\(escapedText)" to targetBuddy
        end tell
        """

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            throw IMSGError.sendFailed("无法创建 AppleScript")
        }
        appleScript.executeAndReturnError(&error)

        if let error = error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? "未知错误"
            throw IMSGError.sendFailed(msg)
        }
    }

    private static func isMessagesRunning() -> Bool {
        let script = """
        tell application "System Events"
            return (name of processes) contains "Messages"
        end tell
        """
        var error: NSDictionary?
        guard let scriptObj = NSAppleScript(source: script) else { return false }
        let result = scriptObj.executeAndReturnError(&error)
        return result.booleanValue
    }

    /// 尝试拉起 Messages.app
    static func launchMessagesIfNeeded() {
        let url = URL(fileURLWithPath: "/System/Applications/Messages.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        // 等一下让它启动
        Thread.sleep(forTimeInterval: 1.5)
    }
}
