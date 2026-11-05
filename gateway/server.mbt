///|
/// Opens one upstream session for a client session.
///
/// The second argument is the tool list the gateway wants registered, or `None`
/// when no backend is configured. `cmd/` supplies this so `gateway/` never
/// imports a provider package.
pub type ProviderFactory = async (String, Json?) -> Result[
  &@ports.RealtimeProvider,
  @ports.ProviderFailure,
]

///|
/// Opens one agent backend for a client session. `None` means the deployment
/// has no backend and `delegate_task` is not offered to the model.
pub type BackendFactory = async (String) -> Result[
  &@ports.BackendPort,
  @ports.ProviderFailure,
]

///|
/// How many northbound events may queue before the provider reader blocks.
/// This is the backpressure bound from `docs/architecture.md`.
pub let outbound_capacity : Int32 = 256

///|
/// Start the gateway and serve until the process is stopped.
///
/// `static_root` is the directory holding the browser client. When omitted,
/// only the API routes are served.
pub async fn run_gateway(
  bind : String,
  open_provider : ProviderFactory,
  open_backend? : BackendFactory,
  static_root? : String,
) -> Unit {
  let addr = @socket.Addr::parse(bind)
  let server = @http.Server(addr)
  println("[gateway] listening on " + bind)
  match (open_backend, static_root) {
    (Some(backend), Some(root)) =>
      serve(server, open_provider, open_backend=backend, static_root=root)
    (Some(backend), None) => serve(server, open_provider, open_backend=backend)
    (None, Some(root)) => serve(server, open_provider, static_root=root)
    (None, None) => serve(server, open_provider)
  }
}

///|
/// Serve on an already-bound server. Tests use this with port 0 so they can
/// read the assigned port before connecting.
pub async fn serve(
  server : @http.Server,
  open_provider : ProviderFactory,
  open_backend? : BackendFactory,
  static_root? : String,
) -> Unit {
  server.run_forever((request, conn) => {
    match (request.meth, request.path) {
      (Get, "/api/health") => handle_health(conn)
      (Get, "/api/realtime") =>
        match open_backend {
          Some(backend) =>
            handle_realtime(request, conn, open_provider, open_backend=backend)
          None => handle_realtime(request, conn, open_provider)
        }
      (Get, path) =>
        match static_root {
          Some(root) => handle_static(conn, root, path)
          None => handle_not_found(conn)
        }
      _ => handle_not_found(conn)
    }
  })
}

///|
/// Byte length, not UTF-16 code units: `Content-Length` counts bytes.
fn byte_length(text : String) -> Int32 {
  @utf8.encode(text).length()
}

///|
async fn respond(
  conn : @http.ServerConnection,
  code : Int32,
  reason : String,
  content_type : String,
  body : String,
) -> Unit {
  conn.send_response(
    code,
    reason,
    extra_headers=Map([
      (@http.CaseInsensitiveString("Content-Type"), content_type),
      (
        @http.CaseInsensitiveString("Content-Length"),
        byte_length(body).to_string(),
      ),
    ]),
  )
  conn.text.write(body)
}

///|
async fn handle_health(conn : @http.ServerConnection) -> Unit {
  respond(conn, 200, "OK", "application/json", health_json())
}

///|
async fn handle_not_found(conn : @http.ServerConnection) -> Unit {
  respond(
    conn, 404, "NotFound", "application/json", "{\"error\":\"not_found\"}",
  )
}

///|
/// Static files are an explicit allowlist, so a request path can never escape
/// `static_root`.
fn static_file(path : String) -> (String, String)? {
  match path {
    "/" | "/index.html" => Some(("index.html", "text/html; charset=utf-8"))
    "/app.js" => Some(("app.js", "text/javascript; charset=utf-8"))
    "/pcm-worklet.js" =>
      Some(("pcm-worklet.js", "text/javascript; charset=utf-8"))
    "/style.css" => Some(("style.css", "text/css; charset=utf-8"))
    _ => None
  }
}

///|
async fn handle_static(
  conn : @http.ServerConnection,
  root : String,
  path : String,
) -> Unit {
  let (name, content_type) = match static_file(path) {
    Some(entry) => entry
    None => {
      handle_not_found(conn)
      return
    }
  }
  let body = @fs.read_text(root + "/" + name) catch {
    _ => {
      handle_not_found(conn)
      return
    }
  }
  respond(conn, 200, "OK", content_type, body)
}

