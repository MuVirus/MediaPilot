///|
fn make_object(fields : Array[(String, Json)]) -> Json {
  let map : Map[String, Json] = Map([])
  for field in fields {
    map.set(field.0, field.1)
  }
  Json::object(map)
}

///|
fn strings_to_json(values : Array[String]) -> Json {
  let items : Array[Json] = []
  for value in values {
    items.push(Json::string(value))
  }
  Json::array(items)
}

///|
fn parse_object(input : String) -> Map[String, Json] raise ProtocolError {
  let json = @json.parse(input) catch {
    error => raise InvalidJson(error.to_string())
  }
  match json {
    Json::Object(map) => map
    _ => raise InvalidField("event", "expected a JSON object")
  }
}

///|
fn event_type(map : Map[String, Json]) -> String raise ProtocolError {
  match map.get("type") {
    Some(Json::String(value)) => value
    Some(_) => raise InvalidField("type", "expected a string")
    None => raise MissingField("type")
  }
}

///|
fn string_field(
  map : Map[String, Json],
  key : String,
) -> String raise ProtocolError {
  match map.get(key) {
    Some(Json::String(value)) => value
    Some(_) => raise InvalidField(key, "expected a string")
    None => raise MissingField(key)
  }
}

///|
/// Read an optional string field. A missing or null field yields `""` so an
/// event from an older peer still decodes.
fn optional_string_field(map : Map[String, Json], key : String) -> String {
  match map.get(key) {
    Some(Json::String(value)) => value
    _ => ""
  }
}

///|
fn int_field(
  map : Map[String, Json],
  key : String,
) -> Int32 raise ProtocolError {
  match map.get(key) {
    Some(Json::Number(value, ..)) => value.to_int()
    Some(_) => raise InvalidField(key, "expected a number")
    None => raise MissingField(key)
  }
}

///|
fn bool_field(
  map : Map[String, Json],
  key : String,
) -> Bool raise ProtocolError {
  match map.get(key) {
    Some(Json::True) => true
    Some(Json::False) => false
    Some(_) => raise InvalidField(key, "expected a boolean")
    None => raise MissingField(key)
  }
}

///|
fn string_array_field(
  map : Map[String, Json],
  key : String,
) -> Array[String] raise ProtocolError {
  match map.get(key) {
    Some(Json::Array(items)) => {
      let values : Array[String] = []
      for item in items {
        match item {
          Json::String(value) => values.push(value)
          _ => raise InvalidField(key, "expected an array of strings")
        }
      }
      values
    }
    Some(_) => raise InvalidField(key, "expected an array of strings")
    None => raise MissingField(key)
  }
}

///|
fn check_audio_format(map : Map[String, Json]) -> Unit raise ProtocolError {
  let format = string_field(map, "format")
  if format != "pcm16" {
    raise InvalidField("format", "only pcm16 is supported")
  }
}

///|
pub fn encode_client_event(event : ClientEvent) -> Json {
  match event {
    Hello(request_id~, protocol_version~, capabilities~) =>
      make_object([
        ("type", Json::string("session.hello")),
        ("requestId", Json::string(request_id)),
        ("protocolVersion", Json::string(protocol_version)),
        ("capabilities", strings_to_json(capabilities)),
      ])
    AudioAppend(data~, format~, sample_rate~, channels~) =>
      make_object([
        ("type", Json::string("input.audio.append")),
        ("data", Json::string(data)),
        ("format", Json::string(format)),
        ("sampleRate", Json::number(sample_rate.to_double())),
        ("channels", Json::number(channels.to_double())),
      ])
    Text(text~) =>
      make_object([
        ("type", Json::string("input.text")),
        ("text", Json::string(text)),
      ])
    ImageAppend(data~, mime_type~) =>
      make_object([
        ("type", Json::string("input.image.append")),
        ("data", Json::string(data)),
        ("mimeType", Json::string(mime_type)),
      ])
    PermissionRespond(request_id~, decision~) =>
      make_object([
        ("type", Json::string("permission.respond")),
        ("requestId", Json::string(request_id)),
        ("decision", Json::string(decision)),
      ])
    Interrupt => make_object([("type", Json::string("session.interrupt"))])
    Close => make_object([("type", Json::string("session.close"))])
  }
}

///|
pub fn encode_client_event_string(event : ClientEvent) -> String {
  encode_client_event(event).stringify()
}

///|
/// Decode a client event. `None` means the event type is unknown and the
/// caller must ignore it, as required by the contract.
pub fn decode_client_event(input : String) -> ClientEvent? raise ProtocolError {
  let map = parse_object(input)
  let kind = event_type(map)
  match kind {
    "session.hello" => {
      let version = string_field(map, "protocolVersion")
      if !is_compatible_version(version) {
        raise UnsupportedVersion(version)
      }
      Some(
        Hello(
          request_id=string_field(map, "requestId"),
          protocol_version=version,
          capabilities=string_array_field(map, "capabilities"),
        ),
      )
    }
    "input.audio.append" => {
      check_audio_format(map)
      Some(
        AudioAppend(
          data=string_field(map, "data"),
          format=string_field(map, "format"),
          sample_rate=int_field(map, "sampleRate"),
          channels=int_field(map, "channels"),
        ),
      )
    }
    "input.text" => Some(Text(text=string_field(map, "text")))
    "input.image.append" =>
      Some(
        ImageAppend(
          data=string_field(map, "data"),
          mime_type=string_field(map, "mimeType"),
        ),
      )
    "session.interrupt" => Some(Interrupt)
    "permission.respond" =>
      Some(
        PermissionRespond(
          request_id=string_field(map, "requestId"),
          decision=string_field(map, "decision"),
        ),
      )
    "session.close" => Some(Close)
    _ => None
  }
}

