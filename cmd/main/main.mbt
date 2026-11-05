///|
fn env_or(key : String, fallback : String) -> String {
  match @env.get_env_var(key) {
    Some(value) if value != "" => value
    _ => fallback
  }
}

///|
let default_instructions : String = "You are a concise voice assistant. Answer in one short sentence. When the user asks you to actually do something, call delegate_task instead of pretending to do it."

///|
/// Gateway entry point.
///
/// Reads configuration from the environment, then serves `GET /api/health` and
/// `WS /api/realtime`. The API key is never printed.
async fn main {
  let api_key = match @env.get_env_var("DASHSCOPE_API_KEY") {
    Some(value) if value != "" => value
    _ => {
      println("[gateway] DASHSCOPE_API_KEY is not set; refusing to start")
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
  let llm_config = @backend.LlmConfig::{
    base_url: env_or("MEDIAPILOT_LLM_BASE_URL", @backend.default_llm_base_url),
    api_key: config.api_key,
    model: env_or("MEDIAPILOT_LLM_MODEL", "qwen-plus"),
    system_prompt: env_or(
      "MEDIAPILOT_LLM_SYSTEM", "You are a concise voice assistant. Answer in one short sentence.",
    ),
  }
  let bind = env_or("MEDIAPILOT_BIND", "127.0.0.1:8787")
  let instructions = env_or("MEDIAPILOT_INSTRUCTIONS", default_instructions)
  let static_root = env_or("MEDIAPILOT_WEB_ROOT", "web")
  let backend_kind = env_or("MEDIAPILOT_BACKEND", "llm")
  let acp_cwd = match @env.get_env_var("MEDIAPILOT_ACP_CWD") {
    Some(value) if value != "" => value
    _ => @fs.realpath(".") catch { _ => "." }
  }
  let acp_config : @backend.AcpConfig = {
    command: env_or("MEDIAPILOT_ACP_COMMAND", "opencode"),
    args: [env_or("MEDIAPILOT_ACP_MODE", "acp")],
    cwd: acp_cwd,
    inherit_env: true,
    model: env_or("MEDIAPILOT_ACP_MODEL", ""),
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
  let open_backend : @gateway.BackendFactory = async fn(_session_id) {
    if backend_kind == "none" {
      return Err(@ports.ProviderFailure::{
        code: @protocol.ErrorCode::InternalError,
        message: "MEDIAPILOT_BACKEND=none disables tools",
        retryable: false,
      })
    }
    if backend_kind == "acp" {
      Ok(@backend.AcpBackend::new(acp_config) as &@ports.BackendPort)
    } else {
      Ok(@backend.LlmBackend::new(llm_config) as &@ports.BackendPort)
    }
  }
  @gateway.run_gateway(bind, open_provider, open_backend~, static_root~)
}
