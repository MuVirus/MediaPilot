///|
/// Read an environment variable, falling back when it is missing or empty.
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
/// Summarize a provider error without echoing any request data. Error bodies
/// from DashScope never contain the API key; we still keep the output to the
/// code and message fields only.
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
fn tone_pcm16(sample_rate : Int32, millis : Int32, freq : Double) -> Bytes {
  let samples = sample_rate * millis / 1000
  let raw : FixedArray[Byte] = FixedArray::make(samples * 2, b'\x00')
  for i = 0; i < samples; i = i + 1 {
    let t = i.to_double() / sample_rate.to_double()
    let sample = (@math.sin(2.0 * 3.141592653589793 * freq * t) * 8000.0).to_int()
    let value = if sample < 0 { sample + 65536 } else { sample }
    raw.unsafe_write_uint16_le(i * 2, value.to_uint16())
  }
  Bytes::from_fixedarray(raw)
}

///|
/// Read events until `response.done` or `error`, reporting only shapes and
/// transcript text. Audio payloads are counted, never printed.
///
/// When `cancel_after_chunks` is set, the probe sends `response.cancel` after
/// that many audio deltas and reports whether the server stops sending audio.
async fn collect_response(
  ws : @websocket.Conn,
  label : String,
  cancel_after_chunks? : Int32,
) -> Unit {
  let mut transcript = ""
  let mut audio_chunks = 0
  let mut audio_base64 = 0
  let mut done = false
  let mut cancelled = false
  for i = 0; i < 200 && !done; i = i + 1 {
    match recv_text(ws, 15000) {
      None => {
        println(
          "[" + label + "] timeout waiting for event " + (i + 1).to_string(),
        )
        done = true
      }
      Some(raw) => {
        let kind = event_kind(raw)
        if kind == "error" {
          println("[" + label + "] event: error" + error_summary(raw))
          done = true
        } else if kind == "response.done" {
          println("[" + label + "] event: response.done")
          done = true
        } else if kind == "response.audio.delta" ||
          kind == "response.output_audio.delta" {
          audio_chunks = audio_chunks + 1
          match field_string(raw, "delta") {
            Some(delta) => audio_base64 = audio_base64 + delta.length()
            None => ()
          }
          match cancel_after_chunks {
            Some(limit) if !cancelled && audio_chunks >= limit => {
              ws.send_text(@realtime.encode_response_cancel().stringify())
              println(
                "[" +
                label +
                "] sent response.cancel after " +
                audio_chunks.to_string() +
                " chunks",
              )
              cancelled = true
            }
            _ => ()
          }
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
  println(
    "[" +
    label +
    "] audio chunks=" +
    audio_chunks.to_string() +
    " base64_chars=" +
    audio_base64.to_string(),
  )
  if transcript != "" {
    println("[" + label + "] transcript: " + transcript)
  }
}

///|
/// P0 smoke test: TLS, Authorization header, model name, session.update, text
/// turn, and audio downlink.
///
/// The API key is read from the process environment and never printed.
async fn main {
  let api_key = match @env.get_env_var("DASHSCOPE_API_KEY") {
    Some(value) if value != "" => value
    _ => {
      println("[smoke] DASHSCOPE_API_KEY is not set; aborting")
      return
    }
  }
  let config = @realtime.ProviderConfig::{
    api_key,
    model: env_or("MEDIAPILOT_REALTIME_MODEL", "qwen-audio-3.1-realtime-flash"),
    endpoint: env_or(
      "MEDIAPILOT_REALTIME_ENDPOINT", @realtime.dashscope_default_endpoint,
    ),
    voice: env_or("MEDIAPILOT_REALTIME_VOICE", "longanqian_v3.1"),
  }
  let provider = @realtime.DashScopeProvider::new(config)
  println("[smoke] endpoint=" + config.endpoint)
  println("[smoke] model=" + config.model)
  println("[smoke] voice=" + config.voice)
  let headers : Map[@http.CaseInsensitiveString, String] = Map([
    (@http.CaseInsensitiveString("Authorization"), provider.auth_header()),
  ])
  let ws = @websocket.connect(provider.connect_url(), headers~) catch {
    error => {
      println("[smoke] connect failed: " + error.to_string())
      return
    }
  }
  println("[smoke] websocket connected (TLS + auth handshake ok)")
  match recv_text(ws, 10000) {
    None => println("[smoke] timed out waiting for the first event")
    Some(raw) => println("[smoke] event: " + event_kind(raw))
  }
  // `manual` disables server turn detection so the probe can exercise
  // `input_audio_buffer.commit`; anything else selects a server VAD type.
  let turn_detection = @env.get_env_var("MEDIAPILOT_SMOKE_TURN_DETECTION")
  let manual_turns = match turn_detection {
    Some(kind) => kind == "manual"
    None => false
  }
  let instructions = "You are a concise voice assistant. Answer in one short sentence."
  let session_update = if manual_turns {
    @realtime.encode_session_update(config.voice, instructions)
  } else {
    match turn_detection {
      Some(kind) =>
        @realtime.encode_session_update(
          config.voice,
          instructions,
          turn_detection=kind,
        )
      None => provider.session_update(instructions)
    }
  }
  ws.send_text(session_update.stringify())
  println("[smoke] sent session.update")
  if manual_turns {
    println("[smoke] turn_detection=manual")
  } else {
    match turn_detection {
      Some(kind) => println("[smoke] turn_detection=" + kind)
      None => println("[smoke] turn_detection=default")
    }
  }
  let mut updated = false
  for i = 0; i < 20 && !updated; i = i + 1 {
    match recv_text(ws, 10000) {
      None =>
        println("[smoke] timeout waiting for event " + (i + 2).to_string())
      Some(raw) => {
        let kind = event_kind(raw)
        println("[smoke] event: " + kind + error_summary(raw))
        if kind == "session.updated" || kind == "error" {
          updated = true
        }
      }
    }
  }
  if updated {
    ws.send_text(
      @realtime.encode_text_message("请用一句话介绍你自己。").stringify(),
    )
    ws.send_text(@realtime.encode_response_create().stringify())
    println("[smoke] sent text turn + response.create")
    collect_response(ws, "text")
    // Interrupt probe: start a second text turn and cancel it mid-stream.
    ws.send_text(
      @realtime.encode_text_message("请用五句话介绍杭州。").stringify(),
    )
    ws.send_text(@realtime.encode_response_create().stringify())
    println("[smoke] sent interrupt probe turn")
    collect_response(ws, "interrupt", cancel_after_chunks=3)
    let pcm = match @env.get_env_var("MEDIAPILOT_SMOKE_PCM") {
      Some(path) if path != "" =>
        try {
          let data = @fs.read_binary(path)
          println("[smoke] uplink pcm bytes=" + data.length().to_string())
          data
        } catch {
          error => {
            println("[smoke] failed to read pcm file: " + error.to_string())
            return
          }
        }
      _ => {
        println("[smoke] uplink pcm=synthetic 440Hz tone")
        tone_pcm16(16000, 1000, 440.0)
      }
    }
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
      // 3200 bytes is 100 ms of 16 kHz mono PCM16. Pace the uplink so server
      // VAD sees a realistic stream instead of one instantaneous burst.
      @async.sleep(100)
    }
    if manual_turns {
      ws.send_text(@realtime.encode_audio_commit().stringify())
      ws.send_text(@realtime.encode_response_create().stringify())
      println("[smoke] sent PCM16 uplink + commit + response.create")
    } else {
      println("[smoke] sent PCM16 uplink; waiting for server VAD")
    }
    collect_response(ws, "audio")
  }
  ws.send_text(@realtime.encode_response_cancel().stringify())
  ws.send_close()
  ws.close()
  println("[smoke] closed")
}
