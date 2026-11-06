///|
/// A scripted provider used by gateway integration tests.
///
/// It records what the gateway sent upstream and replays a fixed event
/// sequence downstream, so the tests exercise the real WebSocket path without
/// touching the network.
struct FakeProvider {
  sent_audio : Array[String]
  sent_text : Array[String]
  background_results : Array[String]
  mut interrupted : Bool
  tool_results : Array[(String, String, Bool)]
  mut tools : Json?
  events : @aqueue.Queue[@ports.RealtimeEvent?]
}

///|
fn FakeProvider::new() -> FakeProvider {
  {
    sent_audio: [],
    sent_text: [],
    background_results: [],
    interrupted: false,
    tool_results: [],
    tools: None,
    events: @aqueue.Queue(kind=Blocking(16)),
  }
}

///|
async fn FakeProvider::push(
  self : FakeProvider,
  event : @protocol.ServerEvent,
) -> Unit {
  self.events.put(Some(@ports.RealtimeEvent::Forward(event~)))
}

///|
async fn FakeProvider::push_tool_call(
  self : FakeProvider,
  call_id : String,
  name : String,
  arguments : String,
) -> Unit {
  self.events.put(
    Some(@ports.RealtimeEvent::ToolCall(call_id~, name~, arguments~)),
  )
}

///|
async fn FakeProvider::finish(self : FakeProvider) -> Unit {
  self.events.put(None)
}

///|
pub impl @ports.RealtimeProvider for FakeProvider with fn send_audio(self, data) {
  self.sent_audio.push(data)
}

///|
pub impl @ports.RealtimeProvider for FakeProvider with fn send_text(self, text) {
  self.sent_text.push(text)
}

///|
pub impl @ports.RealtimeProvider for FakeProvider with fn interrupt(self) {
  self.interrupted = true
}

///|
pub impl @ports.RealtimeProvider for FakeProvider with fn close(_self) {

}

///|
pub impl @ports.RealtimeProvider for FakeProvider with fn next_event(self) {
  self.events.get()
}

///|
pub impl @ports.RealtimeProvider for FakeProvider with fn send_tool_result(
  self,
  call_id,
  output,
  continue_turn,
) {
  self.tool_results.push((call_id, output, continue_turn))
}

///|
pub impl @ports.RealtimeProvider for FakeProvider with fn send_background_result(
  self,
  text,
) {
  self.background_results.push(text)
}

///|
pub impl @ports.RealtimeProvider for FakeProvider with fn input_sample_rate(
  _self,
) {
  16000
}

///|
pub impl @ports.RealtimeProvider for FakeProvider with fn output_sample_rate(
  _self,
) {
  24000
}

///|
fn fake_factory(provider : FakeProvider) -> @gateway.ProviderFactory {
  fn(_session_id, tools) {
    provider.tools = tools
    Ok(provider as &@ports.RealtimeProvider)
  }
}

///|
/// A scripted backend that answers every task with a fixed string.
///
/// When `permission_asks` is non-zero it first asks that many times and blocks
/// until the gateway answers, which is what a real ACP agent does.
struct FakeBackend {
  submitted : Array[String]
  events : @aqueue.Queue[@ports.BackendEvent?]
  permissions : Array[(String, @ports.PermissionDecision)]
  answers : @aqueue.Queue[@ports.PermissionDecision]
  mut permission_asks : Int32
  mut warmed : Bool
  /// When true, `submit` waits on `gate` before producing the answer.
  mut hold : Bool
  gate : @aqueue.Queue[Unit]
  cancelled : Array[String]
}

///|
fn FakeBackend::new() -> FakeBackend {
  {
    submitted: [],
    events: @aqueue.Queue(kind=Blocking(16)),
    permissions: [],
    answers: @aqueue.Queue(kind=Blocking(4)),
    permission_asks: 0,
    warmed: false,
    hold: false,
    gate: @aqueue.Queue(kind=Blocking(1)),
    cancelled: [],
  }
}

///|
fn FakeBackend::with_permission(permission_asks : Int32) -> FakeBackend {
  let backend = FakeBackend::new()
  backend.permission_asks = permission_asks
  backend
}

///|
pub impl @ports.BackendPort for FakeBackend with fn warmup(self) {
  self.warmed = true
}

