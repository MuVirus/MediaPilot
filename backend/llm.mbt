///|
/// Configuration for an OpenAI-compatible chat-completions backend.
#derive(Eq, Debug)
pub(all) struct LlmConfig {
  base_url : String
  api_key : String
  model : String
  system_prompt : String
}

///|
pub extend LlmConfig with Eq::{not_equal, equal}

///|
pub extend LlmConfig with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// DashScope exposes an OpenAI-compatible endpoint, so the same adapter works
/// for Qwen and for any other compatible provider by changing `base_url`.
pub let default_llm_base_url : String = "https://dashscope.aliyuncs.com/compatible-mode/v1"

///|
/// How many events may queue before `submit` blocks. Text deltas are small, so
/// this is really a safety net against a consumer that stopped reading.
pub let llm_event_capacity : Int32 = 64

///|
/// A streaming chat-completions backend.
///
/// This is the minimal backend that proves `BackendPort`: text in, streamed
/// text out, cancellable. It has no tools and no permission flow; those arrive
/// with the ACP adapter.
pub struct LlmBackend {
  config : LlmConfig
  events : @aqueue.Queue[@ports.BackendEvent?]
  mut closed : Bool
  mut cancelled : Bool
}

///|
pub fn LlmBackend::new(config : LlmConfig) -> Self {
  {
    config,
    events: @aqueue.Queue(kind=Blocking(llm_event_capacity)),
    closed: false,
    cancelled: false,
  }
}

///|
pub fn LlmBackend::config(self : LlmBackend) -> LlmConfig {
  self.config
}

///|
fn chat_url(base_url : String) -> String {
  let trimmed = base_url.trim_end().to_owned()
  if trimmed.has_suffix("/chat/completions") {
    trimmed
  } else {
    trimmed + "/chat/completions"
  }
}

///|
fn request_body(config : LlmConfig, instruction : String) -> Json {
  Json::object({
    "model": Json::string(config.model),
    "stream": Json::boolean(true),
    "messages": Json::array([
      Json::object({
        "role": Json::string("system"),
        "content": Json::string(config.system_prompt),
      }),
      Json::object({
        "role": Json::string("user"),
        "content": Json::string(instruction),
      }),
    ]),
  })
}

///|
/// Extract `choices[0].delta.content` from one SSE payload.
fn delta_text(payload : Json) -> String? {
  match payload {
    Json::Object(root) =>
      match root.get("choices") {
        Some(Json::Array(choices)) =>
          match choices {
            [Json::Object(choice), ..] =>
              match choice.get("delta") {
                Some(Json::Object(delta)) =>
                  match delta.get("content") {
                    Some(Json::String(text)) => Some(text)
                    _ => None
                  }
                _ => None
              }
            _ => None
          }
        _ => None
      }
    _ => None
  }
}

///|
/// Extract an error message from a provider error payload.
fn error_message(payload : Json) -> String? {
  match payload {
    Json::Object(root) =>
      match root.get("error") {
        Some(Json::Object(error)) =>
          match error.get("message") {
            Some(Json::String(message)) => Some(message)
            _ =>
              match error.get("code") {
                Some(Json::String(code)) => Some(code)
                _ => None
              }
          }
        _ => None
      }
    _ => None
  }
}

///|
/// Map an HTTP status to the contract error code.
fn status_error_code(status : Int32) -> @protocol.ErrorCode {
  if status == 401 || status == 403 {
    @protocol.ErrorCode::ProviderAuthFailed
  } else if status == 429 || status >= 500 {
    @protocol.ErrorCode::ProviderUnavailable
  } else {
    @protocol.ErrorCode::InvalidEvent
  }
}

///|
fn header(
  name : String,
  value : String,
) -> (@http.CaseInsensitiveString, String) {
  (@http.CaseInsensitiveString(name), value)
}

///|
async fn send_error(
  ws : @aqueue.Queue[@ports.BackendEvent?],
  code : @protocol.ErrorCode,
  message : String,
) -> Unit {
  ws.put(
    Some(
      @ports.BackendEvent::Failed(
        code~,
        message~,
        retryable=code != @protocol.ErrorCode::ProviderAuthFailed,
      ),
    ),
  )
}

///|
/// The LLM backend opens a connection per request, so there is nothing to warm.
pub fn LlmBackend::warmup(self : LlmBackend) -> Unit {
  let _ = self
}

