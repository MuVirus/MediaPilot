///|
fn test_config(port : Int32) -> @backend.LlmConfig {
  @backend.LlmConfig::{
    base_url: "http://127.0.0.1:" + port.to_string(),
    api_key: "test-key",
    model: "qwen-plus",
    system_prompt: "be brief",
  }
}

///|
/// Start a fake chat-completions server that answers with `response_body` and
/// the given status, then run `body` against a backend pointed at it.
async fn with_llm_server(
  status : Int32,
  response_body : String,
  run : async (@backend.LlmBackend) -> Unit,
) -> Unit {
  let server = @http.Server(@socket.Addr::parse("127.0.0.1:0"))
  let http_port = server.addr.port()
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true) <| () => {
      server.run_forever((_request, conn) => {
        conn.skip_request_body() catch {
          _ => ()
        }
        conn.send_response(
          status,
          if status == 200 {
            "OK"
          } else {
            "Error"
          },
          extra_headers=Map([
            (@http.CaseInsensitiveString("Content-Type"), "text/event-stream"),
            (
              @http.CaseInsensitiveString("Content-Length"),
              @utf8.encode(response_body).length().to_string(),
            ),
          ]),
        )
        conn.text.write(response_body)
        conn.end_response()
      })
    }
    @async.sleep(80)
    run(@backend.LlmBackend::new(test_config(http_port)))
  }
}

///|
/// Drain events until `Completed`, `Failed`, or a closed stream.
///
/// Returns the accumulated text and the terminal event.
async fn drain(backend : @backend.LlmBackend) -> (String, @ports.BackendEvent?) {
  let port : &@ports.BackendPort = backend as &@ports.BackendPort
  let mut accumulated = ""
  for _ in 0..<64 {
    match port.next_event() {
      None => return (accumulated, None)
      Some(@ports.BackendEvent::TextDelta(text~)) =>
        accumulated = accumulated + text
      Some(@ports.BackendEvent::Completed) =>
        return (accumulated, Some(@ports.BackendEvent::Completed))
      Some(@ports.BackendEvent::Failed(code~, message~, retryable~)) =>
        return (
          accumulated,
          Some(@ports.BackendEvent::Failed(code~, message~, retryable~)),
        )
      Some(_) => ()
    }
  }
  (accumulated, None)
}

///|
async test "llm backend streams text deltas" {
  let body = "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\n\ndata: [DONE]\n\n"
  with_llm_server(200, body, async fn(backend) {
    let port : &@ports.BackendPort = backend as &@ports.BackendPort
    port.submit("t-1", "say hello")
    let (text, last) = drain(backend)
    assert_eq(last, Some(@ports.BackendEvent::Completed))
    assert_eq(text, "hello world")
  })
}

///|
async test "llm backend emits text done with the full answer" {
  let body = "data: {\"choices\":[{\"delta\":{\"content\":\"abc\"}}]}\n\ndata: [DONE]\n\n"
  with_llm_server(200, body, async fn(backend) {
    let port : &@ports.BackendPort = backend as &@ports.BackendPort
    port.submit("t-1", "x")
    let mut done = ""
    for _ in 0..<16 {
      match port.next_event() {
        Some(@ports.BackendEvent::TextDone(text~)) => {
          done = text
          break
        }
        Some(@ports.BackendEvent::Completed) => break
        Some(_) => ()
        None => break
      }
    }
    assert_eq(done, "abc")
  })
}

///|
async test "llm backend maps 401 to a non-retryable auth failure" {
  with_llm_server(401, "{\"error\":{\"message\":\"bad key\"}}", async fn(
    backend,
  ) {
    let port : &@ports.BackendPort = backend as &@ports.BackendPort
    port.submit("t-1", "x")
    let (_, last) = drain(backend)
    match last {
      Some(@ports.BackendEvent::Failed(code~, message~, retryable~)) => {
        assert_eq(code, @protocol.ErrorCode::ProviderAuthFailed)
        assert_false(retryable)
        assert_true(message.contains("bad key"))
      }
      _ => panic()
    }
  })
}

///|
async test "llm backend maps 500 to a retryable provider failure" {
  with_llm_server(500, "upstream exploded", async fn(backend) {
    let port : &@ports.BackendPort = backend as &@ports.BackendPort
    port.submit("t-1", "x")
    let (_, last) = drain(backend)
    match last {
      Some(@ports.BackendEvent::Failed(code~, retryable~, ..)) => {
        assert_eq(code, @protocol.ErrorCode::ProviderUnavailable)
        assert_true(retryable)
      }
      _ => panic()
    }
  })
}

///|
async test "llm backend reports provider errors inside the stream" {
  let body = "data: {\"error\":{\"message\":\"model overloaded\"}}\n\ndata: [DONE]\n\n"
  with_llm_server(200, body, async fn(backend) {
    let port : &@ports.BackendPort = backend as &@ports.BackendPort
    port.submit("t-1", "x")
    let (_, last) = drain(backend)
    match last {
      Some(@ports.BackendEvent::Failed(message~, ..)) =>
        assert_true(message.contains("model overloaded"))
      _ => panic()
    }
  })
}

///|
async test "llm backend closes with a sentinel" {
  with_llm_server(200, "data: [DONE]\n\n", async fn(backend) {
    let port : &@ports.BackendPort = backend as &@ports.BackendPort
    port.close()
    assert_eq(port.next_event(), None)
  })
}