///|
pub impl @ports.BackendPort for FakeBackend with fn submit(
  self,
  _task_id,
  instruction,
) {
  self.submitted.push(instruction)
  let mut ask = 0
  while ask < self.permission_asks {
    ask = ask + 1
    let request_id = "p-" + ask.to_string()
    self.events.put(
      Some(
        @ports.BackendEvent::PermissionRequest(
          request_id~,
          operation="execute",
          description="run `moon test`",
        ),
      ),
    )
    let decision = self.answers.get()
    if !decision.allows() {
      self.events.put(
        Some(
          @ports.BackendEvent::Failed(
            code=@protocol.ErrorCode::InvalidEvent,
            message="permission denied",
            retryable=false,
          ),
        ),
      )
      return
    }
  }
  let answer = "agent answer: " + instruction
  if self.hold {
    self.gate.get()
  }
  self.events.put(Some(@ports.BackendEvent::TextDelta(text="agent ")))
  self.events.put(Some(@ports.BackendEvent::TextDelta(text="answer")))
  self.events.put(Some(@ports.BackendEvent::TextDone(text=answer)))
  self.events.put(Some(@ports.BackendEvent::Completed))
}

///|
pub impl @ports.BackendPort for FakeBackend with fn cancel(self, task_id) {
  self.cancelled.push(task_id)
  // A held task is waiting on the gate. Releasing it lets the submission finish
  // so the gateway can observe the cancellation instead of hanging the test.
  if self.hold {
    self.gate.put(())
  }
}

///|
pub impl @ports.BackendPort for FakeBackend with fn respond_tool(
  _self,
  _call_id,
  _output,
) {

}

///|
pub impl @ports.BackendPort for FakeBackend with fn respond_permission(
  self,
  request_id,
  decision,
) {
  self.permissions.push((request_id, decision))
  self.answers.put(decision)
}

///|
pub impl @ports.BackendPort for FakeBackend with fn next_event(self) {
  self.events.get()
}

///|
pub impl @ports.BackendPort for FakeBackend with fn close(_self) {

}

///|
fn fake_backend_factory(backend : FakeBackend) -> @gateway.BackendFactory {
  fn(_session_id, _workspace) { Ok(backend as &@ports.BackendPort) }
}

///|
async fn read_event(ws : @websocket.Conn) -> @protocol.ServerEvent? {
  let raw = try
    @async.with_timeout_opt(5000) <| () => { ws.recv().text.read_all() }
  catch {
    _ => return None
  }
  match raw {
    None => None
    Some(text) => @protocol.decode_server_event(text) catch { _ => None }
  }
}

///|
async fn send_client(
  ws : @websocket.Conn,
  event : @protocol.ClientEvent,
) -> Unit {
  ws.send_text(@protocol.encode_client_event_string(event))
}

///|
async fn hello(ws : @websocket.Conn) -> Unit {
  send_client(
    ws,
    @protocol.ClientEvent::Hello(
      request_id="c-1",
      protocol_version=@protocol.protocol_version,
      capabilities=[
        @protocol.capability_audio_in, @protocol.capability_audio_out, @protocol.capability_text_in,
        @protocol.capability_interrupt,
      ],
      workspace="",
    ),
  )
}

///|
/// Handshake as a client that also understands permission prompts.
async fn hello_with_permission(ws : @websocket.Conn) -> Unit {
  send_client(
    ws,
    @protocol.ClientEvent::Hello(
      request_id="c-1",
      protocol_version=@protocol.protocol_version,
      capabilities=[
        @protocol.capability_audio_in, @protocol.capability_audio_out, @protocol.capability_text_in,
        @protocol.capability_interrupt, @protocol.capability_task, @protocol.capability_permission,
      ],
      workspace="",
    ),
  )
}

///|
/// Start a gateway on an ephemeral port and run `body` against a connected
/// client. The server is cancelled when `body` returns.
async fn with_gateway(
  provider : FakeProvider,
  body : async (@websocket.Conn) -> Unit,
) -> Unit {
  with_gateway_backend(provider, None, body)
}

///|
/// Like `with_gateway`, but with an optional agent backend so `delegate_task`
/// is registered.
async fn with_gateway_backend(
  provider : FakeProvider,
  backend : FakeBackend?,
  body : async (@websocket.Conn) -> Unit,
) -> Unit {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true) <| () => {
      match backend {
        Some(backend) =>
          @gateway.serve(
            server,
            fake_factory(provider),
            open_backend=fake_backend_factory(backend),
          )
        None => @gateway.serve(server, fake_factory(provider))
      }
    }
    @async.sleep(50)
    let ws = @websocket.connect("ws://127.0.0.1:\{port}/api/realtime")
    defer ws.close()
    body(ws)
  }
}

///|
async test "handshake returns ready with negotiated capabilities" {
  let provider = FakeProvider::new()
  with_gateway(provider, async fn(ws) {
    hello(ws)
    match read_event(ws) {
      Some(
        @protocol.ServerEvent::Ready(
          request_id~,
          session_id~,
          capabilities~,
          ..
        )
      ) => {
        assert_eq(request_id, "c-1")
        assert_true(session_id.length() > 0)
        assert_eq(capabilities, [
          @protocol.capability_audio_in, @protocol.capability_audio_out, @protocol.capability_text_in,
          @protocol.capability_interrupt,
        ])
      }
      _ => panic()
    }
  })
}

