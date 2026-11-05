///|
fn test_backend() -> AcpBackend {
  AcpBackend::new({
    command: "opencode",
    args: ["acp"],
    cwd: ".",
    inherit_env: true,
  })
}

///|
/// Take one queued backend event, or `None`.
fn take_event(backend : AcpBackend) -> @ports.BackendEvent? {
  try {
    match backend.events.try_get() {
      Some(Some(event)) => Some(event)
      _ => None
    }
  } catch {
    _ => None
  }
}

///|
async test "acp frames are newline-delimited json-rpc" {
  let frame = frame_request(
    7,
    "session/new",
    Json::object({ "cwd": Json::string("/tmp") }),
  )
  assert_true(frame.has_suffix("\n"))
  let parsed = @json.parse(frame.trim_end())
  match parsed {
    Json::Object(map) => {
      assert_eq(map.get("jsonrpc"), Some(Json::string("2.0")))
      assert_eq(map.get("method"), Some(Json::string("session/new")))
      assert_eq(map.get("id"), Some(Json::number(7.0)))
    }
    _ => panic()
  }
}

///|
async test "acp initializes without fs or terminal capabilities" {
  let params = initialize_params()
  match params {
    Json::Object(map) => {
      assert_eq(map.get("protocolVersion"), Some(Json::number(1.0)))
      let capabilities = match map.get("clientCapabilities") {
        Some(Json::Object(value)) => value
        _ => panic()
      }
      assert_eq(capabilities.get("terminal"), Some(Json::boolean(false)))
      let fs = match capabilities.get("fs") {
        Some(Json::Object(value)) => value
        _ => panic()
      }
      assert_eq(fs.get("readTextFile"), Some(Json::boolean(false)))
      assert_eq(fs.get("writeTextFile"), Some(Json::boolean(false)))
    }
    _ => panic()
  }
}

///|
async test "acp maps agent message chunks to text deltas" {
  let backend = test_backend()
  let frame = "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"s-1\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"你好\"}}}}"
  let ended = backend.handle_frame(frame)
  assert_false(ended)
  assert_eq(
    take_event(backend),
    Some(@ports.BackendEvent::TextDelta(text="你好")),
  )
  assert_eq(backend.turn_text, "你好")
}

///|
async test "acp maps tool calls to progress and ignores unknown updates" {
  let backend = test_backend()
  let tool = "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"s-1\",\"update\":{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"c-1\",\"title\":\"Reading gateway/server.mbt\"}}}"
  let _ = backend.handle_frame(tool)
  assert_eq(
    take_event(backend),
    Some(@ports.BackendEvent::Progress(text="Reading gateway/server.mbt")),
  )
  let unknown = "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"s-1\",\"update\":{\"sessionUpdate\":\"plan\",\"entries\":[]}}}"
  let _ = backend.handle_frame(unknown)
  assert_eq(take_event(backend), None)
}

///|
async test "acp turns permission requests into backend events" {
  let backend = test_backend()
  let frame = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/request_permission\",\"params\":{\"sessionId\":\"s-1\",\"toolCall\":{\"toolCallId\":\"c-1\",\"title\":\"Run `moon test`\",\"kind\":\"execute\"},\"options\":[{\"optionId\":\"allow-once\",\"name\":\"Allow once\",\"kind\":\"allow_once\"},{\"optionId\":\"reject-once\",\"name\":\"Reject\",\"kind\":\"reject_once\"}]}}"
  let _ = backend.handle_frame(frame)
  match take_event(backend) {
    Some(
      @ports.BackendEvent::PermissionRequest(
        request_id~,
        operation~,
        description~
      )
    ) => {
      assert_eq(request_id, "p-3")
      assert_eq(operation, "execute")
      assert_eq(description, "Run `moon test`")
    }
    _ => panic()
  }
  assert_true(backend.permissions.contains("p-3"))
}

///|
async test "acp routes responses to the waiting request" {
  let backend = test_backend()
  let slot : @aqueue.Queue[Json] = @aqueue.Queue(kind=Blocking(1))
  backend.pending.set(11, slot)
  let _ = backend.handle_frame(
    "{\"jsonrpc\":\"2.0\",\"id\":11,\"result\":{\"sessionId\":\"s-9\"}}",
  )
  let response = slot.get()
  match response {
    Json::Object(map) =>
      match map.get("result") {
        Some(Json::Object(result)) =>
          assert_eq(result.get("sessionId"), Some(Json::string("s-9")))
        _ => panic()
      }
    _ => panic()
  }
  assert_false(backend.pending.contains(11))
}

///|
test "acp picks the option that matches the decision" {
  let options : Array[AcpOption] = [
    { option_id: "allow-once", kind: "allow_once", },
    { option_id: "allow-always", kind: "allow_always", },
    { option_id: "reject-once", kind: "reject_once", },
  ]
  assert_eq(
    choose_option(options, @ports.PermissionDecision::AllowOnce),
    "allow-once",
  )
  assert_eq(
    choose_option(options, @ports.PermissionDecision::AllowSession),
    "allow-always",
  )
  assert_eq(
    choose_option(options, @ports.PermissionDecision::Deny),
    "reject-once",
  )
  let deny_only : Array[AcpOption] = [
    { option_id: "reject", kind: "reject_once", },
  ]
  assert_eq(choose_option(deny_only, @ports.PermissionDecision::AllowOnce), "")
}

///|
test "permission decision tokens round trip" {
  let tokens = ["allow_once", "allow_task", "allow_session", "deny"]
  let decisions = [
    @ports.PermissionDecision::AllowOnce,
    @ports.PermissionDecision::AllowTask,
    @ports.PermissionDecision::AllowSession,
    @ports.PermissionDecision::Deny,
  ]
  for i in 0..<tokens.length() {
    assert_eq(decisions[i].to_token(), tokens[i])
    assert_eq(
      @ports.PermissionDecision::from_token(tokens[i]),
      Some(decisions[i]),
    )
  }
  assert_eq(@ports.PermissionDecision::from_token("always"), None)
  assert_true(@ports.PermissionDecision::AllowOnce.allows())
  assert_false(@ports.PermissionDecision::Deny.allows())
}
