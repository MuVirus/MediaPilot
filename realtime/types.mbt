///|
/// An event normalized out of a provider's wire protocol.
///
/// The gateway turns these into `@protocol.ServerEvent` values by adding the
/// session ID. Provider adapters must never return raw provider JSON.
#derive(Eq, Debug)
pub(all) enum ProviderEvent {
  /// The provider started a response. Adapters use this to track whether an
  /// explicit cancel is meaningful; it has no northbound representation.
  ResponseStarted
  AudioDelta(delta~ : String, sample_rate~ : Int32)
  TranscriptPartial(role~ : String, text~ : String)
  TranscriptFinal(role~ : String, text~ : String)
  Interrupted
  TurnComplete
  /// The model asked to call a tool. `arguments` is the raw JSON string the
  /// provider produced; the caller parses it.
  FunctionCall(call_id~ : String, name~ : String, arguments~ : String)
  Error(code~ : @protocol.ErrorCode, message~ : String, retryable~ : Bool)
}

///|
#derive(Debug, Show)
pub(all) suberror ProviderError {
  InvalidFrame(String)
  MissingField(String)
  UnsupportedProvider(String)
  ConnectFailed(String)
  SessionRejected(String)
}

///|
/// Map a provider failure to a contract error code.
///
/// The adapter owns this mapping so `gateway/` never sees provider error
/// shapes. Messages must already be free of secrets.
pub fn ProviderError::to_error_code(
  self : ProviderError,
) -> @protocol.ErrorCode {
  match self {
    ConnectFailed(_) => @protocol.ErrorCode::ProviderUnavailable
    SessionRejected(message) => {
      let lower = message.to_lower()
      let auth_like = lower.contains("auth") ||
        lower.contains("api key") ||
        lower.contains("unauthorized") ||
        lower.contains("401") ||
        lower.contains("403")
      if auth_like {
        @protocol.ErrorCode::ProviderAuthFailed
      } else {
        @protocol.ErrorCode::ProviderUnavailable
      }
    }
    InvalidFrame(_) | MissingField(_) | UnsupportedProvider(_) =>
      @protocol.ErrorCode::InternalError
  }
}

///|
/// True when retrying the same request could succeed.
pub fn ProviderError::is_retryable(self : ProviderError) -> Bool {
  self.to_error_code() != @protocol.ErrorCode::ProviderAuthFailed
}

///|
/// Configuration shared by realtime provider adapters.
#derive(Eq, Debug)
pub(all) struct ProviderConfig {
  api_key : String
  model : String
  endpoint : String
  voice : String
}