///|
async test "business events before hello are rejected" {
  let provider = FakeProvider::new()
  with_gateway(provider, async fn(ws) {
    send_client(ws, @protocol.ClientEvent::Interrupt)
    match read_event(ws) {
      Some(@protocol.ServerEvent::Error(code~, ..)) =>
        assert_eq(code, @protocol.ErrorCode::HandshakeRequired)
      _ => panic()
    }
  })
}

///|
async test "unsupported major version is rejected" {
  let provider = FakeProvider::new()
  with_gateway(provider, async fn(ws) {
    send_client(
      ws,
      @protocol.ClientEvent::Hello(
        request_id="c-1",
        protocol_version="1.0.0",
        capabilities=[],
        workspace="",
      ),
    )
    match read_event(ws) {
      Some(@protocol.ServerEvent::Error(code~, ..)) =>
        assert_eq(code, @protocol.ErrorCode::UnsupportedVersion)
      _ => panic()
    }
  })
}

///|
async test "text input reaches the provider" {
  let provider = FakeProvider::new()
  with_gateway(provider, async fn(ws) {
    hello(ws)
    let _ = read_event(ws)
    send_client(ws, @protocol.ClientEvent::Text(text="你好"))
    @async.sleep(100)
    assert_eq(provider.sent_text, ["你好"])
  })
}

///|
async test "audio with the wrong format is rejected" {
  let provider = FakeProvider::new()
  with_gateway(provider, async fn(ws) {
    hello(ws)
    let _ = read_event(ws)
    send_client(
      ws,
      @protocol.ClientEvent::AudioAppend(
        data="AAEC",
        format="pcm16",
        sample_rate=48000,
        channels=1,
      ),
    )
    match read_event(ws) {
      Some(@protocol.ServerEvent::Error(code~, message~, ..)) => {
        assert_eq(code, @protocol.ErrorCode::AudioFormatUnsupported)
        assert_true(message.contains("16000"))
      }
      _ => panic()
    }
    assert_eq(provider.sent_audio, [])
  })
}

///|
async test "audio with the right format reaches the provider" {
  let provider = FakeProvider::new()
  with_gateway(provider, async fn(ws) {
    hello(ws)
    let _ = read_event(ws)
    send_client(
      ws,
      @protocol.ClientEvent::AudioAppend(
        data="AAEC",
        format="pcm16",
        sample_rate=16000,
        channels=1,
      ),
    )
    @async.sleep(100)
    assert_eq(provider.sent_audio, ["AAEC"])
  })
}

///|
async test "interrupt reaches the provider" {
  let provider = FakeProvider::new()
  with_gateway(provider, async fn(ws) {
    hello(ws)
    let _ = read_event(ws)
    send_client(ws, @protocol.ClientEvent::Interrupt)
    @async.sleep(100)
    assert_true(provider.interrupted)
  })
}

///|
async test "unknown client events are ignored" {
  let provider = FakeProvider::new()
  with_gateway(provider, async fn(ws) {
    hello(ws)
    let _ = read_event(ws)
    ws.send_text("{\"type\":\"future.event\"}")
    // The connection must stay usable: a following text turn still arrives.
    send_client(ws, @protocol.ClientEvent::Text(text="still here"))
    @async.sleep(100)
    assert_eq(provider.sent_text, ["still here"])
  })
}

///|
async test "provider events are forwarded to the client" {
  let provider = FakeProvider::new()
  with_gateway(provider, async fn(ws) {
    hello(ws)
    let _ = read_event(ws)
    provider.push(
      @protocol.ServerEvent::AudioDelta(
        session_id="s-1",
        data="AAEC",
        format="pcm16",
        sample_rate=24000,
        channels=1,
      ),
    )
    match read_event(ws) {
      Some(@protocol.ServerEvent::AudioDelta(data~, sample_rate~, ..)) => {
        assert_eq(data, "AAEC")
        assert_eq(sample_rate, 24000)
      }
      _ => panic()
    }
  })
}

///|
async test "provider close reports a retryable error, then closes" {
  let provider = FakeProvider::new()
  with_gateway(provider, async fn(ws) {
    hello(ws)
    let _ = read_event(ws)
    provider.finish()
    match read_event(ws) {
      Some(@protocol.ServerEvent::Error(code~, retryable~, ..)) => {
        assert_eq(code, @protocol.ErrorCode::ProviderUnavailable)
        assert_true(retryable)
      }
      _ => panic()
    }
    // After the error the gateway closes the socket.
    assert_eq(read_event(ws), None)
  })
}

