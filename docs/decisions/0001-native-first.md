# ADR 0001：Native-first，浏览器做音频前端

- 状态：已接受
- 日期：2026-11-05
- 相关：[architecture.md](../architecture.md)

## 背景

参考项目 `qwen-audio-agent` 是 Node.js 全栈，音频采集与播放靠浏览器/Electron 的
WebAudio 完成，服务端只处理 PCM 流。MoonBit 侧的情况不同：

- `moonbitlang/async` 提供 native WebSocket server/client，已在 Windows 验证可用。
- `moonbit-community/moon_cpal` 能枚举输入/输出设备，已在 Windows 验证可用。
- 原生音频没有成熟的 AEC、降噪、自动增益；浏览器 WebAudio 天然具备。
- 根模块原先 `preferred_target = "wasm"`，而音频与 socket 依赖 native。

## 决定

1. 网关主目标是 `native`，不是 wasm。
2. P0/P1 的音频前端用浏览器（WebAudio），负责采集、播放、重采样和打断。
3. 网关只接收/发送显式格式的 PCM16，不做隐式重采样。
4. 原生客户端音频前处理推迟到 P2 之后，且必须先有 AEC 方案再动手。
5. `protocol/` 保持可编译到 wasm，便于未来复用类型和浏览器侧校验。

## 后果

- 需要同时维护 MoonBit 网关和一份浏览器客户端，但客户端可以先是最小 HTML/TS。
- 不依赖 Node/Python 中间层，部署是单进程 + 静态文件。
- 原生客户端暂时不是一等公民；这符合 P0/P1 的目标。
- `moon.mod` 的 `preferred_target` 需要改为 `native`，否则默认构建会走错目标。
- 若后续必须原生采集，先做 AEC  spike 并另写 ADR，不要在网关里塞 DSP。
- 本决定只覆盖音频阶段。视频传输（WebRTC/WebCodecs/编码格式）另写 ADR，不在
  P0–P3 预设。
