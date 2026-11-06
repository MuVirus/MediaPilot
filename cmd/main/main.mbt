///|
/// True when a command can be found either as a path or on `PATH`.
///
/// The check is intentionally best-effort and only runs for ACP deployments;
/// the actual process start still reports its own failure.
async fn command_available(command : String) -> Bool {
  if command.contains("/") || command.contains("\\") {
    return @fs.exists(command) catch { _ => false }
  }
  let (probe, args) = if @async.platform is Windows {
    ("where", [command])
  } else {
    ("which", [command])
  }
  try {
    let result = @process.run(
      probe,
      args,
      stdout=@process.Discard,
      stderr=@process.Discard,
    )
    result.exit_code == 0
  } catch {
    _ => false
  }
}

///|
let default_instructions : String = "You are a concise voice assistant. Answer in one short sentence. When the user asks you to actually do something, call delegate_task instead of pretending to do it; call the tool before answering. The tool result may say the work was accepted, not finished: in that case tell the user briefly that you are working on it and do not claim it is done. A later background result will arrive as a system notice; report its actual outcome. If the user asks how that work is going, call get_agent_task_status instead of guessing. If the user asks you to stop it, call cancel_agent_task."

///|
/// Gateway entry point.
///
/// Configuration is read from `.media_pilot/config.env` in the working
/// directory, falling back to the user's `.media_pilot/config.env` for missing
/// keys. The process environment always wins. Secrets are never printed.
async fn main {
  let loaded = @config.load_config()
  println("[gateway] config root=" + loaded.root)
  for file in loaded.files {
    println("[gateway] config file=" + file)
  }
  if loaded.files.length() == 0 {
    println(
      "[gateway] no config file found; expected " +
      @config.join_path(loaded.root, @config.config_file_name),
    )
  }
  let api_key = match loaded.get("DASHSCOPE_API_KEY") {
    Some(value) if value != "" => value
    _ => {
      println("[gateway] DASHSCOPE_API_KEY is not set; refusing to start")
      println(
        "[gateway] checked the process environment and the files listed above",
      )
      println(
        "[gateway] add DASHSCOPE_API_KEY to " +
        @config.join_path(loaded.root, @config.config_file_name),
      )
      return
    }
  }
  let config = @realtime.ProviderConfig::{
    api_key,
    model: loaded.get_or(
      "MEDIAPILOT_REALTIME_MODEL", @realtime.dashscope_default_model,
    ),
    endpoint: loaded.get_or(
      "MEDIAPILOT_REALTIME_ENDPOINT", @realtime.dashscope_default_endpoint,
    ),
    voice: loaded.get_or("MEDIAPILOT_REALTIME_VOICE", "longanqian_v3.1"),
  }
  let llm_config = @backend.LlmConfig::{
    base_url: loaded.get_or(
      "MEDIAPILOT_LLM_BASE_URL", @backend.default_llm_base_url,
    ),
    api_key: config.api_key,
    model: loaded.get_or("MEDIAPILOT_LLM_MODEL", "qwen-plus"),
    system_prompt: loaded.get_or(
      "MEDIAPILOT_LLM_SYSTEM", "You are a concise voice assistant. Answer in one short sentence.",
    ),
  }
  let bind = loaded.get_or("MEDIAPILOT_BIND", "127.0.0.1:8787")
  let _ = @socket.Addr::parse(bind) catch {
    _ => {
      println(
        "[gateway] invalid MEDIAPILOT_BIND, expected host:port, got " + bind,
      )
      return
    }
  }
  let max_sessions = match loaded.get("MEDIAPILOT_MAX_SESSIONS") {
    Some(text) =>
      match @config.parse_positive_int(text) {
        Some(value) => value
        None => {
          println(
            "[gateway] MEDIAPILOT_MAX_SESSIONS must be a positive integer, got " +
            text,
          )
          return
        }
      }
    None => @gateway.default_max_sessions
  }
  let max_tasks_per_session = match loaded.get("MEDIAPILOT_MAX_TASKS") {
    Some(text) =>
      match @config.parse_positive_int(text) {
        Some(value) => value
        None => {
          println(
            "[gateway] MEDIAPILOT_MAX_TASKS must be a positive integer, got " +
            text,
          )
          return
        }
      }
    None => @gateway.default_max_tasks_per_session
  }
  let auth_token = loaded.get_or("MEDIAPILOT_AUTH_TOKEN", "")
  let instructions = loaded.get_or(
    "MEDIAPILOT_INSTRUCTIONS", default_instructions,
  )
  let static_root = loaded.get_or("MEDIAPILOT_WEB_ROOT", "web")
  let web_exists = @fs.exists(static_root) catch { _ => false }
  if !web_exists {
    println(
      "[gateway] MEDIAPILOT_WEB_ROOT does not exist: " +
      static_root +
      "; run from the repository root or set an absolute path",
    )
    return
  }
  let backend_kind = loaded.get_or("MEDIAPILOT_BACKEND", "llm")
  if !["llm", "acp", "none"].contains(backend_kind) {
    println(
      "[gateway] MEDIAPILOT_BACKEND must be llm, acp, or none, got " +
      backend_kind,
    )
    return
  }
  let acp_cwd = match loaded.get("MEDIAPILOT_ACP_CWD") {
    Some(value) if value != "" => value
    _ => @fs.realpath(".") catch { _ => "." }
  }
  // Workspace selection is ACP-only: the LLM backend has no filesystem view.
  // With no explicit list the deployment keeps the old single-directory
  // behaviour and still advertises that one directory.
  let workspace_roots : Array[String] = if backend_kind == "acp" {
    let configured = match loaded.get("MEDIAPILOT_ACP_ROOTS") {
      Some(text) => @config.split_list(text)
      None => []
    }
    if configured.length() == 0 {
      [acp_cwd]
    } else {
      let resolved : Array[String] = []
      for entry in configured {
        let path = @config.expand_home(entry, @config.home_directory())
        if !@config.is_absolute_path(path) {
          println(
            "[gateway] MEDIAPILOT_ACP_ROOTS entries must be absolute paths, got " +
            entry,
          )
          return
        }
        if !(@fs.exists(path) catch { _ => false }) {
          println(
            "[gateway] MEDIAPILOT_ACP_ROOTS entry does not exist: " + path,
          )
          return
        }
        let real = @fs.realpath(path) catch { _ => path }
        if !resolved.contains(real) {
          resolved.push(real)
        }
      }
      resolved
    }
  } else {
    []
  }
  let workspaces = @gateway.Workspaces::new(
    workspace_roots,
    if workspace_roots.length() > 0 {
      workspace_roots[0]
    } else {
      ""
    },
  )
  let acp_config : @backend.AcpConfig = {
    command: loaded.get_or("MEDIAPILOT_ACP_COMMAND", "opencode"),
    args: [loaded.get_or("MEDIAPILOT_ACP_MODE", "acp")],
    cwd: acp_cwd,
    inherit_env: true,
    model: loaded.get_or("MEDIAPILOT_ACP_MODEL", ""),
  }
  if backend_kind == "acp" && !command_available(acp_config.command) {
    println(
      "[gateway] MEDIAPILOT_ACP_COMMAND was not found: " + acp_config.command,
    )
    println(
      "[gateway] install the agent CLI or set MEDIAPILOT_ACP_COMMAND to its full path",
    )
    return
  }
  println("[gateway] model=" + config.model)
  println("[gateway] voice=" + config.voice)
  println(
    "[gateway] backend=" +
    backend_kind +
    (if backend_kind == "acp" {
      " command=" + acp_config.command
    } else {
      " model=" + llm_config.model
    }),
  )
  println("[gateway] web=" + static_root)
  println(
    "[gateway] workspaces=" +
    workspaces.roots().length().to_string() +
    (if workspaces.is_enabled() {
      " default=" + workspaces.default_root()
    } else {
      " disabled"
    }),
  )
  println(
    "[gateway] max sessions=" +
    max_sessions.to_string() +
    " max tasks/session=" +
    max_tasks_per_session.to_string() +
    (if auth_token == "" { " auth=off" } else { " auth=on" }),
  )
  let open_provider : @gateway.ProviderFactory = async fn(session_id, tools) {
    let session = match tools {
      Some(tool_list) =>
        @realtime.DashScopeSession::open(
          config,
          session_id,
          instructions,
          tools=tool_list,
        ) catch {
          error =>
            return Err(@ports.ProviderFailure::{
              code: error.to_error_code(),
              message: error.to_string(),
              retryable: error.is_retryable(),
            })
        }
      None =>
        @realtime.DashScopeSession::open(config, session_id, instructions) catch {
          error =>
            return Err(@ports.ProviderFailure::{
              code: error.to_error_code(),
              message: error.to_string(),
              retryable: error.is_retryable(),
            })
        }
    }
    Ok(session as &@ports.RealtimeProvider)
  }
  let open_backend : @gateway.BackendFactory = fn(_session_id, workspace) {
    if backend_kind == "none" {
      return Err(@ports.ProviderFailure::{
        code: @protocol.ErrorCode::InternalError,
        message: "MEDIAPILOT_BACKEND=none disables tools",
        retryable: false,
      })
    }
    if backend_kind == "acp" {
      let session_config : @backend.AcpConfig = {
        command: acp_config.command,
        args: acp_config.args,
        cwd: if workspace != "" {
          workspace
        } else {
          acp_config.cwd
        },
        inherit_env: acp_config.inherit_env,
        model: acp_config.model,
      }
      Ok(@backend.AcpBackend::new(session_config) as &@ports.BackendPort)
    } else {
      Ok(@backend.LlmBackend::new(llm_config) as &@ports.BackendPort)
    }
  }
  @gateway.run_gateway(
    bind,
    open_provider,
    open_backend~,
    static_root~,
    max_sessions~,
    max_tasks_per_session~,
    auth_token~,
    workspaces~,
  )
}
