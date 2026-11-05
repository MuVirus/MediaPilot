///|
/// P2 spike: does the realtime model support function calling?
///
/// It answers three questions that decide the P2 topology:
///
/// 1. Does `session.update` accept a `tools` array?
/// 2. Does the model emit `response.function_call_arguments.done`?
/// 3. Does injecting `function_call_output` resume the turn and produce speech?
///
/// The probe prints event types and tool arguments only. It never prints the
/// API key or audio payloads.

///|
fn env_or(key : String, fallback : String) -> String {
  match @env.get_env_var(key) {
    Some(value) if value != "" => value
    _ => fallback
  }
}

///|
fn parse_object(raw : String) -> Map[String, Json]? {
  let parsed = @json.parse(raw) catch { _ => return None }
  match parsed {
    Json::Object(map) => Some(map)
    _ => None
  }
}

///|
fn event_kind(raw : String) -> String {
  match parse_object(raw) {
    Some(map) =>
      match map.get("type") {
        Some(Json::String(kind)) => kind
        _ => "<missing-type>"
      }
    None => "<invalid-json>"
  }
}

///|
fn field_string(raw : String, key : String) -> String? {
  match parse_object(raw) {
    Some(map) =>
      match map.get(key) {
        Some(Json::String(value)) => Some(value)
        _ => None
      }
    None => None
  }
}

///|
/// Extract `response.status` and `response.status_details.reason` so a failed
/// generation is visible instead of looking like an empty answer.
fn response_status(raw : String) -> String {
  match parse_object(raw) {
    Some(map) =>
      match map.get("response") {
        Some(Json::Object(response)) => {
          let status = match response.get("status") {
            Some(Json::String(value)) => value
            _ => "?"
          }
          let reason = match response.get("status_details") {
            Some(Json::Object(details)) =>
              match details.get("reason") {
                Some(Json::String(value)) => value
                _ => ""
              }
            _ => ""
          }
          if reason == "" {
            " status=" + status
          } else {
            " status=" + status + " reason=" + reason
          }
        }
        _ => ""
      }
    None => ""
  }
}

///|
fn error_summary(raw : String) -> String {
  match parse_object(raw) {
    Some(map) =>
      match map.get("error") {
        Some(Json::Object(error)) =>
          match (error.get("code"), error.get("message")) {
            (Some(Json::String(code)), Some(Json::String(message))) =>
              " code=" + code + " message=" + message
            (Some(Json::String(code)), _) => " code=" + code
            (_, Some(Json::String(message))) => " message=" + message
            _ => ""
          }
        _ =>
          match map.get("message") {
            Some(Json::String(message)) => " message=" + message
            _ => ""
          }
      }
    None => ""
  }
}

///|
async fn recv_text(ws : @websocket.Conn, timeout_ms : Int32) -> String? {
  @async.with_timeout_opt(timeout_ms) <| () => { ws.recv().text.read_all() }
}

///|
/// The tool the model is allowed to call. Deliberately trivial so a correct
/// answer is easy to recognize.
fn time_tool() -> Json {
  Json::array([
    @realtime.function_tool(
      "get_current_time",
      "Get the user's current local date, time, and weekday. Use this whenever the user asks about the current time or date.",
      Json::object({
        "type": Json::string("object"),
        "properties": Json::object({}),
        "additionalProperties": Json::boolean(false),
      }),
    ),
  ])
}

///|
fn truncate(text : String, limit : Int32) -> String {
  if text.length() <= limit {
    text
  } else {
    text[:limit].to_string() + "…(" + text.length().to_string() + " chars)"
  }
}

///|
/// Read events until `response.done` or `error`. Returns the tool call if the
/// model asked for one.
async fn collect_turn(
  ws : @websocket.Conn,
  label : String,
) -> (String, String, String)? {
  let raw_mode = match @env.get_env_var("MEDIAPILOT_PROBE_RAW") {
    Some(value) => value == "1"
    None => false
  }
  let mut call : (String, String, String)? = None
  let mut audio_chunks = 0
  let mut transcript = ""
  for _ in 0..<200 {
    match recv_text(ws, 20000) {
      None => {
        println("[" + label + "] timeout")
        break
      }
      Some(raw) => {
        let kind = event_kind(raw)
        if raw_mode {
          println("[" + label + "] raw: " + truncate(raw, 600))
        }
        if kind == "error" {
          println("[" + label + "] error" + error_summary(raw))
          break
        } else if kind == "response.done" {
          println("[" + label + "] response.done" + response_status(raw))
          break
        } else if kind == "response.audio.delta" ||
          kind == "response.output_audio.delta" {
          audio_chunks = audio_chunks + 1
        } else if kind == "response.function_call_arguments.done" {
          let call_id = field_string(raw, "call_id").unwrap_or("")
          let name = field_string(raw, "name").unwrap_or("")
          let arguments = field_string(raw, "arguments").unwrap_or("")
          println(
            "[" +
            label +
            "] FUNCTION CALL name=" +
            name +
            " call_id=" +
            call_id +
            " arguments=" +
            arguments,
          )
          call = Some((call_id, name, arguments))
        } else if kind == "response.audio_transcript.delta" ||
          kind == "response.output_audio_transcript.delta" {
          match field_string(raw, "delta") {
            Some(delta) => transcript = transcript + delta
            None => ()
          }
        } else if kind == "response.audio_transcript.done" ||
          kind == "response.output_audio_transcript.done" {
          match field_string(raw, "transcript") {
            Some(text) => transcript = text
            None => ()
          }
        } else {
          println("[" + label + "] event: " + kind)
        }
      }
    }
  }
  println("[" + label + "] audio chunks=" + audio_chunks.to_string())
  if transcript != "" {
    println("[" + label + "] transcript: " + transcript)
  }
  call
}

