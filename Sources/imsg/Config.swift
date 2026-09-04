import Foundation

// MARK: - Config

enum IMSGError: Error, CustomStringConvertible {
    case databaseNotAccessible(String)
    case messagesNotRunning
    case contactNotFound(String)
    case notInAllowlist(String)
    case allowlistEmpty
    case sendFailed(String)
    case unsupportedSchema(String)

    var description: String {
        switch self {
        case .databaseNotAccessible(let path):
            return "无法访问消息数据库: \(path)\n请确保终端有完全磁盘访问权限（系统设置 → 隐私与安全性 → 完全磁盘访问权限）"
        case .messagesNotRunning:
            return "Messages.app 未运行。请先打开 Messages.app"
        case .contactNotFound(let id):
            return "找不到联系人: \(id)"
        case .notInAllowlist(let id):
            return "不在白名单中: \(id)\n请在白名单文件中添加此联系人"
        case .allowlistEmpty:
            return "白名单为空。请编辑白名单文件添加至少一个联系人"
        case .sendFailed(let reason):
            return "发送失败: \(reason)"
        case .unsupportedSchema(let detail):
            return "数据库结构不支持: \(detail)\n当前 macOS 版本可能未适配"
        }
    }
}

enum Config {
    static let dbPath = NSString(string: "~/Library/Messages/chat.db").expandingTildeInPath

    /// 白名单路径：优先环境变量，其次从当前目录向上查找 allowlist 文件
    static var allowlistPath: String {
        if let custom = ProcessInfo.processInfo.environment["IMSG_ALLOWLIST"] {
            return NSString(string: custom).expandingTildeInPath
        }
        // 从当前目录向上查找 allowlist
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while true {
            let candidate = dir.appendingPathComponent("allowlist").path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break } // 到根了
            dir = parent
        }
        // 找不到就返回当前目录下的（doctor 会提示不存在）
        return FileManager.default.currentDirectoryPath + "/allowlist"
    }
}
