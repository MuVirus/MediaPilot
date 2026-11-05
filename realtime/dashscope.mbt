///|
pub let dashscope_default_endpoint : String = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"

///|
pub let dashscope_input_sample_rate : Int32 = 16000

///|
pub let dashscope_output_sample_rate : Int32 = 24000

///|
/// Turn detection used by the Qwen Audio 3.x realtime family. Verified against
/// `qwen-audio-3.1-realtime-flash`: the server emits `speech_started`,
/// `speech_stopped`, `committed`, then creates the response itself.
pub let dashscope_default_turn_detection : String = "smart_turn_v2"

///|
/// DashScope Realtime adapter skeleton.
///
/// Transport (WebSocket connect, send, receive) is added in the P0 spike.
/// This type owns everything that can be decided without a socket: endpoint,
/// auth header, audio formats, and wire event translation.
pub struct DashScopeProvider {
  config : ProviderConfig
}

///|
pub fn DashScopeProvider::new(config : ProviderConfig) -> Self {
  { config, }
}

///|
pub fn DashScopeProvider::config(self : DashScopeProvider) -> ProviderConfig {
  self.config
}

///|
/// DashScope selects the model with a query parameter.
pub fn DashScopeProvider::connect_url(self : DashScopeProvider) -> String {
  let separator = if self.config.endpoint.contains("?") { "&" } else { "?" }
  self.config.endpoint + separator + "model=" + self.config.model
}

///|
/// Never log the returned value.
pub fn DashScopeProvider::auth_header(self : DashScopeProvider) -> String {
  "Bearer " + self.config.api_key
}

///|
pub fn DashScopeProvider::input_sample_rate(self : DashScopeProvider) -> Int32 {
  dashscope_input_sample_rate
}

///|
pub fn DashScopeProvider::output_sample_rate(self : DashScopeProvider) -> Int32 {
  dashscope_output_sample_rate
}

///|
/// The `session.update` frame this provider expects for a voice session.
///
/// Server-side turn detection is on by default because the Qwen Audio 3.x
/// family drives turns itself. Use `encode_session_update` directly when a test
/// needs manual `input_audio_buffer.commit` instead.
pub fn DashScopeProvider::session_update(
  self : DashScopeProvider,
  instructions : String,
  turn_detection? : String,
) -> Json {
  let detection = match turn_detection {
    Some(kind) => kind
    None => dashscope_default_turn_detection
  }
  encode_session_update(
    self.config.voice,
    instructions,
    turn_detection=detection,
  )
}

///|
pub fn encode_audio_append(audio : String) -> Json {
  Json::object({
    "type": Json::string("input_audio_buffer.append"),
    "audio": Json::string(audio),
  })
}

///|
pub fn encode_text_message(text : String) -> Json {
  Json::object({
    "type": Json::string("conversation.item.create"),
    "item": Json::object({
      "type": Json::string("message"),
      "role": Json::string("user"),
      "content": Json::array([
        Json::object({
          "type": Json::string("input_text"),
          "text": Json::string(text),
        }),
      ]),
    }),
  })
}

///|
/// Minimal DashScope `session.update`.
///
/// `turn_detection` is optional so the smoke command can isolate transport and
/// auth failures from VAD configuration. Production sessions set it to the
/// provider-appropriate value (`smart_turn_v2` for the Qwen Audio 3.1 family)
/// so the server creates responses automatically.
pub fn encode_session_update(
  voice : String,
  instructions : String,
  turn_detection? : String,
) -> Json {
  let session : Map[String, Json] = {
    "modalities": Json::array([Json::string("text"), Json::string("audio")]),
    "instructions": Json::string(instructions),
    "voice": Json::string(voice),
    "input_audio_format": Json::string("pcm"),
    "output_audio_format": Json::string("pcm"),
  }
  match turn_detection {
    Some(kind) =>
      session.set(
        "turn_detection",
        Json::object({ "type": Json::string(kind) }),
      )
    None => ()
  }
  Json::object({
    "type": Json::string("session.update"),
    "session": Json::object(session),
  })
}

///|
/// Close the current input audio buffer so the provider treats it as one turn.
pub fn encode_audio_commit() -> Json {
  Json::object({ "type": Json::string("input_audio_buffer.commit") })
}

