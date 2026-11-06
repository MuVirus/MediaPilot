///|
/// One subdirectory returned by `GET /api/fs/list`.
pub struct FilesystemEntry {
  name : String
  path : String
}

///|
/// Maximum number of entries returned for one directory. A picker does not need
/// thousands of rows, and the bound keeps a huge directory from monopolizing the
/// response. `truncated` tells the client to narrow the path.
pub let fs_entry_limit : Int32 = 1000

///|
/// One directory listing. `parent` is `None` at a filesystem root.
pub struct DirectoryListing {
  path : String
  parent : String?
  entries : Array[FilesystemEntry]
  truncated : Bool
}

///|
/// True for a POSIX absolute path, a Windows drive path, or a UNC path.
/// Workspace requests never depend on the process directory, so relative paths
/// are rejected before touching the filesystem.
pub fn is_absolute_path(path : String) -> Bool {
  let value = path.trim()
  if value.has_prefix("/") || value.has_prefix("\\\\") {
    return true
  }
  if value.length() < 3 {
    return false
  }
  let drive = match value.get_char(0) {
    Some(ch) => {
      let code = ch.to_int()
      (code >= 65 && code <= 90) || (code >= 97 && code <= 122)
    }
    None => false
  }
  let separator = value[2:3]
  drive && value[1:2] == ":" && (separator == "/" || separator == "\\")
}

///|
/// The shortest valid root prefix for an absolute path.
///
/// - `C:\` (3) or `C:/` (3)
/// - `/` (1)
/// - `\\` (2) for a UNC path
fn root_prefix_length(path : String) -> Int32 {
  if path.has_prefix("\\\\") {
    return 2
  }
  if path.has_prefix("/") {
    return 1
  }
  if path.length() >= 3 && path[1:2] == ":" {
    return 3
  }
  0
}

///|
/// Remove trailing separators without turning a root into a drive letter or an
/// empty string.
fn trim_separators(path : String) -> String {
  let minimum = root_prefix_length(path)
  let mut end = path.length()
  while end > minimum && (path[end - 1:end] == "/" || path[end - 1:end] == "\\") {
    end = end - 1
  }
  path[:end].to_owned()
}

///|
/// Join a directory and a child name. The child is never an absolute path here.
pub fn join_entry_path(directory : String, name : String) -> String {
  if directory.has_suffix("/") || directory.has_suffix("\\") {
    directory + name
  } else if @async.platform is Windows {
    directory + "\\" + name
  } else {
    directory + "/" + name
  }
}

///|
/// The parent directory, or `None` when `path` is already a filesystem root.
pub fn parent_of(path : String) -> String? {
  let normalized = trim_separators(path)
  let minimum = root_prefix_length(normalized)
  if minimum == 0 || normalized.length() <= minimum {
    return None
  }
  let mut index = normalized.length() - 1
  while index >= minimum - 1 {
    let separator = normalized[index:index + 1]
    if separator == "/" || separator == "\\" {
      if index + 1 == minimum {
        return Some(normalized[:minimum].to_owned())
      }
      return Some(normalized[:index].to_owned())
    }
    index = index - 1
  }
  None
}

///|
/// Compare two names lexicographically. MoonBit's `String` ordering is shortlex
/// (length first), which would put `z` before `aa`; a directory picker should
/// read like a file manager instead.
fn compare_entry_names(left : String, right : String) -> Int32 {
  let left_length = left.length()
  let right_length = right.length()
  let limit = if left_length < right_length {
    left_length
  } else {
    right_length
  }
  let mut index = 0
  while index < limit {
    let left_code = match left.get_char(index) {
      Some(ch) => ch.to_int()
      None => 0
    }
    let right_code = match right.get_char(index) {
      Some(ch) => ch.to_int()
      None => 0
    }
    if left_code != right_code {
      return if left_code < right_code { -1 } else { 1 }
    }
    index = index + 1
  }
  left_length.compare(right_length)
}

///|
/// Resolve a requested directory to an absolute, existing folder.
///
/// The client may ask for any path on the machine: there is no configured
/// allowlist. Validation is limited to "absolute, exists, is a directory" so a
/// typo produces a clear error instead of an agent started in the wrong place.
pub async fn resolve_directory(path : String) -> Result[String, String] {
  let trimmed = path.trim().to_owned()
  if trimmed == "" {
    return Err("workspace is empty")
  }
  if !is_absolute_path(trimmed) {
    return Err("workspace must be an absolute path")
  }
  let resolved = @fs.realpath(trimmed) catch {
    _ => return Err("workspace does not exist: " + trimmed)
  }
  let kind = @fs.kind(resolved) catch {
    _ => return Err("workspace cannot be inspected: " + resolved)
  }
  match kind {
    @fs.FileKind::Directory => Ok(resolved)
    _ => Err("workspace is not a directory: " + resolved)
  }
}

