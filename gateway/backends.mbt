///|
/// One backend the gateway can offer to a session.
pub(all) struct BackendEntry {
  id : String
  label : String
  /// True when this backend reads and writes files, so a session must choose a
  /// workspace. `llm` and `none` are false.
  requires_workspace : Bool
}

///|
/// The backends a deployment offers, plus the id used when a client does not
/// choose one. The catalog is built at startup from configuration; a client can
/// only select an id from this list, never an arbitrary command.
pub struct BackendCatalog {
  default_id : String
  entries : Array[BackendEntry]
}

///|
/// A catalog with no agent behind it. `none` is still selectable so a client
/// can explicitly ask for a voice-only session.
pub fn BackendCatalog::disabled() -> BackendCatalog {
  {
    default_id: "none",
    entries: [
      { id: "none", label: "无后台代理", requires_workspace: false, },
    ],
  }
}

///|
pub fn BackendCatalog::new(
  default_id : String,
  entries : Array[BackendEntry],
) -> BackendCatalog {
  { default_id, entries, }
}

///|
pub fn BackendCatalog::default_id(self : BackendCatalog) -> String {
  self.default_id
}

///|
pub fn BackendCatalog::entries(self : BackendCatalog) -> Array[BackendEntry] {
  self.entries
}

///|
pub fn BackendCatalog::find(
  self : BackendCatalog,
  id : String,
) -> BackendEntry? {
  for entry in self.entries {
    if entry.id == id {
      return Some(entry)
    }
  }
  None
}

///|
/// Resolve a client request. An empty id selects the deployment default; any
/// other id must be in the catalog.
pub fn BackendCatalog::resolve(
  self : BackendCatalog,
  requested : String,
) -> Result[BackendEntry, String] {
  let trimmed = requested.trim().to_owned()
  let id = if trimmed == "" { self.default_id } else { trimmed }
  match self.find(id) {
    Some(entry) => Ok(entry)
    None =>
      Err(
        "backend is not available; choose one of the ids from GET /api/backends",
      )
  }
}

///|
/// True when at least one backend uses a working directory. The filesystem
/// browser stays advertised either way, but clients can use this to avoid
/// showing a picker that cannot apply.
pub fn BackendCatalog::any_requires_workspace(self : BackendCatalog) -> Bool {
  for entry in self.entries {
    if entry.requires_workspace {
      return true
    }
  }
  false
}

///|
/// The `GET /api/backends` body.
pub fn BackendCatalog::payload(self : BackendCatalog) -> Json {
  let entries : Array[Json] = []
  for entry in self.entries {
    entries.push(
      Json::object({
        "id": Json::string(entry.id),
        "label": Json::string(entry.label),
        "requiresWorkspace": Json::boolean(entry.requires_workspace),
      }),
    )
  }
  Json::object({
    "default": Json::string(self.default_id),
    "backends": Json::array(entries),
  })
}

///|
pub fn BackendCatalog::json(self : BackendCatalog) -> String {
  self.payload().stringify()
}
