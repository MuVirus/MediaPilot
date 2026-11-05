# LLM backend

本页只回答一个问题：`backend/` 里的 LLM adapter 怎么工作，以及它不做什么。

验证环境：MoonBit `0.1.20261029`，DashScope compatible-mode，
模型 `qwen-plus`。验证程序是 `cmd/llm-smoke`，它只打印流式 delta 和最终文本，
不打印 key。

## 定位

这是 **`BackendPort` 的一致性基线**，不是 agent。它证明端口的
`submit` / 流式输出 / `cancel` / `close` 形状是对的，并且可以离线用假 HTTP server
测。工具调用和权限流程由 ACP backend 承担。

参考项目里对应的是 `backend/adapters/llm/backend-adapter.mjs`，
同样刻意最小：`stream: false`、`authorization: false`、`delegation: false`。

## 接口

```text
POST {base_url}/chat/completions
Authorization: Bearer <DASHSCOPE_API_KEY>
Content-Type: application/json
Accept: text/event-stream
```

请求体：

```json
{
  "model": "qwen-plus",
  "stream": true,
  "messages": [
    { "role": "system", "content": "..." },
    { "role": "user", "content": "..." }
  ]
}
```

响应是标准 SSE：

```text
data: {"choices":[{"delta":{"content":"你"}}]}
data: {"choices":[{"delta":{"content":"好"}}]}
data: [DONE]
```

适配器逐行读取，提取 `choices[0].delta.content`，每个非空 delta 发一个
`BackendEvent::TextDelta`，结束时发 `TextDone` 和 `Completed`。

## 事件

| 时机 | 事件 |
| --- | --- |
| 收到非空 delta | `TextDelta(text)` |
| `[DONE]` 或流结束 | `TextDone(text)`，内容是本轮完整文本 |
| 正常结束 | `Completed` |
| HTTP 401/403 | `Failed(ProviderAuthFailed, retryable=false)` |
| HTTP 429/5xx | `Failed(ProviderUnavailable, retryable=true)` |
| 其他非 200 | `Failed(InvalidEvent, retryable=false)` |
| 流内 `{"error":{...}}` | `Failed(ProviderUnavailable, ...)` |
| 网络/流读取失败 | `Failed(ProviderUnavailable, ...)` |

`submit` 会一直运行到任务结束，并在这期间把事件推进内部有界队列（容量 64）。
调用方如果要在任务执行时观察进度，就并发地跑 `submit` 和 `next_event`。

## 不做什么

- 不拼接对话历史：每次 `submit` 只发 system + 一条 user 消息。多轮上下文属于网关。
- 不支持工具：`respond_tool` 和 `respond_permission` 是空实现。
- 不做重试：`Failed.retryable` 只是告诉调用方能不能重试。
- 不读取 provider 原始错误文本以外的字段，也不会把 key 放进事件。

## 配置

| 环境变量 | 默认值 |
| --- | --- |
| `MEDIAPILOT_LLM_BASE_URL` | `https://dashscope.aliyuncs.com/compatible-mode/v1` |
| `MEDIAPILOT_LLM_MODEL` | `qwen-plus` |
| `MEDIAPILOT_LLM_SYSTEM` | `You are a concise voice assistant. Answer in one short sentence.` |

`DASHSCOPE_API_KEY` 与 realtime 共用。base URL 换掉就是另一个 OpenAI 兼容 provider，
适配器本身不需要改。

## 测试

`backend/llm_test.mbt` 用假的 `@http.Server` 覆盖：

- 多 delta 累积成完整文本
- `TextDone` 带完整文本
- 401 映射成不可重试的鉴权错误
- 500 映射成可重试的上游错误
- 流内 error 载荷
- `close` 后 `next_event` 返回 `None`

真实端点的流式行为由 `cmd/llm-smoke` 验证，不进 CI。
