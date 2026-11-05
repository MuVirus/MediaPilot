# MediaPilot

MoonBit 原生的实时音视频网关，当前聚焦实时音频。浏览器负责麦克风与播放，网关负责会话、协议和
可替换的实时音视频 provider。

状态：P0，协议与 provider spike。当前还不能用于生产。视频在 P4。

## 读什么

- [文档索引](docs/README.md)
- [网关契约](docs/contract.md) — 客户端唯一可以依赖的承诺
- [架构](docs/architecture.md) — 分层、依赖方向、会话生命周期
- [路线图](docs/roadmap.md) — P0–P4 与退出条件

## 快速开始

需要 MoonBit `0.1.20261029` 或更新版本。

```sh
moon check --target native
moon test --target native
moon run cmd/main
```

目前 `cmd/main` 只打印 `Hello`。P0 完成后会启动网关并托管浏览器客户端。

## 设计来源

架构和协议设计参考 [`qwen-audio-agent`](https://github.com/QwenAudio/qwen-audio-agent)
（Apache-2.0）。MediaPilot 是 MoonBit 重实现，不包含其源码；派生部分会保留
`NOTICE` 与署名。

## License

Apache-2.0，见 [LICENSE](LICENSE)。
