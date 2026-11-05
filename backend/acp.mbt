///|
/// The ACP major version this client speaks.
///
/// ACP versions are a single integer that only changes on breaking changes.
/// See `docs/backends/acp.md`.
pub let acp_protocol_version : Int32 = 1

///|
/// How many backend events may queue before the reader blocks.
pub let acp_event_capacity : Int32 = 64

///|
/// How to launch an ACP agent.
///
/// `command` is used as-is, so on Windows it must be an executable the OS can
/// start without a shell (`opencode.exe`, not the npm `.cmd` shim).
#derive(Eq, Debug)
pub(all) struct AcpConfig {
  command : String
  args : Array[String]
  /// Absolute working directory the agent may operate in.
  cwd : String
  inherit_env : Bool
  /// Model ID to select through `session/set_config_option`. Empty leaves the
  /// agent's own default alone.
  model : String
}

///|
/// One permission option offered by the agent.
priv struct AcpOption {
  option_id : String
  kind : String
}

///|
/// A permission request waiting for an answer from the gateway.
priv struct AcpPermission {
  /// The JSON-RPC id to answer, echoed back unchanged.
  rpc_id : Json
  options : Array[AcpOption]
}

///|
/// An Agent Client Protocol backend.
///
/// The agent is a child process that speaks newline-delimited JSON-RPC 2.0 on
/// stdio. MediaPilot is the client: it creates one session per gateway session
/// and forwards the agent's message chunks as task progress.
///
/// The adapter advertises no file-system, terminal, or elicitation capability,
/// so the agent performs tool calls in its own process and asks for approval
/// through `session/request_permission`. That keeps the gateway out of the
/// tool-execution business.
pub struct AcpBackend {
  config : AcpConfig
  events : @aqueue.Queue[@ports.BackendEvent?]
  /// In-flight client requests: id -> the queue that receives the response.
  pending : Map[Int64, @aqueue.Queue[Json]]
  /// Pending permission requests: gateway request id -> agent slot.
  priv permissions : Map[String, AcpPermission]
  write_lock : @async.Mutex
  /// Serializes connection setup and task execution: only one reader may own
  /// the agent's stdout at a time.
  priv setup_lock : @async.Mutex
  mut child : @process.OrphanProcess?
  mut next_id : Int64
  mut session_id : String
  /// The JSON-RPC id of the in-flight `session/prompt`, or 0 when idle.
  mut turn_id : Int64
  mut turn_text : String
  mut last_stderr : String
  mut closed : Bool
  mut cancelled : Bool
}

///|
pub fn AcpBackend::new(config : AcpConfig) -> AcpBackend {
  {
    config,
    events: @aqueue.Queue(kind=Blocking(acp_event_capacity)),
    pending: Map([]),
    permissions: Map([]),
    write_lock: @async.Mutex(),
    setup_lock: @async.Mutex(),
    child: None,
    next_id: 1,
    session_id: "",
    turn_id: 0,
    turn_text: "",
    last_stderr: "",
    closed: false,
    cancelled: false,
  }
}

///|
pub fn AcpBackend::config(self : AcpBackend) -> AcpConfig {
  self.config
}