///|
/// List the immediate subdirectories of `path`.
///
/// Files are omitted: a workspace picker only offers directories. Entries are
/// sorted by name and capped at `fs_entry_limit`.
pub async fn list_directory(path : String) -> Result[DirectoryListing, String] {
  let resolved = match resolve_directory(path) {
    Ok(path) => path
    Err(message) => return Err(message)
  }
  let dir = @fs.opendir(resolved) catch {
    _ => return Err("cannot read directory: " + resolved)
  }
  defer dir.close()
  let entries : Array[FilesystemEntry] = []
  let mut truncated = false
  try {
    while dir.next() is Some(entry) {
      if !entry.is_dir {
        continue
      }
      if entries.length() >= fs_entry_limit {
        truncated = true
        break
      }
      entries.push({
        name: entry.name,
        path: join_entry_path(resolved, entry.name),
      })
    }
  } catch {
    _ => return Err("cannot read directory: " + resolved)
  }
  entries.sort_by(compare_entry_names2)
  Ok({ path: resolved, parent: parent_of(resolved), entries, truncated, })
}

///|
fn compare_entry_names2(
  left : FilesystemEntry,
  right : FilesystemEntry,
) -> Int32 {
  compare_entry_names(left.name, right.name)
}

///|
/// The filesystem roots a client can start browsing from. Windows exposes every
/// drive that responds; other systems expose `/`.
pub async fn filesystem_roots() -> Array[FilesystemEntry] {
  let roots : Array[FilesystemEntry] = []
  if @async.platform is Windows {
    for code in 65..<91 {
      let letter = match code.to_char() {
        Some(ch) => ch.to_string()
        None => continue
      }
      let path = letter + ":\\"
      let exists = @fs.exists(path) catch { _ => false }
      if exists {
        roots.push({ name: path, path, })
      }
    }
  } else {
    roots.push({ name: "/", path: "/", })
  }
  roots
}

///|
/// The `GET /api/fs/roots` body. `default` lets any client open the picker at
/// the deployment's default workspace instead of guessing.
pub async fn roots_payload(default_root : String, enabled : Bool) -> Json {
  let roots : Array[Json] = []
  for root in filesystem_roots() {
    roots.push(
      Json::object({
        "name": Json::string(root.name),
        "path": Json::string(root.path),
      }),
    )
  }
  Json::object({
    "default": Json::string(default_root),
    "enabled": Json::boolean(enabled),
    "roots": Json::array(roots),
  })
}

///|
pub fn DirectoryListing::payload(self : DirectoryListing) -> Json {
  let entries : Array[Json] = []
  for entry in self.entries {
    entries.push(
      Json::object({
        "name": Json::string(entry.name),
        "path": Json::string(entry.path),
      }),
    )
  }
  Json::object({
    "path": Json::string(self.path),
    "parent": match self.parent {
      Some(parent) => Json::string(parent)
      None => Json::null()
    },
    "entries": Json::array(entries),
    "truncated": Json::boolean(self.truncated),
  })
}

///|
/// Percent-decode a query value. Browsers encode `D:\work` as
/// `D%3A%5Cwork`, so paths must be decoded before use. `+` is kept literal
/// because Windows paths may contain it.
pub fn percent_decode(value : String) -> String {
  if !value.contains("%") {
    return value
  }
  let length = value.length()
  let bytes : Array[Byte] = []
  let mut index = 0
  while index < length {
    let ch = value.get_char(index)
    match ch {
      Some('%') =>
        if index + 2 < length {
          match (value.get_char(index + 1), value.get_char(index + 2)) {
            (Some(high), Some(low)) =>
              match (hex_value(high), hex_value(low)) {
                (Some(high), Some(low)) => {
                  bytes.push((high * 16 + low).to_byte())
                  index = index + 3
                  continue
                }
                _ => ()
              }
            _ => ()
          }
          bytes.push((37).to_byte())
          index = index + 1
        } else {
          bytes.push((37).to_byte())
          index = index + 1
        }
      Some(character) => {
        for byte in @utf8.encode(character.to_string()) {
          bytes.push(byte)
        }
        index = index + 1
      }
      None => index = index + 1
    }
  }
  @utf8.decode_lossy(Bytes::from_array(bytes))
}

///|
fn hex_value(ch : Char) -> Int32? {
  let code = ch.to_int()
  if code >= 48 && code <= 57 {
    Some(code - 48)
  } else if code >= 65 && code <= 70 {
    Some(code - 55)
  } else if code >= 97 && code <= 102 {
    Some(code - 87)
  } else {
    None
  }
}