///|
async test "interrupt confirms with playback.clear and stops audio" {
  let provider = FakeProvider::new()
  with_gateway(provider, async fn(ws) {
    hello(ws)
    let _ = read_event(ws)
    for _ in 0..<5 {
      provider.push(
        @protocol.ServerEvent::AudioDelta(
          session_id="s-1",
          data="AAEC",
          format="pcm16",
          sample_rate=24000,
          channels=1,
        ),
      )
    }
    send_client(ws, @protocol.ClientEvent::Interrupt)
    // Audio may still arrive for the chunks already in flight; the gateway
    // must send playback.clear and then stop forwarding that response.
    let mut cleared = false
    for _ in 0..<12 {
      match read_event(ws) {
        Some(@protocol.ServerEvent::PlaybackClear(reason~, ..)) => {
          assert_eq(reason, "client_interrupt")
          cleared = true
          break
        }
        Some(_) => ()
        None => break
      }
    }
    assert_true(cleared)
    assert_true(provider.interrupted)
    // Nothing queued for the cancelled response may follow the clear.
    for _ in 0..<5 {
      match read_event(ws) {
        Some(@protocol.ServerEvent::AudioDelta(..)) =>
          fail("audio delta arrived after playback.clear")
        Some(_) => ()
        None => break
      }
    }
  })
}

///|
async test "client close is not reported as a provider error" {
  let provider = FakeProvider::new()
  with_gateway(provider, async fn(ws) {
    hello(ws)
    let _ = read_event(ws)
    send_client(ws, @protocol.ClientEvent::Close)
    // The session ends without an error event; the socket simply closes.
    match read_event(ws) {
      Some(@protocol.ServerEvent::Error(..)) =>
        fail("client close must not produce an error event")
      _ => ()
    }
  })
}

///|
test "delegate_task tool is well-formed" {
  let tool = @gateway.delegate_task_tool()
  let parsed = @json.parse(tool.stringify())
  let function = match parsed {
    Json::Object(root) =>
      match root.get("function") {
        Some(Json::Object(function)) => function
        _ => panic()
      }
    _ => panic()
  }
  assert_eq(function.get("name"), Some(Json::string("delegate_task")))
  let parameters = match function.get("parameters") {
    Some(Json::Object(parameters)) => parameters
    _ => panic()
  }
  assert_eq(
    parameters.get("required"),
    Some(Json::array([Json::string("instruction")])),
  )
}

///|
async test "delegate_task runs the backend and answers the tool call" {
  let provider = FakeProvider::new()
  let backend = FakeBackend::new()
  with_gateway_backend(provider, Some(backend), async fn(ws) {
    hello(ws)
    let _ = read_event(ws)
    provider.push_tool_call(
      "call-1", "delegate_task", "{\"instruction\":\"查一下明天杭州的天气\"}",
    )
    // Expect progress plus the final answer.
    let mut saw_running = false
    let mut completed_text = ""
    for _ in 0..<20 {
      match read_event(ws) {
        Some(@protocol.ServerEvent::TaskUpdated(task_id~, status~, text~, ..)) => {
          assert_eq(task_id, "t-1")
          if status == "running" {
            saw_running = true
          }
          if status == "completed" {
            completed_text = text
            break
          }
          if status == "failed" {
            fail("delegated task failed")
          }
        }
        Some(_) => ()
        None => break
      }
    }
    assert_true(saw_running)
    assert_eq(completed_text, "agent answer: 查一下明天杭州的天气")
    // The tool call is answered immediately with an acceptance receipt; the
    // final answer arrives later as a background result.
    @async.sleep(120)
    assert_eq(backend.submitted, ["查一下明天杭州的天气"])
    assert_eq(provider.tool_results.length(), 1)
    let (call_id, output, continue_turn) = provider.tool_results[0]
    assert_true(continue_turn)
    assert_eq(call_id, "call-1")
    assert_true(output.contains("accepted"))
    assert_true(!output.contains("agent answer"))
    assert_eq(provider.background_results.length(), 1)
    assert_true(provider.background_results[0].contains("agent answer"))
  })
}

///|
async test "the provider keeps reading events while a task runs" {
  let provider = FakeProvider::new()
  let backend = FakeBackend::new()
  backend.hold = true
  with_gateway_backend(provider, Some(backend), async fn(ws) {
    hello(ws)
    let _ = read_event(ws)
    provider.push_tool_call(
      "call-1", "delegate_task", "{\"instruction\":\"慢任务\"}",
    )
    // The tool call is accepted even though the backend has not answered.
    let mut accepted = false
    for _ in 0..<40 {
      if provider.tool_results.length() > 0 {
        accepted = true
        break
      }
      @async.sleep(20)
    }
    assert_true(accepted)
    // A provider event must still reach the client while the backend is held.
    provider.push(
      @protocol.ServerEvent::TranscriptFinal(
        session_id="s-1",
        role="assistant",
        text="still reading",
      ),
    )
    let mut saw_transcript = false
    for _ in 0..<20 {
      match read_event(ws) {
        Some(@protocol.ServerEvent::TranscriptFinal(text~, ..)) => {
          assert_eq(text, "still reading")
          saw_transcript = true
          break
        }
        Some(_) => ()
        None => break
      }
    }
    assert_true(saw_transcript)
    backend.gate.put(())
    @async.sleep(120)
    assert_eq(provider.background_results.length(), 1)
    assert_true(
      provider.background_results[0].contains("agent answer: 慢任务"),
    )
  })
}

