///|
fn test_config() -> @realtime.ProviderConfig {
  @realtime.ProviderConfig::{
    api_key: "test-key",
    model: "qwen3-omni-flash-realtime",
    endpoint: @realtime.dashscope_default_endpoint,
    voice: "Cherry",
  }
}

///|
test "connect url selects the model" {
  let provider = @realtime.DashScopeProvider::new(test_config())
  assert_eq(
    provider.connect_url(),
    "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-omni-flash-realtime",
  )
  assert_eq(provider.auth_header(), "Bearer test-key")
}

///|
test "connect url keeps an existing query" {
  let provider = @realtime.DashScopeProvider::new(@realtime.ProviderConfig::{
    api_key: "k",
    model: "m",
    endpoint: "wss://example.test/realtime?workspace=w",
    voice: "",
  })
  assert_eq(
    provider.connect_url(),
    "wss://example.test/realtime?workspace=w&model=m",
  )
}

///|
test "audio delta uses the provider output rate by default" {
  let decoded = @realtime.normalize_incoming(
    "{\"type\":\"response.audio.delta\",\"delta\":\"AAEC\"}",
  ).unwrap()
  assert_eq(
    decoded,
    Some(@realtime.ProviderEvent::AudioDelta(delta="AAEC", sample_rate=24000)),
  )
}

///|
test "audio delta honours an explicit sample rate" {
  let decoded = @realtime.normalize_incoming(
    "{\"type\":\"response.output_audio.delta\",\"delta\":\"AAEC\",\"sampleRate\":48000}",
  ).unwrap()
  assert_eq(
    decoded,
    Some(@realtime.ProviderEvent::AudioDelta(delta="AAEC", sample_rate=48000)),
  )
}

///|
test "assistant transcript delta and done" {
  let partial = @realtime.normalize_incoming(
    "{\"type\":\"response.audio_transcript.delta\",\"delta\":\"hel\"}",
  ).unwrap()
  assert_eq(
    partial,
    Some(
      @realtime.ProviderEvent::TranscriptPartial(role="assistant", text="hel"),
    ),
  )
  let final = @realtime.normalize_incoming(
    "{\"type\":\"response.audio_transcript.done\",\"transcript\":\"hello\"}",
  ).unwrap()
  assert_eq(
    final,
    Some(
      @realtime.ProviderEvent::TranscriptFinal(role="assistant", text="hello"),
    ),
  )
}

///|
test "user transcription events use the user role" {
  let final = @realtime.normalize_incoming(
    "{\"type\":\"conversation.item.input_audio_transcription.completed\",\"transcript\":\"你好\"}",
  ).unwrap()
  assert_eq(
    final,
    Some(@realtime.ProviderEvent::TranscriptFinal(role="user", text="你好")),
  )
}

///|
test "speech start maps to interrupt" {
  let decoded = @realtime.normalize_incoming(
    "{\"type\":\"input_audio_buffer.speech_started\"}",
  ).unwrap()
  assert_eq(decoded, Some(@realtime.ProviderEvent::Interrupted))
}

///|
test "auth errors are not retryable" {
  let decoded = @realtime.normalize_incoming(
    "{\"type\":\"error\",\"error\":{\"code\":\"InvalidApiKey\",\"message\":\"Incorrect API key provided\"}}",
  ).unwrap()
  assert_eq(
    decoded,
    Some(
      @realtime.ProviderEvent::Error(
        code=@protocol.ErrorCode::ProviderAuthFailed,
        message="Incorrect API key provided",
        retryable=false,
      ),
    ),
  )
}

///|
test "unknown provider events are ignored" {
  let expected : @realtime.ProviderEvent? = None
  let decoded = @realtime.normalize_incoming(
    "{\"type\":\"response.something.new\"}",
  ).unwrap()
  assert_eq(decoded, expected)
}

///|
test "outgoing frames use the provider wire format" {
  let encoded = @realtime.encode_audio_append("AAEC").stringify()
  assert_true(encoded.contains("\"input_audio_buffer.append\""))
  assert_true(encoded.contains("\"audio\":\"AAEC\""))
}
