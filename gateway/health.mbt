///|
/// The `GET /api/health` body.
///
/// Clients use this to discover the protocol version and the capability set.
/// It must never include provider names, keys, or session state.
pub fn health_payload() -> Json {
  let capabilities : Array[Json] = []
  for capability in @protocol.all_capabilities() {
    capabilities.push(Json::string(capability))
  }
  Json::object({
    "protocolVersion": Json::string(@protocol.protocol_version),
    "capabilities": Json::array(capabilities),
    "status": Json::string("ok"),
  })
}

///|
pub fn health_json() -> String {
  health_payload().stringify()
}
