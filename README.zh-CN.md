# Crow

[English](README.md) | 简体中文

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

## 服务模式

| 模式 | 说明 |
| --- | --- |
| **本地**（默认） | `crowd` daemon 使用你自己的 API Key 直接调用模型。支持 OpenAI、Anthropic、DeepSeek、Moonshot、Qwen、GLM、OpenRouter、Ollama 及任意 OpenAI 兼容接口。 |
| **Crow Cloud** | 请求发往 `crow-cloud` 服务，可在本地运行或部署到云端。 |

## 快速开始

```bash
cp .env.example .env   # 可选：设置 CROW_LLM_PROVIDER / CROW_LLM_MODEL / CROW_LLM_API_KEY
./scripts/run-crow-mac.sh
```

也可以在 App 的 **Settings → Model** 中配置模型，API Key 保存在钥匙串中。

使用 Crow Cloud：运行 `./scripts/run-crow-server.sh`，并将模式切换为 **Crow Cloud**。

要求：macOS、Go 1.24+、Swift 工具链。

## 通过 MCP 使用电脑操作

其他 Agent 可以通过 Crow 查看和操作这台 Mac。先在 Crow 设置里打开电脑操作，再注册 MCP 服务：

```bash
go build -o ~/.local/bin/crowctl ./apps/daemon/cmd/crowctl
claude mcp add crow-computer -- ~/.local/bin/crowctl mcp   # Claude Code；任何 stdio MCP 客户端都可以
```

这些调用同样遵守 Crow 的审批策略、只看模式和停止快捷键（⌃⌥⎋），每个会话会显示为一个"External agent"任务。

## 文档

详见 [`docs/`](docs/) 与 [路线图](docs/roadmap.md)，入口推荐 [`product-blueprint.md`](docs/product-blueprint.md) 与 [`system-design.md`](docs/system-design.md)。

## License

[MIT](LICENSE)。`apps/*/Sources/CRNNoise/rnnoise` 来自 [RNNoise](https://github.com/xiph/rnnoise)（BSD-3-Clause）。
