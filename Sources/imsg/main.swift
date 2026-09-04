import Foundation
import Darwin

// MARK: - Date formatting

let displayDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm"
    f.locale = Locale(identifier: "zh_CN")
    return f
}()

// MARK: - UI 渲染（Claude Code 风格）

let appVersion = "1.0.0"

/// 终端是否支持彩色输出
let useColor = isatty(STDOUT_FILENO) == 1

func ansi(_ code: String, _ s: String) -> String {
    useColor ? "\u{001B}[\(code)m\(s)\u{001B}[0m" : s
}

let uiSeparator = String(repeating: "─", count: 60)

func uiHeader(contact: String) {
    let cwd = FileManager.default.currentDirectoryPath
    print("▗ ▗   ▖ ▖  imsg v\(appVersion)")
    print("           \(contact) · iMessage")
    print("  ▘▘ ▝▝    \(cwd)")
    print("")
}

/// 消息正文：tapback → emoji；空文本 → [图片]/[空消息]
func messageBody(_ msg: Message) -> String {
    if let emoji = tapbackEmoji(for: msg.tapbackType, custom: msg.tapbackEmoji) {
        return emoji
    }
    if msg.text.isEmpty {
        return msg.hasAttachments ? "[图片]" : "[空消息]"
    }
    return msg.text
}

/// 单条消息的 turn 块（前置分隔线 + 发送者/时间 + 缩进正文）
func renderTurn(_ msg: Message, myName: String, otherName: String) -> String {
    let time = displayDateFormatter.string(from: msg.date)
    var out = ansi("2", uiSeparator) + "\n"
    if msg.isFromMe {
        out += "  \(ansi("1;36", "❯")) \(ansi("1", "你")) · \(ansi("2", time))\n"
    } else {
        out += "  \(ansi("1", otherName)) · \(ansi("2", time))\n"
    }
    for line in messageBody(msg).components(separatedBy: "\n") {
        out += "  \(line)\n"
    }
    return out
}

// MARK: - Name resolution

func resolveName(for handle: String, allowlist: Allowlist) -> String {
    // 1. 白名单别名优先
    if let entry = allowlist.entry(for: handle), let alias = entry.alias {
        return alias
    }
    // 2. 通讯录名
    if let contactName = ContactResolver.name(forHandle: handle) {
        return contactName
    }
    // 3. 原始 handle
    return handle
}

// MARK: - Commands

func cmdDoctor() throws {
    print("imsg doctor")
    print(String(repeating: "─", count: 40))

    // 1. macOS 版本
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    print("✓ macOS: \(osVersion)")

    // 2. 数据库
    let dbPath = Config.dbPath
    if FileManager.default.fileExists(atPath: dbPath) {
        do {
            let db = try MessageDB()
            try db.checkSchema()
            print("✓ 消息数据库: \(dbPath)")
        } catch {
            print("✗ 消息数据库: \(error)")
        }
    } else {
        print("✗ 消息数据库不存在: \(dbPath)")
    }

    // 3. 白名单
    let allowlistPath = Config.allowlistPath
    if FileManager.default.fileExists(atPath: allowlistPath) {
        do {
            let allowlist = try Allowlist.load(from: allowlistPath)
            if allowlist.isEmpty {
                print("⚠ 白名单为空: \(allowlistPath)")
                print("  请添加至少一个联系人（每行一个号码或邮箱）")
            } else {
                print("✓ 白名单: \(allowlistPath) (\(allowlist.entries.count) 个联系人)")
            }
        } catch {
            print("✗ 白名单读取失败: \(error)")
        }
    } else {
        print("⚠ 白名单文件不存在: \(allowlistPath)")
        print("  创建文件并添加联系人，每行一个号码或邮箱")
    }

    // 4. Messages.app
    let script = """
    tell application "System Events"
        return (name of processes) contains "Messages"
    end tell
    """
    if let scriptObj = NSAppleScript(source: script) {
        var error: NSDictionary?
        let result = scriptObj.executeAndReturnError(&error)
        if result.booleanValue {
            print("✓ Messages.app 正在运行")
        } else {
            print("⚠ Messages.app 未运行（发送消息前需要启动）")
        }
    }

    print(String(repeating: "─", count: 40))
}

