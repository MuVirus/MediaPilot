///|
test "health payload advertises the protocol version" {
  let parsed = @json.parse(@gateway.health_json())
  let map = match parsed {
    Json::Object(map) => map
    _ => panic()
  }
  assert_eq(
    map.get("protocolVersion"),
    Some(Json::string(@protocol.protocol_version)),
  )
  assert_eq(map.get("status"), Some(Json::string("ok")))
}

///|
test "health payload lists every capability" {
  let parsed = @json.parse(@gateway.health_json())
  let capabilities = match parsed {
    Json::Object(map) =>
      match map.get("capabilities") {
        Some(Json::Array(items)) => items
        _ => panic()
      }
    _ => panic()
  }
  assert_eq(capabilities.length(), @protocol.all_capabilities().length())
  for capability in @protocol.all_capabilities() {
    assert_true(capabilities.contains(Json::string(capability)))
  }
}

///|
test "capability negotiation keeps only the intersection" {
  let negotiated = @gateway.negotiate_capabilities([
    @protocol.capability_audio_in, "future.capability",
  ])
  assert_eq(negotiated, [@protocol.capability_audio_in])
}

///|
test "capability negotiation preserves server order" {
  let negotiated = @gateway.negotiate_capabilities([
    @protocol.capability_interrupt, @protocol.capability_audio_out, @protocol.capability_audio_in,
  ])
  assert_eq(negotiated, [
    @protocol.capability_audio_in, @protocol.capability_audio_out, @protocol.capability_interrupt,
  ])
}

///|
test "unknown client capabilities are dropped, not fatal" {
  let negotiated = @gateway.negotiate_capabilities(["nope"])
  assert_eq(negotiated, [])
}