///|
async fn send_event(
  ws : @websocket.Conn,
  event : @protocol.ServerEvent,
) -> Unit {
  ws.send_text(@protocol.encode_server_event_string(event))
}

///|
async fn send_error(
  ws : @websocket.Conn,
  code : @protocol.ErrorCode,
  message : String,
  retryable : Bool,
) -> Unit {
  send_event(ws, @protocol.ServerEvent::Error(code~, message~, retryable~))
}

///|
/// One client connection: handshake, then bridge client and provider.
async fn handle_realtime(
  request : @http.RequestHeader,
  conn : @http.ServerConnection,
  open_provider : ProviderFactory,
  open_backend? : BackendFactory,
) -> Unit {
  let ws = @websocket.from_http_server(request, conn) catch {
    _ => {
      handle_not_found(conn)
      return
    }
  }
  defer ws.close()
  // 1. Handshake. The first frame must be `session.hello`.
  let hello = match read_client_event(ws) {
    None => return
    Some(Err(error)) => {
      send_error(ws, protocol_error_code(error), error.to_string(), false)
      return
    }
    Some(
      Ok(
        Some(
          @protocol.ClientEvent::Hello(
            request_id~,
            protocol_version~,
            capabilities~
          )
        )
      )
    ) => (request_id, protocol_version, capabilities)
    Some(Ok(_)) => {
      send_error(
        ws,
        @protocol.ErrorCode::HandshakeRequired,
        "first event must be session.hello",
        false,
      )
      return
    }
  }
  let (request_id, protocol_version, client_capabilities) = hello
  if !@protocol.is_compatible_version(protocol_version) {
    send_error(
      ws,
      @protocol.ErrorCode::UnsupportedVersion,
      "unsupported protocol version " + protocol_version,
      false,
    )
    return
  }
  let session_id = next_session_id()
  let backend = match open_backend {
    Some(factory) =>
      match factory(session_id) {
        Ok(backend) => Some(backend)
        Err(failure) => {
          println(
            "[gateway] backend unavailable, continuing without tools: " +
            failure.message,
          )
          None
        }
      }
    None => None
  }
  let tools = match backend {
    Some(_) => Some(Json::array([delegate_task_tool()]))
    None => None
  }
  let provider = match open_provider(session_id, tools) {
    Ok(provider) => provider
    Err(failure) => {
      match backend {
        Some(backend) => backend.close() catch { _ => () }
        None => ()
      }
      send_error(ws, failure.code, failure.message, failure.retryable)
      return
    }
  }
  let capabilities = negotiate_capabilities(client_capabilities)
  send_event(
    ws,
    @protocol.ServerEvent::Ready(
      request_id~,
      session_id~,
      protocol_version=@protocol.protocol_version,
      capabilities~,
    ),
  )
  bridge(ws, provider, session_id, capabilities, backend)
  provider.close()
  match backend {
    Some(backend) => backend.close() catch { _ => () }
    None => ()
  }
}

///|
/// The single tool the gateway offers the realtime coordinator.
///
/// The model is told to hand real work to the backend instead of pretending to
/// do it. Small talk stays in the realtime model so latency stays low.
pub fn delegate_task_tool() -> Json {
  Json::object({
    "type": Json::string("function"),
    "function": Json::object({
      "name": Json::string("delegate_task"),
      "description": Json::string(
        "Hand a multi-step task to the background agent. Use this when the user asks you to actually do something that needs tools, files, code, or current information. Do not use it for small talk or questions you can answer yourself.",
      ),
      "parameters": Json::object({
        "type": Json::string("object"),
        "properties": Json::object({
          "instruction": Json::object({
            "type": Json::string("string"),
            "description": Json::string(
              "A self-contained instruction for the agent. Include all context it needs, because it cannot hear the conversation.",
            ),
          }),
        }),
        "required": Json::array([Json::string("instruction")]),
        "additionalProperties": Json::boolean(false),
      }),
    }),
  })
}

///|
/// Intersect the client's capabilities with ours, preserving our order.
pub fn negotiate_capabilities(client : Array[String]) -> Array[String] {
  let result : Array[String] = []
  for capability in @protocol.all_capabilities() {
    if client.contains(capability) {
      result.push(capability)
    }
  }
  result
}

