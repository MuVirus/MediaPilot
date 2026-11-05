# Gateway contract

本文件是外部客户端（Web、桌面、CLI、第三方集成）**唯一**可以依赖的承诺清单。
未列出的内容——内部模块路径、数据库结构、配置目录里的文件、日志格式——都不是契约，
可以随时改变。

状态：`v0.4.0`，P2 进行中。之后的协议变更必须升版本并更新此表。

范围：当前契约只覆盖实时音频。视频复用同一会话与事件模型，P4 才进入契约。

每条承诺都由测试锁定。`Locked by` 写测试文件；没有测试的行为不算承诺——
想新增承诺，就在同一次改动里加上测试。

## 版本与能力协商

`GET /api/health` 返回：

```json
{
  "protocolVersion": "0.4.0",
  "capabilities": ["realtime.audio-in", "realtime.audio-out"]
}
```

- 版本遵循 SemVer：新增能力升 minor，破坏任一已列端点或事件升 major。
- 客户端按 **能力 ID** 分支，不比较产品版本号。未知能力必须降级，不能崩溃。
- 未知事件类型必须忽略，不能断开连接。

| Capability | 含义 | Locked by |
| --- | --- | --- |
| `realtime.session` | `WS /api/realtime` 接受 `session.hello` 并返回 `session.ready` | `gateway/integration_test.mbt` |
| `realtime.audio-in` | 客户端可推送 PCM16 单声道 16 kHz 音频 | `gateway/integration_test.mbt` |
| `realtime.audio-out` | 服务端推送 PCM16 单声道 24 kHz 音频 | `gateway/integration_test.mbt` |
| `realtime.text-in` | 客户端可发送文本输入 | `gateway/integration_test.mbt` |
| `realtime.interrupt` | 客户端可打断当前回复并清空播放 | `gateway/integration_test.mbt` |
| `realtime.playback-clear` | 服务端可要求客户端停止播放已缓冲音频 | `protocol/codec_test.mbt` |
| `realtime.task` | 服务端可推送 `task.updated` 背景任务进度 | `gateway/integration_test.mbt` |
| `realtime.permission` | 服务端可要求客户端批准后台操作 | `gateway/integration_test.mbt` |

事件的 JSON 形状由 `protocol/codec_test.mbt` 锁定；`GET /api/health` 的响应形状由
`gateway/gateway_test.mbt` 锁定。

## 端点

### `GET /api/health`

无需认证。返回 `protocolVersion`、`capabilities`、`status`。用于客户端启动时探测，
不能用于判断具体功能是否可用——那要看能力列表。

### `WS /api/realtime`

一条连接承载一个会话。文本帧是 JSON；音频只出现在 JSON 的 `data` 字段里（base64），
不混用二进制帧，保证浏览器和原生客户端行为一致。

### `GET /`

参考浏览器客户端。网关只托管 `web/` 下的固定文件（`index.html`、`app.js`、
`pcm-worklet.js`、`style.css`），其他路径返回 404。静态资源不是契约的一部分，
客户端可以完全不用它。

## 握手

客户端连接后必须首先发送：

```json
{
  "type": "session.hello",
  "requestId": "c-1",
  "protocolVersion": "0.4.0",
  "capabilities": ["realtime.audio-in", "realtime.audio-out"]
}
```

服务端回复：

```json
{
  "type": "session.ready",
  "requestId": "c-1",
  "sessionId": "s-1",
  "protocolVersion": "0.4.0",
  "capabilities": ["realtime.audio-in", "realtime.audio-out"]
}
```

规则：

- 握手前收到其他事件 → `error`，`code = "handshake_required"`。
- 双方能力取交集；服务端只发送交集内的能力事件。
- `requestId` 原样回传，仅用于关联，不参与业务语义。

## 客户端事件

| `type` | 字段 | 含义 |
| --- | --- | --- |
| `input.audio.append` | `data`, `format`, `sampleRate`, `channels` | 追加一段音频 |
| `input.text` | `text` | 发送一条文本输入 |
| `input.image.append` | `data`, `mimeType` | 追加一帧图像（P4） |
| `session.interrupt` | — | 打断当前回复、取消进行中的后台任务并清空待播放音频 |
| `permission.respond` | `requestId`, `decision` | 批准或拒绝一次后台操作 |
| `session.close` | — | 正常关闭会话 |

`format` 目前只允许 `pcm16`。单次音频块建议 20–100 ms；服务端不得假设固定块大小。

## 服务端事件

| `type` | 字段 | 含义 |
| --- | --- | --- |
| `session.ready` | `requestId`, `sessionId`, `protocolVersion`, `capabilities` | 握手完成 |
| `transcript.partial` | `role`, `text` | 增量转写 |
| `transcript.final` | `role`, `text` | 一段话的最终转写 |
| `audio.delta` | `data`, `format`, `sampleRate`, `channels` | 一段可播放音频 |
| `playback.clear` | `reason` | 立即停止播放并丢弃已缓冲音频 |
| `task.updated` | `taskId`, `status`, `text`, `step` | 背景任务进度 |
| `permission.request` | `requestId`, `taskId`, `operation`, `description`, `timeoutMs` | 请求批准一次后台操作 |
| `permission.resolved` | `requestId`, `decision`, `source` | 该请求已有结果，客户端应关闭等待界面 |
| `error` | `code`, `message`, `retryable` | 可恢复或不可恢复错误 |

所有服务端事件都带 `type`；除 `error` 外都带 `sessionId`。事件不保证跨会话有序，
同一会话内按发送顺序处理。

`playback.clear` 的 `reason` 是稳定 token，客户端不得依赖自由文本：