///|
async test "unknown tools are rejected without calling the backend" {
  let provider = FakeProvider::new()
  let backend = FakeBackend::new()
  with_gateway_backend(provider, Some(backend), async fn(ws) {
    hello(ws)
    let _ = read_event(ws)
    provider.push_tool_call("call-1", "delete_everything", "{}")
    @async.sleep(120)
    assert_eq(backend.submitted, [])
    assert_eq(provider.tool_results.length(), 1)
    let (_, output, _) = provider.tool_results[0]
    assert_true(output.contains("unknown tool"))
  })
}

///|
/// Read events until a permission request arrives. Returns its id, or "".
async fn await_permission_request(
  ws : @websocket.Conn,
  max_events : Int32,
) -> String {
  for _ in 0..<max_events {
    match read_event(ws) {
      Some(@protocol.ServerEvent::PermissionRequest(request_id~, ..)) =>
        return request_id
      Some(_) => ()
      None => break
    }
  }
  ""
}

///|
async test "backend is warmed before the first task" {
  let provider = FakeProvider::new()
  let backend = FakeBackend::new()
  with_gateway_backend(provider, Some(backend), async fn(ws) {
    hello(ws)
    let _ = read_event(ws)
    let mut warmed = false
    for _ in 0..<40 {
      if backend.warmed {
        warmed = true
        break
      }
      @async.sleep(50)
    }
    assert_true(warmed)
  })
}

///|
async test "permission request is approved once and the task continues" {
  let provider = FakeProvider::new()
  let backend = FakeBackend::with_permission(1)
  with_gateway_backend(provider, Some(backend), async fn(ws) {
    hello_with_permission(ws)
    let _ = read_event(ws)
    provider.push_tool_call(
      "call-1", "delegate_task", "{\"instruction\":\"跑一下测试\"}",
    )
    let captured = await_permission_request(ws, 10)
    assert_true(captured != "")
    // The tool call was already answered with an acceptance receipt while the
    // backend is blocked on the permission prompt.
    assert_eq(provider.tool_results.length(), 1)
    assert_true(provider.tool_results[0].1.contains("accepted"))
    send_client(
      ws,
      @protocol.ClientEvent::PermissionRespond(
        request_id=captured,
        decision="allow_once",
      ),
    )
    let mut completed = ""
    let mut resolved = false
    for _ in 0..<20 {
      match read_event(ws) {
        Some(
          @protocol.ServerEvent::PermissionResolved(
            request_id~,
            decision~,
            source~,
            ..
          )
        ) =>
          if request_id == captured {
            assert_eq(decision, "allow_once")
            assert_eq(source, "client")
            resolved = true
          }
        Some(@protocol.ServerEvent::TaskUpdated(status~, text~, ..)) =>
          if status == "completed" {
            completed = text
            break
          }
        Some(_) => ()
        None => break
      }
    }
    assert_true(resolved)
    assert_eq(completed, "agent answer: 跑一下测试")
    assert_eq(backend.permissions.length(), 1)
    assert_eq(
      backend.permissions[0],
      (captured, @ports.PermissionDecision::AllowOnce),
    )
    let (_, output, continue_turn) = provider.tool_results[0]
    assert_true(output.contains("accepted"))
    assert_true(continue_turn)
    assert_eq(provider.background_results.length(), 1)
    assert_true(provider.background_results[0].contains("agent answer"))
  })
}

///|
async test "denying permission reports the failure as a background result" {
  let provider = FakeProvider::new()
  let backend = FakeBackend::with_permission(1)
  with_gateway_backend(provider, Some(backend), async fn(ws) {
    hello_with_permission(ws)
    let _ = read_event(ws)
    provider.push_tool_call(
      "call-1", "delegate_task", "{\"instruction\":\"删除全部文件\"}",
    )
    let captured = await_permission_request(ws, 10)
    assert_true(captured != "")
    send_client(
      ws,
      @protocol.ClientEvent::PermissionRespond(
        request_id=captured,
        decision="deny",
      ),
    )
    let mut failed = false
    for _ in 0..<20 {
      match read_event(ws) {
        Some(@protocol.ServerEvent::TaskUpdated(status~, ..)) =>
          if status == "failed" {
            failed = true
            break
          }
        Some(_) => ()
        None => break
      }
    }
    assert_true(failed)
    assert_eq(
      backend.permissions[0],
      (captured, @ports.PermissionDecision::Deny),
    )
    @async.sleep(120)
    let (_, output, _) = provider.tool_results[0]
    assert_true(output.contains("accepted"))
    assert_eq(provider.background_results.length(), 1)
    assert_true(provider.background_results[0].contains("permission denied"))
  })
}