///|
async fn main {
  let api_key = match @env.get_env_var("DASHSCOPE_API_KEY") {
    Some(value) if value != "" => value
    _ => {
      println("[probe] DASHSCOPE_API_KEY is not set; aborting")
      return
    }
  }
  let config = @realtime.ProviderConfig::{
    api_key,
    model: env_or(
      "MEDIAPILOT_REALTIME_MODEL", @realtime.dashscope_default_model,
    ),
    endpoint: env_or(
      "MEDIAPILOT_REALTIME_ENDPOINT", @realtime.dashscope_default_endpoint,
    ),
    voice: env_or("MEDIAPILOT_REALTIME_VOICE", "longanqian_v3.1"),
  }
  let provider = @realtime.DashScopeProvider::new(config)
  println("[probe] model=" + config.model)
  let headers : Map[@http.CaseInsensitiveString, String] = Map([
    (@http.CaseInsensitiveString("Authorization"), provider.auth_header()),
  ])
  let ws = @websocket.connect(provider.connect_url(), headers~) catch {
    error => {
      println("[probe] connect failed: " + error.to_string())
      return
    }
  }
  println("[probe] connected")
  let _ = recv_text(ws, 10000)
  let with_tools = match @env.get_env_var("MEDIAPILOT_PROBE_NO_TOOLS") {
    Some(value) => value != "1"
    None => true
  }
  let instructions = "You are a voice assistant. When the user asks about the current time or date, you must call the get_current_time tool instead of guessing."
  let update = if with_tools {
    provider.session_update(instructions, tools=time_tool())
  } else {
    provider.session_update(instructions)
  }
  ws.send_text(update.stringify())
  println(
    "[probe] sent session.update (tools=" +
    (if with_tools { "on" } else { "off" }) +
    ")",
  )
  let mut accepted = false
  for _ in 0..<20 {
    match recv_text(ws, 10000) {
      None => break
      Some(raw) => {
        let kind = event_kind(raw)
        println("[probe] event: " + kind + error_summary(raw))
        if kind == "session.updated" {
          accepted = true
          break
        }
        if kind == "error" {
          break
        }
      }
    }
  }
  if !accepted {
    println("[probe] RESULT: session.update with tools was rejected")
    ws.send_close()
    ws.close()
    return
  }
  println("[probe] RESULT: session.update with tools accepted")

  let question = env_or("MEDIAPILOT_PROBE_QUESTION", "现在几点了？")
  match @env.get_env_var("MEDIAPILOT_PROBE_PCM") {
    Some(path) if path != "" => {
      let pcm = @fs.read_binary(path) catch {
        error => {
          println("[probe] failed to read pcm: " + error.to_string())
          ws.send_close()
          ws.close()
          return
        }
      }
      println(
        "[probe] streaming " + pcm.length().to_string() + " bytes of PCM16",
      )
      let chunk_bytes = 3200
      let mut offset = 0
      while offset < pcm.length() {
        let end = if offset + chunk_bytes > pcm.length() {
          pcm.length()
        } else {
          offset + chunk_bytes
        }
        ws.send_text(
          @realtime.encode_audio_append(@base64.encode(pcm[offset:end])).stringify(),
        )
        offset = end
        @async.sleep(100)
      }
      println("[probe] uplink done, waiting for server VAD")
    }
    _ => {
      ws.send_text(@realtime.encode_text_message(question).stringify())
      ws.send_text(@realtime.encode_response_create().stringify())
      println("[probe] asked: " + question)
    }
  }
  match collect_turn(ws, "turn1") {
    None => println("[probe] RESULT: no function call was emitted")
    Some((call_id, name, arguments)) => {
      println("[probe] RESULT: function call emitted for " + name)
      let output = "{\"status\":\"ok\",\"local_time\":\"2026-11-05T13:30:00+08:00\",\"weekday\":\"Thursday\"}"
      ws.send_text(
        @realtime.encode_function_output(call_id, output).stringify(),
      )
      ws.send_text(@realtime.encode_response_create().stringify())
      println(
        "[probe] injected function_call_output, waiting for the spoken answer",
      )
      let _ = collect_turn(ws, "turn2")
      println("[probe] RESULT: tool result injection completed")
      let _ = arguments
    }
  }
  ws.send_close()
  ws.close()
  println("[probe] closed")
}
