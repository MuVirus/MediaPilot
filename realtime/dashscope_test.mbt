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
test "audio contract is 16 kHz in and 24 kHz out" {
  let provider = @realtime.DashScopeProvider::new(test_config())
  assert_eq(provider.input_sample_rate(), 16000)
  assert_eq(provider.output_sample_rate(), 24000)
}

///|
test "known models resolve to their family defaults" {
  let plus = @realtime.resolve_model_profile("qwen-audio-3.1-realtime-plus")
  assert_eq(plus.voice, Some("longanqian_v3.1"))
  assert_eq(plus.turn_detection, "smart_turn_v2")
  assert_true(plus.supports_tools)

  let omni = @realtime.resolve_model_profile("qwen3.5-omni-flash-realtime")
  assert_eq(omni.voice, Some("Ethan"))
  assert_eq(omni.turn_detection, "semantic_vad")
  assert_true(omni.supports_tools)

  let audio30 = @realtime.resolve_model_profile("qwen-audio-3.0-realtime-flash")
  assert_eq(audio30.voice, Some("longanqian"))
  assert_eq(audio30.turn_detection, "smart_turn")
  assert_true(audio30.supports_tools)
}

///|
test "the broken 3.1 flash model is marked as tool-less" {
  let profile = @realtime.resolve_model_profile("qwen-audio-3.1-realtime-flash")
  assert_false(profile.supports_tools)
}

///|
test "unknown models fall back to the conservative profile" {
  let profile = @realtime.resolve_model_profile("some-future-model")
  assert_eq(profile.voice, None)
  assert_eq(profile.turn_detection, @realtime.dashscope_default_turn_detection)
  assert_false(profile.supports_tools)
}

///|
test "session update uses the profile turn detection" {
  let provider = @realtime.DashScopeProvider::new(@realtime.ProviderConfig::{
    api_key: "k",
    model: "qwen3.5-omni-flash-realtime",
    endpoint: @realtime.dashscope_default_endpoint,
    voice: "",
  })
  let parsed = @json.parse(provider.session_update("be brief").stringify())
  let session = match parsed {
    Json::Object(root) =>
      match root.get("session") {
        Some(Json::Object(session)) => session
        _ => panic()
      }
    _ => panic()
  }
  assert_eq(
    session.get("turn_detection"),
    Some(Json::object({ "type": Json::string("semantic_vad") })),
  )
  // An empty configured voice falls back to the model default.
  assert_eq(session.get("voice"), Some(Json::string("Ethan")))
}

///|
test "tools are dropped for models that cannot handle them" {
  let provider = @realtime.DashScopeProvider::new(@realtime.ProviderConfig::{
    api_key: "k",
    model: "qwen-audio-3.1-realtime-flash",
    endpoint: @realtime.dashscope_default_endpoint,
    voice: "",
  })
  let tools = Json::array([@realtime.function_tool("t", "d", Json::object({}))])
  let parsed = @json.parse(
    provider.session_update("be brief", tools~).stringify(),
  )
  let session = match parsed {
    Json::Object(root) =>
      match root.get("session") {
        Some(Json::Object(session)) => session
        _ => panic()
      }
    _ => panic()
  }
  assert_eq(session.get("tools"), None)
}

