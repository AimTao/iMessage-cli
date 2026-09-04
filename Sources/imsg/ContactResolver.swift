import Foundation
import SQLite3

/// 从 macOS 通讯录数据库读取联系人姓名
/// 数据库路径: ~/Library/Application Support/AddressBook/Sources/*/AddressBook-v22.abcddb
enum ContactResolver {
    private static var cache: [String: String] = [:]

    static func name(forHandle handle: String) -> String? {
        let normalized = Handle.normalize(handle)
        if let cached = cache[normalized] {
            return cached
        }
        guard let dbPath = findAddressBookDB() else { return nil }
        guard let name = queryName(dbPath: dbPath, handle: normalized) else { return nil }
        cache[normalized] = name
        return name
    }

    private static func findAddressBookDB() -> String? {
        let base = NSString(string: "~/Library/Application Support/AddressBook/Sources").expandingTildeInPath
        guard let enumerator = FileManager.default.enumerator(atPath: base) else { return nil }
        while let item = enumerator.nextObject() as? String {
            if item.hasSuffix(".abcddb") {
                return base + "/" + item
            }
        }
        return nil
    }

    private static func queryName(dbPath: String, handle: String) -> String? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let dbHandle = db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(dbHandle) }

        // 尝试通过电话号码或邮箱查找联系人
        // 通讯录 schema 比较复杂，这里做一个简化查询
        let phoneDigits = handle.filter { $0.isNumber }
        let sql = """
        SELECT ZABCDRECORD.ZFIRSTNAME, ZABCDRECORD.ZLASTNAME
        FROM ZABCDRECORD
        JOIN ZABCDPHONENUMBER ON ZABCDPHONENUMBER.ZOWNER = ZABCDRECORD.Z_PK
        WHERE ZABCDPHONENUMBER.ZFULLNUMBER LIKE ?
        LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(dbHandle, sql, -1, &stmt, nil) == SQLITE_OK else {
            // 尝试邮箱
            return queryNameByEmail(db: dbHandle, email: handle)
        }
        defer { sqlite3_finalize(stmt) }

        let pattern = "%\(phoneDigits.suffix(8))%"
        sqlite3_bind_text(stmt, 1, pattern, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        if sqlite3_step(stmt) == SQLITE_ROW {
            let first = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let last = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let full = (first + " " + last).trimmingCharacters(in: .whitespaces)
            return full.isEmpty ? nil : full
        }
        return nil
    }

    private static func queryNameByEmail(db: OpaquePointer, email: String) -> String? {
        let sql = """
        SELECT ZABCDRECORD.ZFIRSTNAME, ZABCDRECORD.ZLASTNAME
        FROM ZABCDRECORD
        JOIN ZABCDEMAILADDRESS ON ZABCDEMAILADDRESS.ZOWNER = ZABCDRECORD.Z_PK
        WHERE ZABCDEMAILADDRESS.ZADDRESS = ?
        LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, email, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        if sqlite3_step(stmt) == SQLITE_ROW {
            let first = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let last = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let full = (first + " " + last).trimmingCharacters(in: .whitespaces)
            return full.isEmpty ? nil : full
        }
        return nil
    }
}