///|
/// Map a decode failure to a contract error code.
fn protocol_error_code(error : @protocol.ProtocolError) -> @protocol.ErrorCode {
  match error {
    UnsupportedVersion(_) => @protocol.ErrorCode::UnsupportedVersion
    InvalidJson(_) | MissingField(_) | InvalidField(_, _) =>
      @protocol.ErrorCode::InvalidEvent
  }
}

///|
/// Read one client frame.
///
/// `None` means the transport closed. `Some(Err(_))` means the frame was
/// readable but not a valid event, which the caller must report to the client
/// instead of closing silently.
async fn read_client_event(
  ws : @websocket.Conn,
) -> Result[@protocol.ClientEvent?, @protocol.ProtocolError]? {
  let raw = ws.recv().text.read_all() catch { _ => return None }
  Some(@protocol.decode_client_event(raw))
}

///|
/// The gateway asks the client and waits this long before treating a permission
/// request as denied.
pub let permission_timeout_ms : Int32 = 60000

///|
/// A client answer to one `permission.request`.
priv struct PermissionAnswer {
  request_id : String
  decision : @ports.PermissionDecision
  /// `client`, `timeout`, `policy`, or `cancelled`.
  source : String
}

///|
/// State shared by the two pumps of one client session.
priv struct SessionFlow {
  outbound : @aqueue.Queue[@protocol.ServerEvent?]
  session_id : String
  answers : @aqueue.Queue[PermissionAnswer]
  /// The request id the gateway is waiting on, or "" when none.
  pending_permission : Ref[String]
  /// The delegated task id, or "" when idle. Used to cancel on interrupt.
  current_task : Ref[String]
  /// Incremented on every client interrupt. A queued task captures the value
  /// when it is accepted and is dropped if the generation moved on.
  interrupt_generation : Ref[Int32]
  /// Set once the client allows everything for the rest of the session.
  session_allow : Ref[Bool]
  /// True when the client advertised `realtime.permission`, so the gateway may
  /// ask. A client that did not is denied by policy instead of waiting.
  can_ask : Bool
}

///|
/// One accepted `delegate_task`, waiting for the serial task runner.
priv struct TaskJob {
  task_id : String
  instruction : String
  /// Value of `SessionFlow::interrupt_generation` at acceptance.
  generation : Int32
}

///|
/// How one delegated task ended. The runner turns this into either a spoken
/// background result or silence.
priv enum TaskOutcome {
  Completed(text~ : String)
  Failed(message~ : String)
  Cancelled
}

///|
async fn SessionFlow::task_updated(
  self : SessionFlow,
  task_id : String,
  status : String,
  text : String,
  step : String,
) -> Unit {
  self.outbound.put(
    Some(
      @protocol.ServerEvent::TaskUpdated(
        session_id=self.session_id,
        task_id~,
        status~,
        text~,
        step~,
      ),
    ),
  )
}

///|
/// Run the three pumps until the session ends.
///
/// - client reader: decodes client events and drives the provider
/// - provider reader: normalizes upstream events into the outbound queue
/// - writer: drains the queue to the client
///
/// The queue is bounded, so a slow client blocks the provider reader instead
/// of growing memory without limit.
async fn bridge(
  ws : @websocket.Conn,
  provider : &@ports.RealtimeProvider,
  session_id : String,
  capabilities : Array[String],
  backend : &@ports.BackendPort?,
) -> Unit {
  let outbound : @aqueue.Queue[@protocol.ServerEvent?] = @aqueue.Queue(
    kind=Blocking(outbound_capacity),
  )
  let done : @aqueue.Queue[Unit] = @aqueue.Queue(kind=Blocking(1))
  // Set when the client closed on purpose, so an upstream shutdown is not
  // reported back as a retryable error.
  let client_closing : Ref[Bool] = Ref(false)
  // Accepted tasks wait here so the provider reader never blocks on one.
  let tool_jobs : @aqueue.Queue[TaskJob?] = @aqueue.Queue(kind=Blocking(4))
  let flow : SessionFlow = {
    outbound,
    session_id,
    answers: @aqueue.Queue(kind=Blocking(4)),
    pending_permission: Ref(""),
    current_task: Ref(""),
    interrupt_generation: Ref(0),
    session_allow: Ref(false),
    can_ask: capabilities.contains(@protocol.capability_permission),
  }
  @async.with_task_group() <| group => {
    // Prepare the backend while the user is still talking, so the first
    // delegated task does not pay the process and handshake cost.
    match backend {
      Some(backend) =>
        group.spawn_bg(no_wait=true) <| () => { backend.warmup() }
      None => ()
    }
    group.spawn_bg(no_wait=true) <| () => {
      client_pump(ws, provider, flow, client_closing, backend)
      done.put(())
    }
    group.spawn_bg(no_wait=true) <| () => {
      provider_pump(provider, flow, client_closing, backend, tool_jobs)
    }
    match backend {
      Some(backend) =>
        group.spawn_bg(no_wait=true) <| () => {
          tool_runner(provider, backend, flow, tool_jobs)
        }
      None => ()
    }
    group.spawn_bg(no_wait=true) <| () => {
      writer_pump(ws, outbound)
      done.put(())
    }
    done.get()
  }
}

