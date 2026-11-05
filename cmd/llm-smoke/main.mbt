///|
/// P2 spike: exercise the LLM backend against a real OpenAI-compatible
/// endpoint. Prints the first streamed delta, then the final answer.
///
/// The API key comes from the environment and is never printed.
fn env_or(key : String, fallback : String) -> String {
  match @env.get_env_var(key) {
    Some(value) if value != "" => value
    _ => fallback
  }
}

///|
async fn main {
  let api_key = match @env.get_env_var("DASHSCOPE_API_KEY") {
    Some(value) if value != "" => value
    _ => {
      println("[llm] DASHSCOPE_API_KEY is not set; aborting")
      return
    }
  }
  let config = @backend.LlmConfig::{
    base_url: env_or("MEDIAPILOT_LLM_BASE_URL", @backend.default_llm_base_url),
    api_key,
    model: env_or("MEDIAPILOT_LLM_MODEL", "qwen-plus"),
    system_prompt: env_or(
      "MEDIAPILOT_LLM_SYSTEM", "You are a concise voice assistant. Answer in one short sentence.",
    ),
  }
  println("[llm] base_url=" + config.base_url)
  println("[llm] model=" + config.model)
  let backend = @backend.LlmBackend::new(config)
  let port : &@ports.BackendPort = backend as &@ports.BackendPort
  let question = env_or(
    "MEDIAPILOT_LLM_QUESTION", "用一句话介绍你自己。",
  )
  println("[llm] question=" + question)
  let mut answer = ""
  @async.with_task_group() <| group => {
    group.spawn_bg(no_wait=true) <| () => { port.submit("t-1", question) }
    let mut deltas = 0
    for ;; {
      match port.next_event() {
        None => break
        Some(@ports.BackendEvent::TextDelta(text~)) => {
          if deltas == 0 {
            println("[llm] first delta: " + text)
          }
          deltas = deltas + 1
          answer = answer + text
        }
        Some(@ports.BackendEvent::TextDone(text~)) => {
          println("[llm] text done, chars=" + text.length().to_string())
          answer = text
        }
        Some(@ports.BackendEvent::Completed) => {
          println("[llm] completed with " + deltas.to_string() + " deltas")
          break
        }
        Some(@ports.BackendEvent::Failed(code~, message~, retryable~)) => {
          println(
            "[llm] failed code=" +
            code.to_code() +
            " retryable=" +
            retryable.to_string() +
            " message=" +
            message,
          )
          break
        }
        Some(_) => ()
      }
    }
  }
  println("[llm] answer: " + answer)
  port.close()
}
