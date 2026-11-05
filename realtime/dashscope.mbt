///|
pub let dashscope_default_endpoint : String = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"

///|
pub let dashscope_input_sample_rate : Int32 = 16000

///|
pub let dashscope_output_sample_rate : Int32 = 24000

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
