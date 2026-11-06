# MediaPilot

MoonBit 原生的实时音视频网关，当前聚焦实时音频。浏览器负责麦克风与播放，网关负责会话、协议和
可替换的实时音视频 provider。

状态：P2 已完成，P3 进行中。实时音频 + agent backend 可以本地试用，尚不能用于生产。
视频在 P4。

当前能力：DashScope Realtime 音频往返、打断、浏览器客户端；`delegate_task` 异步
委托给 LLM/ACP backend，受理时先语音确认，完成后另起一轮播报结果；后台权限请求
可转交客户端批准。模型还能查询任务状态或取消任务。任务执行期间用户仍可继续说话
或打断。网关支持可配置的并发会话上限和可选 token 鉴权。

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
New-Item -ItemType Directory -Force .media_pilot
Copy-Item .env.example .media_pilot/config.env   # 填入 DASHSCOPE_API_KEY
moon run cmd/main --target native
```

网关不需要先手工注入环境变量：启动时会按下面的顺序查找配置目录，并读取其中的
`config.env`。

1. `MEDIAPILOT_CONFIG_DIR` 指定的目录
2. 当前工作目录下的 `.media_pilot`
3. 用户目录下的 `.media_pilot`（例如 `~/.media_pilot`）

旧布局的 `.env.local` / `.env` 仍会读取，但优先级低于 `config.env`；进程环境变量
始终最高。缺失 API key、非法 `MEDIAPILOT_BIND`、非法上限或找不到配置的 ACP 命令
会在启动时报错退出，而不是带病运行。

然后打开 <http://127.0.0.1:8787/>，点“开始”授权麦克风即可对话。页面必须通过
`127.0.0.1` 访问，否则浏览器不会授予麦克风权限。

网关提供：

- `GET /api/health` — 协议版本、能力列表、当前会话数与上限
- `WS /api/realtime` — 实时音频会话
- `GET /` — 参考浏览器客户端（`web/`）

### 并发与鉴权

- `MEDIAPILOT_MAX_SESSIONS`（默认 `16`）限制并发会话。每个会话占用一个上游连接；
  用 ACP backend 时还会占用一个 agent 进程。超限的连接在发送 `session.hello` 后会收到
  `session_limit` 错误然后关闭，已有会话不受影响。
- `MEDIAPILOT_MAX_TASKS`（默认 `4`）限制每个会话排队中的 `delegate_task` 数量。
- 设置 `MEDIAPILOT_AUTH_TOKEN` 后，`WS /api/realtime` 要求
  `Authorization: Bearer <token>` 或 `?token=<token>`；不匹配返回 HTTP `401`。
  浏览器客户端从地址栏读取 `?token=`。`GET /api/health` 和静态资源不需要鉴权。
- token 只用于准入，不是多租户身份；所有会话仍共享同一套 provider 和 ACP 工作目录。

### 真实连接 DashScope（无浏览器）

```sh
moon run cmd/dashscope-smoke --target native
```

`cmd/dashscope-smoke` 会连接 DashScope、发送 `session.update`、跑一次文本轮次、
一次打断探测和一次音频轮次，只打印事件类型与转写文本，不打印 key 和音频内容。
它目前只读进程环境变量：先从 `.media_pilot/config.env`（或旧 `.env.local`）把值
注入进程，例如在 PowerShell 里 `Set-Item Env:DASHSCOPE_API_KEY ...`。

## 设计来源

架构和协议设计参考 [`qwen-audio-agent`](https://github.com/QwenAudio/qwen-audio-agent)
（Apache-2.0）。MediaPilot 是 MoonBit 重实现，不包含其源码；派生部分会保留
`NOTICE` 与署名。

## License

Apache-2.0，见 [LICENSE](LICENSE)。
