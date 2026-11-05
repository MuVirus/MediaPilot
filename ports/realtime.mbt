///|
/// A provider failure already translated into contract terms.
///
/// The gateway only needs these three fields; it never inspects provider error
/// shapes. Adapters build this from their own error type.
pub(all) struct ProviderFailure {
  code : @protocol.ErrorCode
  message : String
  retryable : Bool
} derive(Eq, Debug)

///|
/// A live upstream realtime session.
///
/// `gateway/` owns client connections and session lifecycle; it talks to the
/// upstream only through this trait. `realtime/` implements it. Neither package
/// imports the other, so provider wire details cannot leak into the gateway.
///
/// Events are already normalized to `@protocol.ServerEvent`, including the
/// session ID, so the gateway can forward them without translation.
pub(open) trait RealtimeProvider {
  /// Append base64 PCM16 audio to the current input turn.
  async fn send_audio(Self, data : String) -> Unit

  /// Send a text turn.
  async fn send_text(Self, text : String) -> Unit

  /// Cancel the in-flight response and discard buffered input.
  async fn interrupt(Self) -> Unit

  /// Close the upstream connection. Safe to call more than once.
  async fn close(Self) -> Unit

  /// Block until the next normalized event.
  ///
  /// `None` means the upstream closed and no further events will arrive.
  /// Upstream failures arrive as `ServerEvent::Error`, not as `None`.
  async fn next_event(Self) -> @protocol.ServerEvent?

  /// Sample rate the upstream expects for client audio.
  fn input_sample_rate(Self) -> Int32

  /// Sample rate the upstream produces for client playback.
  fn output_sample_rate(Self) -> Int32
}
