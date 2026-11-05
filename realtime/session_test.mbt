///|
test "audio delta becomes a northbound audio event" {
  let mapped = @realtime.to_server_event(
    "s-1",
    @realtime.ProviderEvent::AudioDelta(delta="AAEC", sample_rate=24000),
  )
  assert_eq(
    mapped,
    Some(
      @protocol.ServerEvent::AudioDelta(
        session_id="s-1",
        data="AAEC",
        format="pcm16",
        sample_rate=24000,
        channels=1,
      ),
    ),
  )
}

///|
test "assistant transcript keeps its role" {
  let mapped = @realtime.to_server_event(
    "s-1",
    @realtime.ProviderEvent::TranscriptPartial(role="assistant", text="hel"),
  )
  assert_eq(
    mapped,
    Some(
      @protocol.ServerEvent::TranscriptPartial(
        session_id="s-1",
        role="assistant",
        text="hel",
      ),
    ),
  )
}

///|
test "user transcript final keeps its role" {
  let mapped = @realtime.to_server_event(
    "s-1",
    @realtime.ProviderEvent::TranscriptFinal(role="user", text="你好"),
  )
  assert_eq(
    mapped,
    Some(
      @protocol.ServerEvent::TranscriptFinal(
        session_id="s-1",
        role="user",
        text="你好",
      ),
    ),
  )
}

///|
test "interruption becomes playback.clear" {
  let mapped = @realtime.to_server_event(
    "s-1",
    @realtime.ProviderEvent::Interrupted,
  )
  assert_eq(
    mapped,
    Some(
      @protocol.ServerEvent::PlaybackClear(
        session_id="s-1",
        reason="user_interruption",
      ),
    ),
  )
}

///|
test "turn completion has no northbound event" {
  let mapped : @protocol.ServerEvent? = @realtime.to_server_event(
    "s-1",
    @realtime.ProviderEvent::TurnComplete,
  )
  assert_eq(mapped, None)
}

///|
test "provider errors keep their contract code" {
  let mapped = @realtime.to_server_event(
    "s-1",
    @realtime.ProviderEvent::Error(
      code=@protocol.ErrorCode::ProviderAuthFailed,
      message="bad key",
      retryable=false,
    ),
  )
  assert_eq(
    mapped,
    Some(
      @protocol.ServerEvent::Error(
        code=@protocol.ErrorCode::ProviderAuthFailed,
        message="bad key",
        retryable=false,
      ),
    ),
  )
}
