# ACP backend

本页只回答一个问题：`backend/` 里的 ACP adapter 怎么把 `opencode acp` 接成
`BackendPort`，以及它明确不做什么。

验证环境：opencode `2.2.5`，ACP 协议版本 `1`，MoonBit `0.1.20261104`。

## 定位

ACP（Agent Client Protocol）是编辑器与编码 agent 之间的 JSON-RPC 协议。MediaPilot
在这里扮演 **client**：它启动 agent 进程、创建会话、发送用户指令，并把 agent 的
输出与权限请求翻译成 `BackendEvent`。

和 LLM backend 的区别：LLM backend 只能说话，ACP backend 真的会读写文件、执行命令。
所以它是权限流程的第一个真实来源。

参考项目对应的是 `backend/adapters/acp/*`（JSON-RPC 客户端 + 会话管理）。

实现方式：MediaPilot 的 ACP client 是 `backend/acp.mbt` 里手写的 JSON-RPC over
stdio，**没有**引入 ACP SDK。参考项目使用 TypeScript 的
`@agentclientprotocol/sdk`；这里只实现当前需要的方法子集（`initialize`、
`session/new`、`session/prompt`、`session/cancel`、`session/request_permission`、
`session/set_config_option`）。ACP 新增能力时需要自己补解析和映射，不能依赖 SDK
自动升级。

## 传输

- `@process.spawn_orphan` 启动一个子进程，stdin/stdout 是管道。
- 每行一个 JSON-RPC 2.0 消息（请求、响应、通知都走同一行协议）。
- stderr 单独读取并丢弃，只保留最后一行用于错误信息。不读会导致子进程写满管道后卡死。
- 一个网关会话对应一个子进程；`close` 关闭 stdin 并释放管道句柄。agent 读到 EOF
  后自行退出。

## 启动与会话

```text
initialize        { protocolVersion: 1, clientCapabilities: { fs: {readTextFile:false, writeTextFile:false}, terminal:false } }
session/new       { cwd: <会话选择的工作目录>, mcpServers: [] }
session/prompt    { sessionId, prompt: [{ type: "text", text: instruction }] }
session/cancel    { sessionId }                     // 通知，取消进行中的 turn
```

`cwd` 来自本会话握手时选定的工作目录（见下文“工作目录”）。子进程的启动目录与
`session/new` 的 `cwd` 始终是同一个值。

显式声明 **不支持** 文件系统与终端能力。这样 agent 用自己的工具执行操作，只在需要
用户批准时发 `session/request_permission`；网关不替 agent 执行任何工具，也不接管
它的工作目录。

`initialize` 超时 20 秒，`session/new` 超时 30 秒，`session/prompt` 不设超时：长任务
可以跑几分钟，由用户的 `session.interrupt` 结束。

### 预热

会话建立后，网关立刻在后台调用 `BackendPort::warmup`：启动进程、`initialize`、
`session/new`。用户说完第一句话到模型决定调用工具之间通常有 1–2 秒，预热就在这段
时间完成，所以第一个任务不再额外等 2–3 秒的握手。

预热与任务用同一把锁串行：同一时刻只有一个 reader 可以在读 agent 的 stdout。预热
失败不产生北向事件，下一次任务会重新尝试并正常报错。

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
| `MEDIAPILOT_ACP_CWD` | 进程当前目录的绝对路径 | 默认工作目录；必须是绝对路径且启动时存在 |
| `MEDIAPILOT_ACP_MODEL` | 空（用 agent 自己的默认模型） | 通过 `session/set_config_option` 选择的模型 ID |

```powershell
$env:MEDIAPILOT_BACKEND = "acp"
$env:MEDIAPILOT_ACP_COMMAND = "$env:APPDATA\npm\node_modules\@opencode\cli\bin\opencode.exe"
$env:MEDIAPILOT_ACP_CWD = "D:\work\alpha"
$env:MEDIAPILOT_ACP_MODEL = "deepseek/deepseek-v4-pro"
moon run cmd/main --target native
```

例如从 `D:\File\Project\Agent\MediaPilot` 启动网关，但让 agent 在
`D:\agents\workspace` 里工作，只需要设置 `MEDIAPILOT_ACP_CWD=D:\agents\workspace`；
MediaPilot 的配置发现、静态文件路径不会跟着变。

`MEDIAPILOT_ACP_MODEL` 不是必须的，但 agent 的默认模型可能不可用。opencode 的
默认模型由它自己的配置和远端目录决定，MediaPilot 不猜；要让语音任务稳定，显式选一个
可用模型更可靠。

agent 自己的权限策略（例如哪些命令需要确认）由 opencode 的配置文件决定，不是
MediaPilot 的配置。MediaPilot 只在 agent 发来请求时询问用户。

## 工作目录

工作目录是 ACP 唯一需要按会话变化的状态：agent 的读写和命令都在这个目录下执行。

### 默认目录与可浏览范围

- **agent 工作目录独立于 MediaPilot 的启动目录。** 配置文件的查找、`MEDIAPILOT_WEB_ROOT`
  等仍以 MediaPilot 的启动目录为基准；agent 只在 `MEDIAPILOT_ACP_CWD` 指定的目录
  里工作。两者可以完全不同。
