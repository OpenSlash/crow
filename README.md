# Crow

> ⚠️ **Experimental / Work in Progress** — 实验项目，仍在早期开发阶段，功能不完整，API 与结构随时可能变动。

Crow 是一个运行在 macOS 上的个人 AI 执行中枢：通过语音和文字理解意图，调用工具与 AI Agent（如 Codex）完成实际任务，敏感操作前请求确认。

> Crow turns intent into action.

## 结构

| 目录 | 说明 |
| --- | --- |
| `apps/daemon` | Go 本地守护进程（ConnectRPC） |
| `apps/macos` | 原生 macOS 客户端（Swift） |
| `apps/island-native` | 刘海 / 灵动岛式交互界面（Swift） |
| `apps/status-native` | 状态栏组件（Swift） |
| `server` | Crow Cloud 后端（Go，可部署 Cloud Run） |
| `proto` | 协议定义 |
| `docs` | 产品与技术设计文档 |
| `scripts` | 开发运行脚本 |

## 快速开始

```bash
cp .env.example .env   # 填入所需配置，如 CROW_OPENAI_API_KEY
./scripts/run-crow-server.sh
./scripts/run-crow-mac.sh
```

要求：macOS、Go 1.24+、Swift 工具链。

## 文档

详见 [`docs/`](docs/)，入口推荐 [`product-blueprint.md`](docs/product-blueprint.md) 与 [`system-design.md`](docs/system-design.md)。

## License

[MIT](LICENSE)。`apps/*/Sources/CRNNoise/rnnoise` 来自 [RNNoise](https://github.com/xiph/rnnoise)（BSD-3-Clause）。
