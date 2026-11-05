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
/// One item read from the upstream session.
///
/// Most events are forwarded to the client unchanged. A `ToolCall` is not a
/// northbound event: the gateway decides whether to delegate it to a backend
/// and answers with `send_tool_result`.
pub(all) enum RealtimeEvent {
  Forward(event~ : @protocol.ServerEvent)
  ToolCall(call_id~ : String, name~ : String, arguments~ : String)
} derive(Eq, Debug)

///|
/// A live upstream realtime session.
///
/// `gateway/` owns client connections and session lifecycle; it talks to the
/// upstream only through this trait. `realtime/` implements it. Neither package
/// imports the other, so provider wire details cannot leak into the gateway.
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
  /// Upstream failures arrive as `Forward(ServerEvent::Error)`, not as `None`.
  async fn next_event(Self) -> RealtimeEvent?

  /// Answer a `ToolCall` so the model can continue the turn.
  ///
  /// `continue_turn = false` records the result without asking the model to
  /// speak, which is what an interrupted turn needs: the user asked for
  /// silence, so a late tool result must not start a new response.
  async fn send_tool_result(
    Self,
    call_id : String,
    output : String,
    continue_turn : Bool,
  ) -> Unit

  /// Sample rate the upstream expects for client audio.
  fn input_sample_rate(Self) -> Int32

  /// Sample rate the upstream produces for client playback.
  fn output_sample_rate(Self) -> Int32
}
