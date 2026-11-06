///|
/// Default cap on concurrent client sessions. A deployment that expects more
/// browsers must raise `MEDIAPILOT_MAX_SESSIONS` deliberately: every session
/// owns one upstream socket and, with ACP, one agent process.
pub let default_max_sessions : Int32 = 16

///|
/// Default cap on queued `delegate_task` jobs per session.
pub let default_max_tasks_per_session : Int32 = 4

///|
/// Process-wide admission control for client sessions.
///
/// A session holds one slot from a successful `session.hello` until the socket
/// is closed. The counter is shared by all requests served by one `serve` call.
pub struct SessionLimiter {
  max : Int32
  active : Ref[Int32]
}

///|
pub fn SessionLimiter::new(max : Int32) -> SessionLimiter {
  { max, active: Ref(0), }
}

///|
pub fn SessionLimiter::max(self : SessionLimiter) -> Int32 {
  self.max
}

///|
pub fn SessionLimiter::active(self : SessionLimiter) -> Int32 {
  self.active.val
}

///|
/// Reserve one slot. `max <= 0` means unlimited, which tests may use to avoid
/// coupling unrelated cases to the default cap.
pub fn SessionLimiter::try_acquire(self : SessionLimiter) -> Bool {
  if self.max > 0 && self.active.val >= self.max {
    false
  } else {
    self.active.val = self.active.val + 1
    true
  }
}

///|
pub fn SessionLimiter::release(self : SessionLimiter) -> Unit {
  if self.active.val > 0 {
    self.active.val = self.active.val - 1
  }
}

///|
/// The `GET /api/health` body.
///
/// Clients use this to discover the protocol version and the capability set.
/// It must never include provider names, keys, or session state beyond
/// aggregate counters.
pub fn health_payload(limiter? : SessionLimiter) -> Json {
  let capabilities : Array[Json] = []
  for capability in @protocol.all_capabilities() {
    capabilities.push(Json::string(capability))
  }
  let (active, max) = match limiter {
    Some(limiter) => (limiter.active(), limiter.max())
    None => (0, default_max_sessions)
  }
  Json::object({
    "protocolVersion": Json::string(@protocol.protocol_version),
    "capabilities": Json::array(capabilities),
    "status": Json::string("ok"),
    "sessions": Json::number(active.to_double()),
    "maxSessions": Json::number(max.to_double()),
  })
}

///|
pub fn health_json(limiter? : SessionLimiter) -> String {
  match limiter {
    Some(value) => health_payload(limiter=value).stringify()
    None => health_payload().stringify()
  }
}
