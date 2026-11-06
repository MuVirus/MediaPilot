///|
/// Workspace policy for one gateway process.
///
/// A workspace is only meaningful for backends that touch the filesystem (ACP).
/// Clients may pick any existing absolute directory; there is no configured
/// allowlist. The choice is made in `session.hello` and fixed for the session.
/// Switching directories means closing the connection and reconnecting.
pub struct Workspaces {
  default_root : String
}

///|
/// A deployment without a default directory. Only backends that require a
/// workspace call `resolve`, so this is still safe to use.
pub fn Workspaces::disabled() -> Workspaces {
  { default_root: "", }
}

///|
pub fn Workspaces::new(default_root : String) -> Workspaces {
  { default_root, }
}

///|
pub fn Workspaces::default_root(self : Workspaces) -> String {
  self.default_root
}

///|
/// Resolve a client request to an absolute directory.
///
/// - `""` selects the deployment default.
/// - Any other value must be an absolute, existing directory.
pub async fn Workspaces::resolve(
  self : Workspaces,
  requested : String,
) -> Result[String, String] {
  let trimmed = requested.trim().to_owned()
  if trimmed == "" {
    return Ok(self.default_root)
  }
  resolve_directory(trimmed)
}
