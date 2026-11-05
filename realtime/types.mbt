///|
/// An event normalized out of a provider's wire protocol.
///
/// The gateway turns these into `@protocol.ServerEvent` values by adding the
/// session ID. Provider adapters must never return raw provider JSON.
pub(all) enum ProviderEvent {
  AudioDelta(delta~ : String, sample_rate~ : Int32)
  TranscriptPartial(role~ : String, text~ : String)
  TranscriptFinal(role~ : String, text~ : String)
  Interrupted
  TurnComplete
  Error(code~ : @protocol.ErrorCode, message~ : String, retryable~ : Bool)
} derive(Eq, Debug)

///|
pub(all) suberror ProviderError {
  InvalidFrame(String)
  MissingField(String)
  UnsupportedProvider(String)
} derive(Debug)

///|
/// Configuration shared by realtime provider adapters.
pub(all) struct ProviderConfig {
  api_key : String
  model : String
  endpoint : String
  voice : String
} derive(Eq, Debug)
