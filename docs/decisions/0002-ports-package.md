# 0002 — `ports/` 作为 gateway 与 provider 之间的接缝

状态：已采纳（P1）

## 背景

`AGENTS.md` 规定 `gateway/` 只能依赖 `protocol/`，`realtime/` 也只能依赖
`protocol/`。两者是兄弟包，互不 import。但网关必须调用上游 provider，provider
必须把事件交回网关。

如果让 `gateway/` 直接 import `realtime/`，provider 的 wire 细节就有机会渗进网关；
如果让 `realtime/` import `gateway/`，依赖方向就反了。

## 决定

新增 `ports/` 包，只放 trait 和跨边界的数据类型：

- `RealtimeProvider`：`send_audio`、`send_text`、`interrupt`、`close`、
  `next_event`、`input_sample_rate`、`output_sample_rate`。
- `ProviderFailure`：`code`、`message`、`retryable`，已经是契约语言。

`gateway/` 依赖 `ports/`，`realtime/` 实现 `ports/`，`cmd/` 负责把两者接起来。
`ports/` 只依赖 `protocol/`，不依赖任何传输或 provider。

## 为什么不把 trait 放进 `protocol/`

`protocol/` 必须能编译到 wasm，且只描述 wire。async trait 会把传输语义带进去，
破坏“协议包无 IO”的约束。

## 为什么不把 trait 放进 `gateway/`

那样 `realtime/` 就要 import `gateway/`，依赖方向反转，且 provider 会看到会话
生命周期细节。

## 后果

- 新增一个包，`AGENTS.md` 与 `docs/architecture.md` 的依赖表同步更新。
- 加第二个 provider 时不需要改 `gateway/`。
- `ports/` 的 trait 变更会影响所有 provider，必须谨慎并补测试。