- 默认目录来自 `MEDIAPILOT_ACP_CWD`；未配置时才是网关进程启动目录的绝对路径。
- 启动时校验：必须是绝对路径且存在，否则直接报错退出。校验通过后用 `realpath`
  规范化。
- 浏览范围是整个文件系统，没有白名单。`GET /api/fs/roots` 返回盘符（Windows）或
  `/`（其他系统），`GET /api/fs/list?path=` 返回一级子目录。
- 浏览器、桌面端、TUI 使用同一组端点，不需要各自实现文件系统访问。

### 客户端怎么选

```json
{
  "type": "session.hello",
  "requestId": "c-1",
  "protocolVersion": "0.6.3",
  "capabilities": ["realtime.audio-in", "realtime.audio-out", "realtime.workspace"],
  "workspace": "D:\\work\\beta"
}
```

- 不传或传 `""` → 使用默认目录。
- 传绝对路径且存在、是目录 → 使用该目录；`session.ready.workspace` 回传
  `realpath` 后的字符串。
- 传相对路径、不存在的路径或文件 → `error`（`code = "workspace_denied"`，
  `retryable = false`）并关闭，不会启动 agent 子进程。
- 客户端应通过 `GET /api/fs/*` 选择，不要假设路径存在。

### 运行时语义

- **一个会话一个目录，会话内不可换。** 换目录意味着关闭当前连接并用新的
  `workspace` 重连；旧会话的任务会随连接关闭而取消，不会迁移到新目录。
- **一个会话一个子进程。** 不同会话可以选不同目录，各自拥有独立的 `opencode acp`。
- **不会创建目录。** 目录必须已经存在；网关只校验，不修改文件系统。
- **不是安全边界。** 客户端可以浏览整个文件系统，agent 仍以网关进程的身份运行，
  能访问该身份可访问的一切。`MEDIAPILOT_AUTH_TOKEN` 是准入 token，不是多租户身份；
  需要强隔离时应使用独立进程或容器，并只监听回环地址或限制网络访问。
- **非 ACP backend 没有工作目录。** `MEDIAPILOT_BACKEND=llm` 或 `none` 时，
  `/api/fs/roots` 的 `enabled` 为 `false`，`session.ready.workspace` 为 `""`。

浏览器客户端在页面顶部提供“浏览…”对话框：左侧逐级进入子目录，可以返回上级或切换
盘符，选中后把路径写进 `session.hello.workspace`。页面带 `?token=` 时会用同一个
token 请求 `/api/fs/*`。

## 已验证

真实链路（`opencode acp` + DashScope Realtime + 浏览器客户端）：

- 文本指令 → `delegate_task` → 立即受理回执（模型先说“正在处理”）→ ACP
  `session/prompt` → `tool_call` 进度 → `permission.request`（`execute`，描述
  `echo panel-check`）→ 客户端批准 → `permission.resolved` → 完成后另起一轮语音
  播报结果。
- `allow_session` 之后再出现权限请求时，网关直接按 policy 回答，客户端不再弹窗。
- 打断长任务：`playback.clear` → `task.updated(status=cancelled)` → 不再播报；
  同一会话随后仍能正常回答新问题。
- `deny`：agent 收到拒绝并以“用户拒绝”继续，模型向用户解释，不执行命令。
- 首次委派时延：预热前 9.9 秒到首段音频；预热并显式选模型后，受理确认约 1.2 秒
  开始播报，最终结果约 4.6 秒后到达（文本输入，`echo hi`）。剩下的时间主要是
  agent 自己的模型往返，不是网关或浏览器。
- 会话结束时子进程会被回收：先关 stdin 等 1.5 秒，不退出就 `taskkill` / `kill -9`。

## 已知限制

- 同一会话同时只跑一个任务；第二个 `delegate_task` 会立即受理并排队，等前一个结束
  后开始。队列上限由 `MEDIAPILOT_MAX_TASKS` 控制（默认 4），满了会立即返回错误结果。
  打断只会取消当前正在执行的任务，排队中的任务按 generation 丢弃。
- 每个会话固定一个工作目录，目录选择在握手时完成，会话内不能更换；客户端可以浏览
  整个文件系统。`MEDIAPILOT_AUTH_TOKEN` 只是准入 token，不是多租户身份，不能隔离
  不同用户的工作目录。
- 不支持 `session/load`、`session/resume`、MCP server、终端能力、文件系统能力。
- 不解析 agent 的模型/模式配置选项；使用 agent 自身的默认值。
- 文本按 ACP 的 chunk 转发，可能一块包含多句，也可能一句分多块；客户端不能假设边界。

## 测试

| 行为 | 锁定位置 |
| --- | --- |
| 行协议、`initialize` 参数、update 映射、权限请求解析、选项选择 | `backend/acp_wbtest.mbt` |
| 权限请求 → 批准/拒绝/会话授权/超时降级、受理回执与后台结果播报、`send_tool_result` 的 `continue_turn` | `gateway/integration_test.mbt` |
| `permission.request` / `permission.resolved` 的 JSON 形状 | `protocol/codec_test.mbt` |
| 工作目录路径解析、目录枚举、排序、百分号解码 | `gateway/server_wbtest.mbt` |
| 握手选择目录、默认目录、`workspace_denied`、`GET /api/fs/*` 鉴权与错误码 | `gateway/integration_test.mbt` |
