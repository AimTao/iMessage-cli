# imsg

在终端里收发 iMessage，不打开 Messages.app。

同一条 iMessage 通道，换一层 CLI 壳。消息、联系人、已读状态都和系统 Messages 完全一致。

## 前提

- macOS 13+
- Messages.app 已登录 iMessage
- 终端有完全磁盘访问权限（读消息数据库和通讯录）

## 安装

```bash
git clone https://github.com/yourname/imsg.git
cd imsg
make install
```

产物在 `./imsg`。不要加进 PATH，用完整路径调用（原因见下方「安全」）：

```bash
./imsg doctor
```

## 配置白名单

imsg 采用白名单机制：**名单外的联系人收发都拒绝**，不是确认而是直接不存在。

白名单文件是项目根目录下的 `allowlist`（已加入 `.gitignore`，不会被提交）：

```bash
cat > allowlist << 'EOF'
# 每行一个号码或邮箱，空格后是可选别名
+8613800138000 妈
+8613700137000 同事A
me@example.com
EOF
```

也可以通过环境变量指定路径：

```bash
export IMSG_ALLOWLIST=~/private/my-allowlist
```

## 使用

```bash
# 自检环境
imsg doctor

# 列出白名单内最近会话
imsg chats

# 查看某会话最近消息（默认 10 条）
imsg show 妈
imsg show +8613800138000
imsg show 妈 -n 50

# 发送消息
imsg send 妈 "周六回"
imsg send +8613800138000 "收到"

# 进入交互会话（持续收发）
imsg chat 妈
```

联系人可以是：白名单别名 > 通讯录姓名 > 号码/邮箱。

### 交互会话

`imsg chat` 会显示最近 10 条消息（可用 `-n` 调整），然后进入循环：

```
▗ ▗   ▖ ▖  imsg v1.0.0
           dd · iMessage
  ▘▘ ▝▝    ~/ai/test/space/iMessage

────────────────────────────────────────────
  dd · 09-04 21:12
  周末回来吗
────────────────────────────────────────────
  ❯ 你 · 09-04 21:14
  回，周六下午
────────────────────────────────────────────

❯ _
```

- 输入一行 + 回车发送
- 空行 + 回车退出
- 新消息自动出现

## 权限设置

### 完全磁盘访问

系统设置 → 隐私与安全性 → 完全磁盘访问权限 → 添加你的终端 app。

没有这个权限，imsg 无法读取消息数据库。

### 自动化权限

首次发送消息时，macOS 会弹窗询问是否允许控制 Messages.app，点「允许」即可。

## 安全

- **不要加进 PATH**：放在本地目录，用完整路径调用。这样可以避免本机其他 AI agent 或脚本自动发现并调用这个工具。
- **白名单硬门槛**：只有名单内的联系人可以收发，名单外的消息不显示、不发送。
- **只读读取**：读 `chat.db` 用 `SQLITE_OPEN_READONLY`，不修改消息内容；仅在打开会话时写「已读」标记（`date_read`）以同步红点。
- **不联网**：无任何网络请求，所有操作都在本机完成。

## 不做的事

- 撤回、引用/回复
- 显示图片内容（仅显示 `[图片]` 占位）
- 群聊
- 系统通知管理
- TUI / 全屏界面

这些功能 Messages.app 已经做得很好，imsg 只做「终端里快速收发」这一件事。

## 工作原理

```
对方设备
  ↕ iMessage 协议（Apple 托管）
你的 Mac 上的 Messages 账号
  ↕
├── Messages.app（图形界面）
└── imsg（命令行）
      ├── 读：~/Library/Messages/chat.db（只读）
      └── 发：AppleScript 调 Messages.app
```

imsg 不碰协议层、不碰加密、不碰推送。读同一个数据库，调同一个发送栈。你看到的消息、对方收到的消息、多设备同步，全部和 Messages.app 一致。

## License

MIT
