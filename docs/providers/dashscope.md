# DashScope Realtime

本页只回答一个问题：DashScope Realtime 的 wire 行为是什么，以及 `realtime/` 如何映射它。

验证环境：MoonBit `0.1.20261029`，Windows，端点
`wss://dashscope.aliyuncs.com/api-ws/v1/realtime`。验证程序是
`cmd/dashscope-smoke`（音频往返）和 `cmd/dashscope-tools-probe`（function calling），
它们只打印事件类型、工具参数和转写文本，不打印 key 和音频内容。

## 模型能力

官方文档说 Qwen-Audio-Realtime 和 Qwen-Omni-Realtime 两个系列都支持工具调用，
实测基本成立，但**有一个模型例外**，而且 `turn_detection` 必须按系列选：

| 模型 | function calling | `turn_detection` | 默认 voice |
| --- | --- | --- | --- |
| `qwen-audio-3.1-realtime-plus` | 是（文本 + 语音均验证） | `smart_turn_v2` | `longanqian_v3.1` |
| `qwen-audio-3.1-realtime-flash` | **否**（见下） | `smart_turn_v2` | `longanqian_v3.1` |
| `qwen-audio-3.0-realtime-plus` | 是 | `smart_turn_v2` | `longanqian` |
| `qwen-audio-3.0-realtime-flash` | 是 | `smart_turn_v2` | `longanqian` |
| `qwen3.5-omni-flash-realtime` | 是 | `semantic_vad` | `Ethan` |
| `qwen3.5-omni-plus-realtime` | 是 | `semantic_vad` | `Ethan` |
| `qwen3.8-omni-flash-realtime` | 是 | `semantic_vad` | `Tina` |

两个坑，都是实测出来的：

1. **`qwen-audio-3.1-realtime-flash` 带 `tools` 会静默失败。** `session.update` 返回
   `session.updated`，看起来接受了，但之后每次生成都以
   `response.done.status = "failed"` 结束，`reason` 是
   `An internal error occurred while generating the response.`，音频和转写都是空的。
   连"你好"这种不会触发工具的问题也一样，连续三次稳定复现。
   同系列的 `3.1-plus`、`3.0-plus`、`3.0-flash` 都正常，所以这是**单个模型**的问题，
   不是系列限制。选型时避开它即可。
2. **omni 模型用 `smart_turn_v2` 时音频轮次不会提交。** 用户转写 delta 会到，
   但没有 `speech_stopped` / `committed`，也就没有回复。换成 `semantic_vad` 后
   完整轮次正常。

诊断技巧：如果 `instructions` 里要求调用某个工具，但 `session.update` 没带 `tools`，
模型会把 `<tool_call>` 当普通文本念出来。看到这个字符串就说明工具没注册成功。

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
| `response.created` | `ResponseStarted`（仅用于跟踪是否有活动回复） |
| `response.function_call_arguments.done` | `FunctionCall(call_id, name, arguments)` |
| `response.done` | `TurnComplete` |
| `error` | `Error`（鉴权类不可重试） |
| 其他 | `None`，调用方忽略 |

`input_audio_buffer.speech_stopped`、`input_audio_buffer.committed`、
`conversation.item.created`、`response.audio.done` 等只用于观测，不产生北向事件。

## Function calling

工具定义用 OpenAI 风格：

```json
{
  "type": "function",
  "function": {
    "name": "get_current_time",
    "description": "...",
    "parameters": { "type": "object", "properties": {}, "additionalProperties": false }
  }
}
```

调用流程（`qwen3.5-omni-flash-realtime` 实测）：

```text
response.created
response.output_item.added
response.function_call_arguments.done   name=get_current_time call_id=call_... arguments={}
response.output_item.done
response.done
```

注意 `response.done` 在工具调用后**立即**到达，此时 `status` 是 `completed`，
没有音频。工具结果必须用 `conversation.item.create` 注入：

```json
{
  "type": "conversation.item.create",
  "item": {
    "type": "function_call_output",
    "call_id": "call_...",
    "output": "{\"status\":\"ok\",...}"
  }
}
```

然后发 `response.create`，模型才会把结果说出来。`output` 是**字符串**，不是对象。

`qwen3.8-omni-flash-realtime` 和 `qwen-audio-3.1-realtime-plus` 还会额外发
`response.function_call_arguments.delta`，但 `arguments` 在 `.done` 里才是完整的。

语音输入路径同样成立：`qwen-audio-3.1-realtime-plus` 在
`speech_stopped` → `committed` → `response.created` 之后直接发
`response.function_call_arguments.done`，注入结果后正常播报。

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

**空闲时不能无条件 cancel**：没有进行中的回复时发送 `response.cancel`，服务端返回
`error`，消息是 `Conversation has no active response.`。这会被映射成
`provider_unavailable`，让客户端误以为需要重连。适配器必须记录
`response.created` / `response.done` 之间的状态，只在有活动回复时取消。

`input_audio_buffer.clear` 在服务端 VAD 下也不需要随打断发送：输入音频已经由
`speech_stopped` 自动提交，clear 只会影响用户正在说的内容。

## 已知限制

- 一个会话只有一个 response slot。并发 `response.create` 会被拒绝，
  错误文本包含 `another response is in progress`。
- 上行节奏影响 VAD 判定，网关必须做实时节流，不能攒批发送。
- 模型名与 voice 列表随服务端更新，`invalid_value` 错误会返回当前合法值。
