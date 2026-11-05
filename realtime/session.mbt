///|
/// A live DashScope Realtime session.
///
/// Owns exactly one upstream WebSocket. The gateway creates one per client
/// session and must close it when the client disconnects.
pub struct DashScopeSession {
  ws : @websocket.Conn
  session_id : String
  input_rate : Int32
  output_rate : Int32
  mut closed : Bool
  /// True between `response.created` and `response.done`. Cancelling when no
  /// response is active makes DashScope answer with
  /// `Conversation has no active response.`, which would surface to the client
  /// as a spurious provider error.
  mut response_active : Bool
}

///|
/// Map a normalized provider event to the northbound event.
///
/// `TurnComplete` has no northbound representation: the client learns a turn
/// ended by the absence of further `audio.delta` events.
pub fn to_server_event(
  session_id : String,
  event : ProviderEvent,
) -> @protocol.ServerEvent? {
  match event {
    ResponseStarted => None
    AudioDelta(delta~, sample_rate~) =>
      Some(
        @protocol.ServerEvent::AudioDelta(
          session_id~,
          data=delta,
          format="pcm16",
          sample_rate~,
          channels=1,
        ),
      )
    TranscriptPartial(role~, text~) =>
      Some(@protocol.ServerEvent::TranscriptPartial(session_id~, role~, text~))
    TranscriptFinal(role~, text~) =>
      Some(@protocol.ServerEvent::TranscriptFinal(session_id~, role~, text~))
    Interrupted =>
      Some(
        @protocol.ServerEvent::PlaybackClear(
          session_id~,
          reason="user_interruption",
        ),
      )
    TurnComplete => None
    Error(code~, message~, retryable~) =>
      Some(@protocol.ServerEvent::Error(code~, message~, retryable~))
  }
}

///|
/// Send a text frame, converting transport failures into `ProviderError`.
async fn send_frame(
  ws : @websocket.Conn,
  frame : String,
) -> Unit raise ProviderError {
  ws.send_text(frame) catch {
    error => raise ConnectFailed(error.to_string())
  }
}

///|
/// Read one raw frame and normalize it. Returns `None` when the socket closed
/// or the frame carried no northbound event.
async fn DashScopeSession::recv_event(
  self : DashScopeSession,
  timeout_ms : Int32,
) -> @protocol.ServerEvent? raise ProviderError {
  let raw = try
    @async.with_timeout_opt(timeout_ms) <| () => {
      self.ws.recv().text.read_all()
    }
  catch {
    error => raise ConnectFailed(error.to_string())
  }
  match raw {
    None => None
    Some(text) => {
      let event = match normalize_incoming(text) {
        Ok(event) => event
        Err(error) => raise error
      }
      match event {
        Some(provider_event) => {
          match provider_event {
            ResponseStarted => self.response_active = true
            TurnComplete => self.response_active = false
            _ => ()
          }
          to_server_event(self.session_id, provider_event)
        }
        None => None
      }
    }
  }
}

///|
/// Connect, configure the session, and wait until the provider accepts it.
///
/// Fails with `ConnectFailed` when the socket or TLS handshake fails, and with
/// `SessionRejected` when the provider answers `session.update` with an error.
pub async fn DashScopeSession::open(
  config : ProviderConfig,
  session_id : String,
  instructions : String,
) -> DashScopeSession raise ProviderError {
  let provider = DashScopeProvider::new(config)
  let headers : Map[@http.CaseInsensitiveString, String] = Map([
    (@http.CaseInsensitiveString("Authorization"), provider.auth_header()),
  ])
  let ws = @websocket.connect(provider.connect_url(), headers~) catch {
    error => raise ConnectFailed(error.to_string())
  }
  let session : DashScopeSession = {
    ws,
    session_id,
    input_rate: provider.input_sample_rate(),
    output_rate: provider.output_sample_rate(),
    closed: false,
    response_active: false,
  }
  // The provider sends `session.created` before it accepts any command.
  let _ = session.recv_event(10000) catch {
    error => {
      ws.close()
      raise error
    }
  }
  send_frame(ws, provider.session_update(instructions).stringify()) catch {
    error => {
      ws.close()
      raise error
    }
  }
  // `session.updated` is not a northbound event, so acceptance is "the next
  // frame is not an error". A rejected `session.update` always answers with
  // `error` first.
  let first = session.recv_event(10000) catch {
    error => {
      ws.close()
      raise error
    }
  }
  match first {
    Some(@protocol.ServerEvent::Error(code~, message~, ..)) => {
      ws.close()
      raise SessionRejected(code.to_code() + ": " + message)
    }
    _ => ()
  }
  session
}