///|
pub fn encode_server_event(event : ServerEvent) -> Json {
  match event {
    Ready(request_id~, session_id~, protocol_version~, capabilities~) =>
      make_object([
        ("type", Json::string("session.ready")),
        ("requestId", Json::string(request_id)),
        ("sessionId", Json::string(session_id)),
        ("protocolVersion", Json::string(protocol_version)),
        ("capabilities", strings_to_json(capabilities)),
      ])
    TranscriptPartial(session_id~, role~, text~) =>
      make_object([
        ("type", Json::string("transcript.partial")),
        ("sessionId", Json::string(session_id)),
        ("role", Json::string(role)),
        ("text", Json::string(text)),
      ])
    TranscriptFinal(session_id~, role~, text~) =>
      make_object([
        ("type", Json::string("transcript.final")),
        ("sessionId", Json::string(session_id)),
        ("role", Json::string(role)),
        ("text", Json::string(text)),
      ])
    AudioDelta(session_id~, data~, format~, sample_rate~, channels~) =>
      make_object([
        ("type", Json::string("audio.delta")),
        ("sessionId", Json::string(session_id)),
        ("data", Json::string(data)),
        ("format", Json::string(format)),
        ("sampleRate", Json::number(sample_rate.to_double())),
        ("channels", Json::number(channels.to_double())),
      ])
    PlaybackClear(session_id~, reason~) =>
      make_object([
        ("type", Json::string("playback.clear")),
        ("sessionId", Json::string(session_id)),
        ("reason", Json::string(reason)),
      ])
    TaskUpdated(session_id~, task_id~, status~, text~, step~) =>
      make_object([
        ("type", Json::string("task.updated")),
        ("sessionId", Json::string(session_id)),
        ("taskId", Json::string(task_id)),
        ("status", Json::string(status)),
        ("text", Json::string(text)),
        ("step", Json::string(step)),
      ])
    PermissionRequest(
      session_id~,
      request_id~,
      task_id~,
      operation~,
      description~,
      timeout_ms~
    ) =>
      make_object([
        ("type", Json::string("permission.request")),
        ("sessionId", Json::string(session_id)),
        ("requestId", Json::string(request_id)),
        ("taskId", Json::string(task_id)),
        ("operation", Json::string(operation)),
        ("description", Json::string(description)),
        ("timeoutMs", Json::number(timeout_ms.to_double())),
      ])
    PermissionResolved(session_id~, request_id~, decision~, source~) =>
      make_object([
        ("type", Json::string("permission.resolved")),
        ("sessionId", Json::string(session_id)),
        ("requestId", Json::string(request_id)),
        ("decision", Json::string(decision)),
        ("source", Json::string(source)),
      ])
    Error(code~, message~, retryable~) =>
      make_object([
        ("type", Json::string("error")),
        ("code", Json::string(code.to_code())),
        ("message", Json::string(message)),
        ("retryable", Json::boolean(retryable)),
      ])
  }
}

///|
pub fn encode_server_event_string(event : ServerEvent) -> String {
  encode_server_event(event).stringify()
}

///|
/// Decode a server event. `None` means the event type is unknown and the
/// caller must ignore it.
pub fn decode_server_event(input : String) -> ServerEvent? raise ProtocolError {
  let map = parse_object(input)
  let kind = event_type(map)
  match kind {
    "session.ready" =>
      Some(
        Ready(
          request_id=string_field(map, "requestId"),
          session_id=string_field(map, "sessionId"),
          protocol_version=string_field(map, "protocolVersion"),
          capabilities=string_array_field(map, "capabilities"),
        ),
      )
    "transcript.partial" =>
      Some(
        TranscriptPartial(
          session_id=string_field(map, "sessionId"),
          role=string_field(map, "role"),
          text=string_field(map, "text"),
        ),
      )
    "transcript.final" =>
      Some(
        TranscriptFinal(
          session_id=string_field(map, "sessionId"),
          role=string_field(map, "role"),
          text=string_field(map, "text"),
        ),
      )
    "audio.delta" => {
      check_audio_format(map)
      Some(
        AudioDelta(
          session_id=string_field(map, "sessionId"),
          data=string_field(map, "data"),
          format=string_field(map, "format"),
          sample_rate=int_field(map, "sampleRate"),
          channels=int_field(map, "channels"),
        ),
      )
    }
    "playback.clear" =>
      Some(
        PlaybackClear(
          session_id=string_field(map, "sessionId"),
          reason=string_field(map, "reason"),
        ),
      )
    "task.updated" =>
      Some(
        TaskUpdated(
          session_id=string_field(map, "sessionId"),
          task_id=string_field(map, "taskId"),
          status=string_field(map, "status"),
          text=string_field(map, "text"),
          step=optional_string_field(map, "step"),
        ),
      )
    "permission.request" =>
      Some(
        PermissionRequest(
          session_id=string_field(map, "sessionId"),
          request_id=string_field(map, "requestId"),
          task_id=string_field(map, "taskId"),
          operation=string_field(map, "operation"),
          description=string_field(map, "description"),
          timeout_ms=int_field(map, "timeoutMs"),
        ),
      )
    "permission.resolved" =>
      Some(
        PermissionResolved(
          session_id=string_field(map, "sessionId"),
          request_id=string_field(map, "requestId"),
          decision=string_field(map, "decision"),
          source=string_field(map, "source"),
        ),
      )
    "error" =>
      Some(
        Error(
          code=ErrorCode::from_code(string_field(map, "code")),
          message=string_field(map, "message"),
          retryable=bool_field(map, "retryable"),
        ),
      )
    _ => None
  }
}
