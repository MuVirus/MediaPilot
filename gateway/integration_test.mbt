///|
/// A scripted provider used by gateway integration tests.
///
/// It records what the gateway sent upstream and replays a fixed event
/// sequence downstream, so the tests exercise the real WebSocket path without
/// touching the network.
struct FakeProvider {
  sent_audio : Array[String]
  sent_text : Array[String]
  mut interrupted : Bool
  tool_results : Array[(String, String)]
  mut closed : Bool
  events : @aqueue.Queue[@ports.RealtimeEvent?]
}

///|
fn FakeProvider::new() -> FakeProvider {
  {
    sent_audio: [],
    sent_text: [],
    interrupted: false,
    tool_results: [],
    closed: false,
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
pub impl @ports.RealtimeProvider for FakeProvider with fn close(self) {
  self.closed = true
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
) {
  self.tool_results.push((call_id, output))
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
  async fn(_session_id, _tools) { Ok(provider as &@ports.RealtimeProvider) }
}

///|
/// A scripted backend that answers every task with a fixed string.
struct FakeBackend {
  submitted : Array[String]
  events : @aqueue.Queue[@ports.BackendEvent?]
}

///|
fn FakeBackend::new() -> FakeBackend {
  { submitted: [], events: @aqueue.Queue(kind=Blocking(16)), }
}

///|
pub impl @ports.BackendPort for FakeBackend with fn submit(
  self,
  _task_id,
  instruction,
) {
  self.submitted.push(instruction)
  let answer = "agent answer: " + instruction
  self.events.put(Some(@ports.BackendEvent::TextDelta(text="agent ")))
  self.events.put(Some(@ports.BackendEvent::TextDelta(text="answer")))
  self.events.put(Some(@ports.BackendEvent::TextDone(text=answer)))
  self.events.put(Some(@ports.BackendEvent::Completed))
}

///|
pub impl @ports.BackendPort for FakeBackend with fn cancel(_self, _task_id) {

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
  _self,
  _request_id,
  _allow,
) {

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
  async fn(_session_id) { Ok(backend as &@ports.BackendPort) }
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
    Some(text) =>
      match @protocol.decode_server_event(text) {
        Ok(event) => event
        Err(_) => None
      }
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
      @protocol.ClientEvent::Hello(request_id="c-1", protocol_version="1.0.0", capabilities=[]),
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
    // The gateway must answer the model with the same text.
    @async.sleep(120)
    assert_eq(backend.submitted, ["查一下明天杭州的天气"])
    assert_eq(provider.tool_results.length(), 1)
    let (call_id, output) = provider.tool_results[0]
    assert_eq(call_id, "call-1")
    assert_true(output.contains("agent answer"))
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
    let (_, output) = provider.tool_results[0]
    assert_true(output.contains("unknown tool"))
  })
}