///|
/// Run one chat completion and stream the answer into the event queue.
pub async fn LlmBackend::submit(
  self : LlmBackend,
  _task_id : String,
  instruction : String,
) -> Unit {
  if self.closed {
    return
  }
  self.cancelled = false
  let headers : Map[@http.CaseInsensitiveString, String] = Map([
    header("Authorization", "Bearer " + self.config.api_key),
    header("Content-Type", "application/json"),
    header("Accept", "text/event-stream"),
  ])
  let conn = @http.post(chat_url(self.config.base_url), headers~) catch {
    error => {
      send_error(
        self.events,
        @protocol.ErrorCode::ProviderUnavailable,
        "llm connect failed: " + error.to_string(),
      )
      return
    }
  }
  defer conn.close()
  try {
    conn.write(@utf8.encode(request_body(self.config, instruction).stringify()))
    conn.flush()
  } catch {
    error => {
      send_error(
        self.events,
        @protocol.ErrorCode::ProviderUnavailable,
        "llm request failed: " + error.to_string(),
      )
      return
    }
  }
  let response = conn.end_request() catch {
    error => {
      send_error(
        self.events,
        @protocol.ErrorCode::ProviderUnavailable,
        "llm response failed: " + error.to_string(),
      )
      return
    }
  }
  if response.code != 200 {
    let body = conn.text.read_all() catch { _ => "" }
    let detail = try {
      match error_message(@json.parse(body)) {
        Some(message) => message
        None => body
      }
    } catch {
      _ => body
    }
    send_error(
      self.events,
      status_error_code(response.code),
      "llm http " +
      response.code.to_string() +
      (if detail == "" { "" } else { ": " + detail }),
    )
    return
  }
  let mut text = ""
  let mut done = false
  while !done && !self.cancelled && !self.closed {
    let line = conn.text.read_until("\n") catch {
      error => {
        send_error(
          self.events,
          @protocol.ErrorCode::ProviderUnavailable,
          "llm stream failed: " + error.to_string(),
        )
        return
      }
    }
    match line {
      None => done = true
      Some(raw) => {
        let line = raw.trim_end().to_owned()
        if line == "" || line.has_prefix(":") {
          continue
        }
        let payload = if line.has_prefix("data:") {
          line[5:].trim_start().to_owned()
        } else {
          line
        }
        if payload == "[DONE]" {
          done = true
        } else {
          let parsed = Some(@json.parse(payload)) catch { _ => None }
          match parsed {
            Some(parsed) =>
              match error_message(parsed) {
                Some(message) =>
                  send_error(
                    self.events,
                    @protocol.ErrorCode::ProviderUnavailable,
                    message,
                  )
                None =>
                  match delta_text(parsed) {
                    Some(delta) =>
                      if delta != "" {
                        text = text + delta
                        self.events.put(
                          Some(@ports.BackendEvent::TextDelta(text=delta)),
                        )
                      }
                    None => ()
                  }
              }
            None => ()
          }
        }
      }
    }
  }
  if self.cancelled || self.closed {
    return
  }
  self.events.put(Some(@ports.BackendEvent::TextDone(text~)))
  self.events.put(Some(@ports.BackendEvent::Completed))
}

///|
pub fn LlmBackend::cancel(self : LlmBackend, _task_id : String) -> Unit {
  self.cancelled = true
}

///|
/// The LLM backend has no tool loop, so tool answers are ignored.
pub fn LlmBackend::respond_tool(
  self : LlmBackend,
  _call_id : String,
  _output : String,
) -> Unit {
  let _ = self
}

///|
/// The LLM backend has no permission flow, so permission answers are ignored.
pub fn LlmBackend::respond_permission(
  self : LlmBackend,
  _request_id : String,
  _decision : @ports.PermissionDecision,
) -> Unit {
  let _ = self
}

///|
pub async fn LlmBackend::next_event(self : LlmBackend) -> @ports.BackendEvent? {
  self.events.get()
}

///|
pub async fn LlmBackend::close(self : LlmBackend) -> Unit {
  if !self.closed {
    self.closed = true
    self.events.put(None)
  }
}

///|
pub impl @ports.BackendPort for LlmBackend with fn warmup(self) {
  self.warmup()
}

///|
pub impl @ports.BackendPort for LlmBackend with fn submit(
  self,
  task_id,
  instruction,
) {
  self.submit(task_id, instruction)
}

///|
pub impl @ports.BackendPort for LlmBackend with fn cancel(self, task_id) {
  self.cancel(task_id)
}

///|
pub impl @ports.BackendPort for LlmBackend with fn respond_tool(
  self,
  call_id,
  output,
) {
  self.respond_tool(call_id, output)
}

///|
pub impl @ports.BackendPort for LlmBackend with fn respond_permission(
  self,
  request_id,
  decision,
) {
  self.respond_permission(request_id, decision)
}

///|
pub impl @ports.BackendPort for LlmBackend with fn next_event(self) {
  self.next_event()
}

///|
pub impl @ports.BackendPort for LlmBackend with fn close(self) {
  self.close()
}
