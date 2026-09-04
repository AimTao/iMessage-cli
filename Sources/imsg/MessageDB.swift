import Foundation
import SQLite3

struct Chat {
    let id: Int64
    let lastMessageDate: Date?
    let isGroup: Bool
    let participants: [String] // handles
}

struct Message {
    let id: Int64
    let text: String
    let date: Date
    let isFromMe: Bool
    let hasAttachments: Bool
    let tapbackType: Int      // 0 = 普通消息；2000-2006 = 回应(tapback)
    let tapbackEmoji: String? // type == 2006 时的自定义表情
}

final class MessageDB {
    private var db: OpaquePointer?

    init() throws {
        let path = Config.dbPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw IMSGError.databaseNotAccessible(path)
        }
        // 以只读模式打开
        let flags = SQLITE_OPEN_READONLY
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw IMSGError.databaseNotAccessible("\(path) (\(msg))")
        }
        // 允许读 WAL（WAL 模式下最新数据可能在 -wal 文件里）
        sqlite3_exec(db, "PRAGMA query_only = 1;", nil, nil, nil)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Schema check

    func checkSchema() throws {
        let required = ["message", "chat", "chat_message_join", "handle"]
        for table in required {
            if !tableExists(table) {
                throw IMSGError.unsupportedSchema("缺少表: \(table)")
            }
        }
    }

    private func tableExists(_ name: String) -> Bool {
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name=?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    // MARK: - Mark read

    /// 把某个会话里未读的 incoming 消息标记为已读，让 Messages.app 消除红点。
    /// 用独立可写连接写库；写库失败不影响读取。
    func markChatRead(chatId: Int64) {
        var wdb: OpaquePointer?
        guard sqlite3_open_v2(Config.dbPath, &wdb, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let w = wdb else {
            return
        }
        defer { sqlite3_close(w) }

        let now = Int64(Date().timeIntervalSinceReferenceDate * 1_000_000_000)

        // 1. 未读 incoming 消息写 date_read / is_read
        let sql1 = """
        UPDATE message SET date_read = ?, is_read = 1
        WHERE ROWID IN (SELECT message_id FROM chat_message_join WHERE chat_id = ?)
          AND is_from_me = 0 AND (date_read IS NULL OR is_read = 0)
        """
        if let stmt = prepare(w, sql1) {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, now)
            sqlite3_bind_int64(stmt, 2, chatId)
            sqlite3_step(stmt)
        }

        // 2. 更新 chat.last_read_message_timestamp
        let sql2 = "UPDATE chat SET last_read_message_timestamp = ? WHERE ROWID = ?"
        if let stmt = prepare(w, sql2) {
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, now)
            sqlite3_bind_int64(stmt, 2, chatId)
            sqlite3_step(stmt)
        }
    }

    private func prepare(_ db: OpaquePointer, _ sql: String) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        return stmt
    }

    // MARK: - Query chats

    func recentChats(limit: Int = 20) throws -> [Chat] {
        let sql = """
        SELECT c.ROWID,
               c.style,
               MAX(m.date) as last_date
        FROM chat c
        JOIN chat_message_join cmj ON cmj.chat_id = c.ROWID
        JOIN message m ON m.ROWID = cmj.message_id
        GROUP BY c.ROWID
        ORDER BY last_date DESC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw IMSGError.unsupportedSchema("chat 查询失败")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(limit))

        var chats: [Chat] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let style = sqlite3_column_int(stmt, 1) // 43=group, 45=direct
            let lastDate = timestampToDate(sqlite3_column_int64(stmt, 2))
            chats.append(Chat(
                id: id,
                lastMessageDate: lastDate,
                isGroup: style == 43,
                participants: participantsForChat(chatId: id)
            ))
        }
        return chats
    }

    private func participantsForChat(chatId: Int64) -> [String] {
        let sql = """
        SELECT h.id FROM handle h
        JOIN chat_handle_join chj ON chj.handle_id = h.ROWID
        WHERE chj.chat_id = ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, chatId)
        var handles: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(stmt, 0) {
                handles.append(String(cString: ptr))
            }
        }
        return handles
    }

    // MARK: - Query messages

    func messages(forChat chatId: Int64, limit: Int = 50) throws -> [Message] {
        let sql = """
        SELECT m.ROWID, m.text, m.attributedBody, m.date, m.is_from_me,
               m.cache_has_attachments, m.associated_message_type, m.associated_message_emoji
        FROM message m
        JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        WHERE cmj.chat_id = ?
        ORDER BY m.date DESC, m.ROWID DESC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw IMSGError.unsupportedSchema("message 查询失败")
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, chatId)
        sqlite3_bind_int64(stmt, 2, Int64(limit))

        var messages: [Message] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            var text = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            // text 为空时尝试从 attributedBody 解码
            if text.isEmpty, let blobPtr = sqlite3_column_blob(stmt, 2) {
                let blobSize = sqlite3_column_bytes(stmt, 2)
                let data = Data(bytes: blobPtr, count: Int(blobSize))
                text = Self.decodeAttributedBody(data)
            }
            // 替换附件占位符 U+FFFC
            text = text.replacingOccurrences(of: "\u{FFFC}", with: " [图片] ")
            let date = timestampToDate(sqlite3_column_int64(stmt, 3)) ?? Date(timeIntervalSince1970: 0)
            let isFromMe = sqlite3_column_int(stmt, 4) == 1
            let hasAttachments = sqlite3_column_int(stmt, 5) == 1
            let tapbackType = sqlite3_column_int(stmt, 6)
            let tapbackEmoji = sqlite3_column_text(stmt, 7).map { String(cString: $0) }

            messages.append(Message(
                id: id,
                text: text.isEmpty ? (hasAttachments ? "[图片]" : "") : text,
                date: date,
                isFromMe: isFromMe,
                hasAttachments: hasAttachments,
                tapbackType: Int(tapbackType),
                tapbackEmoji: tapbackEmoji
            ))
        }
        // 查询取最近 N 条（DESC），反转为时间正序返回，供展示与轮询使用
        return messages.reversed()
    }

    // MARK: - Find chat by handle

    func findChat(forHandle handle: String) throws -> Chat? {
        let normalized = Handle.normalize(handle)
        let sql = """
        SELECT c.ROWID, c.style
        FROM chat c
        JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
        JOIN handle h ON h.ROWID = chj.handle_id
        WHERE h.id = ? AND c.style = 45
        ORDER BY c.ROWID DESC
        LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, normalized, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let id = sqlite3_column_int64(stmt, 0)
        let style = sqlite3_column_int(stmt, 1)
        return Chat(
            id: id,
            lastMessageDate: nil,
            isGroup: style == 43,
            participants: participantsForChat(chatId: id)
        )
    }

    // MARK: - Helpers

    private func timestampToDate(_ appleTs: Int64) -> Date? {
        // Apple timestamp: nanoseconds since 2001-01-01
        guard appleTs > 0 else { return nil }
        let seconds = Double(appleTs) / 1_000_000_000.0
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    // MARK: - attributedBody decoding

    /// 解析 streamtyped (NSArchiver) 格式的 attributedBody
    static func decodeAttributedBody(_ data: Data) -> String {
        let bytes = [UInt8](data)

        // 找 "NSString" 标记
        let marker: [UInt8] = [0x4e, 0x53, 0x53, 0x74, 0x72, 0x69, 0x6e, 0x67] // "NSString"
        guard let markerIdx = findPattern(bytes, from: 0, pattern: marker) else { return "" }

        // NSString 后面找 84 01 2b 模式（长度前缀）
        let lengthPrefix: [UInt8] = [0x84, 0x01, 0x2b]
        guard let lpIdx = findPattern(bytes, from: markerIdx + marker.count, pattern: lengthPrefix) else { return "" }

        var idx = lpIdx + lengthPrefix.count
        guard idx < bytes.count else { return "" }

        // 读长度（NeXT typedstream 整数编码）
        // <0x80 单字节；0x81 后跟 2 字节小端；0x82 后跟 3 字节小端
        var length = 0
        if bytes[idx] < 0x80 {
            length = Int(bytes[idx])
            idx += 1
        } else if bytes[idx] == 0x81 {
            guard idx + 2 < bytes.count else { return "" }
            length = Int(bytes[idx + 1]) | (Int(bytes[idx + 2]) << 8)
            idx += 3
        } else if bytes[idx] == 0x82 {
            guard idx + 3 < bytes.count else { return "" }
            length = Int(bytes[idx + 1]) | (Int(bytes[idx + 2]) << 8) | (Int(bytes[idx + 3]) << 16)
            idx += 4
        } else {
            return ""
        }

        // 读字符串
        guard length > 0, idx + length <= bytes.count else { return "" }
        let stringData = Data(bytes[idx..<(idx + length)])
        return String(data: stringData, encoding: .utf8) ?? ""
    }

    private static func findPattern(_ bytes: [UInt8], from start: Int, pattern: [UInt8]) -> Int? {
        guard start >= 0, start + pattern.count <= bytes.count else { return nil }
        for i in start...(bytes.count - pattern.count) {
            if bytes[i..<(i + pattern.count)].elementsEqual(pattern) {
                return i
            }
        }
        return nil
    }
}