///|
/// Discard buffered input. Used together with `response.cancel` when the user
/// interrupts the assistant.
pub fn encode_audio_clear() -> Json {
  Json::object({ "type": Json::string("input_audio_buffer.clear") })
}

///|
pub fn encode_response_create() -> Json {
  Json::object({ "type": Json::string("response.create") })
}

///|
pub fn encode_response_cancel() -> Json {
  Json::object({ "type": Json::string("response.cancel") })
}

///|
fn string_field(
  map : Map[String, Json],
  key : String,
) -> String raise ProviderError {
  match map.get(key) {
    Some(Json::String(value)) => value
    Some(_) => raise InvalidFrame("expected " + key + " to be a string")
    None => raise MissingField(key)
  }
}

///|
fn optional_string(map : Map[String, Json], key : String) -> String {
  match map.get(key) {
    Some(Json::String(value)) => value
    _ => ""
  }
}

///|
fn optional_int(
  map : Map[String, Json],
  key : String,
  fallback : Int32,
) -> Int32 {
  match map.get(key) {
    Some(Json::Number(value, ..)) => value.to_int()
    _ => fallback
  }
}

///|
fn classify_provider_error(message : String) -> @protocol.ErrorCode {
  let lower = message.to_lower()
  if lower.contains("api key") ||
    lower.contains("unauthorized") ||
    lower.contains("authentication") ||
    lower.contains("401") ||
    lower.contains("403") {
    @protocol.ErrorCode::ProviderAuthFailed
  } else {
    @protocol.ErrorCode::ProviderUnavailable
  }
}

///|
fn error_event(map : Map[String, Json]) -> ProviderEvent {
  let (code, message) = match map.get("error") {
    Some(Json::Object(error)) =>
      (optional_string(error, "code"), optional_string(error, "message"))
    _ => ("", optional_string(map, "message"))
  }
  let message = if message == "" { code } else { message }
  let error_code = classify_provider_error(message)
  Error(
    code=error_code,
    message~,
    retryable=error_code != @protocol.ErrorCode::ProviderAuthFailed,
  )
}

///|
fn normalize_object(
  map : Map[String, Json],
) -> Result[ProviderEvent?, ProviderError] raise ProviderError {
  let kind = string_field(map, "type")
  match kind {
    "response.audio.delta" | "response.output_audio.delta" =>
      Ok(
        Some(
          AudioDelta(
            delta=string_field(map, "delta"),
            sample_rate=optional_int(
              map, "sampleRate", dashscope_output_sample_rate,
            ),
          ),
        ),
      )
    "response.audio_transcript.delta"
    | "response.output_audio_transcript.delta"
    | "response.text.delta" =>
      Ok(
        Some(
          TranscriptPartial(role="assistant", text=string_field(map, "delta")),
        ),
      )
    "response.audio_transcript.done"
    | "response.output_audio_transcript.done"
    | "response.text.done" =>
      Ok(
        Some(
          TranscriptFinal(
            role="assistant",
            text=optional_string(map, "transcript") +
              optional_string(map, "text"),
          ),
        ),
      )
    "conversation.item.input_audio_transcription.delta"
    | "conversation.item.input_audio_transcription.text" =>
      Ok(
        Some(
          TranscriptPartial(
            role="user",
            text=optional_string(map, "delta") + optional_string(map, "text"),
          ),
        ),
      )
    "conversation.item.input_audio_transcription.completed" =>
      Ok(
        Some(
          TranscriptFinal(role="user", text=optional_string(map, "transcript")),
        ),
      )
    "input_audio_buffer.speech_started" => Ok(Some(Interrupted))
    "response.created" => Ok(Some(ResponseStarted))
    "response.done" => Ok(Some(TurnComplete))
    "error" => Ok(Some(error_event(map)))
    _ => Ok(None)
  }
}

///|
pub fn normalize_event(json : Json) -> Result[ProviderEvent?, ProviderError] {
  match json {
    Json::Object(map) => normalize_object(map) catch { error => Err(error) }
    _ => Err(InvalidFrame("expected a JSON object"))
  }
}

///|
pub fn normalize_incoming(
  input : String,
) -> Result[ProviderEvent?, ProviderError] {
  let json = @json.parse(input) catch {
    error => return Err(InvalidFrame(error.to_string()))
  }
  normalize_event(json)
}
