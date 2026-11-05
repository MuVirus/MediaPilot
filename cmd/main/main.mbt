///|
fn env_or(key : String, fallback : String) -> String {
  match @env.get_env_var(key) {
    Some(value) if value != "" => value
    _ => fallback
  }
}

///|
let default_instructions : String = "You are a concise voice assistant. Answer in one short sentence."

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
    model: env_or("MEDIAPILOT_REALTIME_MODEL", "qwen-audio-3.1-realtime-flash"),
    endpoint: env_or(
      "MEDIAPILOT_REALTIME_ENDPOINT", @realtime.dashscope_default_endpoint,
    ),
    voice: env_or("MEDIAPILOT_REALTIME_VOICE", "longanqian_v3.1"),
  }
  let bind = env_or("MEDIAPILOT_BIND", "127.0.0.1:8787")
  let instructions = env_or("MEDIAPILOT_INSTRUCTIONS", default_instructions)
  let static_root = env_or("MEDIAPILOT_WEB_ROOT", "web")
  println("[gateway] model=" + config.model)
  println("[gateway] voice=" + config.voice)
  println("[gateway] web=" + static_root)
  let open_provider : @gateway.ProviderFactory = async fn(session_id) {
    let session = @realtime.DashScopeSession::open(
      config, session_id, instructions,
    ) catch {
      error =>
        return Err(@ports.ProviderFailure::{
          code: error.to_error_code(),
          message: error.to_string(),
          retryable: error.is_retryable(),
        })
    }
    Ok(session as &@ports.RealtimeProvider)
  }
  @gateway.run_gateway(bind, open_provider, static_root~)
}
