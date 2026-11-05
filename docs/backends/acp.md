# ACP backend

本页只回答一个问题：`backend/` 里的 ACP adapter 怎么把 `opencode acp` 接成
`BackendPort`，以及它明确不做什么。

验证环境：opencode `2.2.5`，ACP 协议版本 `1`，MoonBit `0.1.20261029`。

## 定位

ACP（Agent Client Protocol）是编辑器与编码 agent 之间的 JSON-RPC 协议。MediaPilot
在这里扮演 **client**：它启动 agent 进程、创建会话、发送用户指令，并把 agent 的
输出与权限请求翻译成 `BackendEvent`。

和 LLM backend 的区别：LLM backend 只能说话，ACP backend 真的会读写文件、执行命令。
所以它是权限流程的第一个真实来源。

参考项目对应的是 `backend/adapters/acp/*`（JSON-RPC 客户端 + 会话管理）。

## 传输

- `@process.spawn_orphan` 启动一个子进程，stdin/stdout 是管道。
- 每行一个 JSON-RPC 2.0 消息（请求、响应、通知都走同一行协议）。
- stderr 单独读取并丢弃，只保留最后一行用于错误信息。不读会导致子进程写满管道后卡死。
- 一个网关会话对应一个子进程；`close` 关闭 stdin 并释放管道句柄。agent 读到 EOF
  后自行退出。

## 启动与会话

```text
initialize        { protocolVersion: 1, clientCapabilities: { fs: {readTextFile:false, writeTextFile:false}, terminal:false } }
session/new       { cwd: <absolute>, mcpServers: [] }
session/prompt    { sessionId, prompt: [{ type: "text", text: instruction }] }
session/cancel    { sessionId }                     // 通知，取消进行中的 turn
```

显式声明 **不支持** 文件系统与终端能力。这样 agent 用自己的工具执行操作，只在需要
用户批准时发 `session/request_permission`；网关不替 agent 执行任何工具，也不接管
它的工作目录。

`initialize` 超时 20 秒，`session/new` 超时 30 秒，`session/prompt` 不设超时：长任务
可以跑几分钟，由用户的 `session.interrupt` 结束。

## 事件映射

`session/update` 通知按 `update.sessionUpdate` 分发：

| ACP update | 后端事件 | 说明 |
| --- | --- | --- |
| `agent_message_chunk`（`content.type = "text"`） | `TextDelta(text)` | 累积成本轮回答 |
| `tool_call` / `tool_call_update` 的 `title` | `Progress(text)` | 网关转成 `task.updated.step`，只用于展示 |
| `agent_thought_chunk` | 忽略 | 思维链不进语音 |
| `plan`、`usage_update`、`available_commands_update`、`current_mode_update` | 忽略 | 客户端不需要 |
| 其他未知 `sessionUpdate` | 忽略 | ACP 会新增类型，旧客户端必须继续工作 |

`agent_message_chunk` 的非文本内容（图片等）被忽略，不拼进回答。

## 权限

`session/request_permission` 是 agent 发起的 **请求**，网关必须回答：

```text
toolCall.kind  -> operation      (read/edit/execute/...，未知值按 other)
toolCall.title -> description    (只展示，不参与判断)
```

`requestId` 由网关生成（`p-<rpc id>`），与 ACP 的 JSON-RPC id 分开，避免把协议细节
泄漏到北向事件。

回答时按 `decision` 选择 agent 提供的选项：

| 网关 decision | 依次尝试的 option kind |
| --- | --- |
| `allow_once` | `allow_once` |
| `allow_task` | `allow_always` → `allow_once` |
| `allow_session` | `allow_always` → `allow_once` |
| `deny` | `reject_once` → `reject_always` |

agent 没有提供匹配项时回 `{"outcome":{"outcome":"cancelled"}}`，绝不回“批准”。
注意 `allow_always` 的“记住”由 agent 自己实现，范围也由 agent 决定；网关侧
`allow_task` / `allow_session` 的重复抑制与它相互独立。

取消 turn 时，所有未回答的权限请求都回 `cancelled`，这是 ACP 的要求。

## 取消与关闭

- `session.interrupt` → 网关调用 `BackendPort::cancel` → 发 `session/cancel` 并回答
  所有待批权限。agent 用 `stopReason = "cancelled"` 结束 prompt。
- 被取消的 turn 仍然发出 `TextDone` + `Completed`，否则网关的消费循环会永远等待。
  网关再用 `continue_turn = false` 注入工具结果，避免打断后又播报一段。
- 子进程退出时，所有在途请求都以错误结束，网关不会挂死。

## 配置

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `MEDIAPILOT_BACKEND` | `llm` | `acp` 启用本 adapter，`none` 关闭委派 |
| `MEDIAPILOT_ACP_COMMAND` | `opencode` | agent 可执行文件；Windows 必须是 `.exe`，不能是 npm 的 `.cmd`/`.ps1` 包装 |
| `MEDIAPILOT_ACP_MODE` | `acp` | 传给可执行文件的第一个参数 |
| `MEDIAPILOT_ACP_CWD` | 进程当前目录的绝对路径 | agent 的工作目录，必须是绝对路径 |

```powershell
$env:MEDIAPILOT_BACKEND = "acp"
$env:MEDIAPILOT_ACP_COMMAND = "$env:APPDATA\npm\node_modules\@opencode\cli\bin\opencode.exe"
$env:MEDIAPILOT_ACP_CWD = (Get-Location).Path
moon run cmd/main --target native
```

agent 自己的权限策略（例如哪些命令需要确认）由 opencode 的配置文件决定，不是
MediaPilot 的配置。MediaPilot 只在 agent 发来请求时询问用户。

## 已验证

真实链路（`opencode acp` + DashScope Realtime + 浏览器客户端）：

- 文本指令 → `delegate_task` → ACP `session/prompt` → `tool_call` 进度 →
  `permission.request`（`execute`，描述 `echo panel-check`）→ 客户端批准 →
  `permission.resolved` → 结果回注 → 语音播报。
- `allow_session` 之后再出现权限请求时，网关直接按 policy 回答，客户端不再弹窗。
- 打断长任务：`playback.clear` → `task.updated(status=cancelled)` → 不再播报；
  同一会话随后仍能正常回答新问题。
- `deny`：agent 收到拒绝并以“用户拒绝”继续，模型向用户解释，不执行命令。

## 已知限制

- 同一会话同时只跑一个任务；第二个 `delegate_task` 会排队等待网关处理完第一个。
- 不支持 `session/load`、`session/resume`、MCP server、终端能力、文件系统能力。
- 不解析 agent 的模型/模式配置选项；使用 agent 自身的默认值。
- 文本按 ACP 的 chunk 转发，可能一块包含多句，也可能一句分多块；客户端不能假设边界。

## 测试

| 行为 | 锁定位置 |
| --- | --- |
| 行协议、`initialize` 参数、update 映射、权限请求解析、选项选择 | `backend/acp_wbtest.mbt` |
| 权限请求 → 批准/拒绝/会话授权/超时降级、`send_tool_result` 的 `continue_turn` | `gateway/integration_test.mbt` |
| `permission.request` / `permission.resolved` 的 JSON 形状 | `protocol/codec_test.mbt` |
