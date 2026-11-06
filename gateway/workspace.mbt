///|
/// Workspace policy for one gateway process.
///
/// Clients may pick any existing absolute directory on the machine; there is no
/// configured allowlist. `enabled` is false for deployments without an ACP
/// backend, where a working directory has no meaning.
///
/// The choice is made in `session.hello` and fixed for the session. Switching
/// directories means closing the connection and reconnecting.
pub struct Workspaces {
  default_root : String
  enabled : Bool
}

///|
/// A deployment without workspace selection. `session.hello` must omit the
/// field (or send `""`), and `session.ready` echoes `""`.
pub fn Workspaces::disabled() -> Workspaces {
  { default_root: "", enabled: false, }
}

///|
pub fn Workspaces::new(default_root : String, enabled : Bool) -> Workspaces {
  { default_root, enabled, }
}

///|
pub fn Workspaces::default_root(self : Workspaces) -> String {
  self.default_root
}

///|
/// True when the deployment uses agent working directories at all.
pub fn Workspaces::is_enabled(self : Workspaces) -> Bool {
  self.enabled
}

///|
/// Resolve a client request to an absolute directory.
///
/// - `""` selects the deployment default (or `""` when disabled).
/// - Any other value must be an absolute, existing directory.
/// - Asking for a directory on a deployment that has no workspaces is denied.
pub async fn Workspaces::resolve(
  self : Workspaces,
  requested : String,
) -> Result[String, String] {
  let trimmed = requested.trim().to_owned()
  if trimmed == "" {
    return if self.enabled { Ok(self.default_root) } else { Ok("") }
  }
  if !self.enabled {
    return Err("this deployment does not use agent working directories")
  }
  resolve_directory(trimmed)
}
