import Foundation

struct AllowlistEntry {
    let handle: String   // 原始号码或邮箱（归一化后）
    let alias: String?   // 手动指定的别名，nil 表示用通讯录名
}

struct Allowlist {
    private(set) var entries: [AllowlistEntry]
    private let rawHandles: Set<String>

    init(entries: [AllowlistEntry]) {
        self.entries = entries
        self.rawHandles = Set(entries.map { $0.handle })
    }

    static func load(from path: String) throws -> Allowlist {
        guard FileManager.default.fileExists(atPath: path) else {
            return Allowlist(entries: [])
        }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        let entries = parse(content: content)
        return Allowlist(entries: entries)
    }

    private static func parse(content: String) -> [AllowlistEntry] {
        content.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            let handle = Handle.normalize(String(parts[0]))
            let alias = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil
            return AllowlistEntry(handle: handle, alias: alias)
        }
    }

    func contains(_ handle: String) -> Bool {
        rawHandles.contains(Handle.normalize(handle))
    }

    func entry(for handle: String) -> AllowlistEntry? {
        let normalized = Handle.normalize(handle)
        return entries.first { $0.handle == normalized }
    }

    func resolveAlias(_ nameOrHandle: String) -> String? {
        let normalized = Handle.normalize(nameOrHandle)
        // 直接匹配 handle
        if let entry = entry(for: normalized) {
            return entry.handle
        }
        // 匹配别名
        return entries.first {
            guard let alias = $0.alias else { return false }
            return alias == nameOrHandle || alias == normalized
        }?.handle
    }

    var isEmpty: Bool { entries.isEmpty }
}

// MARK: - Handle normalization

enum Handle {
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        // 去掉 tel: 前缀
        if s.hasPrefix("tel:") { s = String(s.dropFirst(4)) }
        // 去掉所有非数字非@非.的字符（保留邮箱）
        if s.contains("@") {
            return s.lowercased()
        }
        // 电话号码：只保留数字和前导+
        let filtered = s.filter { $0.isNumber || $0 == "+" }
        // 归一化：确保有 +86 或原样
        if filtered.hasPrefix("+") {
            return filtered
        }
        // 纯数字：假设中国号码
        if filtered.count == 11 && filtered.hasPrefix("1") {
            return "+86" + filtered
        }
        if filtered.count == 13 && filtered.hasPrefix("86") {
            return "+" + filtered
        }
        return filtered
    }
}
