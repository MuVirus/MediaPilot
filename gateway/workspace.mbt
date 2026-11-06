///|
/// The agent working directories this deployment allows, plus the directory a
/// client gets when it does not ask for one.
///
/// A client can never name an arbitrary path: `resolve` only accepts the exact
/// strings listed here. The list is fixed when the gateway starts; switching
/// directories means closing the session and connecting again with another
/// value.
pub struct Workspaces {
  roots : Array[String]
  default_root : String
}

///|
/// A deployment without workspace selection. `session.hello` must omit the
/// field (or send `""`), and `session.ready` echoes `""`.
pub fn Workspaces::disabled() -> Workspaces {
  { roots: [], default_root: "", }
}

///|
pub fn Workspaces::new(
  roots : Array[String],
  default_root : String,
) -> Workspaces {
  { roots, default_root, }
}

///|
pub fn Workspaces::roots(self : Workspaces) -> Array[String] {
  self.roots
}

///|
pub fn Workspaces::default_root(self : Workspaces) -> String {
  self.default_root
}

///|
/// True when the deployment advertised at least one directory.
pub fn Workspaces::is_enabled(self : Workspaces) -> Bool {
  self.roots.length() > 0
}

///|
/// Trim surrounding whitespace and trailing separators so `D:\work\` and
/// `D:\work` compare equal. The configured entry, not the request, is what a
/// session receives.
fn normalize_workspace(path : String) -> String {
  let mut current = path.trim().to_owned()
  while current.length() > 1 &&
        (current.has_suffix("/") || current.has_suffix("\\")) {
    current = current[:current.length() - 1].to_owned()
  }
  current
}

///|
/// Resolve a client request. `""` selects the deployment default. A non-empty
/// value must match one of the advertised directories.
pub fn Workspaces::resolve(
  self : Workspaces,
  requested : String,
) -> Result[String, String] {
  if requested.trim() == "" {
    return Ok(self.default_root)
  }
  let wanted = normalize_workspace(requested)
  for root in self.roots {
    if normalize_workspace(root) == wanted {
      return Ok(root)
    }
  }
  Err(
    "workspace is not allowed; choose one of the directories from GET /api/workspaces",
  )
}

///|
/// The `GET /api/workspaces` body.
///
/// These are filesystem paths, so the route is gated by the same token as
/// `/api/realtime` when one is configured. It never contains keys or session
/// state.
pub fn Workspaces::payload(self : Workspaces) -> Json {
  let roots : Array[Json] = []
  for root in self.roots {
    roots.push(Json::string(root))
  }
  Json::object({
    "default": Json::string(self.default_root),
    "workspaces": Json::array(roots),
  })
}

///|
pub fn Workspaces::json(self : Workspaces) -> String {
  self.payload().stringify()
}
