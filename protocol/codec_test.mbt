///|
test "hello round trip" {
  let event = @protocol.ClientEvent::Hello(
    request_id="c-1",
    protocol_version=@protocol.protocol_version,
    capabilities=[@protocol.capability_audio_in, @protocol.capability_audio_out],
  )
  let decoded = @protocol.decode_client_event(
    @protocol.encode_client_event_string(event),
  ).unwrap()
  assert_eq(decoded, Some(event))
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
  ).unwrap()
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
  let decoded = @protocol.decode_client_event("{\"type\":\"future.thing\"}").unwrap()
  assert_eq(decoded, expected)
}

///|
test "missing type is a protocol error" {
  let decoded = @protocol.decode_client_event("{}")
  assert_true(decoded is Err(@protocol.MissingField("type")))
}

///|
test "unsupported major version is rejected" {
  let raw = "{\"type\":\"session.hello\",\"requestId\":\"c-1\",\"protocolVersion\":\"1.0.0\",\"capabilities\":[]}"
  let decoded = @protocol.decode_client_event(raw)
  assert_true(decoded is Err(@protocol.UnsupportedVersion("1.0.0")))
}

///|
test "non pcm16 audio is rejected" {
  let raw = "{\"type\":\"input.audio.append\",\"data\":\"AAEC\",\"format\":\"opus\",\"sampleRate\":16000,\"channels\":1}"
  let decoded = @protocol.decode_client_event(raw)
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
  ).unwrap()
  assert_eq(decoded, Some(event))
}

///|
test "playback clear round trip" {
  let event = @protocol.ServerEvent::PlaybackClear(
    session_id="s-1",
    reason="user_interruption",
  )
  let decoded = @protocol.decode_server_event(
    @protocol.encode_server_event_string(event),
  ).unwrap()
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
  ).unwrap()
  assert_eq(decoded, Some(event))
}
