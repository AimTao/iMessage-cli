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

/// 单条消息的 turn（发送者/时间头部顶格 + 正文缩进 6 空格，无分隔线）
func renderTurn(_ msg: Message, myName: String, otherName: String) -> String {
    let time = displayDateFormatter.string(from: msg.date)
    let header = msg.isFromMe
        ? "\(ansi("1;36", "❯")) \(ansi("1", "你")) · \(ansi("2", time))"
        : "\(ansi("1", otherName)) · \(ansi("2", time))"
    var lines = [header]
    for line in messageBody(msg).components(separatedBy: "\n") {
        lines.append("      \(line)")
    }
    return lines.joined(separator: "\n")
}

// MARK: - 原始模式输入（自己处理回显与退格）

/// 进入原始模式，返回原 termios；用 defer restoreTerminal 恢复
func enableRawMode() -> termios {
    var orig = termios()
    tcgetattr(STDIN_FILENO, &orig)
    var raw = orig
    raw.c_lflag &= ~tcflag_t(ECHO | ICANON | ISIG | IEXTEN)
    raw.c_iflag &= ~tcflag_t(IXON)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    return orig
}

func restoreTerminal(_ t: termios) {
    var copy = t
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &copy)
}

/// 直接写字节到 stdout（绕过 stdio 缓冲，避免与 print 交错乱序）
func writeOut(_ s: String) {
    s.utf8CString.withUnsafeBufferPointer { buf in
        _ = write(STDOUT_FILENO, buf.baseAddress, buf.count - 1)
    }
    fflush(stdout)
}

/// 清空当前行（回车到行首 + 擦除到行尾）
func clearLine() {
    writeOut("\r\u{1B}[2K")
}

/// 删除字节数组末尾一个完整 UTF-8 字符（中文多字节，不能只删一个字节）
func dropLastUTF8Char(_ bytes: inout [UInt8]) {
    guard !bytes.isEmpty else { return }
    var idx = bytes.count - 1
    while idx > 0 && (bytes[idx] & 0xC0) == 0x80 { idx -= 1 }
    bytes.removeSubrange(idx..<bytes.count)
}

func inputDisplay(_ bytes: [UInt8]) -> String {
    // 只取可解码的 UTF-8 前缀，末尾未完成的字节序列暂不显示（正在敲中文多字节字符时）
    var b = bytes
    while !b.isEmpty {
        if let s = String(bytes: b, encoding: .utf8) { return s }
        b.removeLast()
    }
    return ""
}

