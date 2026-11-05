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
  /// Cumulative user transcript for the current speech item.
  mut user_partial : String
  /// Cumulative assistant transcript for the current response.
  mut assistant_partial : String
  /// Serializes frame writes. Client audio, tool receipts, and background
  /// results are sent from different tasks of one session.
  send_lock : @async.Mutex
}

///|
/// How long a background result waits for the current response to finish
/// before sending anyway. A response that never ends must not strand the
/// result forever.
let background_result_wait_ms : Int32 = 20000

///|
/// Response instructions for a background result. Mirrors the reference
/// project's `resultResponseInstructions`: the item is material, not a new
/// user request, and the model must not start another tool loop.
let background_result_instructions : String = "这是先前提交工作的最终结果，不是用户的新请求。把结果当作事实材料，结合当前对话自然回应；开头直接说实际结果、关键发现、阻塞或必要问题，不用“好的、收到、任务完成了”等空泛承接语。屏幕上已经展示详细结果时，只说重点和查看方向，不要逐字朗读。不要朗读协议前缀、字段、执行 ID、路径、URL 或不适合口语的长内容。不要调用工具，不要添加结果中没有的事实，也不要把未完成说成完成。"

///|
/// Merge a provider transcript fragment into the running partial for a role.
///
/// The wire is inconsistent: DashScope sends user input as cumulative
/// `text` + `stash`, while assistant output arrives as incremental deltas.
/// Clients get one cumulative value per segment so they can replace the line
/// instead of appending, which is the only behaviour that works for both.
pub fn merge_partial(
  role : String,
  current : String,
  incoming : String,
) -> String {
  if role == "user" {
    incoming
  } else {
    current + incoming
  }
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
    // Tool calls are routed by the gateway in P2; until then they are dropped
    // rather than leaked to clients as unknown events.
    FunctionCall(..) => None
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
/// Serialize one frame write for this session.
///
/// WebSocket frames are atomic, but unrelated tasks must not interleave a
/// multi-frame sequence such as `conversation.item.create` + `response.create`.
async fn DashScopeSession::write(
  self : DashScopeSession,
  frame : String,
) -> Unit raise ProviderError {
  self.send_lock.acquire()
  defer self.send_lock.release()
  send_frame(self.ws, frame)
}

///|
/// Read one raw frame and normalize it. Returns `None` when the socket closed
/// or the frame carried no northbound event.
async fn DashScopeSession::recv_event(
  self : DashScopeSession,
  timeout_ms : Int32,
) -> @ports.RealtimeEvent? raise ProviderError {
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
      let event = normalize_incoming(text)
      match event {
        Some(provider_event) =>
          match provider_event {
            ResponseStarted => {
              self.response_active = true
              self.assistant_partial = ""
              None
            }
            TurnComplete => {
              self.response_active = false
              None
            }
            TranscriptPartial(role~, text~) => {
              let current = if role == "user" {
                self.user_partial
              } else {
                self.assistant_partial
              }
              let merged = merge_partial(role, current, text)
              if role == "user" {
                self.user_partial = merged
              } else {
                self.assistant_partial = merged
              }
              if merged == "" {
                None
              } else {
                Some(
                  @ports.RealtimeEvent::Forward(
                    event=@protocol.ServerEvent::TranscriptPartial(
                      session_id=self.session_id,
                      role~,
                      text=merged,
                    ),
                  ),
                )
              }
            }
            TranscriptFinal(role~, text~) => {
              // The done frame normally repeats the whole segment; fall back to
              // what was streamed when it does not.
              let merged = if text != "" {
                text
              } else if role == "user" {
                self.user_partial
              } else {
                self.assistant_partial
              }
              if role == "user" {
                self.user_partial = ""
              } else {
                self.assistant_partial = ""
              }
              Some(
                @ports.RealtimeEvent::Forward(
                  event=@protocol.ServerEvent::TranscriptFinal(
                    session_id=self.session_id,
                    role~,
                    text=merged,
                  ),
                ),
              )
            }
            Interrupted => {
              self.user_partial = ""
              Some(
                @ports.RealtimeEvent::Forward(
                  event=@protocol.ServerEvent::PlaybackClear(
                    session_id=self.session_id,
                    reason="user_interruption",
                  ),
                ),
              )
            }
            FunctionCall(call_id~, name~, arguments~) => {
              // The response that carried the call is over: `response.done` is
              // queued behind this frame but the gateway will not read it until
              // after the tool finishes. Treating the response as still active
              // makes an interrupt send `response.cancel`, which DashScope
              // rejects with "Conversation has no active response.".
              self.response_active = false
              Some(@ports.RealtimeEvent::ToolCall(call_id~, name~, arguments~))
            }
            _ =>
              match to_server_event(self.session_id, provider_event) {
                Some(server_event) =>
                  Some(@ports.RealtimeEvent::Forward(event=server_event))
                None => None
              }
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
  tools? : @json.Json,
) -> DashScopeSession raise ProviderError {
  let provider = DashScopeProvider::new(config)
  let headers : Map[@http.CaseInsensitiveString, String] = Map([
    (@http.CaseInsensitiveString("Authorization"), provider.auth_header()),
  ])
  let ws = @websocket.connect(provider.connect_url(), headers~) catch {
    error => raise ConnectFailed(error.to_string())
  }
  // Every failure from here on must drop the socket before propagating.
  errdefer ws.close()
  let session : DashScopeSession = {
    ws,
    session_id,
    input_rate: provider.input_sample_rate(),
    output_rate: provider.output_sample_rate(),
    closed: false,
    response_active: false,
    user_partial: "",
    assistant_partial: "",
    send_lock: @async.Mutex(),
  }
  // The provider sends `session.created` before it accepts any command.
  let _ = session.recv_event(10000)
  let session_update = match tools {
    Some(tool_list) => provider.session_update(instructions, tools=tool_list)
    None => provider.session_update(instructions)
  }
  send_frame(ws, session_update.stringify())
  // `session.updated` is not a northbound event, so acceptance is "the next
  // frame is not an error". A rejected `session.update` always answers with
  // `error` first.
  let first = session.recv_event(10000)
  match first {
    Some(
      @ports.RealtimeEvent::Forward(
        event=@protocol.ServerEvent::Error(code~, message~, ..)
      )
    ) => raise SessionRejected(code.to_code() + ": " + message)
    _ => ()
  }
  session
}

///|
pub async fn DashScopeSession::send_audio(
  self : DashScopeSession,
  data : String,
) -> Unit raise ProviderError {
  self.write(encode_audio_append(data).stringify())
}

///|
pub async fn DashScopeSession::send_text(
  self : DashScopeSession,
  text : String,
) -> Unit raise ProviderError {
  self.write(encode_text_message(text).stringify())
  self.write(encode_response_create().stringify())
  self.response_active = true
}

///|
/// Inject a background result as a user-role note and start a new response.
///
/// The result may arrive while the acceptance reply is still streaming, so
/// wait for the current response to finish first. The response explicitly
/// disables tools: the model should narrate the result, not delegate again.
pub async fn DashScopeSession::send_background_result(
  self : DashScopeSession,
  text : String,
) -> Unit raise ProviderError {
  let mut waited : Int32 = 0
  while self.response_active && waited < background_result_wait_ms {
    @async.sleep(100)
    waited = waited + 100
  }
  self.write(encode_text_message("[后台任务结果]\n" + text).stringify())
  self.write(
    encode_response_create_with_instructions(background_result_instructions).stringify(),
  )
  self.response_active = true
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
    self.write(encode_response_cancel().stringify())
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
/// Block until the next upstream item. `None` means the upstream closed.
pub async fn DashScopeSession::next_event(
  self : DashScopeSession,
) -> @ports.RealtimeEvent? {
  for _ in 0..<1000 {
    let event = self.recv_event(60000) catch {
      error =>
        return Some(
          @ports.RealtimeEvent::Forward(
            event=@protocol.ServerEvent::Error(
              code=@protocol.ErrorCode::ProviderUnavailable,
              message=error.to_string(),
              retryable=true,
            ),
          ),
        )
    }
    match event {
      Some(item) => return Some(item)
      None => ()
    }
  }
  None
}

///|
/// Answer a tool call and let the model continue the turn.
pub async fn DashScopeSession::send_tool_result(
  self : DashScopeSession,
  call_id : String,
  output : String,
  continue_turn : Bool,
) -> Unit raise ProviderError {
  self.write(encode_function_output(call_id, output).stringify())
  if continue_turn {
    self.write(encode_response_create().stringify())
    self.response_active = true
  }
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
pub impl @ports.RealtimeProvider for DashScopeSession with fn send_tool_result(
  self,
  call_id,
  output,
  continue_turn,
) {
  self.send_tool_result(call_id, output, continue_turn) catch {
    _ => ()
  }
}

///|
pub impl @ports.RealtimeProvider for DashScopeSession with fn send_background_result(
  self,
  text,
) {
  self.send_background_result(text) catch {
    _ => ()
  }
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
