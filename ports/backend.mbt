///|
/// What a backend produces while it works on a task.
///
/// The gateway turns these into northbound events: `TextDelta`/`TextDone`
/// become speech, `ToolCall` and `PermissionRequest` become the P2 task and
/// authorization flow.
pub(all) enum BackendEvent {
  /// Incremental assistant text.
  TextDelta(text~ : String)
  /// The complete assistant text for this task.
  TextDone(text~ : String)
  /// The backend wants a tool executed. The gateway executes it and calls
  /// `respond_tool` with the result.
  ToolCall(call_id~ : String, name~ : String, arguments~ : String)
  /// The backend needs the user to approve an action before continuing.
  PermissionRequest(
    request_id~ : String,
    operation~ : String,
    description~ : String
  )
  /// The task failed. `retryable` follows the same rule as the wire contract.
  Failed(code~ : @protocol.ErrorCode, message~ : String, retryable~ : Bool)
  /// The task finished successfully. Always the last event of a submission.
  Completed
} derive(Eq, Debug)

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
  /// Run one task to completion, emitting events as they occur.
  async fn submit(Self, task_id : String, instruction : String) -> Unit

  /// Ask the in-flight task to stop. Idempotent.
  async fn cancel(Self, task_id : String) -> Unit

  /// Answer a `ToolCall`.
  async fn respond_tool(Self, call_id : String, output : String) -> Unit

  /// Answer a `PermissionRequest`. `allow` is the final decision.
  async fn respond_permission(Self, request_id : String, allow : Bool) -> Unit

  /// Block until the next event. `None` means the backend is closed.
  async fn next_event(Self) -> BackendEvent?

  /// Release resources. Idempotent.
  async fn close(Self) -> Unit
}
