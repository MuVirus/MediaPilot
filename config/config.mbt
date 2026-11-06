///|
/// The product directory name used both in the working directory and in the
/// user's home directory.
pub let config_directory_name : String = ".media_pilot"

///|
/// The file a deployment is expected to edit inside the configuration root.
pub let config_file_name : String = "config.env"

///|
/// Configuration resolved from files and the process environment.
///
/// `values` may contain secrets, so never print it. `root` and `files` are safe
/// to log and are meant for startup diagnostics.
pub(all) struct LoadedConfig {
  root : String
  files : Array[String]
  values : Map[String, String]
}

///|
/// Read a configuration value. The process environment has already overridden
/// file values during loading.
pub fn LoadedConfig::get(self : LoadedConfig, key : String) -> String? {
  self.values.get(key)
}

///|
/// Read a configuration value, treating an empty value as absent.
pub fn LoadedConfig::get_or(
  self : LoadedConfig,
  key : String,
  fallback : String,
) -> String {
  match self.get(key) {
    Some(value) if value != "" => value
    _ => fallback
  }
}

///|
/// Join two path fragments without producing a doubled separator.
pub fn join_path(left : String, right : String) -> String {
  if left == "" {
    right
  } else if left.has_suffix("/") || left.has_suffix("\\") {
    left + right
  } else {
    left + "/" + right
  }
}

///|
/// Expand a leading `~` using the supplied home directory. Other values are
/// returned trimmed and unchanged; this deliberately does not expand `$VAR`.
pub fn expand_home(path : String, home : String) -> String {
  let trimmed = path.trim()
  if trimmed == "~" {
    home
  } else if trimmed.has_prefix("~/") || trimmed.has_prefix("~\\") {
    join_path(home, trimmed[2:].to_owned())
  } else {
    trimmed.to_owned()
  }
}

///|
/// The user's home directory, with Windows and POSIX variables both supported.
pub fn home_directory() -> String {
  let candidates = ["USERPROFILE", "HOME"]
  for key in candidates {
    match @env.get_env_var(key) {
      Some(value) if value != "" => return value
      _ => ()
    }
  }
  "."
}

///|
/// Pick the configuration root. `MEDIAPILOT_CONFIG_DIR` wins; otherwise the
/// working directory's `.media_pilot` wins when it exists, then the user's.
/// The working-directory path is the fallback when neither exists so the
/// startup hint points at a writable, obvious location.
///
/// There is deliberately no upward search for a project root: the working
/// directory is the only local scope. Run the gateway from the directory whose
/// `.media_pilot` it should read, or set `MEDIAPILOT_CONFIG_DIR`.
pub fn choose_root(
  cwd : String,
  home : String,
  explicit : String?,
  local_exists : Bool,
  user_exists : Bool,
) -> String {
  match explicit {
    Some(value) if value.trim() != "" => expand_home(value, home)
    _ => {
      let local_root = join_path(cwd, config_directory_name)
      if local_exists {
        local_root
      } else if user_exists {
        join_path(home, config_directory_name)
      } else {
        local_root
      }
    }
  }
}

///|
/// Append a path only once, preserving the caller's priority order.
fn push_unique(paths : Array[String], path : String) -> Unit {
  if !paths.contains(path) {
    paths.push(path)
  }
}

///|
/// Configuration files in priority order, highest first.
///
/// The local `.media_pilot/config.env` overrides the user-wide one for the same
/// key; missing keys fall back to the user-wide file. There is no `.env` or
/// `.env.local` compatibility input.
pub fn candidate_files(home : String, root : String) -> Array[String] {
  let paths : Array[String] = []
  push_unique(paths, join_path(root, config_file_name))
  push_unique(
    paths,
    join_path(home, config_directory_name + "/" + config_file_name),
  )
  paths
}

///|
/// Remove one matching pair of single or double quotes. No escape sequences are
/// interpreted, so a key's value is exactly what the file contains.
pub fn strip_quotes(value : String) -> String {
  let length = value.length()
  if length >= 2 &&
    (
      (value.has_prefix("\"") && value.has_suffix("\"")) ||
      (value.has_prefix("'") && value.has_suffix("'"))
    ) {
    value[1:length - 1].to_owned()
  } else {
    value
  }
}

///|
/// Parse dotenv-style text. Blank lines and `#` comments are ignored; an
/// optional `export ` prefix is accepted. Splitting happens on the first `=`.
pub fn parse_env_text(text : String) -> Array[(String, String)] {
  let entries : Array[(String, String)] = []
  for raw in text.split("\n") {
    let line = raw.trim()
    if line == "" || line.has_prefix("#") {
      continue
    }
    let body = if line.has_prefix("export ") { line[7:].trim() } else { line }
    match body.find("=") {
      Some(index) => {
        let key = body[:index].trim().to_owned()
        let value = strip_quotes(body[index + 1:].trim().to_owned())
        if key != "" {
          entries.push((key, value))
        }
      }
      None => ()
    }
  }
  entries
}

///|
/// Parse a strictly positive decimal integer. Used for limits so a malformed
/// value produces a clear startup error instead of a surprising `0`.
pub fn parse_positive_int(text : String) -> Int32? {
  let trimmed = text.trim()
  if trimmed == "" {
    return None
  }
  let mut value = 0
  for ch in trimmed.iter() {
    if !ch.is_ascii_digit() {
      return None
    }
    value = value * 10 + (ch.to_int() - 48)
  }
  if value <= 0 {
    None
  } else {
    Some(value)
  }
}

///|
/// Load configuration from a supplied working directory and home directory.
/// This is the testable form; `load_config` reads the real process state.
pub async fn load_from(
  cwd : String,
  home : String,
  explicit : String?,
) -> LoadedConfig {
  let local_exists = @fs.exists(join_path(cwd, config_directory_name)) catch {
    _ => false
  }
  let user_exists = @fs.exists(join_path(home, config_directory_name)) catch {
    _ => false
  }
  let root = choose_root(cwd, home, explicit, local_exists, user_exists)
  let values : Map[String, String] = Map([])
  let files : Array[String] = []
  for path in candidate_files(home, root) {
    let exists = @fs.exists(path) catch { _ => false }
    if exists {
      files.push(path)
      let text = @fs.read_text(path) catch { _ => "" }
      for entry in parse_env_text(text) {
        if !values.contains(entry.0) {
          values.set(entry.0, entry.1)
        }
      }
    }
  }
  // Process environment always wins over files. This happens after loading so
  // a one-off `$env:KEY=...` override never needs editing a file.
  let process_env = @env.get_env_vars()
  for key in process_env.keys() {
    match process_env.get(key) {
      Some(value) => values.set(key, value)
      None => ()
    }
  }
  { root, files, values, }
}

///|
/// Load configuration for the running gateway.
pub async fn load_config() -> LoadedConfig {
  let cwd = match @env.current_dir() {
    Some(directory) => directory
    None => "."
  }
  let explicit = @env.get_env_var("MEDIAPILOT_CONFIG_DIR")
  load_from(cwd, home_directory(), explicit)
}
