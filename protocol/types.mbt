///|
/// The protocol version this package implements.
///
/// Additive changes bump the minor; any breaking change to a client-visible
/// event or field bumps the major. See `docs/contract.md`.
pub let protocol_version : String = "0.1.0"

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
pub fn all_capabilities() -> Array[String] {
  [
    capability_session, capability_audio_in, capability_audio_out, capability_text_in,
    capability_interrupt,
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
  Error(code~ : ErrorCode, message~ : String, retryable~ : Bool)
} derive(Eq, Debug)

///|
pub(all) suberror ProtocolError {
  InvalidJson(String)
  MissingField(String)
  InvalidField(String, String)
  UnsupportedVersion(String)
} derive(Debug)
