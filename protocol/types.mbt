///|
/// The protocol version this package implements.
///
/// Additive changes bump the minor; any breaking change to a client-visible
/// event or field bumps the major. See `docs/contract.md`.
pub let protocol_version : String = "0.4.0"

///|
/// Capability IDs are the only stable feature check for clients.
pub let capability_session : String = "realtime.session"

///|
pub let capability_audio_in : String = "realtime.audio-in"

///|
pub let capability_audio_out : String = "realtime.audio-out"

///|
pub let capability_text_in : String = "realtime.text-in"

///|
pub let capability_interrupt : String = "realtime.interrupt"

///|
/// The gateway can tell the client to stop playing buffered audio, for example
/// when server-side VAD detects that the user started speaking.
pub let capability_playback_clear : String = "realtime.playback-clear"

///|
/// The gateway reports background task progress (`task.updated`).
pub let capability_task : String = "realtime.task"

///|
/// The gateway asks the client to approve a backend action and waits for an
/// answer (`permission.request` / `permission.respond`).
pub let capability_permission : String = "realtime.permission"

///|
pub fn all_capabilities() -> Array[String] {
  [
    capability_session, capability_audio_in, capability_audio_out, capability_text_in,
    capability_interrupt, capability_playback_clear, capability_task, capability_permission,
  ]
}

///|
/// True when the peer's major version matches this implementation.
pub fn is_compatible_version(version : String) -> Bool {
  match version.split(".").next() {
    Some(major) => major.equal_to_string("0")
    None => false
  }
}

///|
/// Stable error codes. Unknown values are preserved so a newer peer is not
/// forced to drop information.
pub(all) enum ErrorCode {
  HandshakeRequired
  UnsupportedVersion
  InvalidEvent
  AudioFormatUnsupported
  ProviderUnavailable
  ProviderAuthFailed
  SessionLimit
  InternalError
  Unknown(String)
} derive(Eq, Debug)

///|
pub fn ErrorCode::to_code(self : ErrorCode) -> String {
  match self {
    HandshakeRequired => "handshake_required"
    UnsupportedVersion => "unsupported_version"
    InvalidEvent => "invalid_event"
    AudioFormatUnsupported => "audio_format_unsupported"
    ProviderUnavailable => "provider_unavailable"
    ProviderAuthFailed => "provider_auth_failed"
    SessionLimit => "session_limit"
    InternalError => "internal_error"
    Unknown(code) => code
  }
}

///|
pub fn ErrorCode::from_code(code : String) -> ErrorCode {
  match code {
    "handshake_required" => HandshakeRequired
    "unsupported_version" => UnsupportedVersion
    "invalid_event" => InvalidEvent
    "audio_format_unsupported" => AudioFormatUnsupported
    "provider_unavailable" => ProviderUnavailable
    "provider_auth_failed" => ProviderAuthFailed
    "session_limit" => SessionLimit
    "internal_error" => InternalError
    _ => Unknown(code)
  }
}

///|
/// An event sent by a client over `WS /api/realtime`.
pub(all) enum ClientEvent {
  Hello(
    request_id~ : String,
    protocol_version~ : String,
    capabilities~ : Array[String]
  )
  AudioAppend(
    data~ : String,
    format~ : String,
    sample_rate~ : Int32,
    channels~ : Int32
  )
  Text(text~ : String)
  ImageAppend(data~ : String, mime_type~ : String)
  /// Answer a pending `permission.request`. `decision` is one of
  /// `allow_once`, `allow_task`, `allow_session`, `deny`.
  PermissionRespond(request_id~ : String, decision~ : String)
  Interrupt
  Close
} derive(Eq, Debug)

///|
/// An event sent by the gateway over `WS /api/realtime`.
pub(all) enum ServerEvent {
  Ready(
    request_id~ : String,
    session_id~ : String,
    protocol_version~ : String,
    capabilities~ : Array[String]
  )
  TranscriptPartial(session_id~ : String, role~ : String, text~ : String)
  TranscriptFinal(session_id~ : String, role~ : String, text~ : String)
  AudioDelta(
    session_id~ : String,
    data~ : String,
    format~ : String,
    sample_rate~ : Int32,
    channels~ : Int32
  )
  /// Stop playing buffered audio. `reason` is a stable token such as
  /// `user_interruption`; clients must not branch on free-form text.
  PlaybackClear(session_id~ : String, reason~ : String)
  /// Background task progress. `status` is one of `running`, `completed`,
  /// `failed`; `text` carries the accumulated result so far and may be empty;
  /// `step` is a short human-readable progress line and may be empty.
  TaskUpdated(
    session_id~ : String,
    task_id~ : String,
    status~ : String,
    text~ : String,
    step~ : String
  )
  /// The backend needs approval before it can continue.
  ///
  /// `operation` is a stable token (`read`, `edit`, `execute`, …);
  /// `description` is backend-authored text and must not drive decisions.
  /// `timeout_ms` says how long the gateway waits before treating the request
  /// as `deny`.
  PermissionRequest(
    session_id~ : String,
    request_id~ : String,
    task_id~ : String,
    operation~ : String,
    description~ : String,
    timeout_ms~ : Int32
  )
  /// A permission request is no longer pending. `source` is one of `client`,
  /// `timeout`, `policy`, `cancelled`.
  PermissionResolved(
    session_id~ : String,
    request_id~ : String,
    decision~ : String,
    source~ : String
  )
  Error(code~ : ErrorCode, message~ : String, retryable~ : Bool)
} derive(Eq, Debug)

///|
pub(all) suberror ProtocolError {
  InvalidJson(String)
  MissingField(String)
  InvalidField(String, String)
  UnsupportedVersion(String)
} derive(Debug, Show)