func cmdChats(allowlist: Allowlist) throws {
    guard !allowlist.isEmpty else { throw IMSGError.allowlistEmpty }

    let db = try MessageDB()
    let chats = try db.recentChats(limit: 30)

    // 只显示白名单内的单人会话
    let filtered = chats.filter { chat in
        !chat.isGroup && chat.participants.contains { allowlist.contains($0) }
    }

    if filtered.isEmpty {
        print("没有白名单内的会话")
        return
    }

    for chat in filtered {
        let handle = chat.participants.first { allowlist.contains($0) } ?? chat.participants.first ?? "?"
        let name = resolveName(for: handle, allowlist: allowlist)
        let timeStr = chat.lastMessageDate.map { displayDateFormatter.string(from: $0) } ?? ""
        let timePad = timeStr.padding(toLength: 12, withPad: " ", startingAt: 0)
        print("\(timePad) \(name)")
    }
}

func cmdShow(_ target: String, count: Int, allowlist: Allowlist) throws {
    guard !allowlist.isEmpty else { throw IMSGError.allowlistEmpty }

    // 解析目标
    guard let handle = allowlist.resolveAlias(target) ?? Optional(Handle.normalize(target)),
          allowlist.contains(handle) else {
        throw IMSGError.notInAllowlist(target)
    }

    let db = try MessageDB()
    guard let chat = try db.findChat(forHandle: handle) else {
        throw IMSGError.contactNotFound(target)
    }

    let messages = try db.messages(forChat: chat.id, limit: count)
    let name = resolveName(for: handle, allowlist: allowlist)

    // 打开会话即同步已读
    db.markChatRead(chatId: chat.id)

    uiHeader(contact: name)
    for msg in messages {
        print(renderTurn(msg, myName: "你", otherName: name))
    }
    print(ansi("2", uiSeparator))
}

func cmdSend(_ target: String, text: String, allowlist: Allowlist) throws {
    guard !allowlist.isEmpty else { throw IMSGError.allowlistEmpty }

    guard let handle = allowlist.resolveAlias(target) ?? Optional(Handle.normalize(target)),
          allowlist.contains(handle) else {
        throw IMSGError.notInAllowlist(target)
    }

    // 如果 Messages 没运行，尝试拉起
    let script = "tell application \"System Events\" to return (name of processes) contains \"Messages\""
    if let scriptObj = NSAppleScript(source: script) {
        var error: NSDictionary?
        let result = scriptObj.executeAndReturnError(&error)
        if !result.booleanValue {
            print("Messages.app 未运行，正在启动...")
            Sender.launchMessagesIfNeeded()
        }
    }

    try Sender.send(to: handle, text: text)
    print("已发送 → \(resolveName(for: handle, allowlist: allowlist))")
}

func cmdChat(_ target: String, count: Int, allowlist: Allowlist) throws {
    guard !allowlist.isEmpty else { throw IMSGError.allowlistEmpty }

    guard let handle = allowlist.resolveAlias(target) ?? Optional(Handle.normalize(target)),
          allowlist.contains(handle) else {
        throw IMSGError.notInAllowlist(target)
    }

    let db = try MessageDB()
    guard let chat = try db.findChat(forHandle: handle) else {
        throw IMSGError.contactNotFound(target)
    }

    let name = resolveName(for: handle, allowlist: allowlist)

    // 显示最近消息
    let messages = try db.messages(forChat: chat.id, limit: count)
    uiHeader(contact: name)
    for msg in messages {
        print(renderTurn(msg, myName: "你", otherName: name))
    }
    print(ansi("2", uiSeparator))

    // 打开会话即同步已读
    db.markChatRead(chatId: chat.id)

    // 如果 Messages 没运行，拉起
    let checkScript = "tell application \"System Events\" to return (name of processes) contains \"Messages\""
    if let scriptObj = NSAppleScript(source: checkScript) {
        var error: NSDictionary?
        let result = scriptObj.executeAndReturnError(&error)
        if !result.booleanValue {
            print("Messages.app 未运行，正在启动...")
            Sender.launchMessagesIfNeeded()
        }
    }

    // 进入交互循环
    var lastMessageId = messages.last?.id ?? 0

    // 初始提示符（只打一次，避免累积）
    print("❯ ", terminator: "")
    fflush(stdout)

    while true {
        // 轮询新消息
        var printedNew = false
        if let newMessages = try? pollNewMessages(db: db, chatId: chat.id, after: lastMessageId),
           !newMessages.isEmpty {
            print("") // 结束当前提示符行
            for msg in newMessages {
                print(renderTurn(msg, myName: "你", otherName: name))
                if msg.id > lastMessageId { lastMessageId = msg.id }
            }
            printedNew = true
        }

        // 读取输入（1 秒超时）
        guard let line = readLineWithTimeout(seconds: 1) else {
            // 超时：仅当有输出才重打提示符
            if printedNew {
                print("❯ ", terminator: "")
                fflush(stdout)
            }
            continue
        }

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            // 空行退出
            print("已退出")
            return
        }

        do {
            try Sender.send(to: handle, text: trimmed)
            // 立即取最新消息作为已发内容显示，并推进游标，避免轮询重复显示
            if let msgs = try? db.messages(forChat: chat.id, limit: 1),
               let last = msgs.last, last.id > lastMessageId {
                print("")
                print(renderTurn(last, myName: "你", otherName: name))
                lastMessageId = last.id
            }
        } catch {
            print("发送失败: \(error)")
        }

        // 重新打印提示符
        print("❯ ", terminator: "")
        fflush(stdout)
    }
}

