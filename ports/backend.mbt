///|
/// What a backend produces while it works on a task.
///
/// The gateway turns these into northbound events: `TextDelta`/`TextDone`
/// become speech, `Progress` becomes the `step` field of `task.updated`,
/// `PermissionRequest` becomes a northbound permission prompt.
#derive(Eq, Debug)
pub(all) enum BackendEvent {
  /// Incremental assistant text.
  TextDelta(text~ : String)
  /// The complete assistant text for this task.
  TextDone(text~ : String)
  /// A short human-readable step, such as "正在执行 `git status`". Not part of
  /// the answer; the gateway forwards it as progress only.
  Progress(text~ : String)
  /// The backend wants a tool executed. The gateway executes it and calls
  /// `respond_tool` with the result.
  ToolCall(call_id~ : String, name~ : String, arguments~ : String)
  /// The backend needs the user to approve an action before continuing.
  ///
  /// `operation` is a stable token (`read`, `edit`, `execute`, …); `description`
  /// is human-readable text authored by the backend and must not be used for
  /// decisions.
  PermissionRequest(
    request_id~ : String,
    operation~ : String,
    description~ : String
  )
  /// The task failed. `retryable` follows the same rule as the wire contract.
  Failed(code~ : @protocol.ErrorCode, message~ : String, retryable~ : Bool)
  /// The task finished successfully. Always the last event of a submission.
  Completed
}

///|
pub extend BackendEvent with Eq::{not_equal, equal}

///|
pub extend BackendEvent with @moonbitlang/core/debug.Debug::{to_repr}

///|
/// How long a remembered permission decision lasts.
///
/// The backend maps these onto whatever option vocabulary it has. A backend
/// without an "always" option must fall back to `AllowOnce`; the gateway
/// remembers the wider scope itself, so the user is not asked again either way.
#derive(Eq, Debug)
pub(all) enum PermissionDecision {
  /// This request only.
  AllowOnce
  /// Every request for the current task.
  AllowTask
  /// Every request until the session ends.
  AllowSession
  /// Refuse this request.
  Deny
}

///|
pub extend PermissionDecision with Eq::{not_equal, equal}

///|
pub extend PermissionDecision with @moonbitlang/core/debug.Debug::{to_repr}

///|
pub fn PermissionDecision::to_token(self : PermissionDecision) -> String {
  match self {
    AllowOnce => "allow_once"
    AllowTask => "allow_task"
    AllowSession => "allow_session"
    Deny => "deny"
  }
}

///|
/// Parse a client-supplied decision token. Returns `None` for unknown tokens so
/// a newer client cannot silently approve something.
pub fn PermissionDecision::from_token(token : String) -> PermissionDecision? {
  match token {
    "allow_once" => Some(AllowOnce)
    "allow_task" => Some(AllowTask)
    "allow_session" => Some(AllowSession)
    "deny" => Some(Deny)
    _ => None
  }
}

///|
/// True when the decision approves the operation.
pub fn PermissionDecision::allows(self : PermissionDecision) -> Bool {
  match self {
    Deny => false
    _ => true
  }
}

///|
/// A task backend behind the gateway.
///
/// Lifecycle: one instance per gateway session. `submit` runs one task and
/// pushes events into an internal queue; the caller runs it concurrently with
/// `next_event` when it wants to observe progress.
///
/// `submit` returns when the task finishes. `next_event` returns `None` only
/// after `close`.
pub(open) trait BackendPort {
  /// Prepare the backend before the first task, so the user does not pay the
  /// connection cost while waiting for an answer. Idempotent; safe to call
  /// concurrently with `submit`. Failures are reported when a task runs.
  async fn warmup(Self) -> Unit

  /// Run one task to completion, emitting events as they occur.
  async fn submit(Self, task_id : String, instruction : String) -> Unit

  /// Ask the in-flight task to stop. Idempotent.
  async fn cancel(Self, task_id : String) -> Unit

  /// Answer a `ToolCall`.
  async fn respond_tool(Self, call_id : String, output : String) -> Unit

  /// Answer a `PermissionRequest`. Idempotent; unknown IDs are ignored.
  async fn respond_permission(
    Self,
    request_id : String,
    decision : PermissionDecision,
  ) -> Unit

  /// Block until the next event. `None` means the backend is closed.
  async fn next_event(Self) -> BackendEvent?

  /// Release resources. Idempotent.
  async fn close(Self) -> Unit
}
