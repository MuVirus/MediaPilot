# MediaPilot

MoonBit 原生的实时音视频网关，当前聚焦实时音频。浏览器负责麦克风与播放，网关负责会话、协议和
可替换的实时音视频 provider。

状态：P2，实时音频 + agent backend。可以本地试用，尚不能用于生产。视频在 P4。

当前能力：DashScope Realtime 音频往返、打断、浏览器客户端；`delegate_task` 异步
委托给 LLM/ACP backend，受理时先语音确认，完成后另起一轮播报结果；后台权限请求
可转交客户端批准。任务执行期间用户仍可继续说话或打断。

## 读什么

- [文档索引](docs/README.md)
- [网关契约](docs/contract.md) — 客户端唯一可以依赖的承诺
- [架构](docs/architecture.md) — 分层、依赖方向、会话生命周期
- [路线图](docs/roadmap.md) — P0–P4 与退出条件
- [DashScope wire](docs/providers/dashscope.md) — 已验证的上游行为

## 快速开始

需要 MoonBit `0.1.20261104` 或更新版本。

```sh
moon check --target native
moon test --target native
```

### 运行网关与浏览器客户端

```sh
Copy-Item .env.example .env.local   # 填入 DASHSCOPE_API_KEY
moon run cmd/main --target native
```

然后打开 <http://127.0.0.1:8787/>，点“开始”授权麦克风即可对话。页面必须通过
`127.0.0.1` 访问，否则浏览器不会授予麦克风权限。

网关提供：

- `GET /api/health` — 协议版本与能力列表
- `WS /api/realtime` — 实时音频会话
- `GET /` — 参考浏览器客户端（`web/`）

### 真实连接 DashScope（无浏览器）

```sh
moon run cmd/dashscope-smoke --target native
```

`cmd/dashscope-smoke` 会连接 DashScope、发送 `session.update`、跑一次文本轮次、
一次打断探测和一次音频轮次，只打印事件类型与转写文本，不打印 key 和音频内容。
环境变量需要先注入到进程里（例如在 PowerShell 中读取 `.env.local` 后
`Set-Item Env:`）。

## 设计来源

架构和协议设计参考 [`qwen-audio-agent`](https://github.com/QwenAudio/qwen-audio-agent)
（Apache-2.0）。MediaPilot 是 MoonBit 重实现，不包含其源码；派生部分会保留
`NOTICE` 与署名。

## License

Apache-2.0，见 [LICENSE](LICENSE)。