///|
/// Drop queued events that belong to the response the user just cancelled.
///
/// The sentinel is put back so the writer still learns the session ended.
async fn drain_outbound(
  outbound : @aqueue.Queue[@protocol.ServerEvent?],
) -> Unit {
  let mut sentinel = false
  for ;; {
    let item = outbound.try_get() catch { _ => break }
    match item {
      Some(Some(_)) => ()
      Some(None) => {
        sentinel = true
        break
      }
      None => break
    }
  }
  if sentinel {
    outbound.put(None)
  }
}

///|
async fn client_pump(
  ws : @websocket.Conn,
  provider : &@ports.RealtimeProvider,
  flow : SessionFlow,
  client_closing : Ref[Bool],
  backend : &@ports.BackendPort?,
) -> Unit {
  let input_rate = provider.input_sample_rate()
  for ;; {
    let raw = ws.recv().text.read_all() catch {
      _ => {
        client_closing.val = true
        return
      }
    }
    let event = match @protocol.decode_client_event(raw) {
      Ok(event) => event
      Err(error) => {
        flow.outbound.put(
          Some(
            @protocol.ServerEvent::Error(
              code=@protocol.ErrorCode::InvalidEvent,
              message=error.to_string(),
              retryable=false,
            ),
          ),
        )
        continue
      }
    }
    match event {
      None => ()
      Some(@protocol.ClientEvent::Hello(..)) =>
        flow.outbound.put(
          Some(
            @protocol.ServerEvent::Error(
              code=@protocol.ErrorCode::InvalidEvent,
              message="session.hello is only valid once",
              retryable=false,
            ),
          ),
        )
      Some(
        @protocol.ClientEvent::AudioAppend(
          data~,
          format~,
          sample_rate~,
          channels~
        )
      ) =>
        if format != "pcm16" || sample_rate != input_rate || channels != 1 {
          flow.outbound.put(
            Some(
              @protocol.ServerEvent::Error(
                code=@protocol.ErrorCode::AudioFormatUnsupported,
                message="expected pcm16 mono " +
                  input_rate.to_string() +
                  " Hz, got " +
                  format +
                  " " +
                  channels.to_string() +
                  "ch " +
                  sample_rate.to_string() +
                  " Hz",
                retryable=false,
              ),
            ),
          )
        } else {
          provider.send_audio(data)
        }
      Some(@protocol.ClientEvent::Text(text~)) => provider.send_text(text)
      Some(@protocol.ClientEvent::PermissionRespond(request_id~, decision~)) => {
        let parsed = match @ports.PermissionDecision::from_token(decision) {
          Some(decision) => decision
          None => {
            flow.outbound.put(
              Some(
                @protocol.ServerEvent::Error(
                  code=@protocol.ErrorCode::InvalidEvent,
                  message="unknown permission decision: " + decision,
                  retryable=false,
                ),
              ),
            )
            continue
          }
        }
        if flow.pending_permission.val != request_id {
          flow.outbound.put(
            Some(
              @protocol.ServerEvent::Error(
                code=@protocol.ErrorCode::InvalidEvent,
                message="no pending permission request for " + request_id,
                retryable=false,
              ),
            ),
          )
        } else {
          flow.answers.put({ request_id, decision: parsed, source: "client", })
        }
      }
      Some(@protocol.ClientEvent::Interrupt) => {
        // Cancel upstream first, then drop audio already queued for the
        // cancelled response, then confirm to the client.
        provider.interrupt()
        drain_outbound(flow.outbound)
        // Stop the delegated task too. The waiter gets a cancel answer so it
        // does not sit on the permission timeout.
        let task_id = flow.current_task.val
        flow.interrupt_generation.val = flow.interrupt_generation.val + 1
        if task_id != "" {
          match backend {
            Some(backend) => backend.cancel(task_id)
            None => ()
          }
          let pending = flow.pending_permission.val
          if pending != "" {
            flow.answers.put({
              request_id: pending,
              decision: @ports.PermissionDecision::Deny,
              source: "cancelled",
            })
          }
        }
        flow.outbound.put(
          Some(
            @protocol.ServerEvent::PlaybackClear(
              session_id=flow.session_id,
              reason="client_interrupt",
            ),
          ),
        )
      }
      Some(@protocol.ClientEvent::Close) => {
        client_closing.val = true
        return
      }
      Some(@protocol.ClientEvent::ImageAppend(..)) =>
        flow.outbound.put(
          Some(
            @protocol.ServerEvent::Error(
              code=@protocol.ErrorCode::InvalidEvent,
              message="image input is not supported before P4",
              retryable=false,
            ),
          ),
        )
    }
  }
}

