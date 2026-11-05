# Roadmap

阶段按“可验证的退出条件”划分，不按日期。上一阶段退出条件没满足，不进入下一阶段。

当前主线是实时音频；视频在 P4，不提前引入传输或编解码依赖。

## P0 — 音频与 provider spike

目标：证明 MoonBit 能在本机完成一次 DashScope Realtime 往返。

- [x] `protocol/`：事件类型、JSON 编解码、能力常量，附往返测试。
- [x] `realtime/`：`ProviderEvent` 归一化 + DashScope wire 骨架（URL、鉴权头、音频格式、事件映射）。
- [x] 连接 DashScope，发送 16 kHz PCM，收到 24 kHz PCM。见 `cmd/dashscope-smoke` 与 [providers/dashscope.md](providers/dashscope.md)。
- [x] 打断：`response.cancel` 后服务端停止音频并补发收尾事件。
- [x] 浏览器最小客户端：麦克风 → WS → 播放，能打断。见 `web/`。
- [ ] 记录首字延迟、端到端延迟、断线行为，写进 `docs/decisions/` 或本页。
- [ ] 失败也要有结论：若 MoonBit async/WS 不可用，记录替代方案和影响范围。

P0 已验证的事实：

- `moonbitlang/core/async/websocket` 在 Windows 上可以完成 `wss://` 连接、TLS 握手和文本帧收发。
- 一次完整语音轮次（VAD → 用户转写 → 助手音频 + 转写）在 MoonBit 进程内跑通，无 Node/Python 中间层。
- 上行必须按实时节奏发送；一次性灌入整段音频时服务端 VAD 不会判定轮次结束。
- 浏览器参考客户端在 Edge headless + 假麦克风下完成握手、采集、文本轮次、10.6s 下行音频与转写渲染。

退出条件：本机一次完整“说话 → 转写 → 回复音频”跑通，且不依赖 Node/Python 中间层。

## P1 — Gateway MVP

目标：一个可被外部客户端依赖的稳定北向协议。

- [x] `gateway/`：`GET /api/health`、`WS /api/realtime`。
- [x] 握手、能力协商、错误码按 `docs/contract.md` 实现。
- [x] 会话生命周期、上游断线处理、背压上限（有界出站队列）。
- [x] 契约测试：事件 schema、握手、未知事件忽略、错误码映射。
- [x] 静态客户端托管（`web/`，显式白名单，无路径穿越）。
- [x] 浏览器客户端作为参考实现，覆盖采集、播放、打断、重连。
- [x] 上游断开映射为 `provider_unavailable` + `retryable = true`，客户端指数退避重连。
- [x] 客户端打断：丢弃待发送队列并回 `playback.clear` 确认。

退出条件：`contract.md` 中 P1 相关承诺全部有 `Locked by` 测试；
第三方按文档能写一个最小客户端。

## P2 — Agent backend 与权限

目标：语音不只是聊天，而是能调用工具、需要授权的代理。

- [x] `BackendPort`：`submit` / `cancel` / `respond_tool` / `respond_permission` / `next_event` / `close`。
- [x] LLM backend：OpenAI 兼容 `/chat/completions`，SSE 流式输出，错误映射。
- [ ] ACP backend：JSON-RPC over stdio，先接 `opencode acp`。
- [ ] realtime 侧注册 `delegate_task` 工具，把工具调用转给 `BackendPort`。
- [ ] 工具结果回注 realtime 会话并播报。
- [ ] 权限请求进入北向事件（`task.updated` / 授权事件）。
- [ ] 会话级授权范围（once / task / session）与超时。
- [ ] 审计日志：谁、在哪个会话、批准了什么。

退出条件：一个需要用户授权的工具调用可以完整走完“请求 → 批准 → 执行 → 播报”。

P2 已验证的事实：

- `qwen-audio-3.1-realtime-plus` 支持 function calling，文本和语音路径都跑通了
  “工具调用 → 结果注入 → 播报”。
- DashScope compatible-mode 支持 SSE 流式输出，`backend/` 能逐 delta 读取。
- 参考项目的模型目录不含 `qwen-audio-3.1-realtime-flash`；该模型带 `tools` 会稳定失败。

## P3 — 产品化

- [ ] 配置加载与校验、启动自检、缺失配置的明确报错。
- [ ] 结构化日志、指标、健康检查分级。
- [ ] 打包与分发（单文件二进制优先）。
- [ ] 并发会话上限与资源回收。
- [ ] 桌面壳评估（Electron/Tauri 仅作为客户端，不进入核心）。

退出条件：非开发者按 README 能在 10 分钟内跑起来并完成一次对话。

## P4 — 扩展

- [ ] 第二个实时 provider（OpenAI 或 Gemini），验证抽象是否成立。
- [ ] 图像/视觉输入。
- [ ] 摄像头/屏幕视频：先写传输与编解码 ADR，再实现。
- [ ] 原生客户端音频前处理（AEC/NS/AGC）。
- [ ] 多语言文档与文档站点（仅当文档量与外部需求成立）。

## 明确不做

- 自研语音模型。
- 在音频阶段自研 WebRTC 栈（音频先用 WS + PCM；视频阶段重新评估）。
- 插件市场、多租户计费、移动端原生壳。
- 为了“和参考项目一样”而复制其全部 238 个源文件。