///|
async test "session grant answers later requests without prompting again" {
  let provider = FakeProvider::new()
  let backend = FakeBackend::with_permission(2)
  with_gateway_backend(provider, Some(backend), async fn(ws) {
    hello_with_permission(ws)
    let _ = read_event(ws)
    provider.push_tool_call(
      "call-1", "delegate_task", "{\"instruction\":\"x\"}",
    )
    let captured = await_permission_request(ws, 10)
    assert_true(captured != "")
    send_client(
      ws,
      @protocol.ClientEvent::PermissionRespond(
        request_id=captured,
        decision="allow_session",
      ),
    )
    let mut policy = false
    let mut completed = false
    for _ in 0..<24 {
      match read_event(ws) {
        Some(
          @protocol.ServerEvent::PermissionResolved(request_id~, source~, ..)
        ) => if request_id == "p-2" && source == "policy" { policy = true }
        Some(@protocol.ServerEvent::PermissionRequest(..)) =>
          fail("the gateway asked again after a session grant")
        Some(@protocol.ServerEvent::TaskUpdated(status~, ..)) =>
          if status == "completed" {
            completed = true
            break
          }
        Some(_) => ()
        None => break
      }
    }
    assert_true(policy)
    assert_true(completed)
    assert_eq(backend.permissions.length(), 2)
    assert_eq(
      backend.permissions[1],
      ("p-2", @ports.PermissionDecision::AllowSession),
    )
  })
}

///|
async test "clients without the permission capability are denied by policy" {
  let provider = FakeProvider::new()
  let backend = FakeBackend::with_permission(1)
  with_gateway_backend(provider, Some(backend), async fn(ws) {
    // Old client: it did not advertise `realtime.permission`.
    hello(ws)
    let _ = read_event(ws)
    provider.push_tool_call(
      "call-1", "delegate_task", "{\"instruction\":\"x\"}",
    )
    let mut resolved = ""
    for _ in 0..<10 {
      match read_event(ws) {
        Some(@protocol.ServerEvent::PermissionResolved(decision~, source~, ..)) => {
          assert_eq(source, "policy")
          resolved = decision
          break
        }
        Some(@protocol.ServerEvent::PermissionRequest(..)) =>
          fail("must not prompt a client that did not advertise the capability")
        Some(_) => ()
        None => break
      }
    }
    assert_eq(resolved, "deny")
    assert_eq(backend.permissions[0].1, @ports.PermissionDecision::Deny)
  })
}

///|
async test "task tools are registered when a backend exists" {
  let provider = FakeProvider::new()
  let backend = FakeBackend::new()
  with_gateway_backend(provider, Some(backend), async fn(ws) {
    hello(ws)
    let _ = read_event(ws)
    match provider.tools {
      Some(Json::Array(items)) => {
        assert_eq(items.length(), 3)
        let text = Json::array(items).stringify()
        assert_true(text.contains("delegate_task"))
        assert_true(text.contains("get_agent_task_status"))
        assert_true(text.contains("cancel_agent_task"))
      }
      _ => fail("the provider did not receive the task tool list")
    }
  })
}

///|
async test "status tool reports the latest completed task" {
  let provider = FakeProvider::new()
  let backend = FakeBackend::new()
  with_gateway_backend(provider, Some(backend), async fn(ws) {
    hello_with_permission(ws)
    let _ = read_event(ws)
    provider.push_tool_call(
      "call-1", "delegate_task", "{\"instruction\":\"统计文件\"}",
    )
    let mut completed = false
    for _ in 0..<20 {
      match read_event(ws) {
        Some(@protocol.ServerEvent::TaskUpdated(status~, ..)) =>
          if status == "completed" {
            completed = true
            break
          }
        Some(_) => ()
        None => break
      }
    }
    assert_true(completed)
    provider.push_tool_call("call-2", "get_agent_task_status", "{}")
    for _ in 0..<20 {
      if provider.tool_results.length() >= 2 {
        break
      }
      @async.sleep(20)
    }
    assert_eq(provider.tool_results.length(), 2)
    let output = provider.tool_results[1].1
    assert_true(output.contains("\"state\":\"completed\""))
    assert_true(output.contains("agent answer: 统计文件"))
  })
}