///|
/// Read upstream events and accept tool calls without waiting for the work.
///
/// A `delegate_task` is answered immediately with an acceptance receipt so the
/// model can speak a short confirmation. The actual work runs in `tool_runner`
/// and comes back later as a background result, which is why this loop must
/// keep reading provider events.
async fn provider_pump(
  provider : &@ports.RealtimeProvider,
  flow : SessionFlow,
  client_closing : Ref[Bool],
  backend : &@ports.BackendPort?,
  tool_jobs : @aqueue.Queue[TaskJob?],
) -> Unit {
  let mut task_seq : Int32 = 0
  for ;; {
    match provider.next_event() {
      Some(@ports.RealtimeEvent::Forward(event~)) =>
        flow.outbound.put(Some(event))
      Some(@ports.RealtimeEvent::ToolCall(call_id~, name~, arguments~)) => {
        if name != "delegate_task" {
          provider.send_tool_result(
            call_id,
            tool_error("unknown tool: " + name),
            true,
          )
          continue
        }
        let instruction = match tool_instruction(arguments) {
          Some(text) => text
          None => {
            provider.send_tool_result(
              call_id,
              tool_error("delegate_task requires a non-empty instruction"),
              true,
            )
            continue
          }
        }
        match backend {
          None =>
            provider.send_tool_result(
              call_id,
              tool_error(
                "no backend is configured, so the task cannot be delegated",
              ),
              true,
            )
          Some(_) => {
            task_seq = task_seq + 1
            let task_id = "t-" + task_seq.to_string()
            flow.task_updated(task_id, "running", "", "")
            tool_jobs.put(
              Some({
                task_id,
                instruction,
                generation: flow.interrupt_generation.val,
              }),
            )
            provider.send_tool_result(call_id, tool_accepted(task_id), true)
          }
        }
      }
      None => {
        if !client_closing.val {
          flow.outbound.put(
            Some(
              @protocol.ServerEvent::Error(
                code=@protocol.ErrorCode::ProviderUnavailable,
                message="upstream closed the realtime session",
                retryable=true,
              ),
            ),
          )
        }
        tool_jobs.put(None)
        flow.outbound.put(None)
        return
      }
    }
  }
}

///|
/// Build a JSON tool result for the model.
fn tool_error(message : String) -> String {
  "{\"status\":\"error\",\"message\":" + Json::string(message).stringify() + "}"
}

///|
/// Acceptance receipt for `delegate_task`.
///
/// The model gets this before any backend work starts, so its next response is
/// a short natural confirmation rather than a claim that the task finished.
fn tool_accepted(task_id : String) -> String {
  Json::object({
    "status": Json::string("accepted"),
    "task_id": Json::string(task_id),
    "message": Json::string(
      "任务已受理并在后台执行。请用一句简短自然的口语告诉用户你正在处理，不要声称已经完成，也不要为同一请求再次调用 delegate_task。",
    ),
  }).stringify()
}