///|
/// True when the agent process is running and a session exists.
pub fn AcpBackend::is_ready(self : AcpBackend) -> Bool {
  self.child is Some(_) && self.session_id != ""
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

///|
fn object_field(map : Map[String, Json], key : String) -> Map[String, Json] {
  match map.get(key) {
    Some(Json::Object(value)) => value
    _ => Map([])
  }
}

///|
fn string_field(map : Map[String, Json], key : String) -> String? {
  match map.get(key) {
    Some(Json::String(value)) => Some(value)
    _ => None
  }
}

///|
fn response_result(response : Map[String, Json]) -> Map[String, Json]? {
  match response.get("result") {
    Some(Json::Object(result)) => Some(result)
    _ => None
  }
}

///|
fn response_result_string(
  response : Map[String, Json],
  key : String,
) -> String? {
  match response_result(response) {
    Some(result) => string_field(result, key)
    None => None
  }
}

///|
fn response_error(response : Map[String, Json]) -> String? {
  match response.get("error") {
    Some(Json::Object(error)) =>
      match string_field(error, "message") {
        Some(message) => Some(message)
        None =>
          match error.get("code") {
            Some(Json::Number(code, ..)) => Some(code.to_string())
            _ => Some("unknown agent error")
          }
      }
    _ => None
  }
}

// ---------------------------------------------------------------------------
// Framing
// ---------------------------------------------------------------------------

///|
fn frame_request(id : Int64, method_name : String, params : Json) -> String {
  Json::object({
    "jsonrpc": Json::string("2.0"),
    "id": Json::number(id.to_double()),
    "method": Json::string(method_name),
    "params": params,
  }).stringify() +
  "\n"
}

///|
fn frame_notification(method_name : String, params : Json) -> String {
  Json::object({
    "jsonrpc": Json::string("2.0"),
    "method": Json::string(method_name),
    "params": params,
  }).stringify() +
  "\n"
}

///|
fn frame_result(id : Json, result : Json) -> String {
  Json::object({ "jsonrpc": Json::string("2.0"), "id": id, "result": result }).stringify() +
  "\n"
}

///|
fn frame_error(id : Json, code : Int32, message : String) -> String {
  Json::object({
    "jsonrpc": Json::string("2.0"),
    "id": id,
    "error": Json::object({
      "code": Json::number(code.to_double()),
      "message": Json::string(message),
    }),
  }).stringify() +
  "\n"
}

///|
fn selected_outcome(option_id : String) -> Json {
  Json::object({
    "outcome": Json::object({
      "outcome": Json::string("selected"),
      "optionId": Json::string(option_id),
    }),
  })
}

///|
fn cancelled_outcome() -> Json {
  Json::object({
    "outcome": Json::object({ "outcome": Json::string("cancelled") }),
  })
}

///|
/// Render a JSON-RPC id for use inside a gateway request id.
fn id_token(id : Json) -> String {
  match id {
    Json::Number(value, ..) => value.to_int64().to_string()
    Json::String(value) => value
    _ => "0"
  }
}

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

///|
async fn AcpBackend::send_line(self : AcpBackend, line : String) -> Unit {
  self.write_lock.acquire()
  defer self.write_lock.release()
  match self.child {
    Some(child) => child.stdin.text.write(line) catch { _ => () }
    None => ()
  }
}

///|
async fn AcpBackend::fail(
  self : AcpBackend,
  code : @protocol.ErrorCode,
  message : String,
) -> Unit {
  self.events.put(
    Some(@ports.BackendEvent::Failed(code~, message~, retryable=true)),
  )
}

///|
/// Start the agent process if it is not running. Returns false when the
/// process could not be started; the failure is already queued.
async fn AcpBackend::ensure_started(self : AcpBackend) -> Bool {
  match self.child {
    Some(_) => return true
    None => ()
  }
  try {
    let child = @process.spawn_orphan(
      self.config.command,
      self.config.args,
      inherit_env=self.config.inherit_env,
      stdin=@process.FeedFromParent,
      stdout=@process.Collect,
      stderr=@process.Collect,
      cwd=self.config.cwd,
      no_console_window=true,
    )
    self.child = Some(child)
    true
  } catch {
    error => {
      self.fail(
        @protocol.ErrorCode::ProviderUnavailable,
        "cannot start the ACP agent `" +
        self.config.command +
        "`: " +
        error.to_string(),
      )
      false
    }
  }
}

///|
/// Send one request and wait for its response. `timeout_ms = 0` waits forever.
async fn AcpBackend::request_with_id(
  self : AcpBackend,
  id : Int64,
  method_name : String,
  params : Json,
  timeout_ms : Int32,
) -> Map[String, Json]? {
  let slot : @aqueue.Queue[Json] = @aqueue.Queue(kind=Blocking(1))
  self.pending.set(id, slot)
  self.send_line(frame_request(id, method_name, params))
  let response : Json? = if timeout_ms > 0 {
    try @async.with_timeout_opt(timeout_ms) <| () => { slot.get() } catch {
      _ => None
    }
  } else {
    Some(slot.get())
  }
  match response {
    None => {
      self.pending.remove(id)
      self.fail(
        @protocol.ErrorCode::ProviderUnavailable,
        "ACP " + method_name + " timed out",
      )
      None
    }
    Some(frame) => {
      let map = match frame {
        Json::Object(map) => map
        _ => Map([])
      }
      match response_error(map) {
        Some(message) => {
          self.fail(
            @protocol.ErrorCode::InvalidEvent,
            "ACP " + method_name + " failed: " + message,
          )
          None
        }
        None => Some(map)
      }
    }
  }
}

///|
async fn AcpBackend::request(
  self : AcpBackend,
  method_name : String,
  params : Json,
  timeout_ms : Int32,
) -> Map[String, Json]? {
  let id = self.next_id
  self.next_id = id + 1
  self.request_with_id(id, method_name, params, timeout_ms)
}

///|
/// Read agent frames until the prompt response arrives or the process exits.
async fn AcpBackend::read_loop(self : AcpBackend) -> Unit {
  let reader = match self.child {
    Some(child) => child.stdout.text
    None => return
  }
  let mut eof = false
  for ;; {
    let line = reader.read_until("\n") catch {
      _ => {
        eof = true
        break
      }
    }
    match line {
      None => {
        eof = true
        break
      }
      Some(raw) => {
        let text = raw.trim_end().to_owned()
        if text != "" && self.handle_frame(text) {
          break
        }
      }
    }
  }
  if eof {
    match self.child {
      Some(child) => {
        child.stdin.close()
        child.stdout.close()
        child.stderr.close()
        child.close()
      }
      None => ()
    }
    self.child = None
    self.resolve_pending_on_exit()
  }
}

///|
/// Drain stderr so a chatty agent cannot block on a full pipe. The last line is
/// kept for error messages.
async fn AcpBackend::stderr_loop(self : AcpBackend) -> Unit {
  let reader = match self.child {
    Some(child) => child.stderr.text
    None => return
  }
  for ;; {
    let line = reader.read_until("\n") catch { _ => break }
    match line {
      None => break
      Some(raw) => {
        let text = raw.trim_end().to_owned()
        if text != "" {
          self.last_stderr = text
        }
      }
    }
  }
}

///|
/// Fail every in-flight request so nobody waits forever on a dead process.
async fn AcpBackend::resolve_pending_on_exit(self : AcpBackend) -> Unit {
  let waiting = self.pending.to_array()
  for entry in waiting {
    self.pending.remove(entry.0)
    entry.1.put(
      Json::object({
        "error": Json::object({
          "message": Json::string(
            "ACP agent exited" +
            (if self.last_stderr == "" { "" } else { ": " + self.last_stderr }),
          ),
        }),
      }),
    )
  }
  let permissions = self.permissions.to_array()
  for entry in permissions {
    self.permissions.remove(entry.0)
  }
  if !self.closed && !self.cancelled {
    self.fail(
      @protocol.ErrorCode::ProviderUnavailable,
      "ACP agent exited" +
      (if self.last_stderr == "" { "" } else { ": " + self.last_stderr }),
    )
  }
}

// ---------------------------------------------------------------------------
// Inbound frames
// ---------------------------------------------------------------------------

///|
/// Handle one frame. Returns true when the in-flight prompt finished.
async fn AcpBackend::handle_frame(self : AcpBackend, raw : String) -> Bool {
  let parsed = @json.parse(raw) catch { _ => return false }
  let map = match parsed {
    Json::Object(map) => map
    _ => return false
  }
  match map.get("method") {
    Some(Json::String(method_name)) =>
      match map.get("id") {
        Some(id) => {
          self.handle_agent_request(method_name, id, map)
          false
        }
        None => {
          self.handle_notification(method_name, map)
          false
        }
      }
    _ => self.handle_response(map)
  }
}

///|
async fn AcpBackend::handle_response(
  self : AcpBackend,
  map : Map[String, Json],
) -> Bool {
  let id = match map.get("id") {
    Some(Json::Number(value, ..)) => value.to_int64()
    _ => return false
  }
  match self.pending.remove_and_get(id) {
    Some(slot) => slot.put(Json::object(map))
    None => ()
  }
  self.turn_id != 0 && id == self.turn_id
}

///|
async fn AcpBackend::handle_notification(
  self : AcpBackend,
  method_name : String,
  map : Map[String, Json],
) -> Unit {
  if method_name != "session/update" {
    return
  }
  let update = object_field(object_field(map, "params"), "update")
  let kind = match string_field(update, "sessionUpdate") {
    Some(value) => value
    None => return
  }
  if kind == "agent_message_chunk" {
    let content = object_field(update, "content")
    match string_field(content, "type") {
      Some("text") =>
        match string_field(content, "text") {
          Some(text) =>
            if text != "" {
              self.turn_text = self.turn_text + text
              self.events.put(Some(@ports.BackendEvent::TextDelta(text~)))
            }
          None => ()
        }
      _ => ()
    }
  } else if kind == "tool_call" || kind == "tool_call_update" {
    match string_field(update, "title") {
      Some(title) =>
        if title != "" {
          self.events.put(Some(@ports.BackendEvent::Progress(text=title)))
        }
      None => ()
    }
  }
  // Unknown update kinds are ignored on purpose: ACP adds new ones and an
  // older client must keep working.
}

///|
/// Answer a request initiated by the agent.
async fn AcpBackend::handle_agent_request(
  self : AcpBackend,
  method_name : String,
  id : Json,
  map : Map[String, Json],
) -> Unit {
  if method_name == "session/request_permission" {
    self.handle_permission_request(id, object_field(map, "params"))
  } else {
    // No fs, terminal, or elicitation capability was advertised, so the agent
    // must not call these. Answer anyway so it never waits forever.
    self.send_line(
      frame_error(id, -32601, "MediaPilot does not implement " + method_name),
    )
  }
}

///|
async fn AcpBackend::handle_permission_request(
  self : AcpBackend,
  id : Json,
  params : Map[String, Json],
) -> Unit {
  let tool_call = object_field(params, "toolCall")
  let operation = match string_field(tool_call, "kind") {
    Some(kind) => kind
    None => "other"
  }
  let description = match string_field(tool_call, "title") {
    Some(title) => title
    None => ""
  }
  let options : Array[AcpOption] = []
  match params.get("options") {
    Some(Json::Array(items)) =>
      for item in items {
        match item {
          Json::Object(option) =>
            match
              (string_field(option, "optionId"), string_field(option, "kind")) {
              (Some(option_id), Some(kind)) =>
                options.push({ option_id, kind, })
              _ => ()
            }
          _ => ()
        }
      }
    _ => ()
  }
  let request_id = "p-" + id_token(id)
  self.permissions.set(request_id, { rpc_id: id, options, })
  self.events.put(
    Some(
      @ports.BackendEvent::PermissionRequest(
        request_id~,
        operation~,
        description~,
      ),
    ),
  )
}

// ---------------------------------------------------------------------------
// Outbound requests
// ---------------------------------------------------------------------------

///|
fn initialize_params() -> Json {
  Json::object({
    "protocolVersion": Json::number(acp_protocol_version.to_double()),
    "clientCapabilities": Json::object({
      "fs": Json::object({
        "readTextFile": Json::boolean(false),
        "writeTextFile": Json::boolean(false),
      }),
      "terminal": Json::boolean(false),
    }),
    "clientInfo": Json::object({
      "name": Json::string("mediapilot"),
      "title": Json::string("MediaPilot"),
      "version": Json::string(@protocol.protocol_version),
    }),
  })
}

///|
fn new_session_params(cwd : String) -> Json {
  Json::object({ "cwd": Json::string(cwd), "mcpServers": Json::array([]) })
}

///|
fn prompt_params(session_id : String, instruction : String) -> Json {
  Json::object({
    "sessionId": Json::string(session_id),
    "prompt": Json::array([
      Json::object({
        "type": Json::string("text"),
        "text": Json::string(instruction),
      }),
    ]),
  })
}

///|
fn cancel_params(session_id : String) -> Json {
  Json::object({ "sessionId": Json::string(session_id) })
}

///|
/// Spawn the agent and create a session if needed.
///
/// The caller holds `setup_lock` and is running the stdout reader. Returns
/// false when setup failed; the failure is already queued.
async fn AcpBackend::ensure_session(self : AcpBackend) -> Bool {
  if self.session_id != "" {
    return true
  }
  if !self.ensure_started() {
    return false
  }
  let responded = match self.request("initialize", initialize_params(), 20000) {
    Some(response) => response
    None => return false
  }
  if response_result(responded) is None {
    self.fail(
      @protocol.ErrorCode::InvalidEvent,
      "ACP initialize returned no result",
    )
    return false
  }
  let created = match
    self.request("session/new", new_session_params(self.config.cwd), 30000) {
    Some(response) => response
    None => return false
  }
  match response_result_string(created, "sessionId") {
    Some(session_id) => {
      self.session_id = session_id
      if self.config.model != "" {
        let selected = self.request(
          "session/set_config_option",
          Json::object({
            "sessionId": Json::string(session_id),
            "configId": Json::string("model"),
            "value": Json::string(self.config.model),
          }),
          15000,
        )
        if selected is None {
          self.session_id = ""
          return false
        }
      }
      true
    }
    None => {
      self.fail(
        @protocol.ErrorCode::InvalidEvent,
        "ACP session/new returned no sessionId",
      )
      false
    }
  }
}

///|
/// Drop events left over from a failed warmup. Only called when no consumer is
/// active, so nothing real can be lost.
fn AcpBackend::drain_events(self : AcpBackend) -> Unit {
  for ;; {
    let item = self.events.try_get() catch { _ => break }
    match item {
      Some(_) => ()
      None => break
    }
  }
}

///|
/// Connect and create a session if needed, then run one prompt.
async fn AcpBackend::run_turn(self : AcpBackend, instruction : String) -> Unit {
  if !self.ensure_session() {
    return
  }
  let id = self.next_id
  self.next_id = id + 1
  self.turn_id = id
  let response = self.request_with_id(
    id,
    "session/prompt",
    prompt_params(self.session_id, instruction),
    0,
  )
  self.turn_id = 0
  match response {
    None => return
    Some(_) => ()
  }
  if self.closed {
    return
  }
  // A cancelled turn still ends the submission, so the gateway's consumer loop
  // finishes instead of waiting for an event that will never come.
  self.events.put(Some(@ports.BackendEvent::TextDone(text=self.turn_text)))
  self.events.put(Some(@ports.BackendEvent::Completed))
}

// ---------------------------------------------------------------------------
// BackendPort
// ---------------------------------------------------------------------------

///|
/// Start the agent and create its session before the first task, so the first
/// real task does not pay the process and handshake cost.
async fn AcpBackend::warmup(self : AcpBackend) -> Unit {
  if self.closed {
    return
  }
  self.setup_lock.acquire()
  defer self.setup_lock.release()
  if self.closed || self.session_id != "" {
    return
  }
  // The child must exist before the reader starts, otherwise the reader sees
  // `child = None` and exits instead of consuming the initialize response.
  if !self.ensure_started() {
    return
  }
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true) <| () => { self.read_loop() }
    group.spawn_bg(no_wait=true) <| () => { self.stderr_loop() }
    let _ = self.ensure_session()
  }
}

