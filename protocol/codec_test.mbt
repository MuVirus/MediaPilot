///|
test "hello round trip" {
  let event = @protocol.ClientEvent::Hello(
    request_id="c-1",
    protocol_version=@protocol.protocol_version,
    capabilities=[@protocol.capability_audio_in, @protocol.capability_audio_out],
    backend="acp",
    workspace="/work/project",
  )
  let decoded = @protocol.decode_client_event(
    @protocol.encode_client_event_string(event),
  )
  assert_eq(decoded, Some(event))
}

///|
test "hello without backend or workspace decodes as defaults" {
  let decoded = @protocol.decode_client_event(
    "{\"type\":\"session.hello\",\"requestId\":\"c-1\",\"protocolVersion\":\"0.6.4\",\"capabilities\":[]}",
  )
  assert_eq(
    decoded,
    Some(
      @protocol.ClientEvent::Hello(
        request_id="c-1",
        protocol_version="0.6.4",
        capabilities=[],
        backend="",
        workspace="",
      ),
    ),
  )
}

///|
test "audio append round trip" {
  let event = @protocol.ClientEvent::AudioAppend(
    data="AAEC",
    format="pcm16",
    sample_rate=16000,
    channels=1,
  )
  let decoded = @protocol.decode_client_event(
    @protocol.encode_client_event_string(event),
  )
  assert_eq(decoded, Some(event))
}

///|
test "interrupt encodes to the documented shape" {
  let encoded = @protocol.encode_client_event(@protocol.ClientEvent::Interrupt)
  let expected = @json.parse("{\"type\":\"session.interrupt\"}")
  assert_eq(encoded, expected)
}

///|
test "unknown events are ignored" {
  let expected : @protocol.ClientEvent? = None
  let decoded = @protocol.decode_client_event("{\"type\":\"future.thing\"}")
  assert_eq(decoded, expected)
}

///|
test "missing type is a protocol error" {
  let decoded = Ok(@protocol.decode_client_event("{}")) catch {
    error => Err(error)
  }
  assert_true(decoded is Err(@protocol.MissingField("type")))
}

///|
test "unsupported major version is rejected" {
  let raw = "{\"type\":\"session.hello\",\"requestId\":\"c-1\",\"protocolVersion\":\"1.0.0\",\"capabilities\":[]}"
  let decoded = Ok(@protocol.decode_client_event(raw)) catch {
    error => Err(error)
  }
  assert_true(decoded is Err(@protocol.UnsupportedVersion("1.0.0")))
}

///|
test "non pcm16 audio is rejected" {
  let raw = "{\"type\":\"input.audio.append\",\"data\":\"AAEC\",\"format\":\"opus\",\"sampleRate\":16000,\"channels\":1}"
  let decoded = Ok(@protocol.decode_client_event(raw)) catch {
    error => Err(error)
  }
  assert_true(
    decoded is Err(@protocol.InvalidField("format", "only pcm16 is supported")),
  )
}

///|
test "server audio delta round trip" {
  let event = @protocol.ServerEvent::AudioDelta(
    session_id="s-1",
    data="AAEC",
    format="pcm16",
    sample_rate=24000,
    channels=1,
  )
  let decoded = @protocol.decode_server_event(
    @protocol.encode_server_event_string(event),
  )
  assert_eq(decoded, Some(event))
}

///|
test "task updated round trip" {
  let event = @protocol.ServerEvent::TaskUpdated(
    session_id="s-1",
    task_id="t-1",
    status="running",
    text="partial",
    step="reading gateway/server.mbt",
  )
  let decoded = @protocol.decode_server_event(
    @protocol.encode_server_event_string(event),
  )
  assert_eq(decoded, Some(event))
}

///|
test "task updated without step still decodes" {
  let decoded = @protocol.decode_server_event(
    "{\"type\":\"task.updated\",\"sessionId\":\"s-1\",\"taskId\":\"t-1\",\"status\":\"running\",\"text\":\"partial\"}",
  )
  match decoded {
    Some(@protocol.ServerEvent::TaskUpdated(step~, ..)) => assert_eq(step, "")
    _ => fail("expected task.updated")
  }
}

///|
test "permission request round trip" {
  let event = @protocol.ServerEvent::PermissionRequest(
    session_id="s-1",
    request_id="p-1",
    task_id="t-1",
    operation="execute",
    description="run `moon test`",
    timeout_ms=60000,
  )
  let decoded = @protocol.decode_server_event(
    @protocol.encode_server_event_string(event),
  )
  assert_eq(decoded, Some(event))
}

///|
test "permission resolved round trip" {
  let event = @protocol.ServerEvent::PermissionResolved(
    session_id="s-1",
    request_id="p-1",
    decision="allow_once",
    source="client",
  )
  let decoded = @protocol.decode_server_event(
    @protocol.encode_server_event_string(event),
  )
  assert_eq(decoded, Some(event))
}

///|
test "permission respond round trip" {
  let event = @protocol.ClientEvent::PermissionRespond(
    request_id="p-1",
    decision="allow_session",
  )
  let decoded = @protocol.decode_client_event(
    @protocol.encode_client_event_string(event),
  )
  assert_eq(decoded, Some(event))
}

///|
test "permission decision tokens are validated by the gateway" {
  let decoded = @protocol.decode_client_event(
    "{\"type\":\"permission.respond\",\"requestId\":\"p-1\",\"decision\":\"always\"}",
  )
  match decoded {
    Some(@protocol.ClientEvent::PermissionRespond(decision~, ..)) =>
      assert_eq(decision, "always")
    _ => fail("expected permission.respond")
  }
}

///|
test "playback clear round trip" {
  let event = @protocol.ServerEvent::PlaybackClear(
    session_id="s-1",
    reason="user_interruption",
  )
  let decoded = @protocol.decode_server_event(
    @protocol.encode_server_event_string(event),
  )
  assert_eq(decoded, Some(event))
}

///|
test "unknown error codes are preserved" {
  let event = @protocol.ServerEvent::Error(
    code=@protocol.ErrorCode::Unknown("future_error"),
    message="not yet classified",
    retryable=false,
  )
  let decoded = @protocol.decode_server_event(
    @protocol.encode_server_event_string(event),
  )
  assert_eq(decoded, Some(event))
}
