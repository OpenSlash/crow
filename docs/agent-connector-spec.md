# Crow Agent Connector Spec

Crow 的执行层采用本地连接器模型：主应用负责任务编排、状态持久化、审批和事件展示；真正的 agent 能力由可插拔连接器执行。

## V1 连接器

### Mock Agent

默认连接器。未设置 `CROW_AGENT_COMMAND` 时启用，用于演示 Crow 的任务生命周期、事件时间线和 Agent 状态卡片。

### Local Command Agent

设置 `CROW_AGENT_COMMAND` 后启用。Crow 会通过本地 shell 启动该命令，并把 stdout/stderr 的每一行写入任务时间线。

启动命令：

```bash
cd apps/desktop
CROW_AGENT_COMMAND='printf "reading context\nrunning codex\nsummary ready\n"' ./build/bin/Crow.app/Contents/MacOS/desktop
```

创建包含 `codex`、`claude` 或 `agent` 的任务后，该任务会进入 agent 路由。

## 环境变量协议

Crow 启动外部命令时会注入：

- `CROW_TASK_ID`: 当前任务 ID
- `CROW_TASK_TITLE`: 当前任务标题

外部 agent 只需要向 stdout 输出进度即可，例如：

```bash
echo "reading project files"
echo "running implementation checks"
echo "summary ready"
```

stderr 也会被捕获，并以 `stderr: ...` 写入事件流。

## 当前边界

- V1 只支持单命令桥接，不支持取消、暂停、结构化工具调用。
- V1 不解析 JSON 事件，所有输出都按文本行进入 `agent.running`。
- 审批仍由 Crow 主应用控制；外部 agent 的高风险操作应在后续协议中转换为 Crow approval request。

## 下一步协议

后续应扩展为结构化事件协议：

```json
{"type":"progress","message":"reading files"}
{"type":"approval.required","title":"Run shell command","riskLevel":3,"preview":"rm ..."}
{"type":"artifact.created","path":"~/Library/Application Support/Crow/artifacts/report.md"}
{"type":"completed","message":"done"}
```

这样 Crow 可以统一接入 Codex、Claude、自研 agent 和浏览器自动化执行器。