///|
async fn AcpBackend::submit(
  self : AcpBackend,
  _task_id : String,
  instruction : String,
) -> Unit {
  if self.closed {
    return
  }
  // Warmup and submit must never read stdout at the same time.
  self.setup_lock.acquire()
  defer self.setup_lock.release()
  self.cancelled = false
  self.turn_text = ""
  self.drain_events()
  // The child must exist before the reader starts.
  if !self.ensure_started() {
    return
  }
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true) <| () => { self.read_loop() }
    group.spawn_bg(no_wait=true) <| () => { self.stderr_loop() }
    self.run_turn(instruction)
  }
}

///|
async fn AcpBackend::cancel(self : AcpBackend, _task_id : String) -> Unit {
  self.cancelled = true
  // ACP requires every pending permission request to be answered as cancelled
  // when the turn is cancelled.
  let pending = self.permissions.to_array()
  self.permissions.clear()
  for entry in pending {
    self.send_line(frame_result(entry.1.rpc_id, cancelled_outcome()))
  }
  if self.session_id != "" {
    self.send_line(
      frame_notification("session/cancel", cancel_params(self.session_id)),
    )
  }
}

///|
/// Pick the agent option that matches the gateway decision.
///
/// Returns "" when the agent offered nothing compatible, which the caller turns
/// into a `cancelled` outcome so the agent never treats silence as approval.
fn choose_option(
  options : Array[AcpOption],
  decision : @ports.PermissionDecision,
) -> String {
  let preferred : Array[String] = match decision {
    @ports.PermissionDecision::AllowOnce => ["allow_once"]
    @ports.PermissionDecision::AllowTask => ["allow_always", "allow_once"]
    @ports.PermissionDecision::AllowSession => ["allow_always", "allow_once"]
    @ports.PermissionDecision::Deny => ["reject_once", "reject_always"]
  }
  for want in preferred {
    for option in options {
      if option.kind == want {
        return option.option_id
      }
    }
  }
  ""
}

