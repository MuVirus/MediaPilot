# 架构

## 一句话

一个 MoonBit 原生进程同时提供静态 Web 客户端和 `WS /api/realtime`，把浏览器或原生客户端的
音频、文本（以及 P4 的视频）转成统一事件，交给可替换的实时 provider，并把结果归一化后推回客户端。

```text
Browser / Native client
        │  WS JSON (provider-neutral)
        ▼
┌──────────────────────────────────────────────┐
│ gateway/                                     │
│  HTTP static + /api/health + /api/realtime   │
│  session lifecycle · capability negotiation  │
│  event routing · backpressure · reconnect    │
└───────────────┬──────────────────────────────┘
                │ normalized events
       ┌────────┴─────────┐
       ▼                  ▼
┌──────────────┐   ┌──────────────┐
│ realtime/    │   │ backend/     │
│ DashScope    │   │ LLM / ACP    │
│ OpenAI …     │   │ MCP tools    │
└──────┬───────┘   └──────┬───────┘
       │ provider wire     │ tool calls
       ▼                  ▼
   Upstream APIs      Agent runtimes
```

## 包边界

| 包 | 职责 | 禁止 |
| --- | --- | --- |
| `protocol/` | 事件类型、JSON 编解码、版本与能力常量、错误码 | 网络、文件、provider、backend |
| `ports/` | 连接 `gateway/` 与 provider/backend 的 trait | 具体实现、网络 |
| `gateway/` | 连接、会话、路由、静态资源、健康检查 | 直接拼接 provider 报文 |
| `realtime/` | provider 适配器与事件映射 | 感知客户端 wire 细节 |
| `backend/` | `BackendPort` 与 LLM/ACP/MCP 适配器 | 感知音频传输 |
| `audio/` | 采集、播放、重采样 | 感知会话业务 |
| `cmd/` | 组装依赖、读配置、启动 | 业务分支 |

依赖方向：`cmd → gateway/realtime/backend/audio → ports → protocol`。
`protocol/` 不依赖任何其他包，这样它才能同时编译到 native 和 wasm。
`gateway/` 与 `realtime/` 是兄弟包，互不 import，只共享 `ports/` 的 trait。

## 为什么 provider 和 gateway 要分开

实时音视频 provider 的差异不只在 URL 和鉴权，还在：

- 事件模型（增量转写、音频 delta、turn 边界）
- 音频格式与分块
- 打断语义（有的 provider 需要显式 cancel，有的靠新输入覆盖）
- 会话保活与重连

如果这些差异渗进 `gateway/`，每加一个 provider 就要改客户端协议。因此：

1. `realtime/` 定义一套归一化事件（与 `protocol/` 的服务端事件同名同形）。
2. 每个 adapter 只负责 `provider JSON ⇄ normalized event`。
3. `gateway/` 只转发归一化事件，永远不知道 provider 是谁。
4. provider 的原始错误必须映射到 [contract.md](contract.md) 的错误码，原始文本只进日志。

## 视频的位置

音视频共用同一套会话、能力协商和事件模型，但**视频不在当前实现范围内**。

- 不为视频提前建 `video/` 包，也不提前引入编解码依赖。
- P4 时视频仍走 `realtime/` 适配器边界：provider 原始帧不出适配器。
- 传输选型（WebRTC、WebCodecs、WS + 编码帧）单独写 ADR，不在音频阶段预设。
- 契约先不加视频事件；加了才升版本并补 `Locked by` 测试。

## 会话生命周期

```text
connect → session.hello → session.ready → streaming → session.close
                │                            │
                └── unsupported_version ─────┘
                                             └── provider_unavailable → 关闭或重连
```

- 一个 WS 连接对应一个会话，一个会话对应一个上游连接。
- 客户端断开时，网关必须关闭上游连接；不能留下孤儿会话。
- 上游断开时，向客户端发 `error`（`provider_unavailable`, `retryable = true`），
  由客户端决定是否重连。网关不做透明重放，避免重复计费和重复朗读。
- 会话内不做跨连接恢复；P1 只保证“重连后是新会话”。

## 后台任务

`delegate_task` 是异步受理：provider 读取协程收到工具调用后立刻回受理回执，不等待
backend。真正的执行在独立的 `tool_runner` 协程里串行进行，完成后通过
`send_background_result` 注入一个新的实时轮次并播报。这样 provider 读取不会被阻塞，
用户可以在任务执行期间继续说话、打断或派新任务。

打断会推进一个会话内 generation；已受理但未开始的任务、以及被打断的当前任务都不会
再产生迟到的结果播报。

## 背压与打断

- 下发方向：`audio.delta` 走有界队列（256 条）。客户端读得太慢时，上游读取
  协程被阻塞，不会无限占内存。
- 上行方向：网关逐帧读取并等待上游写入完成，超量数据由 TCP 接收缓冲和上游
  写入速度限制；进程内不为上行音频额外排队。
- `session.interrupt` 的顺序固定：取消上游当前回复 → 丢弃网关待发送队列中属于
  该回复的 `audio.delta` → 向客户端回 `playback.clear`（`reason = "client_interrupt"`）。
- 下行 `audio.delta` 只保证会话内顺序，不保证与转写事件严格交错。

## 目标与平台

- 主目标：`native`。WebSocket 服务、音频设备、进程管理都在 native。
- `protocol/` 与浏览器客户端产物：`wasm` 可用，但 P0 不追求 wasm 网关。
- 浏览器负责采集/播放和重采样；网关不做隐式重采样。
- 原生客户端的回声消除、降噪、自动增益在 P2 之后评估，先用浏览器 WebAudio 规避。
- 视频传输与渲染在 P4 单独选型；音频阶段只送 PCM。

## 失败处理原则

1. 能降级就降级：缺能力时不发该能力的事件，而不是报错退出。
2. 能重试就标清楚：`error.retryable` 是客户端唯一依据。
3. 不吞错：所有 `internal_error` 必须带可检索的日志 ID。
4. 不泄漏：日志里不出现 API key、Authorization、完整音频。