///|
/// Ask the model to narrate a completed background result.
fn background_result_text(text : String) -> String {
  "任务已完成。\n\n结果：\n" + text
}

///|
/// Ask the model to explain a failed background task honestly.
fn background_failure_text(message : String) -> String {
  "任务失败。请如实、简短地告诉用户失败原因，不要编造成功。\n\n原因：\n" +
  message
}

///|
/// Read the `instruction` field out of the model's tool arguments.
fn tool_instruction(arguments : String) -> String? {
  let parsed = @json.parse(arguments) catch { _ => return None }
  match parsed {
    Json::Object(map) =>
      match map.get("instruction") {
        Some(Json::String(text)) =>
          if text.trim().is_empty() {
            None
          } else {
            Some(text)
          }
        _ => None
      }
    _ => None
  }
}

///|
/// Serializes audit writes. The async stdio writer is not reentrant, and one
/// process can host several sessions.
let audit_lock : @async.Mutex = @async.Mutex()

///|
/// One audit line per permission decision.
///
/// Writes to stderr unbuffered so the line survives a redirected log and a
/// later kill. Deliberately excludes the description: it is agent-authored text
/// that may echo commands or file contents.
async fn audit_permission(
  session_id : String,
  task_id : String,
  request_id : String,
  operation : String,
  decision : @ports.PermissionDecision,
  source : String,
) -> Unit {
  let line = "[audit] permission session=" +
    session_id +
    " task=" +
    task_id +
    " request=" +
    request_id +
    " operation=" +
    operation +
    " decision=" +
    decision.to_token() +
    " source=" +
    source +
    "\n"
  audit_lock.acquire()
  defer audit_lock.release()
  @stdio.stderr.write(@utf8.encode(line)) catch {
    _ => ()
  }
}

///|
/// Ask the client for permission and wait for an answer or the timeout.
async fn ask_permission(
  flow : SessionFlow,
  task_id : String,
  request_id : String,
  operation : String,
  description : String,
) -> @ports.PermissionDecision {
  if !flow.can_ask {
    // No permission capability was negotiated, so asking would hang on the
    // timeout. Deny and tell the client why.
    flow.outbound.put(
      Some(
        @protocol.ServerEvent::PermissionResolved(
          session_id=flow.session_id,
          request_id~,
          decision="deny",
          source="policy",
        ),
      ),
    )
    audit_permission(
      flow.session_id,
      task_id,
      request_id,
      operation,
      @ports.PermissionDecision::Deny,
      "policy",
    )
    return @ports.PermissionDecision::Deny
  }
  flow.pending_permission.val = request_id
  flow.outbound.put(
    Some(
      @protocol.ServerEvent::PermissionRequest(
        session_id=flow.session_id,
        request_id~,
        task_id~,
        operation~,
        description~,
        timeout_ms=permission_timeout_ms,
      ),
    ),
  )
  let answer = try
    @async.with_timeout_opt(permission_timeout_ms) <| () => {
      flow.answers.get()
    }
  catch {
    _ => None
  }
  flow.pending_permission.val = ""
  let (decision, source) = match answer {
    Some(answer) =>
      if answer.request_id == request_id {
        (answer.decision, answer.source)
      } else {
        (@ports.PermissionDecision::Deny, "timeout")
      }
    None => (@ports.PermissionDecision::Deny, "timeout")
  }
  flow.outbound.put(
    Some(
      @protocol.ServerEvent::PermissionResolved(
        session_id=flow.session_id,
        request_id~,
        decision=decision.to_token(),
        source~,
      ),
    ),
  )
  audit_permission(
    flow.session_id,
    task_id,
    request_id,
    operation,
    decision,
    source,
  )
  decision
}

