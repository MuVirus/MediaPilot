///|
pub let dashscope_default_endpoint : String = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"

///|
pub let dashscope_input_sample_rate : Int32 = 16000

///|
pub let dashscope_output_sample_rate : Int32 = 24000

///|
/// Turn detection used when the model is unknown. The Qwen Audio 3.1 family
/// uses this; omni models need `semantic_vad` instead.
pub let dashscope_default_turn_detection : String = "smart_turn_v2"

///|
/// Per-model defaults.
///
/// DashScope's realtime families differ in default voice, turn detection, and
/// whether `tools` is safe to send. Sending `tools` to a model that does not
/// support them fails silently: `session.update` is accepted, then every
/// generation ends with `status = "failed"`. So the profile is the only place
/// that decides whether tools may be attached.
#derive(Eq, Debug)
pub(all) struct ModelProfile {
  model : String
  /// Default voice, or `None` when the model is unknown and the configured
  /// voice should be used as-is.
  voice : String?
  turn_detection : String
  supports_tools : Bool
}

///|
/// Resolve a model ID to its profile.
///
/// Unknown models get the conservative defaults: no tools, `smart_turn_v2`.
/// A new model that supports tools must be added here explicitly rather than
/// guessed, because the failure mode is a silent empty response.
pub fn resolve_model_profile(model : String) -> ModelProfile {
  match model {
    "qwen-audio-3.1-realtime-plus" =>
      {
        model,
        voice: Some("longanqian_v3.1"),
        turn_detection: "smart_turn_v2",
        supports_tools: true,
      }
    // Verified broken: `session.update` accepts tools, then every generation
    // fails with "An internal error occurred while generating the response."
    "qwen-audio-3.1-realtime-flash" =>
      {
        model,
        voice: Some("longanqian_v3.1"),
        turn_detection: "smart_turn_v2",
        supports_tools: false,
      }
    "qwen-audio-3.0-realtime-plus" =>
      {
        model,
        voice: Some("longanqian"),
        turn_detection: "smart_turn",
        supports_tools: true,
      }
    "qwen-audio-3.0-realtime-flash" =>
      {
        model,
        voice: Some("longanqian"),
        turn_detection: "smart_turn",
        supports_tools: true,
      }
    "qwen3.5-omni-flash-realtime" =>
      {
        model,
        voice: Some("Ethan"),
        turn_detection: "semantic_vad",
        supports_tools: true,
      }
    "qwen3.5-omni-plus-realtime" =>
      {
        model,
        voice: Some("Ethan"),
        turn_detection: "semantic_vad",
        supports_tools: true,
      }
    "qwen3.8-omni-flash-realtime" =>
      {
        model,
        voice: Some("Tina"),
        turn_detection: "semantic_vad",
        supports_tools: true,
      }
    _ =>
      {
        model,
        voice: None,
        turn_detection: dashscope_default_turn_detection,
        supports_tools: false,
      }
  }
}

///|
/// The model this project defaults to. Matches the reference project's default.
pub let dashscope_default_model : String = "qwen-audio-3.1-realtime-plus"

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
pub fn DashScopeProvider::input_sample_rate(_self : DashScopeProvider) -> Int32 {
  dashscope_input_sample_rate
}

///|
pub fn DashScopeProvider::output_sample_rate(
  _self : DashScopeProvider,
) -> Int32 {
  dashscope_output_sample_rate
}

///|
/// The model profile this provider is configured for.
pub fn DashScopeProvider::profile(self : DashScopeProvider) -> ModelProfile {
  resolve_model_profile(self.config.model)
}

///|
/// The voice to use: the configured voice when set, otherwise the model's
/// default.
pub fn DashScopeProvider::voice(self : DashScopeProvider) -> String {
  if self.config.voice != "" {
    self.config.voice
  } else {
    match self.profile().voice {
      Some(voice) => voice
      None => ""
    }
  }
}

