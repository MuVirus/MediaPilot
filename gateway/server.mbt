///|
/// Opens one upstream session for a client session.
///
/// `cmd/` supplies this so `gateway/` never imports a provider package.
pub type ProviderFactory = async (String) -> Result[
  &@ports.RealtimeProvider,
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
  static_root? : String,
) -> Unit {
  let addr = @socket.Addr::parse(bind)
  let server = @http.Server(addr)
  println("[gateway] listening on " + bind)
  match static_root {
    Some(root) => serve(server, open_provider, static_root=root)
    None => serve(server, open_provider)
  }
}

///|
/// Serve on an already-bound server. Tests use this with port 0 so they can
/// read the assigned port before connecting.
pub async fn serve(
  server : @http.Server,
  open_provider : ProviderFactory,
  static_root? : String,
) -> Unit {
  server.run_forever((request, conn) => {
    match (request.meth, request.path) {
      (Get, "/api/health") => handle_health(conn)
      (Get, "/api/realtime") => handle_realtime(request, conn, open_provider)
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
  let provider = match open_provider(session_id) {
    Ok(provider) => provider
    Err(failure) => {
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
  bridge(ws, provider, session_id)
  provider.close()
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
) -> Unit {
  let outbound : @aqueue.Queue[@protocol.ServerEvent?] = @aqueue.Queue(
    kind=Blocking(outbound_capacity),
  )
  let done : @aqueue.Queue[Unit] = @aqueue.Queue(kind=Blocking(1))
  // Set when the client closed on purpose, so an upstream shutdown is not
  // reported back as a retryable error.
  let client_closing : Ref[Bool] = Ref(false)
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true) <| () => {
      client_pump(ws, provider, session_id, outbound, client_closing)
      done.put(())
    }
    group.spawn_bg(no_wait=true) <| () => {
      provider_pump(provider, outbound, client_closing)
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
  session_id : String,
  outbound : @aqueue.Queue[@protocol.ServerEvent?],
  client_closing : Ref[Bool],
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
        outbound.put(
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
        outbound.put(
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
          outbound.put(
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
      Some(@protocol.ClientEvent::Interrupt) => {
        // Cancel upstream first, then drop audio already queued for the
        // cancelled response, then confirm to the client.
        provider.interrupt()
        drain_outbound(outbound)
        outbound.put(
          Some(
            @protocol.ServerEvent::PlaybackClear(
              session_id~,
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
        outbound.put(
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
async fn provider_pump(
  provider : &@ports.RealtimeProvider,
  outbound : @aqueue.Queue[@protocol.ServerEvent?],
  client_closing : Ref[Bool],
) -> Unit {
  for ;; {
    match provider.next_event() {
      Some(event) => outbound.put(Some(event))
      None => {
        if !client_closing.val {
          outbound.put(
            Some(
              @protocol.ServerEvent::Error(
                code=@protocol.ErrorCode::ProviderUnavailable,
                message="upstream closed the realtime session",
                retryable=true,
              ),
            ),
          )
        }
        outbound.put(None)
        return
      }
    }
  }
}

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