/// 重绘当前提示符行（清行 + ❯ + 已输入内容）
func redrawPrompt(_ bytes: [UInt8]) {
    clearLine()
    writeOut("❯ " + inputDisplay(bytes))
    fflush(stdout)
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
    if Sender.isMessagesRunning() {
        print("✓ Messages.app 正在运行")
    } else {
        print("⚠ Messages.app 未运行（发送消息前需要启动）")
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

/// 校验目标联系人在白名单内，返回归一化后的 handle（show/send/chat 共用）
func resolveHandle(_ target: String, allowlist: Allowlist) throws -> String {
    guard !allowlist.isEmpty else { throw IMSGError.allowlistEmpty }
    guard let handle = allowlist.resolveAlias(target) ?? Optional(Handle.normalize(target)),
          allowlist.contains(handle) else {
        throw IMSGError.notInAllowlist(target)
    }
    return handle
}

func cmdShow(_ target: String, count: Int, allowlist: Allowlist) throws {
    let handle = try resolveHandle(target, allowlist: allowlist)

    let db = try MessageDB()
    guard let chat = try db.findChat(forHandle: handle) else {
        throw IMSGError.contactNotFound(target)
    }

    let messages = try db.messages(forChat: chat.id, limit: count)
    let name = resolveName(for: handle, allowlist: allowlist)

    db.markChatRead(chatId: chat.id)

    uiHeader(contact: name)
    printHistory(messages, myName: "你", otherName: name)
}

func cmdSend(_ target: String, text: String, allowlist: Allowlist) throws {
    let handle = try resolveHandle(target, allowlist: allowlist)

    ensureMessagesRunning()
    try Sender.send(to: handle, text: text)
    print("已发送 → \(resolveName(for: handle, allowlist: allowlist))")
}

func cmdChat(_ target: String, count: Int, allowlist: Allowlist) throws {
    let handle = try resolveHandle(target, allowlist: allowlist)

    let db = try MessageDB()
    guard let chat = try db.findChat(forHandle: handle) else {
        throw IMSGError.contactNotFound(target)
    }

    let name = resolveName(for: handle, allowlist: allowlist)

    let messages = try db.messages(forChat: chat.id, limit: count)
    uiHeader(contact: name)
    printHistory(messages, myName: "你", otherName: name)

    db.markChatRead(chatId: chat.id)
    ensureMessagesRunning()

    var lastMessageId = messages.last?.id ?? 0
    var inputBytes: [UInt8] = []
    var lastPoll = Date()

    // 进入原始模式前，把 stdio 缓冲的头部/历史先冲出去，避免与 write 交错乱序
    fflush(stdout)
    let orig = enableRawMode()
    defer { restoreTerminal(orig) }

    redrawPrompt(inputBytes)

    while true {
        // 1. 读输入（原始模式，逐字节）
        var fds = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)]
        if poll(&fds, 1, 100) > 0, (fds[0].revents & Int16(POLLIN)) != 0 {
            var buf = [UInt8](repeating: 0, count: 32)
            let n = buf.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, 32) }
            if n > 0 {
                for i in 0..<n {
                    let c = buf[i]
                    switch c {
                    case 0x0d, 0x0a: // Enter
                        let text = String(bytes: inputBytes, encoding: .utf8) ?? ""
                        inputBytes.removeAll()
                        let trimmed = text.trimmingCharacters(in: .whitespaces)
                        clearLine()
                        if trimmed.isEmpty {
                            writeOut("已退出\n")
                            return
                        }
                        do {
                            try Sender.send(to: handle, text: trimmed)
                            if let msgs = try? db.messages(forChat: chat.id, limit: 1),
                               let last = msgs.last, last.id > lastMessageId {
                                writeOut(renderTurn(last, myName: "你", otherName: name) + "\n")
                                lastMessageId = last.id
                            }
                        } catch {
                            writeOut("发送失败: \(error)\n")
                        }
                        redrawPrompt(inputBytes)
                    case 0x7f, 0x08: // 退格
                        dropLastUTF8Char(&inputBytes)
                        redrawPrompt(inputBytes)
                    case 0x03: // Ctrl+C
                        writeOut("\n")
                        return
                    case 0x04: // Ctrl+D
                        if inputBytes.isEmpty {
                            writeOut("\n已退出\n")
                            return
                        }
                    default:
                        if c >= 0x20 || c == 0x09 {
                            inputBytes.append(c)
                            redrawPrompt(inputBytes)
                        }
                    }
                }
            }
        }

        // 2. 每秒轮询新消息
        if Date().timeIntervalSince(lastPoll) >= 1.0 {
            lastPoll = Date()
            if let newMessages = try? db.newMessages(forChat: chat.id, after: lastMessageId),
               !newMessages.isEmpty {
                clearLine()
                for msg in newMessages {
                    writeOut(renderTurn(msg, myName: "你", otherName: name) + "\n")
                    if msg.id > lastMessageId { lastMessageId = msg.id }
                }
                redrawPrompt(inputBytes)
            }
        }
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

/// 打印一批消息（turn 之间空行分隔，无横线）
func printHistory(_ messages: [Message], myName: String, otherName: String) {
    for msg in messages {
        print(renderTurn(msg, myName: myName, otherName: otherName))
        print("")
    }
}

/// Messages.app 未运行则拉起
func ensureMessagesRunning() {
    if !Sender.isMessagesRunning() {
        Sender.launchMessagesIfNeeded()
    }
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