///|
async test "cancel tool stops the running task without a late announcement" {
  let provider = FakeProvider::new()
  let backend = FakeBackend::new()
  backend.hold = true
  with_gateway_backend(provider, Some(backend), async fn(ws) {
    hello_with_permission(ws)
    let _ = read_event(ws)
    provider.push_tool_call(
      "call-1", "delegate_task", "{\"instruction\":\"长任务\"}",
    )
    for _ in 0..<20 {
      if backend.submitted.length() > 0 {
        break
      }
      @async.sleep(20)
    }
    provider.push_tool_call("call-2", "cancel_agent_task", "{}")
    let mut cancelled = false
    for _ in 0..<20 {
      match read_event(ws) {
        Some(@protocol.ServerEvent::TaskUpdated(status~, ..)) =>
          if status == "cancelled" {
            cancelled = true
            break
          }
        Some(_) => ()
        None => break
      }
    }
    assert_true(cancelled)
    for _ in 0..<20 {
      if provider.tool_results.length() >= 2 {
        break
      }
      @async.sleep(20)
    }
    assert_eq(provider.tool_results.length(), 2)
    assert_true(provider.tool_results[1].1.contains("\"status\":\"ok\""))
    assert_eq(backend.cancelled.length(), 1)
    assert_eq(backend.cancelled[0], "t-1")
    @async.sleep(100)
    assert_eq(provider.background_results.length(), 0)
  })
}

///|
async test "auth token accepts the query form" {
  let provider = FakeProvider::new()
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true) <| () => {
      @gateway.serve(server, fake_factory(provider), auth_token="secret")
    }
    @async.sleep(50)
    let ws = @websocket.connect(
      "ws://127.0.0.1:\{port}/api/realtime?token=secret",
    )
    defer ws.close()
    hello(ws)
    match read_event(ws) {
      Some(@protocol.ServerEvent::Ready(..)) => ()
      _ => fail("a valid query token should complete the handshake")
    }
  }
}

///|
async test "session limit rejects a second client" {
  let provider = FakeProvider::new()
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true) <| () => {
      @gateway.serve(server, fake_factory(provider), max_sessions=1)
    }
    @async.sleep(50)
    let first = @websocket.connect("ws://127.0.0.1:\{port}/api/realtime")
    hello(first)
    match read_event(first) {
      Some(@protocol.ServerEvent::Ready(..)) => ()
      _ => fail("the first session should be accepted")
    }
    let second = @websocket.connect("ws://127.0.0.1:\{port}/api/realtime")
    hello(second)
    match read_event(second) {
      Some(@protocol.ServerEvent::Error(code~, ..)) =>
        assert_eq(code, @protocol.ErrorCode::SessionLimit)
      _ => fail("the second session should be rejected")
    }
    first.close()
    second.close()
  }
}

///|
/// Start a gateway with workspace selection and run `body` with the port.
async fn with_gateway_workspaces(
  provider : FakeProvider,
  workspaces : @gateway.Workspaces,
  auth_token : String,
  body : async (Int32) -> Unit,
) -> Unit {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true) <| () => {
      @gateway.serve(server, fake_factory(provider), workspaces~, auth_token~)
    }
    @async.sleep(50)
    body(port)
  }
}

///|
/// Handshake asking for a specific agent working directory.
async fn hello_in(ws : @websocket.Conn, workspace : String) -> Unit {
  send_client(
    ws,
    @protocol.ClientEvent::Hello(
      request_id="c-1",
      protocol_version=@protocol.protocol_version,
      capabilities=[
        @protocol.capability_audio_in, @protocol.capability_audio_out, @protocol.capability_workspace,
      ],
      workspace~,
    ),
  )
}

///|
async test "hello accepts an existing directory and echoes it" {
  let base = @fs.tmpdir(prefix="mediapilot-ws-")
  let child = base + "/child"
  @fs.mkdir(child, recursive=true, allow_exist=true)
  let resolved = @fs.realpath(child + "/") catch { _ => child }
  let provider = FakeProvider::new()
  let seen : Array[String] = []
  let workspaces = @gateway.Workspaces::new(base, true)
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let port = server.addr.port()
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true) <| () => {
      @gateway.serve(server, fake_factory(provider), workspaces~, open_backend=fn(
        _session_id,
        workspace,
      ) {
        seen.push(workspace)
        Ok(FakeBackend::new() as &@ports.BackendPort)
      })
    }
    @async.sleep(50)
    let ws = @websocket.connect("ws://127.0.0.1:\{port}/api/realtime")
    defer ws.close()
    hello_in(ws, child + "/")
    match read_event(ws) {
      Some(@protocol.ServerEvent::Ready(workspace~, ..)) =>
        assert_eq(workspace, resolved)
      _ => fail("an existing directory should be accepted")
    }
    assert_eq(seen, [resolved])
  }
  @fs.rmdir(base, recursive=true, allow_missing=true)
}

