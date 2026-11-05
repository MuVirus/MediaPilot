# DashScope Realtime

本页只回答一个问题：DashScope Realtime 的 wire 行为是什么，以及 `realtime/` 如何映射它。

验证环境：MoonBit `0.1.20261029`，Windows，模型 `qwen-audio-3.1-realtime-flash`，
端点 `wss://dashscope.aliyuncs.com/api-ws/v1/realtime`。验证程序是
`cmd/dashscope-smoke`，它只打印事件类型和转写文本，不打印 key 和音频内容。

## 连接

```text
wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=<model>
Authorization: Bearer <DASHSCOPE_API_KEY>
```

- 模型通过 query 参数选择，不在 `session.update` 里。
- 鉴权用标准 `Authorization` 头，不是子协议。
- 连接成功后服务端先发 `session.created`，不需要客户端先说话。

## 会话配置

`session.update` 的最小可用形状：

```json
{
  "type": "session.update",
  "session": {
    "modalities": ["text", "audio"],
    "instructions": "...",
    "voice": "longanqian_v3.1",
    "input_audio_format": "pcm",
    "output_audio_format": "pcm",
    "turn_detection": { "type": "smart_turn_v2" }
  }
}
```

- 成功返回 `session.updated`；字段不合法返回 `error`，`code = "invalid_value"`。
- `voice` 必须在该模型支持的列表内。`qwen-audio-3.1-realtime-flash` 不接受 `Cherry`，
  默认用 `longanqian_v3.1`。错误信息会列出全部合法值，这是排查 voice 问题的最快路径。
- `turn_detection` 用 `smart_turn_v2`。Qwen Audio 3.x 由服务端判定轮次，
  客户端不需要发 `input_audio_buffer.commit`。

## 音频格式

| 方向 | 编码 | 采样率 | 声道 |
| --- | --- | --- | --- |
| 上行 | PCM16 little-endian | 16 kHz | 1 |
| 下行 | PCM16 little-endian | 24 kHz | 1 |

- 上行放在 `input_audio_buffer.append` 的 `audio` 字段，base64 编码。
- 下行在 `response.audio.delta` 的 `delta` 字段，base64 编码。
- 上行必须按实时节奏发送。一次性灌入整段音频时，服务端 VAD 只发
  `speech_started`，不会判定轮次结束。`cmd/dashscope-smoke` 按 100 ms 一块发送。

## 事件流

一次完整的语音轮次，实测顺序：

```text
input_audio_buffer.speech_started
conversation.item.input_audio_transcription.delta   (多次)
input_audio_buffer.speech_stopped
input_audio_buffer.committed
conversation.item.created
response.created
response.output_item.added
conversation.item.created
response.content_part.added
conversation.item.input_audio_transcription.completed
response.audio.delta                                (多次)
response.audio.done
response.content_part.done
response.output_item.done
response.done
```

文本轮次（`conversation.item.create` + `response.create`）走同样的
`response.*` 序列，只是没有 `input_audio_buffer.*` 和用户转写。

助手转写来自 `response.audio_transcript.delta` / `response.audio_transcript.done`，
与音频 delta 并行到达。

## 归一化映射

`realtime/dashscope.mbt` 的 `normalize_incoming` 只输出 `ProviderEvent`：

| provider 事件 | 归一化结果 |
| --- | --- |
| `response.audio.delta`, `response.output_audio.delta` | `AudioDelta`（默认 24 kHz） |
| `response.audio_transcript.delta`, `response.output_audio_transcript.delta`, `response.text.delta` | `TranscriptPartial(role="assistant")` |
| `response.audio_transcript.done`, `response.output_audio_transcript.done`, `response.text.done` | `TranscriptFinal(role="assistant")` |
| `conversation.item.input_audio_transcription.delta`, `.text` | `TranscriptPartial(role="user")` |
| `conversation.item.input_audio_transcription.completed` | `TranscriptFinal(role="user")` |
| `input_audio_buffer.speech_started` | `Interrupted` |
| `response.done` | `TurnComplete` |
| `error` | `Error`（鉴权类不可重试） |
| 其他 | `None`，调用方忽略 |

`input_audio_buffer.speech_stopped`、`input_audio_buffer.committed`、
`conversation.item.created`、`response.audio.done` 等只用于观测，不产生北向事件。

## 打断

`input_audio_buffer.speech_started` 表示用户开始说话，此时应：

1. 停止播放本地缓冲；
2. 丢弃网关待发送的旧 `audio.delta`；
3. 需要显式取消时发 `response.cancel`。

服务端在 `smart_turn_v2` 下会自行处理新轮次，`response.cancel` 主要用于
客户端主动打断（例如按钮）。

实测 `response.cancel` 行为：在第 3 个 `response.audio.delta` 后发送 cancel，
服务端立即停止发送音频，随后补发 `response.audio.done`、`response.content_part.done`、
`response.output_item.done`、`response.done`。也就是说 cancel 之后仍会收到收尾事件，
网关必须按 `response.done` 结束本轮，不能把收尾事件当成新回复。

## 已知限制

- 一个会话只有一个 response slot。并发 `response.create` 会被拒绝，
  错误文本包含 `another response is in progress`。
- 上行节奏影响 VAD 判定，网关必须做实时节流，不能攒批发送。
- 模型名与 voice 列表随服务端更新，`invalid_value` 错误会返回当前合法值。