///|
/// The `session.update` frame this provider expects for a voice session.
///
/// Turn detection comes from the model profile, because omni models need
/// `semantic_vad` while the audio family uses `smart_turn*`. Use
/// `encode_session_update` directly when a test needs manual
/// `input_audio_buffer.commit` instead.
///
/// `tools` is dropped with a warning when the profile says the model cannot
/// handle them: sending them anyway produces empty failed responses.
pub fn DashScopeProvider::session_update(
  self : DashScopeProvider,
  instructions : String,
  turn_detection? : String,
  tools? : Json,
) -> Json {
  let profile = self.profile()
  let detection = match turn_detection {
    Some(kind) => kind
    None => profile.turn_detection
  }
  let voice = self.voice()
  let usable_tools = match tools {
    Some(value) =>
      if profile.supports_tools {
        Some(value)
      } else {
        println(
          "[realtime] model " +
          profile.model +
          " does not support tools; dropping the tool list",
        )
        None
      }
    None => None
  }
  match usable_tools {
    Some(value) =>
      encode_session_update(
        voice,
        instructions,
        turn_detection=detection,
        tools=value,
      )
    None => encode_session_update(voice, instructions, turn_detection=detection)
  }
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
///
/// `tools` is the OpenAI-style function list. Passing it is what turns the
/// realtime model into a coordinator that can delegate work.
pub fn encode_session_update(
  voice : String,
  instructions : String,
  turn_detection? : String,
  tools? : Json,
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
  match tools {
    Some(value) => session.set("tools", value)
    None => ()
  }
  Json::object({
    "type": Json::string("session.update"),
    "session": Json::object(session),
  })
}

///|
/// One OpenAI-style function definition.
pub fn function_tool(
  name : String,
  description : String,
  parameters : Json,
) -> Json {
  Json::object({
    "type": Json::string("function"),
    "function": Json::object({
      "name": Json::string(name),
      "description": Json::string(description),
      "parameters": parameters,
    }),
  })
}

///|
/// Inject a tool result back into the conversation.
///
/// `output` is a string, not an object: the provider expects the JSON-encoded
/// result as the `output` field.
pub fn encode_function_output(call_id : String, output : String) -> Json {
  Json::object({
    "type": Json::string("conversation.item.create"),
    "item": Json::object({
      "type": Json::string("function_call_output"),
      "call_id": Json::string(call_id),
      "output": Json::string(output),
    }),
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
/// Start a response with per-response instructions and tool choice.
///
/// DashScope accepts an OpenAI-style `response` object on `response.create`.
/// Background results use `tool_choice = "none"` so the model narrates the
/// result instead of delegating again.
pub fn encode_response_create_with_instructions(instructions : String) -> Json {
  Json::object({
    "type": Json::string("response.create"),
    "response": Json::object({
      "instructions": Json::string(instructions),
      "tool_choice": Json::string("none"),
    }),
  })
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
    | "conversation.item.input_audio_transcription.text" => {
      // DashScope streams the *current* item transcript in `text` plus a
      // pending suffix in `stash`; `delta` is the fallback for older shapes.
      let complete = optional_string(map, "text") +
        optional_string(map, "stash")
      let value = if complete == "" {
        optional_string(map, "delta")
      } else {
        complete
      }
      Ok(Some(TranscriptPartial(role="user", text=value)))
    }
    "conversation.item.input_audio_transcription.completed" =>
      Ok(
        Some(
          TranscriptFinal(role="user", text=optional_string(map, "transcript")),
        ),
      )
    "input_audio_buffer.speech_started" => Ok(Some(Interrupted))
    "response.created" => Ok(Some(ResponseStarted))
    "response.function_call_arguments.done" =>
      Ok(
        Some(
          FunctionCall(
            call_id=optional_string(map, "call_id"),
            name=optional_string(map, "name"),
            arguments=optional_string(map, "arguments"),
          ),
        ),
      )
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
