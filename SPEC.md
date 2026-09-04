# imsg — 本地 iMessage CLI

## 产品定位

在终端里收发 iMessage，不打开 Messages.app。同一条 iMessage 通道，换一层 CLI 壳。

## 命令面

| 命令 | 说明 |
|------|------|
| `imsg doctor` | 自检：权限、数据库、白名单、Messages 状态 |
| `imsg chats` | 列出白名单内最近会话 |
| `imsg show <联系人> [-n 数量]` | 查看某会话最近消息，默认 10 条 |
| `imsg send <联系人> <消息>` | 发送文本消息 |
| `imsg chat <联系人> [-n 数量]` | 进入交互会话，默认显示 10 条 |

## 白名单

- 文件路径：项目根目录下 `allowlist`（可用环境变量 `IMSG_ALLOWLIST` 覆盖）
- 格式：每行一个号码或邮箱，`#` 开头为注释，行内空格后为别名
- 默认为空，名单外的联系人**收发都拒绝**
- 群聊默认拒绝，不在名单内不显示不发送

示例：
```
# 家人
+8613800138000 妈
# 同事
+8613700137000 同事A
me@example.com
```

## 联系人标识

支持三种标识，优先级从高到低：

1. 白名单别名（手写）
2. 通讯录姓名（自动读取）
3. 原始号码 / 邮箱

号码归一化：自动处理 `+86`、`86`、`tel:` 前缀、纯 11 位手机号。

## 消息显示格式

消息以 turn 块展示（Claude Code 风格：发送者/时间头部 + 缩进正文），turn 之间用空行分隔，无横线：

```
▗ ▗   ▖ ▖  imsg v1.0.0
           dd · iMessage
  ▘▘ ▝▝    ~/ai/test/space/iMessage

dd · 09-04 21:12
      周末回来吗

❯ 你 · 09-04 21:14
      回，周六下午

❯ _
```

- 时间格式：`MM-dd HH:mm`
- 图片/贴纸消息显示 `[图片]`，不下载不预览
- 回应（tapback）显示为对应 emoji，如 `👍`、`❤️`
- 空消息显示 `[空消息]`
- 彩色仅在终端（isatty）启用，管道/重定向下自动退化为纯文本

## 已读状态

打开会话（`show` / `chat`）时，把该会话里未读的 incoming 消息标记为已读，同步消除 Messages.app 的红点。

## 通知

CLI 不做系统通知。通知由 Messages.app 照常处理。`imsg chat` 的轮询输出就是 CLI 侧的感知层。

## `imsg chat` 交互语义

1. 启动时显示最近消息（默认 10 条，可用 `-n` 调整）
2. 进入循环：每秒轮询新消息 + 等待用户输入
3. 用户输入一行 + 回车 → 发送
4. 空行 + 回车 → 退出
5. 新消息自动插入显示
6. 发送失败显示错误，不退出

## 安全边界

- **不进 PATH**：只存在于项目目录，用 `./imsg` 调用
- **白名单硬门槛**：名单外的人收发都拒绝，不是确认而是直接不存在
- **只读读取**：读 `chat.db` 用 `SQLITE_OPEN_READONLY`；仅「标记已读」用独立可写连接写 `date_read`
- **不联网**：无任何网络请求
- **日志不落敏感内容**

## 明确不做

- 撤回、引用/回复、图片/贴纸内容显示
- 群聊收发
- 系统通知管理
- 已读回执控制
- 联系人管理命令
- TUI / 全屏界面
- 云同步、远程访问、多设备
- 自动回复、机器人

## 运行前提

1. macOS 13+
2. Messages.app 已登录 iMessage
3. 终端有完全磁盘访问权限（读 `chat.db` 和通讯录）
4. 自动化权限（首次发送时系统弹窗授权）
5. 白名单文件存在且至少有一个联系人

## 技术选型

- 语言：Swift 5.9+
- 数据库：SQLite3（系统库）
- 发送：NSAppleScript 调 Messages.app
- 通讯录：直接读 AddressBook SQLite
- 构建：Swift Package Manager

## 项目文件

```
iMessage/
  Package.swift
  Makefile
  Sources/imsg/
    main.swift          # 入口 + 命令分发
    Config.swift        # 路径 + 错误类型
    Allowlist.swift     # 白名单 + 号码归一化
    MessageDB.swift     # chat.db 读取 + attributedBody 解码
    ContactResolver.swift  # 通讯录姓名
    Sender.swift        # AppleScript 发送
```