// MARK: - Helpers

/// tapback 回应映射为 emoji。type==0 表示普通消息；2006 是自定义表情，取 tapbackEmoji
func tapbackEmoji(for type: Int, custom: String?) -> String? {
    switch type {
    case 2000: return "❤️"
    case 2001: return "👍"
    case 2002: return "👎"
    case 2003: return "😄"
    case 2004: return "‼️"
    case 2005: return "❓"
    case 2006: return custom
    default: return nil
    }
}

func pollNewMessages(db: MessageDB, chatId: Int64, after lastId: Int64) throws -> [Message] {
    let all = try db.messages(forChat: chatId, limit: 100)
    return all.filter { $0.id > lastId }
}

/// 带超时的 readLine（非阻塞轮询用）
func readLineWithTimeout(seconds: Int) -> String? {
    var fds = [pollfd(fd: 0, events: Int16(POLLIN), revents: 0)]
    let ret = poll(&fds, 1, Int32(seconds * 1000))
    if ret > 0 && (fds[0].revents & Int16(POLLIN)) != 0 {
        return readLine(strippingNewline: true)
    }
    return nil
}

// MARK: - Main

func main() {
    let args = CommandLine.arguments

    guard args.count >= 2 else {
        printUsage()
        exit(1)
    }

    let command = args[1]

    do {
        let allowlist = try Allowlist.load(from: Config.allowlistPath)

        switch command {
        case "doctor":
            try cmdDoctor()

        case "chats":
            try cmdChats(allowlist: allowlist)

        case "show":
            guard args.count >= 3 else {
                print("用法: imsg show <联系人> [-n 数量]")
                exit(1)
            }
            try cmdShow(args[2], count: parseCount(args), allowlist: allowlist)

        case "send":
            guard args.count >= 4 else {
                print("用法: imsg send <联系人> <消息>")
                exit(1)
            }
            let text = args[3...].joined(separator: " ")
            try cmdSend(args[2], text: text, allowlist: allowlist)

        case "chat":
            guard args.count >= 3 else {
                print("用法: imsg chat <联系人> [-n 数量]")
                exit(1)
            }
            try cmdChat(args[2], count: parseCount(args), allowlist: allowlist)

        default:
            print("未知命令: \(command)")
            printUsage()
            exit(1)
        }
    } catch let error as IMSGError {
        FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
        exit(1)
    } catch {
        FileHandle.standardError.write("错误: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

/// 从命令行参数里解析 `-n <数量>` / `--num <数量>`，默认 10
func parseCount(_ args: [String]) -> Int {
    for (i, a) in args.enumerated() {
        if (a == "-n" || a == "--num"), i + 1 < args.count, let n = Int(args[i + 1]), n > 0 {
            return n
        }
    }
    return 10
}

func printUsage() {
    print("""
    imsg - 本地 iMessage CLI

    用法:
      imsg doctor                 自检环境
      imsg chats                  列出白名单内最近会话
      imsg show <联系人> [-n 数量]  查看某会话最近消息（默认 10 条）
      imsg send <联系人> <消息>     发送消息
      imsg chat <联系人> [-n 数量]  进入交互会话（默认显示 10 条）

    联系人可以是: 号码、邮箱、白名单别名
    白名单文件: 项目根目录下 allowlist（可用 IMSG_ALLOWLIST 环境变量覆盖）
    """)
}

main()