| `reason` | 含义 |
| --- | --- |
| `user_interruption` | 服务端 VAD 检测到用户开始说话 |
| `client_interrupt` | 服务端已处理 `session.interrupt`，这是打断确认 |

收到 `playback.clear` 后，客户端必须丢弃本地待播放缓冲，不能只暂停。

`task.updated` 的 `status` 是稳定 token：

| `status` | 含义 |
| --- | --- |
| `running` | 任务进行中，`text` 是当前已产生的文本，可能为空 |
| `completed` | 任务完成，`text` 是完整结果 |
| `failed` | 任务失败，`text` 是错误信息 |
| `cancelled` | 用户打断导致任务中止，不能当作失败播报 |

`step` 是一行人类可读的进度（例如“正在执行 git status”），可能为空，只能用于展示。
后端提供 `step` 时，`text` 仍然只表示回答正文，两者不能混用。

同一个 `taskId` 会先收到若干 `running`，再收到一个终态。客户端应在 `running` 时
显示进度，但不能把增量 `text` 当作最终答案。`task.updated` 只是进度展示；
最终答案由同一轮次的 `audio.delta` / `transcript.final` 给出。

## 权限请求

只有客户端在 `session.hello` 里声明了 `realtime.permission`，网关才会发送
`permission.request`。没声明的客户端按“一律拒绝”处理：网关不会发请求，也不会
等待超时。

```json
{
  "type": "permission.request",
  "sessionId": "s-1",
  "requestId": "p-3",
  "taskId": "t-1",
  "operation": "execute",
  "description": "echo hello",
  "timeoutMs": 60000
}
```

- `operation` 是稳定 token：`read`、`edit`、`delete`、`move`、`search`、`execute`、
  `think`、`fetch`、`switch_mode`、`other`。客户端按它选择图标和措辞。
- `description` 由后端撰写，可能包含命令或路径，**只能展示，不能用于判断**。
- `timeoutMs` 是网关等待客户端回答的时间；超时后网关按 `deny` 处理并发送
  `permission.resolved`。

客户端回答：

```json
{
  "type": "permission.respond",
  "requestId": "p-3",
  "decision": "allow_once"
}
```

| `decision` | 含义 |
| --- | --- |
| `allow_once` | 只批准这一次请求 |
| `allow_task` | 当前任务内不再询问 |
| `allow_session` | 当前会话内不再询问 |
| `deny` | 拒绝这一次请求 |

未知 `decision` 值是错误（`invalid_event`），不能按批准处理。网关随后用同一个
`requestId` 发送 `permission.resolved`：

| 字段 | 含义 |
| --- | --- |
| `requestId` | 被解决的请求 |
| `decision` | 最终生效的 `decision` |
| `source` | `client`、`timeout`、`policy`（客户端未声明能力或命中会话授权）、`cancelled`（用户打断） |

`allow_task` / `allow_session` 是网关侧的承诺：后续同类请求由网关直接按同一决定
回答，客户端不会再看到 `permission.request`，但会看到 `source = "policy"` 的
`permission.resolved`。授权范围只影响当前连接；重连后的新会话重新询问。

被拒绝的操作会作为工具结果返回给实时模型，由模型向用户解释；网关不会替用户执行
任何操作，也不会把拒绝当成批准。

## 断线与重连

- 上游断开时，网关先发 `error`（`code = "provider_unavailable"`，
  `retryable = true`），再关闭 WS。
- 不可恢复的错误（如 `provider_auth_failed`）`retryable = false`，客户端不应重试。
- 网关不做透明重放：重连是一条新连接、新会话、新 `sessionId`，之前的
  未播放音频和未完成回复都会丢失。
- 客户端自行 `session.close` 或主动断开时，服务端不保证发出 `error`。
- 网关保证一个 WS 连接对应一个上游连接；客户端断开时上游连接必须关闭。

以上四条由 `gateway/integration_test.mbt` 锁定（上游关闭、客户端关闭、打断顺序）。

## 音频约定

| 方向 | 编码 | 采样率 | 声道 | 分块 |
| --- | --- | --- | --- | --- |
| 上行 | PCM16 little-endian | 16 kHz | 1 | 20–100 ms |
| 下行 | PCM16 little-endian | 24 kHz | 1 | 由服务端决定 |

- 浏览器客户端负责用 WebAudio 重采样；网关不做隐式重采样。
- 网关必须在 `error.message` 中说明格式不匹配的具体字段，不能只说“invalid audio”。
- 打断后，服务端必须停止发送旧回复的 `audio.delta`；客户端收到 `session.interrupt`
  的确认前可以丢弃本地待播放缓冲。
- 16 kHz / 24 kHz 常量由 `realtime/dashscope_test.mbt` 锁定；上游 wire 细节见
  [providers/dashscope.md](providers/dashscope.md)，不属于本契约。

## 错误码

| `code` | 可重试 | 含义 |
| --- | --- | --- |
| `handshake_required` | 否 | 握手前发送了业务事件 |
| `unsupported_version` | 否 | 主版本不兼容 |
| `invalid_event` | 否 | JSON 或字段不合法 |
| `audio_format_unsupported` | 否 | 采样率/编码/声道不支持 |
| `provider_unavailable` | 是 | 上游实时服务不可用 |
| `provider_auth_failed` | 否 | 上游鉴权失败 |
| `session_limit` | 是 | 并发会话超限 |
| `internal_error` | 是 | 未分类的服务端错误 |

## 明确不在契约内

- 内部包名、模块划分、文件布局。
- 上游 provider 的原始 JSON、事件名、错误文本。
- 日志格式、指标名称、追踪字段。
- 视频编解码、传输与渲染细节（P4 之前）。
- 桌面壳、移动端、原生回声消除（P2 之后再评估）。