///|
async fn AcpBackend::respond_permission(
  self : AcpBackend,
  request_id : String,
  decision : @ports.PermissionDecision,
) -> Unit {
  let slot = match self.permissions.remove_and_get(request_id) {
    Some(slot) => slot
    None => return
  }
  let chosen = choose_option(slot.options, decision)
  if chosen == "" {
    self.send_line(frame_result(slot.rpc_id, cancelled_outcome()))
  } else {
    self.send_line(frame_result(slot.rpc_id, selected_outcome(chosen)))
  }
}

///|
async fn AcpBackend::next_event(self : AcpBackend) -> @ports.BackendEvent? {
  self.events.get()
}

///|
/// Stop the child process and release its pipes.
///
/// Closing stdin asks the agent to exit. If it does not within the grace
/// period, kill it: a gateway session must not leak an agent process.
async fn AcpBackend::terminate(self : AcpBackend) -> Unit {
  let child = match self.child {
    Some(child) => child
    None => return
  }
  child.stdin.close()
  child.stdout.close()
  child.stderr.close()
  let pid = child.pid
  let exited = try
    @async.with_timeout_opt(1500) <| () => { @process.wait_pid(pid) }
  catch {
    _ => None
  }
  if exited is None {
    kill_pid(pid)
  }
  child.close()
  self.child = None
}