///|
pub async fn DashScopeSession::send_audio(
  self : DashScopeSession,
  data : String,
) -> Unit raise ProviderError {
  send_frame(self.ws, encode_audio_append(data).stringify())
}

///|
pub async fn DashScopeSession::send_text(
  self : DashScopeSession,
  text : String,
) -> Unit raise ProviderError {
  send_frame(self.ws, encode_text_message(text).stringify())
  send_frame(self.ws, encode_response_create().stringify())
}

///|
/// Cancel the in-flight response, if there is one.
///
/// Sending `response.cancel` while idle makes DashScope answer with
/// `Conversation has no active response.`, so the adapter tracks response
/// state instead of cancelling blindly. `input_audio_buffer.clear` is not sent
/// either: with server-side VAD the input buffer is already committed, and
/// clearing it would discard audio the user is still speaking.
pub async fn DashScopeSession::interrupt(
  self : DashScopeSession,
) -> Unit raise ProviderError {
  if self.response_active {
    self.response_active = false
    send_frame(self.ws, encode_response_cancel().stringify())
  }
}

///|
pub async fn DashScopeSession::close(self : DashScopeSession) -> Unit {
  if !self.closed {
    self.closed = true
    self.ws.send_close()
    self.ws.close()
  }
}

///|
/// Block until the next northbound event. `None` means the upstream closed.
pub async fn DashScopeSession::next_event(
  self : DashScopeSession,
) -> @protocol.ServerEvent? {
  for _ in 0..<1000 {
    let event = self.recv_event(60000) catch {
      error =>
        return Some(
          @protocol.ServerEvent::Error(
            code=@protocol.ErrorCode::ProviderUnavailable,
            message=error.to_string(),
            retryable=true,
          ),
        )
    }
    match event {
      Some(server_event) => return Some(server_event)
      None => ()
    }
  }
  None
}

///|
pub fn DashScopeSession::input_sample_rate(self : DashScopeSession) -> Int32 {
  self.input_rate
}

///|
pub fn DashScopeSession::output_sample_rate(self : DashScopeSession) -> Int32 {
  self.output_rate
}

///|
pub impl @ports.RealtimeProvider for DashScopeSession with fn send_audio(
  self,
  data,
) {
  self.send_audio(data) catch {
    _ => ()
  }
}

///|
pub impl @ports.RealtimeProvider for DashScopeSession with fn send_text(
  self,
  text,
) {
  self.send_text(text) catch {
    _ => ()
  }
}

///|
pub impl @ports.RealtimeProvider for DashScopeSession with fn interrupt(self) {
  self.interrupt() catch {
    _ => ()
  }
}

///|
pub impl @ports.RealtimeProvider for DashScopeSession with fn close(self) {
  self.close()
}

///|
pub impl @ports.RealtimeProvider for DashScopeSession with fn next_event(self) {
  self.next_event()
}

///|
pub impl @ports.RealtimeProvider for DashScopeSession with fn input_sample_rate(
  self,
) {
  self.input_sample_rate()
}

///|
pub impl @ports.RealtimeProvider for DashScopeSession with fn output_sample_rate(
  self,
) {
  self.output_sample_rate()
}