///|
/// Consume accepted tasks one at a time.
///
/// The backend event queue is shared, so tasks are serialized. Keeping this in
/// its own task lets `provider_pump` keep reading realtime events while the
/// backend works, and lets the user speak or interrupt in the meantime.
async fn tool_runner(
  provider : &@ports.RealtimeProvider,
  backend : &@ports.BackendPort,
  flow : SessionFlow,
  jobs : @aqueue.Queue[TaskJob?],
) -> Unit {
  for ;; {
    match jobs.get() {
      None => return
      Some(job) => {
        let outcome = handle_tool_call(
          backend,
          flow,
          job.task_id,
          job.instruction,
          job.generation,
        )
        // An interrupt after the task ended must not produce a late
        // announcement.
        if flow.interrupt_generation.val != job.generation {
          continue
        }
        match outcome {
          Completed(text~) =>
            provider.send_background_result(background_result_text(text))
          Failed(message~) =>
            provider.send_background_result(background_failure_text(message))
          Cancelled => ()
        }
      }
    }
  }
}

///|
/// Run one accepted task and report how it ended.
///
/// `submit` blocks until the task finishes, so it runs in a child task while
/// this function drains the backend queue. That gives the client live
/// `task.updated` progress without blocking the realtime reader.
async fn handle_tool_call(
  backend : &@ports.BackendPort,
  flow : SessionFlow,
  task_id : String,
  instruction : String,
  generation : Int32,
) -> TaskOutcome {
  if flow.interrupt_generation.val != generation {
    flow.task_updated(task_id, "cancelled", "", "")
    return Cancelled
  }
  let mut task_allow = false
  let mut step = ""
  let mut text = ""
  let mut failure = ""
  flow.current_task.val = task_id
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true) <| () => {
      backend.submit(task_id, instruction)
    }
    for ;; {
      match backend.next_event() {
        None => break
        Some(@ports.BackendEvent::TextDelta(text=delta)) => {
          text = text + delta
          flow.task_updated(task_id, "running", text, step)
        }
        Some(@ports.BackendEvent::TextDone(text=final_text)) =>
          text = final_text
        Some(@ports.BackendEvent::Progress(text=line)) => {
          step = line
          flow.task_updated(task_id, "running", text, step)
        }
        Some(
          @ports.BackendEvent::PermissionRequest(
            request_id~,
            operation~,
            description~
          )
        ) => {
          let decision = if flow.session_allow.val || task_allow {
            let inherited = if flow.session_allow.val {
              @ports.PermissionDecision::AllowSession
            } else {
              @ports.PermissionDecision::AllowOnce
            }
            flow.outbound.put(
              Some(
                @protocol.ServerEvent::PermissionResolved(
                  session_id=flow.session_id,
                  request_id~,
                  decision=inherited.to_token(),
                  source="policy",
                ),
              ),
            )
            audit_permission(
              flow.session_id,
              task_id,
              request_id,
              operation,
              inherited,
              "policy",
            )
            inherited
          } else {
            ask_permission(flow, task_id, request_id, operation, description)
          }
          match decision {
            @ports.PermissionDecision::AllowTask => task_allow = true
            @ports.PermissionDecision::AllowSession => {
              task_allow = true
              flow.session_allow.val = true
            }
            _ => ()
          }
          backend.respond_permission(request_id, decision)
        }
        Some(@ports.BackendEvent::Failed(message~, ..)) => {
          failure = message
          break
        }
        Some(@ports.BackendEvent::Completed) => break
        Some(_) => ()
      }
    }
  }
  if flow.current_task.val == task_id {
    flow.current_task.val = ""
  }
  let cancelled = flow.interrupt_generation.val != generation
  if cancelled {
    flow.task_updated(task_id, "cancelled", text, step)
    Cancelled
  } else if failure != "" {
    flow.task_updated(task_id, "failed", failure, step)
    Failed(message=failure)
  } else {
    flow.task_updated(task_id, "completed", text, step)
    Completed(text~)
  }
}

///|

///|
async fn writer_pump(
  ws : @websocket.Conn,
  outbound : @aqueue.Queue[@protocol.ServerEvent?],
) -> Unit {
  for ;; {
    match outbound.get() {
      Some(event) => send_event(ws, event) catch { _ => return }
      None => {
        ws.send_close() catch {
          _ => ()
        }
        return
      }
    }
  }
}

///|
let session_counter : Ref[Int32] = Ref(0)

///|
/// Session IDs are opaque to clients; only uniqueness within a process matters.
fn next_session_id() -> String {
  session_counter.val = session_counter.val + 1
  "s-" + session_counter.val.to_string()
}
