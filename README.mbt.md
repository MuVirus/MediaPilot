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
Copy-Item .media_pilot\config.example.env .media_pilot\config.env   # 填入 DASHSCOPE_API_KEY
moon run cmd/main --target native
```

网关不需要先手工注入环境变量：启动时会从**当前工作目录**的 `.media_pilot` 读取
`config.env`，没有本地文件时回退到用户目录的 `.media_pilot`。

1. `MEDIAPILOT_CONFIG_DIR` 指定的目录
2. 当前工作目录下的 `.media_pilot`
3. 用户目录下的 `.media_pilot`（例如 `~/.media_pilot`）

本地配置优先；同名 key 以本地为准，缺失的 key 再回退到用户级配置。进程环境变量
始终最高。网关不会向上寻找项目根，所以应从希望读取其 `.media_pilot` 的目录启动。
缺失 API key、非法 `MEDIAPILOT_BIND`、非法上限或找不到配置的 ACP 命令会在启动时
报错退出，而不是带病运行。

然后打开 <http://127.0.0.1:8787/>，点“开始”授权麦克风即可对话。页面必须通过
`127.0.0.1` 访问，否则浏览器不会授予麦克风权限。

网关提供：

- `GET /api/health` — 协议版本、能力列表、当前会话数与上限
- `GET /api/fs/roots` — 文件系统浏览起点和默认工作目录（有 token 时需鉴权）
- `GET /api/fs/list?path=` — 列出某个目录下的一级子目录（有 token 时需鉴权）
- `WS /api/realtime` — 实时音频会话
- `GET /` — 参考浏览器客户端（`web/`）

### 并发与鉴权

- `MEDIAPILOT_MAX_SESSIONS`（默认 `16`）限制并发会话。每个会话占用一个上游连接；
  用 ACP backend 时还会占用一个 agent 进程。超限的连接在发送 `session.hello` 后会收到
  `session_limit` 错误然后关闭，已有会话不受影响。
- `MEDIAPILOT_MAX_TASKS`（默认 `4`）限制每个会话排队中的 `delegate_task` 数量。
- 设置 `MEDIAPILOT_AUTH_TOKEN` 后，`WS /api/realtime` 要求
  `Authorization: Bearer <token>` 或 `?token=<token>`；不匹配返回 HTTP `401`。
  浏览器客户端从地址栏读取 `?token=`。`GET /api/health` 和静态资源不需要鉴权，
  `GET /api/fs/*` 需要。
- token 只用于准入，不是多租户身份。

### 选择 ACP 工作目录

`MEDIAPILOT_BACKEND=acp` 时，agent 在哪个目录里执行任务由客户端在握手时选择：

- 默认目录是 `MEDIAPILOT_ACP_CWD`，未设置时为网关进程启动目录。它必须是绝对路径
  且启动时存在，否则网关拒绝启动。
- 客户端通过 `GET /api/fs/roots` 获取起点（Windows 盘符或 `/`），用
  `GET /api/fs/list?path=` 逐级浏览，最后把选中的绝对路径放进
  `session.hello.workspace`。
- 浏览范围是整个文件系统，没有白名单；路径必须存在且是目录，否则收到
  `workspace_denied` 并关闭连接。
- 一个会话固定一个目录，会话内不能切换；换目录就是重连，旧会话的任务随连接结束。
- 浏览器客户端提供“浏览…”对话框，其他客户端可以复用同样两个端点。

细节见 [docs/backends/acp.md](docs/backends/acp.md) 和
[docs/contract.md](docs/contract.md)。

### 真实连接 DashScope（无浏览器）

```sh
moon run cmd/dashscope-smoke --target native
```

`cmd/dashscope-smoke` 会连接 DashScope、发送 `session.update`、跑一次文本轮次、
一次打断探测和一次音频轮次，只打印事件类型与转写文本，不打印 key 和音频内容。
它目前只读进程环境变量：先从 `.media_pilot/config.env` 把值注入进程，例如在
PowerShell 里 `Set-Item Env:DASHSCOPE_API_KEY ...`。

## 设计来源

架构和协议设计参考 [`qwen-audio-agent`](https://github.com/QwenAudio/qwen-audio-agent)
（Apache-2.0）。MediaPilot 是 MoonBit 重实现，不包含其源码；派生部分会保留
`NOTICE` 与署名。

## License

Apache-2.0，见 [LICENSE](LICENSE)。