///|
test "tools are kept for models that support them" {
  let provider = @realtime.DashScopeProvider::new(@realtime.ProviderConfig::{
    api_key: "k",
    model: "qwen-audio-3.1-realtime-plus",
    endpoint: @realtime.dashscope_default_endpoint,
    voice: "",
  })
  let tools = Json::array([@realtime.function_tool("t", "d", Json::object({}))])
  let parsed = @json.parse(
    provider.session_update("be brief", tools~).stringify(),
  )
  let session = match parsed {
    Json::Object(root) =>
      match root.get("session") {
        Some(Json::Object(session)) => session
        _ => panic()
      }
    _ => panic()
  }
  assert_true(session.get("tools") is Some(_))
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
test "user transcription streams text plus stash" {
  let decoded = @realtime.normalize_incoming(
    "{\"type\":\"conversation.item.input_audio_transcription.text\",\"text\":\"你看一下\",\"stash\":\"桌面\"}",
  ).unwrap()
  assert_eq(
    decoded,
    Some(
      @realtime.ProviderEvent::TranscriptPartial(
        role="user",
        text="你看一下桌面",
      ),
    ),
  )
}

///|
test "user transcription falls back to delta" {
  let decoded = @realtime.normalize_incoming(
    "{\"type\":\"conversation.item.input_audio_transcription.delta\",\"delta\":\"你好\"}",
  ).unwrap()
  assert_eq(
    decoded,
    Some(@realtime.ProviderEvent::TranscriptPartial(role="user", text="你好")),
  )
}

///|
test "partial transcripts are cumulative for the client" {
  // User input is cumulative on the wire, assistant output is incremental.
  assert_eq(
    @realtime.merge_partial("user", "你看", "你看一下"),
    "你看一下",
  )
  assert_eq(
    @realtime.merge_partial("user", "你看一下", "你看一下桌面"),
    "你看一下桌面",
  )
  assert_eq(@realtime.merge_partial("assistant", "你", "好"), "你好")
  assert_eq(@realtime.merge_partial("assistant", "你好", "。"), "你好。")
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

///|
test "background result responses disable tools" {
  let encoded = @realtime.encode_response_create_with_instructions(
    "播报结果",
  )
  let parsed = @json.parse(encoded.stringify())
  match parsed {
    Json::Object(root) => {
      assert_eq(root.get("type"), Some(Json::string("response.create")))
      match root.get("response") {
        Some(Json::Object(response)) => {
          assert_eq(
            response.get("instructions"),
            Some(Json::string("播报结果")),
          )
          assert_eq(response.get("tool_choice"), Some(Json::string("none")))
        }
        _ => panic()
      }
    }
    _ => panic()
  }
}

///|
test "session update carries the audio contract" {
  let encoded = @realtime.encode_session_update("longanqian_v3.1", "be brief")
  let parsed = @json.parse(encoded.stringify())
  let session = match parsed {
    Json::Object(root) =>
      match root.get("session") {
        Some(Json::Object(session)) => session
        _ => panic()
      }
    _ => panic()
  }
  assert_eq(
    match parsed {
      Json::Object(root) => root.get("type")
      _ => None
    },
    Some(Json::string("session.update")),
  )
  assert_eq(session.get("voice"), Some(Json::string("longanqian_v3.1")))
  assert_eq(session.get("input_audio_format"), Some(Json::string("pcm")))
  assert_eq(session.get("output_audio_format"), Some(Json::string("pcm")))
  assert_eq(session.get("turn_detection"), None)
}

///|
test "session update adds turn detection when requested" {
  let encoded = @realtime.encode_session_update(
    "longanqian_v3.1",
    "be brief",
    turn_detection="smart_turn_v2",
  )
  let parsed = @json.parse(encoded.stringify())
  let session = match parsed {
    Json::Object(root) =>
      match root.get("session") {
        Some(Json::Object(session)) => session
        _ => panic()
      }
    _ => panic()
  }
  assert_eq(
    session.get("turn_detection"),
    Some(Json::object({ "type": Json::string("smart_turn_v2") })),
  )
}

///|
test "provider session update defaults to server turn detection" {
  let provider = @realtime.DashScopeProvider::new(test_config())
  let encoded = provider.session_update("be brief")
  let parsed = @json.parse(encoded.stringify())
  let session = match parsed {
    Json::Object(root) =>
      match root.get("session") {
        Some(Json::Object(session)) => session
        _ => panic()
      }
    _ => panic()
  }
  assert_eq(
    session.get("turn_detection"),
    Some(
      Json::object({
        "type": Json::string(@realtime.dashscope_default_turn_detection),
      }),
    ),
  )
  assert_eq(session.get("voice"), Some(Json::string("Cherry")))
}

///|
test "commit and clear frames use the provider wire format" {
  assert_eq(
    @realtime.encode_audio_commit().stringify(),
    "{\"type\":\"input_audio_buffer.commit\"}",
  )
  assert_eq(
    @realtime.encode_audio_clear().stringify(),
    "{\"type\":\"input_audio_buffer.clear\"}",
  )
}
