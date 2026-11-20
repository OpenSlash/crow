# Crow Native Island Implementation

Crow Island 的 macOS 原生实现位于：

```text
apps/island-native
```

它是一个 Swift/AppKit companion 进程，职责只包含 macOS 原生窗口体验：

- `NSPanel`
- 透明背景
- 无边框
- 非激活浮窗
- 置顶层级
- 多 Space 可见
- 顶部居中定位
- 刘海融合条和下展矩形面板绘制

主应用仍由 Wails + Go + React 负责。

## 启动

先启动 Crow 主应用，让 Go runtime 写状态文件：

```bash
cd apps/desktop
./build/bin/Crow.app/Contents/MacOS/desktop
```

再启动原生 Crow Island：

```bash
./scripts/run-native-island.sh
```

## 状态协议

Go runtime 会写入：

```text
~/Library/Application Support/Crow/island-state.json
```

原生 Crow Island 每 400ms 读取该文件。

JSON 格式：

```json
{
  "status": "running",
  "title": "Agent output",
  "message": "reading context",
  "kind": "agent",
  "pendingApprovals": 0,
  "updatedAt": "2026-06-03T12:00:00+08:00"
}
```

## 为什么先用状态文件

这是最小可用集成方式：

- 不阻塞 Wails 主应用开发。
- 不要求 Swift 直接接入 SQLite。
- 不需要先设计完整 IPC。
- 可以独立验证 NSPanel、窗口层级、刘海定位和视觉形态。

后续可以替换为：

- Unix domain socket
- WebSocket
- Distributed Notification
- XPC helper

## 当前边界

- 目前只定位到主屏顶部中心，尚未读取真实 notch safe area。
- 目前不提供点击展开/收起交互，默认展示完整下展矩形面板。
- 目前是 companion 进程，尚未由 Wails 主应用自动启动和生命周期管理。