///|
async test "hello without a workspace uses the configured default" {
  let base = @fs.tmpdir(prefix="mediapilot-ws-")
  let resolved = @fs.realpath(base) catch { _ => base }
  let provider = FakeProvider::new()
  let workspaces = @gateway.Workspaces::new(resolved, true)
  with_gateway_workspaces(provider, workspaces, "", async fn(port) {
    let ws = @websocket.connect("ws://127.0.0.1:\{port}/api/realtime")
    defer ws.close()
    hello(ws)
    match read_event(ws) {
      Some(@protocol.ServerEvent::Ready(workspace~, ..)) =>
        assert_eq(workspace, resolved)
      _ => fail("the default workspace should be announced")
    }
  })
  @fs.rmdir(base, recursive=true, allow_missing=true)
}

///|
async test "hello rejects missing and relative workspaces" {
  let base = @fs.tmpdir(prefix="mediapilot-ws-")
  let provider = FakeProvider::new()
  let workspaces = @gateway.Workspaces::new(base, true)
  with_gateway_workspaces(provider, workspaces, "", async fn(port) {
    let missing = @websocket.connect("ws://127.0.0.1:\{port}/api/realtime")
    hello_in(missing, base + "/does-not-exist")
    match read_event(missing) {
      Some(@protocol.ServerEvent::Error(code~, retryable~, ..)) => {
        assert_eq(code, @protocol.ErrorCode::WorkspaceDenied)
        assert_false(retryable)
      }
      _ => fail("a missing directory should be rejected")
    }
    missing.close()
    let relative = @websocket.connect("ws://127.0.0.1:\{port}/api/realtime")
    hello_in(relative, "relative/path")
    match read_event(relative) {
      Some(@protocol.ServerEvent::Error(code~, ..)) =>
        assert_eq(code, @protocol.ErrorCode::WorkspaceDenied)
      _ => fail("a relative path should be rejected")
    }
    relative.close()
  })
  @fs.rmdir(base, recursive=true, allow_missing=true)
}

///|
async test "filesystem roots require the token and report the default" {
  let base = @fs.tmpdir(prefix="mediapilot-ws-")
  let provider = FakeProvider::new()
  let workspaces = @gateway.Workspaces::new(base, true)
  with_gateway_workspaces(provider, workspaces, "secret", async fn(port) {
    let url = "http://127.0.0.1:\{port}/api/fs/roots"
    let (anonymous, _) = @http.get_text(url)
    assert_eq(anonymous.code, 401)
    let (authorized, body) = @http.get_text(
      url,
      headers=Map([("Authorization", "Bearer secret")]),
    )
    assert_eq(authorized.code, 200)
    let map = match @json.parse(body) {
      @json.Json::Object(map) => map
      _ => fail("roots response must be an object")
    }
    assert_eq(
      map.get("default"),
      Some(@json.Json::string(@fs.realpath(base) catch { _ => base })),
    )
    assert_eq(map.get("enabled"), Some(@json.Json::boolean(true)))
    match map.get("roots") {
      Some(@json.Json::Array(roots)) => assert_true(roots.length() > 0)
      _ => fail("roots must be a non-empty array")
    }
  })
  @fs.rmdir(base, recursive=true, allow_missing=true)
}

///|
async test "filesystem listing returns sorted subdirectories" {
  let base = @fs.tmpdir(prefix="mediapilot-ws-")
  @fs.mkdir(base + "/beta", recursive=true, allow_exist=true)
  @fs.mkdir(base + "/alpha", recursive=true, allow_exist=true)
  @fs.write_text(base + "/file.txt", "x")
  let provider = FakeProvider::new()
  let workspaces = @gateway.Workspaces::new(base, true)
  with_gateway_workspaces(provider, workspaces, "", async fn(port) {
    let query = (base + "/").replace_all(old="\\", new="/")
    let url = "http://127.0.0.1:\{port}/api/fs/list?path=" + query
    let (response, body) = @http.get_text(url)
    assert_eq(response.code, 200)
    let map = match @json.parse(body) {
      @json.Json::Object(map) => map
      _ => fail("listing response must be an object")
    }
    let entries = match map.get("entries") {
      Some(@json.Json::Array(items)) => items
      _ => fail("entries must be an array")
    }
    assert_eq(entries.length(), 2)
    let first = match entries[0] {
      @json.Json::Object(entry) => entry
      _ => fail("entry must be an object")
    }
    assert_eq(first.get("name"), Some(@json.Json::string("alpha")))
    let (missing_path, _) = @http.get_text(
      "http://127.0.0.1:\{port}/api/fs/list",
    )
    assert_eq(missing_path.code, 400)
  })
  @fs.rmdir(base, recursive=true, allow_missing=true)
}