///|
async fn kill_pid(pid : Int32) -> Unit {
  let (command, args) = if @async.platform is Windows {
    ("taskkill", ["/PID", pid.to_string(), "/T", "/F"])
  } else {
    ("kill", ["-9", pid.to_string()])
  }
  try {
    let _ = @process.run(
      command,
      args,
      stdout=@process.Discard,
      stderr=@process.Discard,
    )
  } catch {
    _ => ()
  }
}

///|
async fn AcpBackend::close(self : AcpBackend) -> Unit {
  if self.closed {
    return
  }
  self.closed = true
  if self.session_id != "" {
    self.send_line(
      frame_notification("session/cancel", cancel_params(self.session_id)),
    )
  }
  self.terminate()
  self.events.put(None)
}

///|
pub impl @ports.BackendPort for AcpBackend with fn warmup(self) {
  self.warmup()
}

///|
pub impl @ports.BackendPort for AcpBackend with fn submit(
  self,
  task_id,
  instruction,
) {
  self.submit(task_id, instruction)
}

///|
pub impl @ports.BackendPort for AcpBackend with fn cancel(self, task_id) {
  self.cancel(task_id)
}

///|
pub impl @ports.BackendPort for AcpBackend with fn respond_tool(
  self,
  _call_id,
  _output,
) {
  // The agent runs its own tools, so the gateway never routes one here.
  let _ = self
}

///|
pub impl @ports.BackendPort for AcpBackend with fn respond_permission(
  self,
  request_id,
  decision,
) {
  self.respond_permission(request_id, decision)
}

///|
pub impl @ports.BackendPort for AcpBackend with fn next_event(self) {
  self.next_event()
}

///|
pub impl @ports.BackendPort for AcpBackend with fn close(self) {
  self.close()
}
